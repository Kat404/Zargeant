// src/api_sse.zig — SSE parser with cumulative-delta semantics.
//
// Spec:   sdd/api-client/spec   (id=276)
// Design: sdd/api-client/design (id=277)
//
// PR 1 ships the cumulative-delta regression test (locked early per Option C).
// The state machine dispatches one Event per feed() call. Each event reflects
// the latest `delta.content` (REPLACE-not-APPEND) — the TUI never concatenates
// chunks because the server sends cumulative deltas.
//
// Headless invariant: no writes to stdout/stderr.

const std = @import("std");
const testing = std.testing;

// =============================================================================
// Public types
// =============================================================================

pub const Message = struct {
    content: []const u8,
    raw: []const u8,
};

pub const Reasoning = struct {
    content: []const u8,
    raw: []const u8,
};

pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
    cached_tokens: u32,
};

pub const ErrorKind = enum {
    MalformedStream,
    InvalidUtf8,
    ConnectionReset,
    EmptyBody,
    UnsupportedHttpVersion,
    Unknown,
};

pub const StreamError = struct {
    kind: ErrorKind,
    raw_bytes: []const u8,
};

pub const Event = union(enum) {
    message: Message,
    reasoning: Reasoning,
    usage: Usage,
    done: void,
    err: StreamError,
};

/// Per-stream state. Owned by the parser. The state machine is intentionally
/// minimal: feed() appends to the buffer, scans for `data: ` lines, parses
/// JSON, extracts delta.content / delta.reasoning_content, and emits one
/// Event per call. Full state machine (`header → data → dispatch → header`)
/// + property tests land in PR 2.
pub const Parser = struct {
    buf: std.ArrayList(u8),
    arena: std.heap.ArenaAllocator,
    last_content: ?[]u8,
    last_reasoning: ?[]u8,
    done: bool,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return Parser{
            .buf = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .last_content = null,
            .last_reasoning = null,
            .done = false,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.buf.deinit(testing.allocator);
        self.arena.deinit();
        self.last_content = null;
        self.last_reasoning = null;
    }

    /// Append `bytes` to the buffer, return the next complete event. On
    /// success, returns Event.message with cumulative content (REPLACE
    /// previous last_content). On parse failure, returns Event.err with
    /// kind=.MalformedStream. PR 1's minimal implementation: process the
    /// first data line in the buffer, then clear the buffer. PR 2 adds
    /// the full state machine + cross-packet handling.
    pub fn feed(self: *Parser, bytes: []const u8) !Event {
        if (self.done) return .{ .done = {} };

        // Append to internal buffer.
        try self.buf.appendSlice(testing.allocator, bytes);

        // Find the FIRST `data: ` line in the buffer.
        const prefix = "data: ";
        const data_idx = std.mem.indexOf(u8, self.buf.items, prefix) orelse {
            return .{ .err = .{ .kind = .Unknown, .raw_bytes = "" } };
        };
        const json_start = data_idx + prefix.len;
        const json_end = std.mem.indexOfPos(u8, self.buf.items, json_start, "\n") orelse self.buf.items.len;
        const json = self.buf.items[json_start..json_end];

        // Honor `[DONE]` sentinel.
        if (std.mem.eql(u8, json, "[DONE]")) {
            self.done = true;
            self.buf.clearRetainingCapacity();
            return .{ .done = {} };
        }

        // CRITICAL: make a copy of `json` before clearing the buffer, since
        // the Event struct needs to hold a stable slice.
        const json_copy = try self.arena.allocator().dupe(u8, json);

        // Clear the buffer for the next feed (PR 1 minimal; PR 2 adds
        // cross-packet handling).
        self.buf.clearRetainingCapacity();

        // Parse JSON via std.json. Returns the parsed value + arena for
        // owned strings.
        var parsed = std.json.parseFromSlice(std.json.Value, self.arena.allocator(), json_copy, .{}) catch {
            return .{ .err = .{ .kind = .MalformedStream, .raw_bytes = json_copy } };
        };
        defer parsed.deinit();

        const value = parsed.value;
        const choices_node = value.object.get("choices") orelse {
            return .{ .err = .{ .kind = .MalformedStream, .raw_bytes = json_copy } };
        };
        if (choices_node != .array or choices_node.array.items.len == 0) {
            return .{ .err = .{ .kind = .MalformedStream, .raw_bytes = json_copy } };
        }
        const first_choice = choices_node.array.items[0];
        if (first_choice != .object) {
            return .{ .err = .{ .kind = .MalformedStream, .raw_bytes = json_copy } };
        }
        const delta_node = first_choice.object.get("delta") orelse {
            return .{ .err = .{ .kind = .MalformedStream, .raw_bytes = json_copy } };
        };
        if (delta_node != .object) {
            return .{ .err = .{ .kind = .MalformedStream, .raw_bytes = json_copy } };
        }

        // Extract reasoning_content if present.
        if (delta_node.object.get("reasoning_content")) |rc_node| {
            if (rc_node == .string) {
                const new_rc = try self.arena.allocator().dupe(u8, rc_node.string);
                self.last_reasoning = new_rc;
            }
        }

        // Extract content (the dominant field).
        if (delta_node.object.get("content")) |content_node| {
            if (content_node == .string) {
                const new_content = try self.arena.allocator().dupe(u8, content_node.string);
                // REPLACE the previous last_content (do NOT append).
                self.last_content = new_content;
                return .{ .message = .{
                    .content = new_content,
                    .raw = json_copy,
                } };
            }
        }

        // Content absent — was it a reasoning-only chunk?
        if (self.last_reasoning) |rc| {
            return .{ .reasoning = .{
                .content = rc,
                .raw = json_copy,
            } };
        }

        // Usage chunk?
        if (value.object.get("usage")) |usage_node| {
            if (usage_node == .object) {
                const u = parseUsage(usage_node);
                return .{ .usage = u };
            }
        }

        // No recognised field — emit error.
        return .{ .err = .{ .kind = .MalformedStream, .raw_bytes = json_copy } };
    }
};

