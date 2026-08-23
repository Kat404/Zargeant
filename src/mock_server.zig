// test/mock_server.zig — Thread-per-connection mock HTTP server for tests.
//
// Spec:   sdd/api-client/spec   (id=276) §"Mock server binds ephemeral port"
// Design: sdd/api-client/design (id=277) §"test/mock_server.zig"
//
// PR 2 ships the mock server so end-to-end SSE tests can spin up a real
// HTTP responder on `127.0.0.1:0` (kernel-assigned port) without external
// dependencies. Each accepted connection gets its own worker thread that
// pulls the next queued fixture from the registry and writes it verbatim.
//
// Headless invariant: no writes to stdout/stderr (the mock server uses
// `std.os.linux.*` raw syscalls for accept/send, never touches fd 1/2).

const std = @import("std");

// =============================================================================
// Public types
// =============================================================================

/// Opaque handle returned by `start()`. Holds the listening socket fd, the
/// acceptor thread handle, and the registry of queued fixtures.
pub const Handle = struct {
    listen_fd: i32,
    port: u16,
    acceptor: ?std.Thread,
    threads: std.ArrayListUnmanaged(std.Thread) = .empty,
    /// FIFO queue of unnamed fixtures (drained by `sendBytes`). Backed by
    /// the existing test API; the runtime path uses the `named_fixtures`
    /// map keyed by id instead.
    fixtures: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Named registry (id → bytes). PR 1 (tui-runtime-integration #441,
    /// REQ-TUI-037): the runtime registers "default" fixture via
    /// registerFixture + serves it on demand via serveFixture. The FIFO
    /// path stays unchanged for the 96/96 api-client regression suite.
    named_fixtures: std.StringHashMapUnmanaged([]const u8) = .empty,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allocator: std.mem.Allocator,
    /// Spinlock protecting threads + fixtures. Test-grade: ok for low-contention
    /// fixtures appends, no syscall blocking.
    lock_state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// tui-input-bugfixes-1 (REQ-BUGFIX1-006 / D6): optional handshake
    /// delay in milliseconds. When > 0, the worker thread sleeps for
    /// this long before reading the request and serving bytes, allowing
    /// tests to drive Ctrl+C during a simulated handshake. Default 0 =
    /// no delay (preserves existing 96/96 api-client regression suite).
    cancel_delay_ms: u32 = 0,

    fn lock(self: *Handle) void {
        while (self.lock_state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Handle) void {
        _ = self.lock_state.store(0, .release);
    }

    pub fn deinit(self: *Handle) void {
        const allocator = self.allocator;
        self.stop_flag.store(true, .release);
        // Shutdown the listening socket to unblock accept() with EINVAL.
        _ = std.os.linux.shutdown(self.listen_fd, std.os.linux.SHUT.RDWR);
        _ = std.os.linux.close(self.listen_fd);
        // Accept thread may have been joined already by stop(); joining again
        // is UB. The `acceptor` slot is set to null on join to make this safe.
        if (self.acceptor) |t| {
            t.join();
            self.acceptor = null;
        }
        self.lock();
        var threads = self.threads;
        self.threads = .empty;
        var named = self.named_fixtures;
        self.named_fixtures = .empty;
        var fifo = self.fixtures;
        self.fixtures = .empty;
        self.unlock();
        for (threads.items) |t| t.join();
        threads.deinit(allocator);
        // Free any named fixtures still registered. The map owns both the
        // id (key) and the bytes (value); deinit only frees the map storage
        // itself, not the contents.
        var it = named.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        named.deinit(allocator);
        // Any fixtures still in the FIFO queue (not yet popped by a worker)
        // are owned by the Handle and freed here. Popped fixtures are owned
        // by their worker and freed in workerLoop.
        for (fifo.items) |f| allocator.free(f);
        fifo.deinit(allocator);
        // free the Handle itself.
        allocator.destroy(self);
    }
};

const Fixture = struct {
    bytes: []const u8,
};

// =============================================================================
// Public API
// =============================================================================

/// Bind to `127.0.0.1:0` (kernel-assigned ephemeral port), start the
/// acceptor thread. Returns a Handle that can be queried for the assigned
/// port and used to send canned bytes.
pub fn start(allocator: std.mem.Allocator) !*Handle {
    const sock = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (sock < 0) return error.SocketFailed;
    const fd: i32 = @intCast(sock);

    // Bind to 127.0.0.1:0. The `addr` field must be in network byte order.
    var addr: std.os.linux.sockaddr.in = .{
        .family = std.os.linux.AF.INET,
        .port = std.mem.nativeToBig(u16, 0),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const bind_rc: isize = @bitCast(std.os.linux.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
    if (bind_rc < 0) return error.BindFailed;

    // Listen.
    const listen_rc: isize = @bitCast(std.os.linux.listen(fd, 8));
    if (listen_rc < 0) return error.ListenFailed;

    // Read the assigned port.
    var sockname: std.os.linux.sockaddr.in = undefined;
    var sockname_len: std.os.linux.socklen_t = @sizeOf(@TypeOf(sockname));
    const getsockname_rc: isize = @bitCast(std.os.linux.getsockname(fd, @ptrCast(&sockname), &sockname_len));
    if (getsockname_rc < 0) return error.GetsocknameFailed;
    const assigned_port = std.mem.bigToNative(u16, sockname.port);

    const handle = try allocator.create(Handle);
    handle.* = .{
        .listen_fd = fd,
        .port = assigned_port,
        .acceptor = null,
        .allocator = allocator,
    };

    // Spawn the acceptor thread.
    const acceptor = try std.Thread.spawn(.{}, acceptorLoop, .{handle});
    handle.acceptor = acceptor;

    return handle;
}

// =============================================================================
// tui-input-bugfixes-1 (REQ-BUGFIX1-006 / D6): Config-aware overload of
// `start` that lets tests inject a deterministic handshake delay. The
// existing `start(allocator)` overload (above, lines 104-149) is preserved
// unchanged for back-compat with the 96/96 api-client regression suite.
// =============================================================================

/// Configurable knobs for `start(allocator, config)`. Every field defaults
/// to the historical behavior so callers passing `.{}` get exactly the
/// same wire output as the legacy `start(allocator)` overload.
pub const Config = struct {
    /// Optional handshake delay in milliseconds. When > 0, each worker
    /// thread sleeps for this long BEFORE pulling a fixture from the
    /// queue, blocking the connection long enough for tests to drive
    /// Ctrl+C during a simulated handshake. Default 0 = no delay.
    cancel_delay_ms: u32 = 0,
};

/// Bind to `127.0.0.1:0` (kernel-assigned ephemeral port), start the
/// acceptor thread with the given Config. The body intentionally mirrors
/// the legacy `start(allocator)` overload — these two entry points must
/// produce identical wire output when Config fields are at their defaults.
pub fn startWithConfig(allocator: std.mem.Allocator, config: Config) !*Handle {
    const sock = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (sock < 0) return error.SocketFailed;
    const fd: i32 = @intCast(sock);

    // Bind to 127.0.0.1:0. The `addr` field must be in network byte order.
    var addr: std.os.linux.sockaddr.in = .{
        .family = std.os.linux.AF.INET,
        .port = std.mem.nativeToBig(u16, 0),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const bind_rc: isize = @bitCast(std.os.linux.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
    if (bind_rc < 0) return error.BindFailed;

    // Listen.
    const listen_rc: isize = @bitCast(std.os.linux.listen(fd, 8));
    if (listen_rc < 0) return error.ListenFailed;

    // Read the assigned port.
    var sockname: std.os.linux.sockaddr.in = undefined;
    var sockname_len: std.os.linux.socklen_t = @sizeOf(@TypeOf(sockname));
    const getsockname_rc: isize = @bitCast(std.os.linux.getsockname(fd, @ptrCast(&sockname), &sockname_len));
    if (getsockname_rc < 0) return error.GetsocknameFailed;
    const assigned_port = std.mem.bigToNative(u16, sockname.port);

    const handle = try allocator.create(Handle);
    handle.* = .{
        .listen_fd = fd,
        .port = assigned_port,
        .acceptor = null,
        .allocator = allocator,
        .cancel_delay_ms = config.cancel_delay_ms,
    };

    // Spawn the acceptor thread.
    const acceptor = try std.Thread.spawn(.{}, acceptorLoop, .{handle});
    handle.acceptor = acceptor;

    return handle;
}

/// Queue bytes to be sent verbatim on the next accepted connection. Workers
/// pull from the FIFO queue.
pub fn sendBytes(handle: *Handle, bytes: []const u8) !void {
    const owned = try handle.allocator.dupe(u8, bytes);
    handle.lock();
    defer handle.unlock();
    try handle.fixtures.append(handle.allocator, owned);
}

/// Register a named fixture (id → bytes). PR 1 (tui-runtime-integration
/// #441, REQ-TUI-037): the runtime registers a "default" fixture via this
/// path; `serveFixture` is the explicit trigger that copies the named bytes
/// onto the FIFO queue. Multiple ids are stored in `named_fixtures`; the
/// FIFO `sendBytes` path stays unchanged for the 96/96 api-client suite.
pub fn registerFixture(handle: *Handle, id: []const u8, bytes: []const u8) !void {
    const owned_id = try handle.allocator.dupe(u8, id);
    const owned_bytes = try handle.allocator.dupe(u8, bytes);
    handle.lock();
    defer handle.unlock();
    // If id was already registered, free the prior bytes so we don't leak.
    if (namedFetchOwned(handle, owned_id)) |prev| {
        handle.allocator.free(prev);
    }
    handle.named_fixtures.put(handle.allocator, owned_id, owned_bytes) catch |err| {
        handle.allocator.free(owned_id);
        handle.allocator.free(owned_bytes);
        return err;
    };
}

/// ponytail: internal helper used by registerFixture to fetch+remove a
/// pre-existing entry. Keeps the deinit cleanup path self-contained.
fn namedFetchOwned(handle: *Handle, id: []const u8) ?[]const u8 {
    if (handle.named_fixtures.fetchRemove(id)) |kv| {
        handle.allocator.free(kv.key);
        return kv.value;
    }
    return null;
}

/// Serve a registered fixture by id on the next accepted connection.
/// Looks up `id` in the named registry and copies the bytes onto the FIFO
/// queue. The worker pops the bytes off the queue and serves them verbatim.
/// Returns error.UnknownFixtureId when the id is not registered.
pub fn serveFixture(handle: *Handle, id: []const u8) !void {
    const bytes = blk: {
        handle.lock();
        defer handle.unlock();
        const gop = handle.named_fixtures.getEntry(id) orelse return error.UnknownFixtureId;
        break :blk gop.value_ptr.*;
    };
    try sendBytes(handle, bytes);
}

/// Return the kernel-assigned port the server is listening on.
pub fn port(handle: Handle) u16 {
    return handle.port;
}

/// Stop the server's accepting loop and join all worker threads WITHOUT
/// closing listen_fd. The caller MUST still call `deinit()` to release
/// OS resources.
pub fn stop(handle: *Handle) void {
    handle.stop_flag.store(true, .release);
    _ = std.os.linux.shutdown(handle.listen_fd, std.os.linux.SHUT.RDWR);
    if (handle.acceptor) |t| {
        t.join();
        handle.acceptor = null;
    }
    handle.lock();
    var threads = handle.threads;
    handle.threads = .empty;
    handle.unlock();
    for (threads.items) |t| t.join();
    threads.deinit(handle.allocator);
}

// =============================================================================
// Internal helpers
// =============================================================================

fn acceptorLoop(handle: *Handle) void {
    while (!handle.stop_flag.load(.acquire)) {
        var sockaddr: std.os.linux.sockaddr.in = undefined;
        var addr_len: std.os.linux.socklen_t = @sizeOf(@TypeOf(sockaddr));
        const accept_rc: isize = @bitCast(std.os.linux.accept(handle.listen_fd, @ptrCast(&sockaddr), &addr_len));
        if (accept_rc < 0) {
            // EINTR or EBADF (listen_fd closed) — exit cleanly.
            if (handle.stop_flag.load(.acquire)) return;
            continue;
        }
        const conn_fd: i32 = @intCast(accept_rc);
        const worker = std.Thread.spawn(.{}, workerLoop, .{ handle, conn_fd }) catch return;
        handle.lock();
        handle.threads.append(handle.allocator, worker) catch return;
        handle.unlock();
    }
}

fn workerLoop(handle: *Handle, conn_fd: i32) void {
    defer _ = std.os.linux.close(conn_fd);

    // tui-input-bugfixes-1 (REQ-BUGFIX1-006 / D6): if the handle was
    // constructed with a non-zero cancel_delay_ms, sleep BEFORE pulling
    // the fixture. This blocks the worker's accept loop for tests/cancel_e2e.zig
    // to drive Ctrl+C during a simulated handshake. The sleep uses
    // nanosleep directly (best-effort, no EINTR retry needed: the SIGINT
    // handler only writes to a pipe — it does not interrupt this worker).
    // ponytail: best-effort single-shot sleep. The test asserts cancel
    // latency < 100 ms (well below the 5000 ms delay), so nanosleep
    // jitter is irrelevant — if cancel fires, the test passes long
    // before this sleep returns.
    if (handle.cancel_delay_ms > 0) {
        var ts = std.os.linux.timespec{
            .sec = @intCast(@divFloor(handle.cancel_delay_ms, 1000)),
            .nsec = @intCast((handle.cancel_delay_ms % 1000) * std.time.ns_per_ms),
        };
        _ = std.os.linux.nanosleep(&ts, null);
    }

    // Pop the next fixture from the queue.
    handle.lock();
    if (handle.fixtures.items.len == 0) {
        handle.unlock();
        // PR 3 in-flight cancel test: hold the connection open until stop.
        // The client is expected to cancel or close the connection; we poll
        // for either until the server is stopped.
        holdConnectionUntilStop(handle, conn_fd);
        return;
    }
    const fixture = handle.fixtures.orderedRemove(0);
    handle.unlock();

    var written: usize = 0;
    while (written < fixture.len) {
        const n: isize = @bitCast(std.os.linux.write(conn_fd, fixture.ptr + written, fixture.len - written));
        if (n <= 0) break;
        written += @intCast(n);
    }

    // Free the fixture bytes now that we've sent them.
    handle.allocator.free(fixture);

    // Hold the connection open so the client can detect cancel via poll(2)
    // on [socket_fd, cancel_pipe[0]]. Without this, the worker would close
    // immediately and the client's read would return 0 (EOF) before the
    // cancel thread can write to the cancel-pipe.
    holdConnectionUntilStop(handle, conn_fd);
}

/// Polls `conn_fd` for incoming data, discarding anything the client sends,
/// until either the connection is closed by the peer OR the server's stop_flag
/// is set. This keeps the connection alive so the client can block in poll(2)
/// for cancel-pipe detection.
fn holdConnectionUntilStop(handle: *Handle, conn_fd: i32) void {
    var discard: [4096]u8 = undefined;
    while (!handle.stop_flag.load(.acquire)) {
        var pfds: [1]std.os.linux.pollfd = .{
            .{ .fd = conn_fd, .events = std.os.linux.POLL.IN, .revents = 0 },
        };
        const prc = std.os.linux.poll(&pfds, 1, 50);
        if (prc > 0xffff0000) break; // negative errno
        if (prc == 0) continue; // timeout, re-check stop_flag
        // Socket readable — read and discard. Stops on EOF (n == 0) or error.
        if ((pfds[0].revents & (std.os.linux.POLL.HUP | std.os.linux.POLL.ERR)) != 0) break;
        const n: isize = @bitCast(std.os.linux.read(conn_fd, &discard, discard.len));
        if (n <= 0) break;
    }
}

// =============================================================================
// Tests (5 mock-server tests — RED via compile if Handle/symbols missing)
// =============================================================================

const testing = std.testing;

test "bind and read assigned port" {
    const allocator = testing.allocator;
    var h = try start(allocator);
    defer h.deinit();

    const p = port(h.*);
    try testing.expect(p > 0);
}

test "send canned bytes" {
    const allocator = testing.allocator;
    var h = try start(allocator);
    defer h.deinit();

    const canned = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    try sendBytes(h, canned);

    // Connect to the server.
    const sock = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
    const fd: i32 = @intCast(sock);
    try testing.expect(fd >= 0);
    defer _ = std.os.linux.close(fd);

    var addr: std.os.linux.sockaddr.in = .{
        .family = std.os.linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port(h.*)),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const connect_rc = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try testing.expectEqual(@as(usize, 0), connect_rc);

    // Give the worker a moment to spawn and write.
    var ts = std.os.linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);

    var buf: [256]u8 = undefined;
    const read_rc: isize = @bitCast(std.os.linux.read(fd, &buf, buf.len));
    try testing.expect(read_rc > 0);
    try testing.expectEqualStrings(canned, buf[0..@intCast(read_rc)]);
}

test "multiple fixtures per server" {
    const allocator = testing.allocator;
    var h = try start(allocator);
    defer h.deinit();

    try sendBytes(h, "FIRST");
    try sendBytes(h, "SECOND");
    try sendBytes(h, "THIRD");

    const expected_fixtures = [_][]const u8{ "FIRST", "SECOND", "THIRD" };
    for (expected_fixtures) |expected| {
        const sock = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
        const fd: i32 = @intCast(sock);
        try testing.expect(fd >= 0);
        defer _ = std.os.linux.close(fd);

        var addr: std.os.linux.sockaddr.in = .{
            .family = std.os.linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port(h.*)),
            .addr = std.mem.nativeToBig(u32, 0x7F000001),
            .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };
        const connect_rc = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try testing.expectEqual(@as(usize, 0), connect_rc);

        var buf: [64]u8 = undefined;
        const n = std.os.linux.read(fd, &buf, buf.len);
        try testing.expectEqualStrings(expected, buf[0..@intCast(n)]);
    }
}

test "stop releases the port" {
    const allocator = testing.allocator;
    var h = try start(allocator);
    const p = port(h.*);
    h.deinit();

    // Subsequent connect to the same port should fail.
    const sock = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
    const fd: i32 = @intCast(sock);
    try testing.expect(fd >= 0);
    defer _ = std.os.linux.close(fd);

    var addr: std.os.linux.sockaddr.in = .{
        .family = std.os.linux.AF.INET,
        .port = std.mem.nativeToBig(u16, p),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const connect_rc = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try testing.expect(connect_rc != 0);
}

test "thread-per-connection worker exits on stop" {
    const allocator = testing.allocator;
    var h = try start(allocator);
    defer h.deinit();

    // Stop and assert thread list is empty (workers joined).
    stop(h);
    try testing.expectEqual(@as(usize, 0), h.threads.items.len);
}
