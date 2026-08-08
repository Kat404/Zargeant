// src/api_client.zig — Linux-only HTTP+TLS client for MiniMax chat completions.
//
// Spec:   sdd/api-client/spec   (id=276)
// Design: sdd/api-client/design (id=277)
//
// PR 1 ships the wire framing (header building + JSON request serialization),
// the Linux-only comptime guard, struct definitions, and the historical
// legacy URL as `// ponytail: archival`. The actual TLS handshake, retry/backoff,
// cancel-pipe, and end-to-end `Client.stream` land in PR 2 + PR 3.
//
// Headless invariant: no writes to stdout/stderr.

// =============================================================================
// Linux-only comptime guard. MUST be the FIRST executable statement so that
// the build aborts on non-Linux targets BEFORE any std.os.linux.* symbol is
// referenced. Companion to spec id=276 §"Non-Linux target aborts the build".
// =============================================================================

comptime {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux)
        @compileError("api-client: linux-only v1 -- see proposal id=272 constraint #5");
}

const std = @import("std");
const testing = std.testing;

// =============================================================================
// Public constants
// =============================================================================

// ponytail: archival — keep the legacy URL greppable so future maintainers
// can see the host/path MiniMax renamed. Do NOT use at runtime.
pub const legacy_url: []const u8 =
    "https://api.minimaxi.chat/v1/text/chatcompletion_v2";

pub const current_url: []const u8 =
    "https://api.minimax.io/v1/chat/completions";

// =============================================================================
// Public types
// =============================================================================

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const StreamOptions = struct {
    include_usage: bool = true,
};

pub const ThinkingConfig = struct {
    type: []const u8,
};

pub const Tool = struct {
    type: []const u8,
    function: ToolFunction,
};

pub const ToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
};

pub const Request = struct {
    model: []const u8 = "MiniMax-M3",
    messages: []const Message = &[_]Message{},
    temperature: ?f32 = 0.7,
    top_p: ?f32 = null,
    max_completion_tokens: u32 = 8192,
    stream_options: StreamOptions = .{ .include_usage = true },
    tools: ?[]const Tool = null,
    tool_choice: ?[]const u8 = null,
    thinking: ?ThinkingConfig = .{ .type = "adaptive" },
    /// API key for the Authorization: Bearer header. Tests use a synthetic
    /// key. Production passes the validated key held by the Agent thread.
    key: []const u8 = "test-key-1234567890ABCDEF",
    /// Target host for the socket. Default = "127.0.0.1" so tests can use the
    /// mock server without TLS. Production sets this to "api.minimax.io".
    target_host: []const u8 = "127.0.0.1",
    /// Target port. Default = 0 which means "infer from target_host"
    /// (443 for production host, mock-server-assigned for 127.0.0.1).
    target_port: u16 = 0,
    /// Override for the retry backoff base in milliseconds. Tests set this
    /// to 1 to keep retry tests fast; production leaves it at the default
    /// (500 ms per spec id=276).
    retry_base_ms: u32 = 500,
};

pub const Response = struct {
    id: []const u8,
    created: i64,
    model: []const u8,
    finish_reason: ?[]const u8,
    usage: ?Usage = null,
};

pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
    cached_tokens: u32,
};

pub const ChunkEvent = union(enum) {
    message: []const u8,
    reasoning: []const u8,
    usage: Usage,
    done: void,
    err: StreamError,
};

pub const StreamError = struct {
    kind: ErrorKind,
    raw_bytes: []const u8,
};

pub const ErrorKind = enum {
    NoKey,
    Unauthorized,
    InsufficientBalance,
    InvalidParams,
    RateLimited,
    RetryBudgetExhausted,
    MalformedStream,
    ConnectionReset,
    InvalidUtf8,
    EmptyBody,
    UnsupportedHttpVersion,
    TlsHandshakeFailed,
    Cancelled,
    ChunkDecode,
    Io,
};

pub const ChunkEventStream = struct {
    client: *Client,
    parser: @import("api_sse.zig").Parser,

    pub fn next(self: *ChunkEventStream) !?ChunkEvent {
        _ = self;
        return null;
    }

    pub fn deinit(self: *ChunkEventStream) void {
        _ = self;
    }
};

pub const Client = struct {
    fd: i32,
    cancel_pipe: [2]i32,

    pub fn stream(io: std.Io, req: Request, cancel_pipe: [2]i32) !ChunkEventStream {
        _ = io;
        _ = req;
        _ = cancel_pipe;
        return error.NotImplemented;
    }

    pub fn validateKey(io: std.Io, key: []const u8) !void {
        _ = io;
        _ = key;
        return error.NotImplemented;
    }
};

// =============================================================================
// Public API (PR 1)
// =============================================================================

