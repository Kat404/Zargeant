// tests/cancel_e2e.zig — cancel-path tests for the TUI.
//
// tui-input-bugfixes-1 WU-D landed the original e2e test
// (REQ-BUGFIX1-006) and the SIGINT install-order static-grep
// (REQ-BUGFIX1-002, since removed by WU-4).
//
// tui-input-flow-bugfixes-2:
//   - WU-3 (CAP-09) added a writer-side latency assertion — the
//     Ctrl+C key-event intercept at src/tui.zig writes 1 byte to
//     cancel_pipe[1] after setting shutdown; this test verifies the
//     byte is observable on cancel_pipe[0] within ≤1ms (POSIX kernel
//     roundtrip is microseconds).
//   - WU-4 (R2a) removed the SIGINT-handler static-grep test (CAP-R3)
//     because the SIGINT install was deleted from main.zig. The e2e
//     cancel-pipe test is RETAINED: it exercises api_auth's cancel
//     path end-to-end (validateViaApiWithTarget → cancel-pipe poll →
//     error.Cancelled), which is still the property the regression
//     test exists to guard.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Linux-only — matches every other module in the project.
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("cancel_e2e: linux-only v1");
}

const testing = std.testing;
const api_auth = @import("api_auth");
const mock_server = @import("mock_server");

// =============================================================================
// End-to-end cancel test (gated by env var)
// =============================================================================

/// Env var gate per obs#1382 testing strategy. Skipped in fast CI
/// (`zig build test`); runs in full `zig build verify`. The test owns
/// the only E2E flag in the project — keep the name stable across cycles.
const RUN_E2E_ENV = "ZARGEANT_RUN_TUI_CANCEL_E2E";

/// ponytail: zig 0.16 has no libc getenv(3) without `-lc`; copy the
/// /proc/self/environ trick from api_auth.zig:651 (readEnv). Reused here
/// instead of exposing api_auth.readEnv as `pub`.
fn readEnvVar(name: []const u8) ?[]const u8 {
    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        "/proc/self/environ",
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch return null;
    defer _ = std.os.linux.close(fd);

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    var idx: usize = 0;
    while (idx < total) {
        const slice = buf[idx..total];
        const rel_end = std.mem.indexOfScalar(u8, slice, 0);
        const end = if (rel_end) |r| idx + r else total;
        const entry = buf[idx..end];
        if (entry.len > name.len + 1 and entry[name.len] == '=') {
            if (std.mem.eql(u8, entry[0..name.len], name)) {
                return entry[name.len + 1 ..];
            }
        }
        idx = end + 1;
    }
    return null;
}

test "e2e: cancel_pipe[1] write cancels validateViaApiWithTarget within 1000ms (REQ-BUGFIX1-006)" {
    // Gated by env var so `zig build test` stays fast. Set
    // ZARGEANT_RUN_TUI_CANCEL_E2E=1 to enable (locally or in
    // `zig build verify`).
    if (readEnvVar(RUN_E2E_ENV) == null) {
        std.debug.print(
            "\n[cancel_e2e] SKIPPED — set {s}=1 to run end-to-end cancel test\n",
            .{RUN_E2E_ENV},
        );
        return;
    }

    // 1. Create cancel_pipe via std.os.linux.pipe (matches main.zig's
    //    pattern; cf. bridge_sync_async.zig:97 for prior art).
    var cancel_pipe: [2]i32 = .{ -1, -1 };
    {
        const rc = std.os.linux.pipe(&cancel_pipe);
        try testing.expectEqual(@as(usize, 0), rc);
    }
    defer {
        if (cancel_pipe[0] >= 0) _ = std.os.linux.close(cancel_pipe[0]);
        if (cancel_pipe[1] >= 0) _ = std.os.linux.close(cancel_pipe[1]);
    }

    // 2. Start mock_server with 5s handshake delay. The 5s window is
    //    wide enough that any cancel latency under 1000ms is
    //    unambiguous (the test asserts cancel arrives within 1000ms,
    //    not 100ms — generous margin for CI jitter).
    var handle = try mock_server.startWithConfig(
        std.heap.page_allocator,
        .{ .cancel_delay_ms = 5000 },
    );
    defer handle.deinit();
    const port = mock_server.MockServerPort(handle.*);

    // 3. Spawn a thread that writes a byte to cancel_pipe[1] after
    //    100ms. This simulates the SIGINT handler firing.
    const WriterCtx = struct {
        fd: i32,
        delay_ms: u32,
    };
    const writer_ctx = WriterCtx{ .fd = cancel_pipe[1], .delay_ms = 100 };
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(ctx: WriterCtx) void {
            var ts = std.os.linux.timespec{
                .sec = @intCast(@divFloor(ctx.delay_ms, 1000)),
                .nsec = @intCast((ctx.delay_ms % 1000) * std.time.ns_per_ms),
            };
            _ = std.os.linux.nanosleep(&ts, null);
            const byte: [1]u8 = .{0x01};
            _ = std.os.linux.write(ctx.fd, &byte, 1);
        }
    }.run, .{writer_ctx});

    // 4. Call validateViaApiWithTarget. With target_host="127.0.0.1"
    //    we enter the plain HTTP branch (needs_tls=false at
    //    api_auth.zig:194) which honors the cancel_pipe via poll(2).
    //    The mock_server worker is sleeping for 5000ms, so the
    //    client's write succeeds (kernel buffer) and the read loop
    //    blocks on poll([fd, cancel_pipe[0]], 100).
    const start_ns = std.Io.Clock.real.now(testing.io).nanoseconds;
    const result = api_auth.validateViaApiWithTarget(
        testing.io,
        std.heap.page_allocator,
        "sk-fake-test-key-32-chars-padding-x",
        "127.0.0.1",
        port,
        cancel_pipe,
    );
    const elapsed_signed: i96 = std.Io.Clock.real.now(testing.io).nanoseconds - start_ns;
    const elapsed_ns: u64 = if (elapsed_signed > 0) @intCast(elapsed_signed) else 0;
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    writer.join();

    // 5. Assert error.Cancelled within 1000ms (generous margin; the
    //    handler path is async-signal-safe write(2) + poll(2) latency,
    //    typically <50ms).
    try testing.expectError(error.Cancelled, result);
    try testing.expect(elapsed_ms < 1000);

    std.debug.print(
        "\n[cancel_e2e] PASS — error.Cancelled in {d} ms (mock port {d}, delay 5000 ms)\n",
        .{ elapsed_ms, port },
    );
}

