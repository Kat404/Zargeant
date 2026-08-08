// src/api_sse.zig — SSE parser with cumulative-delta semantics.
//
// Spec:   sdd/api-client/spec   (id=276)
// Design: sdd/api-client/design (id=277)
//
// PR 1 ships the cumulative-delta regression test (locked early per Option C).
// The state machine + buffer management are stubbed here; the full
// implementation lands in PR 2 (commit 4). The regression test is the
// non-negotiable gate against OpenAI-SDK-style concatenation: chunks
// arriving with delta.content = "hello" then "hello world" must emit
// ["hello", "hello world"] — NOT ["hello", " world"].
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

/// Per-stream state. Owned by the parser; null after `done` or before
/// initial feed. REPLACE, not APPEND — each new chunk overwrites the
/// previous run-state. The TUI never concatenates chunks because the
/// server sends cumulative deltas.
pub const Parser = struct {
    /// Per-feed buffer (raw bytes fed so far). Owns the slice.
    buf: std.ArrayList(u8),
    arena: std.heap.ArenaAllocator,
    /// Last `delta.content` value (REPLACE-not-APPEND semantics).
    last_content: ?[]u8,
    /// Last `delta.reasoning_content` value (REPLACE-not-APPEND).
    last_reasoning: ?[]u8,
    /// Bound to determine whether the parser has produced a terminal event.
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

    pub fn feed(self: *Parser, bytes: []const u8) !Event {
        _ = self;
        _ = bytes;
        return error.NotImplemented;
    }
};

// =============================================================================
// Tests (1 regression test pinned to PR 1 per Task T1.13)
// =============================================================================

// T1.13 — cumulative-delta regression test. This is the non-negotiable
// guard against OpenAI-SDK-style concatenation. Two chunks with full
// cumulative content must emit ["hello", "hello world"].
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