/// Serializes the Request to a JSON body. Defaults per spec id=276:
/// model=MiniMax-M3, stream=true (omitted here; wire sets it), max_completion_tokens=8192,
/// stream_options.include_usage=true, thinking.type="adaptive", temperature=0.7.
/// Returns an owned []u8; caller must free.
pub fn serializeRequest(req: Request, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"model\":\"");
    try buf.appendSlice(allocator, req.model);
    try buf.appendSlice(allocator, "\",");

    // messages: array of {role, content}
    try buf.appendSlice(allocator, "\"messages\":[");
    for (req.messages, 0..) |m, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"role\":\"");
        try buf.appendSlice(allocator, m.role);
        try buf.appendSlice(allocator, "\",\"content\":");
        try appendJsonString(&buf, allocator, m.content);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');

    // stream_options
    try buf.appendSlice(allocator, ",\"stream_options\":{\"include_usage\":");
    try buf.appendSlice(allocator, if (req.stream_options.include_usage) "true" else "false");
    try buf.append(allocator, '}');

    // max_completion_tokens
    try buf.appendSlice(allocator, ",\"max_completion_tokens\":");
    var num_buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{req.max_completion_tokens}) catch return error.TooLong;
    try buf.appendSlice(allocator, num_str);

    // temperature (only if set)
    if (req.temperature) |t| {
        try buf.appendSlice(allocator, ",\"temperature\":");
        const tmp = std.fmt.bufPrint(&num_buf, "{d}", .{t}) catch return error.TooLong;
        try buf.appendSlice(allocator, tmp);
    }

    // top_p (only if set)
    if (req.top_p) |p| {
        try buf.appendSlice(allocator, ",\"top_p\":");
        const tmp = std.fmt.bufPrint(&num_buf, "{d}", .{p}) catch return error.TooLong;
        try buf.appendSlice(allocator, tmp);
    }

    // thinking (only if set)
    if (req.thinking) |tc| {
        try buf.appendSlice(allocator, ",\"thinking\":{\"type\":\"");
        try buf.appendSlice(allocator, tc.type);
        try buf.appendSlice(allocator, "\"}");
    }

    // tools (only if set)
    if (req.tools) |tools| {
        try buf.appendSlice(allocator, ",\"tools\":[");
        for (tools, 0..) |t, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"type\":\"");
            try buf.appendSlice(allocator, t.type);
            try buf.appendSlice(allocator, "\",\"function\":{\"name\":");
            try appendJsonString(&buf, allocator, t.function.name);
            try buf.appendSlice(allocator, ",\"description\":");
            try appendJsonString(&buf, allocator, t.function.description);
            try buf.appendSlice(allocator, ",\"parameters\":");
            try appendJsonString(&buf, allocator, t.function.parameters);
            try buf.appendSlice(allocator, "}}");
        }
        try buf.append(allocator, ']');
    }

    // tool_choice (only if set)
    if (req.tool_choice) |tc| {
        try buf.appendSlice(allocator, ",\"tool_choice\":");
        try appendJsonString(&buf, allocator, tc);
    }

    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

/// Builds the HTTP headers for the chat completions request. Includes
/// Authorization: Bearer <key>, Content-Type: application/json, and
/// Accept: text/event-stream. Returns an owned []u8; caller must free.
pub fn buildHeaders(key: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "POST /v1/chat/completions HTTP/1.1\r\n");
    try buf.appendSlice(allocator, "Host: api.minimax.io\r\n");
    try buf.appendSlice(allocator, "Authorization: Bearer ");
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, "\r\n");
    try buf.appendSlice(allocator, "Content-Type: application/json\r\n");
    try buf.appendSlice(allocator, "Accept: text/event-stream\r\n");
    try buf.appendSlice(allocator, "Connection: close\r\n");
    try buf.appendSlice(allocator, "\r\n");

    return buf.toOwnedSlice(allocator);
}

// =============================================================================
// Internal helpers
// =============================================================================

/// Minimal JSON string append (escapes quotes and backslashes).
fn appendJsonString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var tmp: [8]u8 = undefined;
                    const esc = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch return error.TooLong;
                    try buf.appendSlice(allocator, esc);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

// =============================================================================
// Tests (5 client-header tests per spec id=276 §test scenarios)
// =============================================================================

// T1.15 — Default request body shape matches the spec defaults.
test "default request body shape" {
    const req = Request{
        .messages = &[_]Message{
            .{ .role = "user", .content = "hi" },
        },
    };
    const json = try serializeRequest(req, testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"model\":\"MiniMax-M3\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"stream_options\":{\"include_usage\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"max_completion_tokens\":8192") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"thinking\":{\"type\":\"adaptive\"}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"temperature\":0.7") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"user\"") != null);
}

