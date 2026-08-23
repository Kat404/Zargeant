// test/fixtures_test.zig — Invariant test for the recorded fixture.
//
// Spec:   sdd/api-client/spec   (id=276) §"Recorded fixture has redacted key"
// Design: sdd/api-client/design (id=277) §"test/fixtures/minimax_stream.jsonl"
//
// PR 2 ships the recorded fixture (key REDACTED to `eyJ…[REDACTED]…`) plus a
// compile-time + runtime invariant that scans every fixture file under
// `test/fixtures/` for any real-shape API key (the `eyJ` JWT prefix followed
// by 32+ base64-ish characters). FAILS the build on any match.

const std = @import("std");
const testing = std.testing;
const mock_server = @import("mock_server.zig");
const api_sse = @import("api_sse.zig");

// T2.7 — Enforce the redaction invariant on every recorded fixture.
test "no real keys in fixtures" {
    const allocator = testing.allocator;
    const io = testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "test/fixtures", .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &[_][]const u8{ "test/fixtures", entry.name });
        defer allocator.free(path);

        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
        defer allocator.free(content);

        // Forbidden: any `eyJ[A-Za-z0-9._-]{32,}` pattern (real JWT-shaped keys).
        // Allowed: the literal redaction marker `eyJ…[REDACTED]…`.
        var idx: usize = 0;
        while (idx < content.len) {
            const remaining = content[idx..];
            const eyJ_idx = std.mem.indexOf(u8, remaining, "eyJ") orelse break;
            const absolute_eyJ = idx + eyJ_idx;

            // Allow `eyJ…[REDACTED]…` literal.
            if (std.mem.startsWith(u8, remaining[eyJ_idx..], "eyJ…[REDACTED]…")) {
                idx = absolute_eyJ + "eyJ…[REDACTED]…".len;
                continue;
            }

            // After `eyJ`, scan the next 64 chars for the suspicious base64 run.
            const after_prefix = remaining[eyJ_idx + 3 ..];
            var run_len: usize = 0;
            for (after_prefix) |c| {
                const is_base64ish = switch (c) {
                    'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => true,
                    else => false,
                };
                if (!is_base64ish) break;
                run_len += 1;
                if (run_len >= 64) break;
            }

            if (run_len >= 32) {
                std.debug.print("\n[grep-fail-fixtures] forbidden key-shape in {s} at offset {d}\n", .{ path, absolute_eyJ });
                return error.ForbiddenRealKeyInFixture;
            }

            idx = absolute_eyJ + 3 + run_len;
        }
    }
}

// T2.8 — Cumulative-delta regression verified end-to-end via the mock
// server. The fixture contains three SSE chunks whose `delta.content`
// values are "Hello", "Hello world", "Hello world!" — strictly growing
// (cumulative). The parser MUST emit `.message` events with exactly these
// values, NOT concatenate them. PR 1 verified this standalone via
// `api_sse.test "two chunks with cumulative content"`. This test verifies
// it through the full HTTP-mock → TCP → SSE-parser stack.
test "cumulative-delta regression end-to-end via mock server" {
    const allocator = testing.allocator;
    const io = testing.io;

    // Load fixture.
    const fixture_content = try std.Io.Dir.cwd().readFileAlloc(io, "test/fixtures/minimax_stream.jsonl", allocator, .limited(1 << 20));
    defer allocator.free(fixture_content);

    // Spin up mock server and queue the fixture.
    var h = try mock_server.start(allocator);
    defer h.deinit();
    try mock_server.sendBytes(h, fixture_content);

    // Connect to the server.
    // allowed: std.os.linux.socket — test-only loopback connection (fixtures_test.zig excluded from production grep)
    const sock = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
    const fd: i32 = @intCast(sock);
    try testing.expect(fd >= 0);
    defer _ = std.os.linux.close(fd);

    var addr: std.os.linux.sockaddr.in = .{
        .family = std.os.linux.AF.INET,
        .port = std.mem.nativeToBig(u16, mock_server.port(h.*)),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const connect_rc = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))); // allowed: std.os.linux.connect — test-only loopback
    try testing.expectEqual(@as(usize, 0), connect_rc);

    // Read all fixture bytes from the socket.
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < fixture_content.len) {
        const n: isize = @bitCast(std.os.linux.read(fd, &buf, buf.len));
        if (n <= 0) break;
        try received.appendSlice(allocator, buf[0..@intCast(n)]);
        total_read += @intCast(n);
    }

    // Feed to the SSE parser and collect .message events.
    var parser = api_sse.Parser.init(allocator);
    defer parser.deinit();

    var messages: [3][]const u8 = undefined;
    var message_count: usize = 0;

    var pos: usize = 0;
    while (pos < received.items.len) {
        // Feed in small chunks to exercise the partial-feed path.
        const chunk_size = @min(received.items.len - pos, 16);
        const ev = try parser.feed(received.items[pos..][0..chunk_size]);
        pos += chunk_size;
        switch (ev) {
            .message => |m| {
                if (message_count < 3) messages[message_count] = m.content;
                message_count += 1;
            },
            .pending => continue,
            .reasoning, .usage => continue,
            .done => break,
            .err => return error.StreamError,
        }
    }

    // Verify cumulative-delta semantics: the events are EXACTLY the three
    // growing strings — NOT concat fragments.
    try testing.expectEqual(@as(usize, 3), message_count);
    try testing.expectEqualStrings("Hello", messages[0]);
    try testing.expectEqualStrings("Hello world", messages[1]);
    try testing.expectEqualStrings("Hello world!", messages[2]);
}
