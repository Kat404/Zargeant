// src/bridge_sync_async.zig — sync→async bridge for stdlib networking.
//
// Per design obs#1369 + investigation docs/io-async-bug-investigation.md.
//
// tui-input-flow-bugfixes-2 WU-4 (R2a, CAP-R2): the side-thread
// watchCancelPipe that forwarded cancel_pipe[0] readability to
// Future.cancel(io) has been REMOVED. The watchdog called Future.cancel
// from a non-awaiter thread, which is stdlib UB per
// /usr/lib/zig/std/Io.zig:1190 ("Idempotent. Not threadsafe"). After R2a,
// the TUI validation path no longer calls runBlocking — the worker thread
// (CAP-11, WU-2) calls validateViaApiWithTarget directly. Cancel-pipe
// readability is observed by the worker via poll(2) inside api_client
// (api_client.zig:376 pollWithCancel), NOT by a side-thread watcher.
//
// The TUI's Ctrl+C keystroke writes 1 byte to cancel_pipe[1] via the
// key-event intercept at src/tui.zig:564 (CAP-09, WU-3). The worker
// observes the readable pipe within ≤100ms (REQ-NEW-006 invariant,
// verified by tests/termios_sim.zig and tests/cancel_e2e.zig).
//
// runBlocking + runBlockingStream are retained as the io.async+await
// wrappers used by api_auth.validateViaApiWithTarget (api_auth.zig:246).
// The cancel_pipe_read_fd parameter is now vestigial (no watcher reads
// it) but kept for source-compat with the api_auth caller; pass -1.
//
// ponytail: cancel_pipe is threaded from Runtime.cancel_pipe[0]
// (runtime.zig:222) — never created per call (REQ-NEW-006).

const std = @import("std");

pub const BridgeError = error{ Cancelled, BridgeFailed };

/// Run `f(args)` synchronously on the calling thread. `cancel_pipe_read_fd`
/// is vestigial after WU-4 (R2a removed the watcher thread); pass -1.
/// Returns `error.BridgeFailed` if `io.async` returns the eager-fallback
/// path (D9).
pub fn runBlockingStream(
    io: std.Io,
    cancel_pipe_read_fd: i32,
    f: anytype,
    args: anytype,
) (BridgeError || anyerror)!std.Io.net.Stream {
    return try runBlocking(io, cancel_pipe_read_fd, f, args);
}

/// Run `f(args)` synchronously on the calling thread. Generic — works for
/// any async fn return type (with or without error union). The result type
/// is inferred from `f`'s return type (which includes any error union).
/// Used by T3.2 (the TLS path in `validateViaApiWithTarget`).
///
/// ponytail: `cancel_pipe_read_fd` is no longer consumed (R2a / WU-4
/// removed watchCancelPipe). The worker that calls validateViaApiWithTarget
/// observes cancel_pipe[0] via poll(2) directly inside api_client.zig's
/// pollWithCancel. Kept as a parameter for source-compat.
pub fn runBlocking(
    io: std.Io,
    cancel_pipe_read_fd: i32,
    f: anytype,
    args: anytype,
) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    _ = cancel_pipe_read_fd; // vestigial after R2a (WU-4)
    const Result = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    var fut: std.Io.Future(Result) = io.async(f, args);
    defer cancelFuture(@TypeOf(fut), &fut, io);

    if (fut.any_future != null) {
        return try fut.await(io);
    }
    return error.BridgeFailed;
}

/// Cancel a pending Future. Idempotent (cancel on done Future is a no-op).
/// comptime branches on whether Result is an error union.
fn cancelFuture(comptime Fut: type, fut: *Fut, io: std.Io) void {
    if (fut.any_future == null) return;
    if (@typeInfo(@typeInfo(Fut).@"struct".fields[1].type) == .error_union) {
        _ = fut.cancel(io) catch {};
    } else _ = fut.cancel(io);
}

const testing = std.testing;

test "runBlockingStream propagates function error" {
    const FailingFn = struct {
        fn f(_: std.Io) anyerror!std.Io.net.Stream {
            return error.FailingForTest;
        }
    };
    try testing.expectError(error.FailingForTest, runBlockingStream(testing.io, -1, FailingFn.f, .{testing.io}));
}
