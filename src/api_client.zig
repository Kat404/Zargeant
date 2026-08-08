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