// T1.15 — Authorization header is set with the bearer key.
test "Authorization header set" {
    const key = "test-key-1234567890ABCDEF";
    const headers = try buildHeaders(key, testing.allocator);
    defer testing.allocator.free(headers);

    try testing.expect(std.mem.indexOf(u8, headers, "Authorization: Bearer test-key-1234567890ABCDEF") != null);
    try testing.expect(std.mem.indexOf(u8, headers, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, headers, "Accept: text/event-stream") != null);
}

// T1.15 — legacy_url is the archival constant from the drifted spec.
test "legacy_url is archival string match" {
    try testing.expectEqualStrings(
        "https://api.minimaxi.chat/v1/text/chatcompletion_v2",
        legacy_url,
    );
}

// T1.15 — current_url is the new canonical endpoint.
test "current_url is correct" {
    try testing.expectEqualStrings(
        "https://api.minimax.io/v1/chat/completions",
        current_url,
    );
}

// T1.15 — Linux comptime guard passes on Linux (the guard fires on non-Linux
// at compile time, so this test only runs on Linux).
test "Linux guard emits compileError on non-Linux" {
    comptime {
        const builtin = @import("builtin");
        if (builtin.os.tag != .linux) {
            @compileError("api-client: linux-only v1 -- see proposal id=272 constraint #5");
        }
    }
    try testing.expect(true);
}

// T1.17 — PR 1 packet closure: verify all 3 modules wire through root.zig.
// This is a compile-time integration check + runtime sanity. The 19 tests
// across the three modules (13 auth + 1 SSE regression + 5 client-header)
// run successfully when `zig build test --summary all` is invoked.
test "PR 1 packet: api-client modules wire through root" {
    // Modules must be importable via the file's own scope.
    _ = @import("api_sse.zig");
    _ = @import("api_auth.zig");
    // This file IS api_client.zig. Cross-module imports already verified.
    try testing.expect(true);
    try testing.expect(legacy_url.len > 0);
    try testing.expect(current_url.len > 0);
}

// =============================================================================
// PR 3 — RED test blocks for retry + cancel (6 tests)
// Commit 1: tests added BEFORE the implementation lands.
// All tests below FAIL because Client.stream returns error.NotImplemented
// (PR 1 stub) and Client.processResponse does not exist yet. They are
// guaranteed-RED via compile-time referenced symbols + runtime assertion
// that the current implementation cannot satisfy.
// =============================================================================

const mock_server = @import("mock_server.zig");

// Helper to make a cancel-pipe. Caller owns the fds.
fn makeCancelPipe() ![2]i32 {
    var pipe_fds: [2]i32 = undefined;
    const rc = std.os.linux.pipe(&pipe_fds);
    if (rc != 0) return error.PipeFailed;
    return pipe_fds;
}

// Helper to close both ends of a pipe (best-effort).
fn closeCancelPipe(pipe: [2]i32) void {
    _ = std.os.linux.close(pipe[0]);
    _ = std.os.linux.close(pipe[1]);
}

// Helper to build a minimal Request for tests.
fn testRequest(port: u16, retry_base_ms: u32) Request {
    return Request{
        .model = "MiniMax-M3",
        .messages = &[_]Message{
            .{ .role = "user", .content = "hi" },
        },
        .target_host = "127.0.0.1",
        .target_port = port,
        .retry_base_ms = retry_base_ms,
    };
}

