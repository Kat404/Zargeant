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
// Tests — PR 1 regression (T1.13) + PR 2 state machine (13 new tests)
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

// T2.3 — three chunks with growing cumulative content in a SINGLE feed call.
// PR 1's minimal parser only emits the FIRST event and clears the entire
// buffer, so the second feed("") call returns err. The full state machine
// must process all 3 events from one feed and buffer the remainder. RED.
test "three chunks growing content" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const combined =
        \\data: {"choices":[{"delta":{"content":"a"}}]}
        \\
        \\data: {"choices":[{"delta":{"content":"ab"}}]}
        \\
        \\data: {"choices":[{"delta":{"content":"abc"}}]}
        \\
        \\
    ;

    const ev1 = try p.feed(combined);
    try testing.expectEqualStrings("a", ev1.message.content);

    const ev2 = try p.feed("");
    try testing.expectEqualStrings("ab", ev2.message.content);

    const ev3 = try p.feed("");
    try testing.expectEqualStrings("abc", ev3.message.content);

    try testing.expectEqualStrings("abc", p.last_content.?);
}

// T2.3 — DONE sentinel terminates the stream and persists. When DONE arrives
// in the SAME feed as content, the parser must emit the content event first,
// then emit .done on the next feed call. PR 1's minimal parser clears the
// buffer after the content event, losing the DONE sentinel. RED.
test "DONE sentinel terminates" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const combined =
        \\data: {"choices":[{"delta":{"content":"hi"}}]}
        \\
        \\data: [DONE]
        \\
        \\
    ;

    const ev1 = try p.feed(combined);
    try testing.expectEqualStrings("hi", ev1.message.content);

    const ev2 = try p.feed("");
    try testing.expect(ev2 == .done);
}

// T2.3 — close-only termination (no [DONE] sentinel). After the last content
// event, the parser must return .done on a subsequent empty feed (simulating
// EOF). PR 1's minimal parser returns err.Unknown on empty feeds. RED.
test "close-only terminates" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const chunk =
        \\data: {"choices":[{"delta":{"content":"hi"}}]}
        \\
        \\
    ;
    _ = try p.feed(chunk);

    const ev = try p.feed("");
    try testing.expect(ev == .done);
}

// T2.3 — empty body (zero bytes) returns error.EmptyBody. PR 1's minimal
// parser returns Event.err.Unknown on empty feeds. RED via error mismatch.
test "empty body returns EmptyBody" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    try testing.expectError(error.EmptyBody, p.feed(""));
}

// T2.3 — partial JSON across TCP boundary. The JSON payload is split between
// two feed() calls. The parser must NOT return err.MalformedStream for the
// first half; it must return Event.pending and emit the assembled event on
// the second feed. PR 1's minimal parser clears the buffer after each call,
// so partial JSON is lost. RED.
test "partial JSON across TCP boundary" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const half1 = "data: {\"choices\":[{\"delta\":{\"content\":";
    const half2 = "\"hi\"}}]}\n\n";

    const r1 = try p.feed(half1);
    try testing.expect(r1 == .pending);

    const ev = try p.feed(half2);
    try testing.expectEqualStrings("hi", ev.message.content);
}

// T2.3 — multi-line data fields within one event join with newlines. SSE
// spec allows multiple `data:` lines per event; JSON parsers treat them as
// one JSON document with embedded newlines. PR 1's minimal parser extracts
// only the FIRST `data:` line and ignores the rest. RED.
test "multi-line data fields join with newline" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const multi =
        \\data: {"choices":[{"delta":{
        \\"content":"hello"
        \\}}]}
        \\
        \\
    ;

    const ev = try p.feed(multi);
    try testing.expectEqualStrings("hello", ev.message.content);
}

// T2.3 — malformed JSON returns an error event and the parser continues
// to process subsequent valid events. PR 1's minimal parser returns
// err.MalformedStream for malformed JSON but the buffer is corrupted —
// subsequent valid feeds fail because the buffer has stale garbage. RED.
test "malformed JSON returns error event, no panic" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const bad = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"";
    const ev1 = try p.feed(bad);
    try testing.expect(ev1 == .err);
    try testing.expectEqual(ErrorKind.MalformedStream, ev1.err.kind);

    const good =
        \\data: {"choices":[{"delta":{"content":"survivor"}}]}
        \\
        \\
    ;
    const ev2 = try p.feed(good);
    try testing.expectEqualStrings("survivor", ev2.message.content);
}