// =============================================================================
// Internal helpers
// =============================================================================

fn parseUsage(usage_node: std.json.Value) Usage {
    var u = Usage{
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .cached_tokens = 0,
    };
    if (usage_node.object.get("prompt_tokens")) |n| {
        if (n == .integer) u.prompt_tokens = @intCast(n.integer);
    }
    if (usage_node.object.get("completion_tokens")) |n| {
        if (n == .integer) u.completion_tokens = @intCast(n.integer);
    }
    if (usage_node.object.get("total_tokens")) |n| {
        if (n == .integer) u.total_tokens = @intCast(n.integer);
    }
    if (usage_node.object.get("cached_tokens")) |n| {
        if (n == .integer) u.cached_tokens = @intCast(n.integer);
    }
    return u;
}

// =============================================================================
// Tests (1 regression test pinned to PR 1 per Task T1.13)
// =============================================================================

// T1.13 — cumulative-delta regression test. Non-negotiable guard against
// OpenAI-SDK-style concatenation. Two chunks with full cumulative content
// must emit ["hello", "hello world"] — NOT ["hello", " world"].
test "two chunks with cumulative content" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const chunk1 =
        \\data: {"id":"chatcmpl-REDACTED","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hello"}}]}
        \\
        \\
    ;

    const ev1 = try p.feed(chunk1);
    try testing.expectEqualStrings("hello", ev1.message.content);
    try testing.expectEqualStrings("hello", p.last_content.?);

    const chunk2 =
        \\data: {"id":"chatcmpl-REDACTED","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hello world"}}]}
        \\
        \\
    ;

    const ev2 = try p.feed(chunk2);
    try testing.expectEqualStrings("hello world", ev2.message.content);
    try testing.expectEqualStrings("hello world", p.last_content.?);
}