// =============================================================================
// tui-input-flow-bugfixes-2 WU-3 (CAP-09 — R2a writer redirect).
//
// Verifies the new code path at src/tui.zig:553-555 (Ctrl+C key-event
// intercept writes 1 byte to cancel_pipe[1] after setting the shutdown
// atomic) is async-signal-safe and roundtrips within ≤1ms — REQ-NEW-006
// invariant is preserved at the writer side.
//
// The test exercises the EXACT write call from src/tui.zig:554 in a
// spawned thread, then polls cancel_pipe[0] with a 1ms timeout. The
// combined path (write + kernel buffer delivery + poll wakeup) MUST
// observe readability within ≤1ms; the existing 100ms tolerance on the
// e2e test above is end-to-end (handler + worker thread park + cancel
// propagation), whereas this is just the writer-side latency.
// =============================================================================

test "key-event intercept: write to cancel_pipe[1] is observable on cancel_pipe[0] within 1ms (CAP-09)" {
    // Always-on (not env-gated): the write is a single syscall; running
    // it in every CI cycle is cheap and proves the CAP-09 invariant.

    // 1. Create cancel_pipe (same call pattern as main.zig:206-218).
    var cancel_pipe: [2]i32 = .{ -1, -1 };
    {
        const rc = std.os.linux.pipe(&cancel_pipe);
        try testing.expectEqual(@as(usize, 0), rc);
    }
    defer {
        if (cancel_pipe[0] >= 0) _ = std.os.linux.close(cancel_pipe[0]);
        if (cancel_pipe[1] >= 0) _ = std.os.linux.close(cancel_pipe[1]);
    }

    // 2. Spawn a writer thread that mirrors the EXACT call from
    //    src/tui.zig:554 — std.os.linux.write(p[1], &.{0x01}, 1).
    //    We don't depend on tuiThreadLoop here because spinning up the
    //    full poll/mibu/render stack would dwarf the latency we're
    //    trying to measure; the writer call is byte-for-byte identical.
    const WriterCtx = struct {
        fd: i32,
    };
    const writer_ctx: WriterCtx = .{ .fd = cancel_pipe[1] };
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(ctx: WriterCtx) void {
            // Mirrors src/tui.zig:554 verbatim.
            _ = std.os.linux.write(ctx.fd, &.{0x01}, 1);
        }
    }.run, .{writer_ctx});

    // 3. Poll cancel_pipe[0] with a 1ms timeout. Assert readability
    //    arrives within ≤1ms (POSIX poll timeout is in milliseconds).
    var pfds: [1]std.os.linux.pollfd = .{.{
        .fd = cancel_pipe[0],
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    const start_ns = std.Io.Clock.real.now(testing.io).nanoseconds;
    // poll() takes a many pointer; coerce the single-item pointer.
    const poll_rc = std.os.linux.poll(@ptrCast(&pfds[0]), 1, 1); // 1ms timeout
    const elapsed_signed: i96 = std.Io.Clock.real.now(testing.io).nanoseconds - start_ns;
    const elapsed_ns: u64 = if (elapsed_signed > 0) @intCast(elapsed_signed) else 0;
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    writer.join();

    // 4. Drain the byte (so we don't leak fd buffer pressure on the
    //    next test in the same process if any).
    var read_buf: [1]u8 = undefined;
    _ = std.os.linux.read(cancel_pipe[0], &read_buf, 1);

    // 5. Assertions:
    //    a. poll returned 1 fd (readable)
    //    b. revents has POLL.IN set
    //    c. wall-clock elapsed < 1ms (kernel roundtrip is microseconds)
    try testing.expectEqual(@as(usize, 1), poll_rc);
    try testing.expect((pfds[0].revents & std.os.linux.POLL.IN) != 0);
    try testing.expect(elapsed_ms < 1);

    std.debug.print(
        "\n[cancel_e2e] CAP-09 PASS — cancel_pipe writer roundtrip in {d} ms\n",
        .{elapsed_ms},
    );
}
