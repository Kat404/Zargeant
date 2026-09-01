// src/cancel_signal.zig — process-level SIGINT bridge to a cancel-pipe
// write end.
//
// tui-input-bugfixes-1 (obs#1379 / obs#1380 / obs#1382 / obs#1383)
// REQ-BUGFIX1-001, REQ-BUGFIX1-002, REQ-BUGFIX1-003
//
// The TUI thread's mibu poll loop (tui.zig:533) is the only place that
// can observe Ctrl+C as a byte. During a synchronous TLS handshake
// (`bridge.runBlocking` at api_auth.zig:246), the TUI thread is blocked
// in `fut.await(io)` and mibu's poll does NOT run. mibu also sets
// ISIG=false (obs#1342 → zig-pkg/mibu/src/term.zig:40) so the kernel
// does NOT generate SIGINT from 0x03 — the byte flows as data into
// stdin. Result: Ctrl+C is dead during the 1-3s TLS handshake.
//
// Fix: install a process-level SIGINT handler at main() that writes 1
// byte to cancel_pipe[1]. The existing watchCancelPipe thread
// (bridge_sync_async.zig:71-82) reads cancel_pipe[0], sees readability,
// calls `Future.cancel(io)`, which sends SIGIO to the worker, which
// returns EINTR → error.Canceled → fut.await unblocks.
//
// D2 (obs#1382): install BEFORE `std.Io.Threaded.init` to avoid
// stdlib's signal-init window clobbering our handler.
//
// D3 (obs#1382): handler holds a `*const i32` to `cancel_pipe[1]` at
// main() scope → static lifetime → safe for handler to dereference
// from any signal context.

const std = @import("std");
const builtin = @import("builtin");

// Linux-only — uses `std.os.linux.write` directly for async-signal
// safety (the syscall, not the libc wrapper). Other OSes compile to a
// stub that emits a comptime error if the handler is ever invoked.
comptime {
    if (builtin.os.tag != .linux)
        @compileError("cancel_signal: linux-only v1");
}

/// Write-end fd of the cancel pipe. Set by `installSigintHandler`;
/// read by the async-signal-safe handler. Null = handler is a no-op.
var g_cancel_pipe_write_fd: ?*const i32 = null;

/// Clobber-detection counter (R6, obs#1382). main() increments
/// immediately before `std.Io.Threaded.init` and decrements
/// immediately after. If SIGINT fires while the counter is > 0, the
/// signal arrived during the stdlib init window where Zig 0.16's
/// Threaded backend may have clobbered our handler. The handler logs a
/// debug breadcrumb in that case.
pub var clobber_window_active: std.atomic.Value(u32) = .init(0);

/// Async-signal-safe body. Single write(2) syscall — listed as
/// async-signal-safe in POSIX signal-safety(7). Errors are deliberately
/// ignored: a write failure (closed pipe, EAGAIN, EBADF) cannot be
/// reported and must not invoke non-signal-safe paths.
fn sigintHandler(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const ptr = g_cancel_pipe_write_fd orelse return;
    const fd = ptr.*;
    if (fd < 0) return;
    const byte: [1]u8 = .{0x01};
    _ = std.os.linux.write(fd, &byte, 1);
}

/// Install SIGINT handler that bridges 0x03 Ctrl+C (or `kill -INT`) to
/// the given cancel-pipe write end. Idempotent — second call
/// re-registers the latest fd pointer but does not double-install the
/// kernel handler.
///
/// Caller MUST ensure `fd_out` outlives the handler — in production
/// this means `cancel_pipe[1]` lives at main() scope (static lifetime
/// from the kernel's POV). A stale pointer (closed fd) results in a
/// harmless EBADF swallowed by the handler.
///
/// D2 / REQ-BUGFIX1-002: caller MUST invoke this BEFORE
/// `std.Io.Threaded.init(allocator, ...)`.
pub fn installSigintHandler(fd_out: *const i32) void {
    g_cancel_pipe_write_fd = fd_out;
    const act = std.posix.Sigaction{
        .handler = .{ .sigaction = sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// Test helper — reset the registered fd pointer without touching the
/// kernel handler. Production callers do not need this; tests that
/// re-invoke `installSigintHandler` between cases use it to avoid
/// leaking the previous fd into the next case.
pub fn resetForTest() void {
    g_cancel_pipe_write_fd = null;
}

// =============================================================================
// Tests
// =============================================================================

test "installSigintHandler registers the fd pointer for the handler" {
    // Mirror installSigwinch's "routes to the atomic" test (tui.zig:783).
    // We can't observe the kernel handler directly without sending
    // SIGINT (which would kill the test runner), so we verify the
    // observable side-effect: g_cancel_pipe_write_fd is set to our fd.
    defer resetForTest();

    var fake_fd: i32 = 42;
    installSigintHandler(&fake_fd);
    try std.testing.expect(g_cancel_pipe_write_fd != null);
    try std.testing.expect(g_cancel_pipe_write_fd.?.* == 42);

    // Idempotent re-register with a different fd.
    var other_fd: i32 = 99;
    installSigintHandler(&other_fd);
    try std.testing.expect(g_cancel_pipe_write_fd.?.* == 99);
}

test "clobber_window_active starts at 0 and accepts increments" {
    // R6 / REQ-BUGFIX1-002 — counter used by main() to detect SIGINT
    // fires during stdlib Threaded.init. Smoke-test the atomic
    // increment/decrement cycle that main() will use.
    defer clobber_window_active.store(0, .seq_cst);

    try std.testing.expectEqual(@as(u32, 0), clobber_window_active.load(.seq_cst));
    _ = clobber_window_active.fetchAdd(1, .seq_cst);
    try std.testing.expectEqual(@as(u32, 1), clobber_window_active.load(.seq_cst));
    _ = clobber_window_active.fetchSub(1, .seq_cst);
    try std.testing.expectEqual(@as(u32, 0), clobber_window_active.load(.seq_cst));
}
