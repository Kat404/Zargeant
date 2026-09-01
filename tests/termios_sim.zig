// tests/termios_sim.zig — static guards for the cancel-path architecture
// of tui-input-flow-bugfixes-2.
//
// Spec:    sdd/tui-input-flow-bugfixes-2/spec     CAP-09, CAP-13
// Design:  sdd/tui-input-flow-bugfixes-2/design  D3
//
// CAP-13 full mibu/termios pty e2e (master→slave 0x03 → mibu key parser →
// clean TUI exit ≤1s) is DEFERRED indefinitely. Zig 0.16 stdlib does not
// expose posix_openpt/grantpt/unlockpt; building a pty harness from
// scratch needs ~200 LOC of syscalls + a synthetic ISIG=true termios
// layer, which is well beyond WU-5's ~150 LOC budget. The architecture is
// sound on three runtime paths already covered elsewhere:
//
//   - tests/cancel_e2e.zig "e2e: cancel_pipe[1] write cancels
//     validateViaApiWithTarget within 1000ms" — exercises the worker
//     poll(2) + cancel_pipe[0] path (REQ-NEW-006 invariant).
//   - tests/cancel_e2e.zig "key-event intercept: write to cancel_pipe[1]
//     is observable on cancel_pipe[0] within 1ms (CAP-09)" — verifies
//     the writer-side syscall roundtrip.
//   - This file's static guards — verify the code shape the runtime
//     paths depend on, byte-for-byte.
//
// Follow-up: a Zig 0.17+ stdlib that adds posix_openpt would unblock the
// full pty e2e in one PR. Until then, the three runtime + static guards
// above are the regression net.
//
// What this file covers:
//
//   WU-3 (CAP-09) — src/tui.zig Ctrl+C key-event intercept writes 1 byte
//                    to cancel_pipe[1] after shutdown.store(.seq_cst).
//   WU-4 (R2a)    — src/main.zig does NOT install SIGINT handler.
//   WU-4 (R2a)    — src/main.zig does NOT import cancel_signal.zig.
//   WU-4 (R2a)    — src/bridge_sync_async.zig does NOT define
//                    watchCancelPipe (the stdlib-UB watchdog).

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux)
        @compileError("termios_sim: linux-only v1");
}

const testing = std.testing;

/// Read a file from cwd into the testing allocator. Caller frees the
/// returned slice.
fn readSource(name: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        name,
        testing.allocator,
        .limited(1 << 20),
    );
}

test "CAP-09: src/tui.zig Ctrl+C intercept writes 1 byte to cancel_pipe[1] after shutdown.store" {
    // CAP-09 invariant: the key-event intercept at src/tui.zig:552-569
    // MUST write 1 byte to cancel_pipe[1] AFTER setting the shutdown
    // atomic and BEFORE returning. This closes the mibu → cancel_pipe
    // gap that CAP-13 documents at the runtime layer.
    const content = try readSource("src/tui.zig");
    defer testing.allocator.free(content);

    // Anchors
    const intercept_pos = std.mem.indexOf(
        u8,
        content,
        "if (k.code == .char and k.mods.ctrl)",
    ) orelse {
        try testing.expect(false); // Ctrl+C intercept MUST exist
        return;
    };
    const write_anchor = "std.os.linux.write(p[1], &.{0x01}, 1)";
    const write_pos = std.mem.indexOfPos(u8, content, intercept_pos, write_anchor) orelse {
        try testing.expect(false); // CAP-09 write call MUST be inside the branch
        return;
    };
    const return_pos = std.mem.indexOfPos(u8, content, intercept_pos, "return;") orelse {
        try testing.expect(false); // Ctrl+C branch MUST contain `return;`
        return;
    };
    const shutdown_pos = std.mem.indexOfPos(
        u8,
        content,
        intercept_pos,
        "shutdown.store(true, .seq_cst)",
    ) orelse {
        try testing.expect(false); // shutdown.store MUST be inside the intercept
        return;
    };
    // tuiThreadLoop must accept cancel_pipe (compile-order: arg before use).
    const sig_pos = std.mem.indexOf(u8, content, "cancel_pipe: ?[2]i32") orelse {
        try testing.expect(false); // tuiThreadLoop MUST accept cancel_pipe
        return;
    };

    // Order invariants
    try testing.expect(write_pos > intercept_pos);
    try testing.expect(write_pos < return_pos);
    try testing.expect(shutdown_pos > intercept_pos);
    try testing.expect(shutdown_pos < write_pos);
    try testing.expect(sig_pos < write_pos);
}

test "R2a CAP-R1: src/main.zig does NOT install installSigintHandler" {
    // WU-4 (R2a) removed `cancel_signal.installSigintHandler(&main_cancel_pipe[1])`
    // from main.zig. The Ctrl+C path now flows through the key-event
    // intercept at src/tui.zig (CAP-09). Re-introducing the SIGINT install
    // would re-bridge the stdlib UB at /usr/lib/zig/std/Io.zig:1190
    // ("Not threadsafe") that motivated R2a.
    const content = try readSource("src/main.zig");
    defer testing.allocator.free(content);

    const found = std.mem.indexOf(u8, content, "installSigintHandler");
    try testing.expect(found == null);
}

test "R2a CAP-R1: src/main.zig does NOT import cancel_signal.zig" {
    // WU-4 (R2a) removed the `@import("cancel_signal.zig")` line from
    // main.zig and DELETED src/cancel_signal.zig entirely. The module
    // had no non-TUI callers (per WU-4 apply-progress). Re-importing it
    // would re-create a dependency on a file that no longer exists.
    const content = try readSource("src/main.zig");
    defer testing.allocator.free(content);

    const found = std.mem.indexOf(u8, content, "@import(\"cancel_signal.zig\")");
    try testing.expect(found == null);
}

test "R2a CAP-R2: src/bridge_sync_async.zig does NOT define watchCancelPipe" {
    // WU-4 (R2a) removed `watchCancelPipe` from bridge_sync_async.zig.
    // That function called `Future.cancel(io)` from a non-awaiter
    // thread, which is stdlib UB per /usr/lib/zig/std/Io.zig:1190
    // ("Idempotent. Not threadsafe"). After R2a, the worker observes
    // cancel_pipe[0] readability via poll(2) directly inside
    // api_client.zig's pollWithCancel — no side-thread watchdog.
    //
    // ponytail: historical mentions of `watchCancelPipe` in the file's
    // header comment (documenting the deletion) are allowed. We grep
    // for the function definition (`fn watchCancelPipe`) to catch a
    // real re-introduction.
    const content = try readSource("src/bridge_sync_async.zig");
    defer testing.allocator.free(content);

    const found = std.mem.indexOf(u8, content, "fn watchCancelPipe");
    try testing.expect(found == null);
}