// T2.3 — non-UTF-8 byte inside a chunk must NOT panic or write out of
// bounds. The parser emits an error event and continues. PR 1's minimal
// parser returns err.MalformedStream but may hold stale buffer state.
// RED via recovery assertion.
test "non-UTF-8 byte returns error event, no panic" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    // Embed 0xFF 0xFE inside a string literal.
    const bad: []const u8 = &[_]u8{
        'd', 'a', 't', 'a',  ':',  ' ',
        '{', '"', 'c', 'h',  'o',  'i',
        'c', 'e', 's', '"',  ':',  '[',
        '{', '"', 'd', 'e',  'l',  't',
        'a', '"', ':', '{',  '"',  'c',
        'o', 'n', 't', 'e',  'n',  't',
        '"', ':', '"', 0xFF, 0xFE, '"',
        '}', '}', ']', '}',  '\n', '\n',
    };

    const ev1 = try p.feed(bad);
    try testing.expect(ev1 == .err);

    // After non-UTF-8 garbage, parser still works on valid input.
    const good =
        \\data: {"choices":[{"delta":{"content":"recovered"}}]}
        \\
        \\
    ;
    const ev2 = try p.feed(good);
    try testing.expectEqualStrings("recovered", ev2.message.content);
}

// T2.3 — reset-by-peer mid-stream. When the Agent thread sees a connection
// reset (ECONNRESET on read), it calls notifyReset() which emits a
// .err.ConnectionReset event. RED via compile error — notifyReset() does
// not exist in PR 1's minimal parser.
test "reset-by-peer returns ConnectionReset" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const chunk =
        \\data: {"choices":[{"delta":{"content":"partial"}}]}
        \\
        \\
    ;
    const ev1 = try p.feed(chunk);
    try testing.expectEqualStrings("partial", ev1.message.content);

    const ev2 = p.notifyReset();
    try testing.expect(ev2 == .err);
    try testing.expectEqual(ErrorKind.ConnectionReset, ev2.err.kind);
}

// T2.3 — chunked transfer encoding dechunker. Per RFC 7230 §4.1 the body
// is delivered as `<size-in-hex>\r\n<bytes>\r\n...0\r\n\r\n`. The
// Dechunker emits the dechunked bytes; downstream the SSE parser consumes
// them. RED via compile error — Dechunker struct does not exist in PR 1.
test "chunked transfer encoding dechunked" {
    var d = Dechunker.init(testing.allocator);
    defer d.deinit();

    const chunked =
        "5\r\nhello\r\n" ++
        "6\r\n world\r\n" ++
        "0\r\n\r\n";

    try d.feed(chunked);
    try testing.expectEqualStrings("hello world", d.output());
}

// T2.3 — 64 KiB single chunk (exactly 65,536 bytes) parses successfully.
// PR 1's minimal parser uses ArrayList with no size cap; the test asserts
// the parser does NOT truncate the content and does NOT panic. RED via
// the all-content assertion (current parser extracts only first 8 KB).
test "64 KiB single chunk parsed" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    // Build a chunk with 65,536 bytes of content payload.
    const padding = "_" ** 60000; // 60 KB padding inside JSON string
    const chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"" ++ padding ++ "\"}}]}\n\n";

    try testing.expect(chunk.len >= 65536);
    try testing.expect(chunk.len < 70000);

    const ev = try p.feed(chunk);
    try testing.expectEqualStrings(padding, ev.message.content);
}

// T2.3 — reasoning content surfaces as a separate .reasoning event when
// the chunk contains only reasoning_content (no content field). PR 1's
// minimal parser emits Event.reasoning only when content is absent AND
// last_reasoning is set from a prior chunk; this test isolates the
// single-chunk reasoning-only path. RED via second-event assertion in
// the same feed (subsequent feed must still work after reasoning emit).
test "reasoning content surfaces separately" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const reasoning_only =
        \\data: {"choices":[{"delta":{"reasoning_content":"<think>plan</think>"}}]}
        \\
        \\
    ;
    const ev1 = try p.feed(reasoning_only);
    try testing.expectEqualStrings("<think>plan</think>", ev1.reasoning.content);

    // Subsequent content event still works in the same parser.
    const content =
        \\data: {"choices":[{"delta":{"content":"hi"}}]}
        \\
        \\
    ;
    const ev2 = try p.feed(content);
    try testing.expectEqualStrings("hi", ev2.message.content);
}

// T2.3 — property test: 1000 randomized `data:` lines must NEVER panic,
// NEVER leave the parser in an unusable state, and MUST recover on a
// subsequent valid feed. PR 1's minimal parser accumulates buffer bytes
// for unrecognized inputs (no `data:` line) without bound. RED via the
// recovery assertion: a valid feed after fuzzing must succeed.
test "feed never panics on fuzzed input" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    var prng = std.Random.DefaultPrng.init(0xC0FFEE01);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var buf: [256]u8 = undefined;
        const len = prng.random().uintAtMost(usize, 256);
        const bytes = buf[0..len];
        for (bytes) |*b| b.* = prng.random().uintAtMost(u8, 255);
        _ = p.feed(bytes) catch {};
    }

    // After 1000 fuzzed feeds, the parser must still emit a valid event.
    const valid =
        \\data: {"choices":[{"delta":{"content":"survivor"}}]}
        \\
        \\
    ;
    const ev = try p.feed(valid);
    try testing.expectEqualStrings("survivor", ev.message.content);
}
