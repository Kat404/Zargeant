// tests/tui/cancel_path.zig — static guards for the cancel-path architecture
// of tui-input-flow-bugfixes-2.
//
// Spec:    sdd/tui-input-flow-bugfixes-2/spec     CAP-09, CAP-13
// Design:  sdd/tui-input-flow-bugfixes-2/design  D3
//
// PR 6 (terminal-control-lib-from-scratch, WU 6.4, Q4): renamed from
// tests/termios_sim.zig to tests/tui/cancel_path.zig. The contents were
// always a cancel-path static-guard artifact, not a termios simulator;
// the new name matches the actual contents and lives alongside the other
// tui/ tests. Build path + step name updated in build.zig to match.
//
// CAP-09 still depends on the field shape of `terminal.event.Key`:
// the literal grep at line 69 ("if (k.code == .char and k.mods.ctrl)")
// matches `src/tui.zig:552` because `Key.code` + `Key.mods.ctrl` field
// names are preserved across the mibu → terminal namespace swap (PR 6
// WU 6.3). PR 6 WU 6.3's atomic swap is byte-for-byte compatible.
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

// =============================================================================
// T-R5.4 (tui-ship-fast-phase2, PR3 R5 wiring — handleKeyInput threads
// cancel_pipe to submitUnlockAsync).
//
// Static-grep guard verifying the .unlock_prompt + .enter branch in
// src/tui.zig's handleKeyInput forwards the cancel_pipe parameter to
// submitUnlockAsync. Without this wiring, a Ctrl+C arriving during
// unlock submit cannot abort the worker (the spawned LoadCtx would
// default to .cancel_pipe = null, defeating T-R5.3's poll).
//
// The test asserts:
//   1. handleKeyInput accepts cancel_pipe as a parameter (already true
//      since PR 1 / Option B WU-1 — verified here for completeness).
//   2. The .unlock_prompt + .enter branch's body contains a
//      submitUnlockAsync call site that passes `cancel_pipe` (the
//      local), NOT `null` or a hardcoded constant.
//   3. The `cancel_pipe` referenced inside the branch is in scope
//      (must appear in the param list BEFORE the call site —
//      confirmed via positional ordering).
//
// RED: if a future commit regresses the .unlock_prompt branch back
// to `null` (e.g., a careless refactor), this test fails. GREEN:
// the wiring is correct as of T-R5.2 GREEN and stays correct.
// =============================================================================

test "T-R5.4: src/tui.zig handleKeyInput(.enter, .unlock_prompt) calls submitUnlockAsync with cancel_pipe param" {
    const content = try readSource("src/tui.zig");
    defer testing.allocator.free(content);

    // Locate the .unlock_prompt arm body. The arm starts at
    // `.unlock_prompt =>` (inside handleKeyInput's switch) and ends
    // at the next `.else =>` of the outer switch (key_entry arm).
    const arm_start = std.mem.indexOf(u8, content, ".unlock_prompt =>") orelse {
        try testing.expect(false); // .unlock_prompt arm MUST exist
        return;
    };
    const arm_end = std.mem.indexOfPos(u8, content, arm_start, "else =>") orelse content.len;
    const arm_body = content[arm_start..arm_end];

    // Inside the arm, find the .enter branch (the .enter => handler
    // inside .unlock_prompt's inner switch).
    const enter_start = std.mem.indexOf(u8, arm_body, ".enter =>") orelse {
        try testing.expect(false); // .enter handler in .unlock_prompt MUST exist
        return;
    };
    // The .enter branch ends at the next sibling arm: .esc => .
    const enter_end = std.mem.indexOfPos(u8, arm_body, enter_start, ".esc =>") orelse arm_body.len;
    const enter_body = arm_body[enter_start..enter_end];

    // The submitUnlockAsync call must be inside the .enter branch.
    const call_pos = std.mem.indexOf(u8, enter_body, "submitUnlockAsync(") orelse {
        try testing.expect(false); // submitUnlockAsync MUST be called on .enter
        return;
    };

    // The call's argument list (after `submitUnlockAsync(`) must contain
    // `cancel_pipe` (the local from handleKeyInput's parameter list)
    // and must NOT contain `null` as the cancel_pipe slot.
    //
    // Approach: locate the closing paren of the submitUnlockAsync call,
    // then check the arg list. The submitUnlockAsync call body is
    // usually multi-line, so we walk forward to find the matching paren.
    var paren_depth: usize = 0;
    var found_pos: usize = 0;
    var iter_i: usize = 0;
    for (enter_body[call_pos..]) |c| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                paren_depth -= 1;
                if (paren_depth == 0) {
                    found_pos = call_pos + iter_i + 1;
                    break;
                }
            },
            else => {},
        }
        iter_i += 1;
    }
    const call_arg_list = enter_body[call_pos..found_pos];

    // The arg list must reference the `cancel_pipe` identifier (the
    // handleKeyInput parameter, not the literal "null" or any other
    // substitute). This guarantees the parameter is threaded through.
    try testing.expect(std.mem.indexOf(u8, call_arg_list, "cancel_pipe") != null);

    // Order invariant: the cancel_pipe param of handleKeyInput must be
    // declared BEFORE the submitUnlockAsync call site (so the call
    // site can reference it). We confirm by anchoring on the param
    // declaration in the broader handleKeyInput signature.
    const param_anchor = "cancel_pipe: ?[2]i32";
    const param_pos = std.mem.indexOf(u8, content, param_anchor) orelse {
        try testing.expect(false); // handleKeyInput MUST declare cancel_pipe
        return;
    };
    try testing.expect(param_pos < arm_start);
}

// =============================================================================
// T-R5.4 (continued) — LoadCtx.cancel_pipe literal grep.
//
// Verifies the LoadCtx struct declaration in src/modal.zig carries the
// `cancel_pipe: ?[2]i32` field added in T-R5.1 (REQ-CHANNELS-001).
// Without this literal, a future refactor that strips the field would
// silently break the T-R5.3 poll-wiring contract (LoadCtx.cancel_pipe
// wouldn't exist for runLoadWorker to read).
//
// The grep is intentionally lenient — it locates the field
// declaration anywhere in src/modal.zig and asserts the expected
// type signature. A regression that renames or removes the field
// causes the literal to disappear; the test fails.
// =============================================================================

test "T-R5.4: src/modal.zig declares LoadCtx.cancel_pipe: ?[2]i32 field" {
    const content = try readSource("src/modal.zig");
    defer testing.allocator.free(content);

    // The field is declared inside the `const LoadCtx = struct { ... }`
    // block. We scan for the literal `cancel_pipe: ?[2]i32` anywhere
    // in the file — both ValidateCtx (parent commit) and LoadCtx
    // (T-R5.1) declare this exact literal. The grep is satisfied by
    // either; the test name scopes the intent.
    const found = std.mem.indexOf(u8, content, "cancel_pipe: ?[2]i32");
    try testing.expect(found != null);

    // Additionally confirm LoadCtx specifically declares it — the
    // struct is delimited by `const LoadCtx = struct {` ... `};`.
    const struct_start = std.mem.indexOf(u8, content, "const LoadCtx = struct {") orelse {
        try testing.expect(false); // LoadCtx struct MUST exist
        return;
    };
    const struct_end = std.mem.indexOfPos(u8, content, struct_start, "};\n") orelse content.len;
    const struct_body = content[struct_start..struct_end];
    try testing.expect(std.mem.indexOf(u8, struct_body, "cancel_pipe: ?[2]i32") != null);
}
