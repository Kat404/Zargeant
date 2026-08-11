// src/tui.zig -- TUI thread body + mibu lifecycle scaffold.
//
// Spec:   sdd/tui-recovery/spec  (id=407) REQ-TUI-002, REQ-TUI-003, REQ-TUI-015
// Design: sdd/tui-recovery/design (id=408) §2.3 (R-PR 1), §2.4
//
// R-PR 1 (this file):
//   - Replaces the libvaxis-era comptime canaries with real type aliases
//     (the canaries are still kept as the compile-time mibu-resolution
//     check used by tests/tui/mibu_smoke.zig).
//   - Adds `tuiThreadMain(args: *const runtime.ThreadArgs) void` — the
//     R-PR 1 stub that consumes `tui_to_agent` and returns on Shutdown.
//   - Real mibu lifecycle (enableRawMode, enterAlternateScreen, syncUpdate,
//     kitty keyboard push, SIGWINCH dual-path) lands in R-PR 4.
//
// Note: the runtime orchestrator in runtime.zig is the only place that
// launches a thread to run this function. tui.zig itself is forbidden
// from launching threads — the runtime's static-grep guard enforces this.
//
// Note: the runtime orchestrator in runtime.zig is the only place that
// calls the threading primitive to launch this function. tui.zig itself
// is forbidden from calling it — the runtime's static-grep guard enforces
// this invariant.
//
// R-PR 4 (future):
//   - Replace the stub body with the mibu render loop per design#408 §2.4.
//   - addImport("mibu", mibu_mod) is already wired to tui_mod in build.zig.
//
// Linux/x86_64 Zig 0.16 only — matches every other module in the project.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Linux-only comptime guard.
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("tui: linux-only v1 -- see sdd/tui/proposal id=373 constraint #5");
}

const mibu = @import("mibu");

// Touch the mibu public API surface at compile time so the dep is
// verified to resolve when tui_mod compiles. R-PR 4 replaces these
// references with the real TUI render loop (`term.enterAlternateScreen`,
// `term.enableRawMode`, `term.beginSynchronizedUpdate`, `events.nextWithTimeout`,
// `term.getSize`, `term.exitAlternateScreen`).
comptime {
    _ = mibu.term.RawTerm;
    _ = mibu.term.TermSize;
    _ = mibu.term.KittyFlags;
    _ = mibu.events.Event;
    _ = mibu.events.nextWithTimeout;
}

// =============================================================================
// TUI thread entry point (R-PR 1 stub).
//
// R-PR 1: no-op consumer of `tui_to_agent`. Exits on `Shutdown{}` or when
// the runtime's `shutdown_requested` atomic flag flips. R-PR 4 replaces
// the body with the mibu render loop per design#408 §2.4.
//
// The signature is fixed at the type level now so the runtime orchestrator
// can call it from its thread-launch site without churn in R-PR 4.
// =============================================================================

pub const ThreadArgs = struct {
    io: std.Io,
    channels: *@import("channels.zig").Channels,
    cancel_pipe: [2]i32,
    shutdown: *std.atomic.Value(bool),
};

/// TUI thread body (R-PR 1 stub). Drains `tui_to_agent` until either:
/// 1. A `Shutdown{}` event arrives — return immediately.
/// 2. The runtime's `shutdown_requested` atomic flag flips — return.
///
/// R-PR 4 replaces the body with the full mibu lifecycle (enableRawMode,
/// enterAlternateScreen, beginSynchronizedUpdate, events.nextWithTimeout).
/// The function signature and ThreadArgs struct stay the same.
pub fn tuiThreadMain(args: *const ThreadArgs) void {
    while (!args.shutdown.load(.seq_cst)) {
        if (args.channels.tui_to_agent.tryGet(args.io)) |event| {
            switch (event) {
                .Shutdown => return,
                else => continue,
            }
        }
        args.io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .real) catch {};
    }
}

// =============================================================================
// Tests (R-PR 1)
// =============================================================================

const testing = std.testing;

test "tui_mod compiles with mibu import (sanity)" {
    // The comptime block at the top of this file references mibu.term.RawTerm,
    // mibu.events.Event, mibu.events.nextWithTimeout, etc. If any of those
    // symbols are missing, the file fails to compile — so the act of
    // compiling the test step is the assertion. The test body just
    // confirms the file evaluated and reached the test block.
    //
    // ponytail: deeper symbol coverage lives in tests/tui/mibu_smoke.zig
    // (R-PR 4 expands that file to 5 tests). R-PR 1 keeps a single
    // sanity test to satisfy the "every src/*.zig has at least one test"
    // invariant without duplicating mibu_smoke's coverage.
    try testing.expect(true);
}

test "tuiThreadMain returns on Shutdown (consumes channels)" {
    // REQ-TUI-001 wiring — the TUI thread is the runtime's 3rd thread
    // and must consume `tui_to_agent`. Shutdown event triggers return.
    // ponytail: call tuiThreadMain directly (no thread spawn needed; the
    // tui.zig file is forbidden from spawning threads per the runtime's
    // "all threading lives in runtime.zig" invariant).
    var ch: @import("channels.zig").Channels = @import("channels.zig").Channels.init();
    defer ch.closeAll(testing.io);
    var shutdown = std.atomic.Value(bool).init(false);

    const args = ThreadArgs{
        .io = testing.io,
        .channels = &ch,
        .cancel_pipe = .{ -1, -1 },
        .shutdown = &shutdown,
    };

    // Push Shutdown before invoking so the loop exits on first iteration.
    try ch.tui_to_agent.tryPut(testing.io, .Shutdown);

    tuiThreadMain(&args);
    // Channel was drained by the function.
    try testing.expectEqual(@as(usize, 0), ch.tui_to_agent.len());
}

test "tuiThreadMain returns when shutdown flag is set" {
    // When no Shutdown event arrives, the function polls the atomic
    // shutdown flag. Setting the flag before invocation makes the
    // function return immediately (the while-loop guard fails first).
    var ch: @import("channels.zig").Channels = @import("channels.zig").Channels.init();
    defer ch.closeAll(testing.io);
    var shutdown = std.atomic.Value(bool).init(true);

    const args = ThreadArgs{
        .io = testing.io,
        .channels = &ch,
        .cancel_pipe = .{ -1, -1 },
        .shutdown = &shutdown,
    };

    tuiThreadMain(&args);
    try testing.expectEqual(@as(usize, 0), ch.tui_to_agent.len());
}
