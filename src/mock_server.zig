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
    fixtures: std.ArrayListUnmanaged([]const u8) = .empty,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allocator: std.mem.Allocator,
    /// Spinlock protecting threads + fixtures. Test-grade: ok for low-contention
    /// fixtures appends, no syscall blocking.
    lock_state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

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
        self.unlock();
        for (threads.items) |t| t.join();
        threads.deinit(allocator);
        // Any fixtures still in the queue (not yet popped by a worker) are
        // owned by the Handle and freed here. Popped fixtures are owned by
        // their worker and freed in workerLoop.
        for (self.fixtures.items) |f| allocator.free(f);
        self.fixtures.deinit(allocator);
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

/// Queue bytes to be sent verbatim on the next accepted connection. Workers
/// pull from the FIFO queue.
pub fn sendBytes(handle: *Handle, bytes: []const u8) !void {
    const owned = try handle.allocator.dupe(u8, bytes);
    handle.lock();
    defer handle.unlock();
    try handle.fixtures.append(handle.allocator, owned);
}

/// Register a named fixture (placeholder for v1; v2 will key by id).
pub fn registerFixture(handle: *Handle, id: []const u8, bytes: []const u8) !void {
    _ = id;
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

    // Pop the next fixture from the queue.
    handle.lock();
    if (handle.fixtures.items.len == 0) {
        handle.unlock();
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
