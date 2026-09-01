// tests/termios_sim.zig — CAP-09 writer-side wiring guard for
// tui-input-flow-bugfixes-2 WU-3.
//
// Spec:    sdd/tui-input-flow-bugfixes-2/spec     CAP-09
// Design:  sdd/tui-input-flow-bugfixes-2/design  D3
//
// CAP-13 full mibu/termios pty e2e (master→slave 0x03 → key parser →
// clean TUI exit ≤1s) is deferred to WU-5 per design D3 follow-up note
// (would need posix_openpt/grantpt/unlockpt + tcsetattr( ISIG=false ) +
// spawn TUI binary on pty — well beyond WU-3 line budget).
//
// What this file covers: the static invariant that the new pipe-write
// is present and ordered correctly inside the mibu key-event intercept
// at src/tui.zig. The runtime roundtrip is in tests/cancel_e2e.zig.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux)
        @compileError("termios_sim: linux-only v1");
}

const testing = std.testing;

test "static-grep: src/tui.zig Ctrl+C intercept writes 1 byte to cancel_pipe[1] (CAP-09)" {
    // CAP-09 invariant: the key-event intercept at src/tui.zig:552-562
    // MUST write 1 byte to cancel_pipe[1] AFTER setting the shutdown
    // atomic and BEFORE returning. This closes the mibu → cancel_pipe
    // gap that CAP-13 documents at the runtime layer.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/tui.zig",
        testing.allocator,
        .limited(1 << 20),
    );
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
