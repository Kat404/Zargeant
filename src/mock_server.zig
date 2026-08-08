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
// Public types — STUB (PR 2 commit 3 RED)
// =============================================================================

pub const Handle = struct {
    _placeholder: u8 = 0,
};

pub fn start(allocator: std.mem.Allocator) !*Handle {
    _ = allocator;
    return error.NotImplemented;
}

pub fn sendBytes(handle: *Handle, bytes: []const u8) !void {
    _ = handle;
    _ = bytes;
    return error.NotImplemented;
}

pub fn registerFixture(handle: *Handle, id: []const u8, bytes: []const u8) !void {
    _ = handle;
    _ = id;
    _ = bytes;
    return error.NotImplemented;
}

pub fn port(handle: Handle) u16 {
    _ = handle;
    return 0;
}

pub fn stop(handle: *Handle) void {
    _ = handle;
}

pub fn deinit(handle: *Handle) void {
    _ = handle;
}

// =============================================================================
// Tests — PR 2 commit 3 RED (5 mock-server test blocks)
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

        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);

        var buf: [64]u8 = undefined;
        const read_rc: isize = @bitCast(std.os.linux.read(fd, &buf, buf.len));
        try testing.expectEqualStrings(expected, buf[0..@intCast(read_rc)]);
    }
}

test "stop releases the port" {
    const allocator = testing.allocator;
    var h = try start(allocator);
    const p = port(h.*);
    h.deinit();

    const fd = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
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

    stop(h);
    try testing.expectEqual(@as(usize, 0), h.threads.items.len);
}