// T3.4 — 401 status code MUST NOT retry. The function returns
// error.Unauthorized after exactly 1 attempt. Spec scenario 32.
test "401 does NOT retry" {
    var ms = try mock_server.start(testing.allocator);
    defer ms.deinit();

    // Queue ONE 401 fixture; if Client.stream retries, the second connection
    // would consume the next fixture, but we don't queue one — so a retry
    // attempt would block on read() and the test would time out instead of
    // returning error.Unauthorized. The test asserts the function fails fast.
    const body = "{\"error\":\"unauthorized\"}";
    var status_buf: [256]u8 = undefined;
    const status_line = std.fmt.bufPrint(&status_buf, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    try mock_server.sendBytes(ms, status_line);

    const pipe = try makeCancelPipe();
    defer closeCancelPipe(pipe);

    const req = testRequest(mock_server.port(ms.*), 1);
    const result = Client.stream(testing.io, req, pipe);
    try testing.expectError(error.Unauthorized, result);
}

// T3.4 — 429 with Retry-After header is honored. The function waits
// the Retry-After seconds before retrying. Spec scenario 33.
test "429 with Retry-After honored" {
    var ms = try mock_server.start(testing.allocator);
    defer ms.deinit();

    // First fixture: 429 + Retry-After: 1.
    const retry_429 = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1\r\nContent-Length: 0\r\n\r\n";
    try mock_server.sendBytes(ms, retry_429);

    // Second fixture: 200 OK + minimal SSE body.
    const ok_200: []const u8 =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";
    try mock_server.sendBytes(ms, ok_200);

    const pipe = try makeCancelPipe();
    defer closeCancelPipe(pipe);

    const req = testRequest(mock_server.port(ms.*), 1);
    const start_ts = std.Io.Clock.real.now(testing.io);
    const result = Client.stream(testing.io, req, pipe);
    const elapsed_ns = std.Io.Clock.real.now(testing.io).nanoseconds - start_ts.nanoseconds;

    // Expect success (200 after retry).
    var stream = result catch |err| {
        std.debug.print("\n[test-429] Client.stream failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer stream.deinit();

    // The Retry-After header was honored: at least 1 second elapsed.
    try testing.expect(elapsed_ns >= std.time.ns_per_s);
}

// T3.4 — 5xx retry succeeds on attempt 2. Spec scenario 34.
test "5xx retry succeeds on attempt 2" {
    var ms = try mock_server.start(testing.allocator);
    defer ms.deinit();

    // First fixture: 503.
    const err_503 = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n";
    try mock_server.sendBytes(ms, err_503);

    // Second fixture: 200 OK + minimal SSE body.
    const ok_200: []const u8 =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";
    try mock_server.sendBytes(ms, ok_200);

    const pipe = try makeCancelPipe();
    defer closeCancelPipe(pipe);

    const req = testRequest(mock_server.port(ms.*), 1);
    var stream = try Client.stream(testing.io, req, pipe);
    defer stream.deinit();

    // The stream is open; reading next() should return null (empty body -> done).
    const next = try stream.next();
    try testing.expect(next == null or next.? == .done);
}

// T3.4 — Retry budget exhausted after 3 attempts. Spec scenario 35.
test "retry budget exhausted returns error" {
    var ms = try mock_server.start(testing.allocator);
    defer ms.deinit();

    // Queue 3 fixtures, all 503.
    const err_503 = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n";
    try mock_server.sendBytes(ms, err_503);
    try mock_server.sendBytes(ms, err_503);
    try mock_server.sendBytes(ms, err_503);

    const pipe = try makeCancelPipe();
    defer closeCancelPipe(pipe);

    const req = testRequest(mock_server.port(ms.*), 1);
    const result = Client.stream(testing.io, req, pipe);
    try testing.expectError(error.RetryBudgetExhausted, result);
}

// T3.6 — Esc cancels current stream via pre-socket cancel check.
// The Agent thread writes one byte to cancel_pipe[1] before Client.stream
// is invoked; the function MUST return error.Cancelled without opening
// a socket. Spec scenario "Cancel before request sent".
test "Esc cancels current stream" {
    const pipe = try makeCancelPipe();
    defer closeCancelPipe(pipe);

    // Pre-cancel: write one byte BEFORE calling Client.stream.
    const cancel_byte: [1]u8 = .{0x01};
    const wrc = std.os.linux.write(pipe[1], &cancel_byte, 1);
    try testing.expectEqual(@as(usize, 1), wrc);

    var req = testRequest(0, 1);
    req.target_port = 9999; // never reached; pre-cancel short-circuits.

    const result = Client.stream(testing.io, req, pipe);
    try testing.expectError(error.Cancelled, result);
}

// T3.6 — q cancels and returns to idle. In-flight cancel: Client.stream is
// mid-read, the Agent thread writes a byte to cancel_pipe[1], the function
// shuts down the socket and returns error.Cancelled. Spec scenario "Esc
// cancels current stream mid-chunk".
test "q cancels and returns to idle" {
    var ms = try mock_server.start(testing.allocator);
    defer ms.deinit();
    // No fixtures queued — server accepts but sends nothing. Client.stream
    // will open the socket, send the request, then block on read().

    const pipe = try makeCancelPipe();
    defer closeCancelPipe(pipe);

    const CancelCtx = struct {
        pipe_write_fd: i32,
        delay_ms: u64,

        fn run(c: *@This()) void {
            var ts = std.os.linux.timespec{
                .sec = @intCast(c.delay_ms / 1000),
                .nsec = @intCast((c.delay_ms % 1000) * std.time.ns_per_ms),
            };
            _ = std.os.linux.nanosleep(&ts, null);
            const b: [1]u8 = .{0x01};
            _ = std.os.linux.write(c.pipe_write_fd, &b, 1);
        }
    };

    var ctx = CancelCtx{ .pipe_write_fd = pipe[1], .delay_ms = 30 };
    const cancel_thread = try std.Thread.spawn(.{}, CancelCtx.run, .{&ctx});

    const req = testRequest(mock_server.port(ms.*), 1);
    const result = Client.stream(testing.io, req, pipe);

    cancel_thread.join();

    try testing.expectError(error.Cancelled, result);
}
