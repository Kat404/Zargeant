// src/bridge_sync_async.zig — sync→async bridge for stdlib networking.
//
// Per design obs#1369 + investigation docs/io-async-bug-investigation.md.
// Spawns a side-thread cancel watcher that forwards cancel_pipe[0]
// readability to Future.cancel(io) — which delivers SIGIO to the worker
// (Section 4.1). The blocking await(io) on the calling thread is woken
// by the futex signal triggered inside Future.cancel. No busy-poll, no
// atomic flag, no runBlockingVoid variant. ponytail: cancel_pipe is
// threaded from Runtime.cancel_pipe[0] (runtime.zig:222) — never created
// per call (REQ-NEW-006).

const std = @import("std");

pub const BridgeError = error{ Cancelled, BridgeFailed };

/// Run `f(args)` synchronously on the calling thread. `cancel_pipe_read_fd`
/// ≥ 0 spawns a watcher that calls Future.cancel(io) on pipe readability
/// (which SIGIO-interrupts the worker). Pass -1 to skip the watcher
/// (unit tests without a runtime). Returns `error.BridgeFailed` if
/// `io.async` returns the eager-fallback path (D9).
pub fn runBlockingStream(
    io: std.Io,
    cancel_pipe_read_fd: i32,
    f: anytype,
    args: anytype,
) (BridgeError || anyerror)!std.Io.net.Stream {
    var fut = io.async(f, args);
    defer cancelFuture(@TypeOf(fut), &fut, io);

    if (fut.any_future != null) {
        var watcher: ?std.Thread = null;
        if (cancel_pipe_read_fd >= 0) {
            watcher = std.Thread.spawn(.{}, watchCancelPipe, .{
                @TypeOf(fut), cancel_pipe_read_fd, &fut, io,
            }) catch null;
        }
        defer if (watcher) |w| w.join();
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

/// Side-thread watcher: polls `read_fd`; on readability, cancels the
/// Future. Exits on fd error (ERR/HUP/NVAL). Per Section 4.1, Future.cancel
/// invokes pthread_kill/tgkill → worker EINTR.
fn watchCancelPipe(comptime Fut: type, read_fd: i32, future: *Fut, io: std.Io) void {
    var pfds: [1]std.os.linux.pollfd = .{.{ .fd = read_fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
    while (true) {
        const n = std.os.linux.poll(&pfds, 1, -1);
        if (n == std.math.maxInt(usize)) break;
        if (pfds[0].revents & (std.os.linux.POLL.ERR | std.os.linux.POLL.HUP | std.os.linux.POLL.NVAL) != 0) break;
        if (pfds[0].revents & std.os.linux.POLL.IN != 0) {
            cancelFuture(Fut, future, io);
            break;
        }
    }
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

test "watchCancelPipe exits cleanly on HUP (write end closed)" {
    var p: [2]i32 = .{ -1, -1 };
    try testing.expectEqual(@as(usize, 0), std.os.linux.pipe(&p));
    _ = std.os.linux.close(p[1]);
    p[1] = -1;
    defer _ = std.os.linux.close(p[0]);
    const Fut = std.Io.Future(std.Io.net.Stream);
    var fut: Fut = .{ .any_future = null, .result = undefined };
    const t = try std.Thread.spawn(.{}, watchCancelPipe, .{ Fut, p[0], &fut, testing.io });
    t.join();
}
