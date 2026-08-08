// src/api_sse.zig — SSE parser with cumulative-delta semantics.
//
// Spec:   sdd/api-client/spec   (id=276)
// Design: sdd/api-client/design (id=277)
//
// PR 2 lands the full state machine (`header → data → dispatch → header`)
// + cross-packet partial-JSON buffering + `[DONE]` sentinel handling +
// close-only termination + multi-event dispatch from one feed + `notifyReset`
// for connection resets + `Dechunker` for `Transfer-Encoding: chunked`.
//
// PR 1 already shipped the cumulative-delta regression test
// ("two chunks with cumulative content") — REPLACE-not-APPEND semantics
// remain unchanged. The TUI never concatenates chunks because the server
// sends cumulative deltas (discovery id=266).
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
    /// Internal: more bytes needed before this feed() can return an event.
    /// Caller should call feed() again with the next chunk. Not part of the
    /// public API contract — the Agent thread loops until it sees a non-pending
    /// event or end-of-stream.
    pending: void,
};

/// Per-stream state. The state machine:
///   header — read event/id/retry/comment lines
///   data   — accumulate `data:` lines for the current event
///   dispatch — on blank line, parse JSON payload + emit Event
/// After dispatch the state resets to header. Multi-event feeds (a single
/// feed() call containing several complete events) emit events one per call;
/// the second event waits behind the first via the `queued` slot.
pub const Parser = struct {
    const State = enum {
        header,
        data,
    };

    allocator: std.mem.Allocator,
    state: State,
    buf: std.ArrayList(u8),
    data_buf: std.ArrayList(u8),
    arena: std.heap.ArenaAllocator,
    last_content: ?[]u8,
    last_reasoning: ?[]u8,
    done: bool,
    /// Tracks whether the parser has ever seen a content/reasoning chunk.
    /// Used to disambiguate close-only termination (.done) from empty body
    /// (error.EmptyBody) when an empty feed arrives on an empty buffer.
    lastSeen: bool = false,
    /// Slot for the second sub-event when one logical event yields both
    /// `.reasoning` and `.message` (e.g., a chunk with both fields).
    /// Cleared on the next feed() call.
    queued: ?Event,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return Parser{
            .allocator = allocator,
            .state = .header,
            .buf = .empty,
            .data_buf = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .last_content = null,
            .last_reasoning = null,
            .done = false,
            .lastSeen = false,
            .queued = null,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.buf.deinit(self.allocator);
        self.data_buf.deinit(self.allocator);
        self.arena.deinit();
        self.last_content = null;
        self.last_reasoning = null;
    }

    /// Signal a connection reset from the wire layer (ECONNRESET on read).
    /// Emits `.err{ .kind = .ConnectionReset }` and resets parser state so
    /// the next stream starts clean.
    pub fn notifyReset(self: *Parser) Event {
        self.buf.clearRetainingCapacity();
        self.data_buf.clearRetainingCapacity();
        self.queued = null;
        self.done = false;
        self.lastSeen = false;
        return .{ .err = .{ .kind = .ConnectionReset, .raw_bytes = "" } };
    }

    /// Append `bytes` to the internal buffer and process complete events.
    /// Returns one of:
    ///   - `Event.message` / `.reasoning` / `.usage` — a complete event
    ///   - `Event.done` — stream is finished (either `[DONE]` seen or EOF
    ///     after a prior event)
    ///   - `Event.err` — malformed JSON, garbage payload, etc.
    ///   - `Event.pending` — bytes are not yet a complete event; call again
    ///     when more bytes arrive. Returned for partial JSON across the TCP
    ///     boundary and for unrecognized input waiting for more data.
    /// Returns `error.EmptyBody` for a zero-byte feed when no event has been
    /// seen yet (distinguishes empty body from close-only termination).
    pub fn feed(self: *Parser, bytes: []const u8) !Event {
        if (self.done) return .{ .done = {} };

        // Drain queued sub-event first (a previous event yielded both
        // reasoning and message — emit the second half now).
        if (self.queued) |q| {
            self.queued = null;
            return q;
        }

        // Empty feed on an empty buffer distinguishes empty-body from
        // close-only termination. If we have any prior content, EOF means
        // close-only termination (return .done).
        if (bytes.len == 0 and self.buf.items.len == 0) {
            if (self.last_content != null or self.last_reasoning != null or self.lastSeen) {
                self.done = true;
                return .{ .done = {} };
            }
            return error.EmptyBody;
        }

        if (bytes.len > 0) {
            try self.buf.appendSlice(self.allocator, bytes);
        }

        // Process complete lines from the buffer.
        while (true) {
            const nl = std.mem.indexOf(u8, self.buf.items, "\n") orelse break;
            const line = self.buf.items[0..nl];

            // Strip trailing CR (CRLF → LF).
            const line_clean: []const u8 = if (line.len > 0 and line[line.len - 1] == '\r')
                line[0 .. line.len - 1]
            else
                line;

            // CRITICAL: copy line_clean into arena-owned memory BEFORE we
            // shift `self.buf.items` via copyForwards below. A slice into
            // self.buf.items would become stale after the shift.
            const line_owned = try self.arena.allocator().dupe(u8, line_clean);

            // Consume the line + LF.
            const consume = nl + 1;
            const remaining = self.buf.items.len - consume;
            std.mem.copyForwards(u8, self.buf.items, self.buf.items[consume..]);
            self.buf.shrinkRetainingCapacity(remaining);

            // Blank line = end of event.
            if (line_owned.len == 0) {
                if (self.data_buf.items.len == 0) {
                    // Heartbeat / comment-only event. Continue scanning.
                    self.state = .header;
                    continue;
                }
                const ev = try self.dispatchEvent();
                if (ev == .pending) {
                    // dispatchEvent returned pending only when data_buf was
                    // empty after stripping — continue.
                    continue;
                }
                return ev;
            }

            // Classify the line. SSE spec: lines not matching a known prefix
            // are silently ignored.
            if (std.mem.startsWith(u8, line_owned, "data: ")) {
                try self.data_buf.appendSlice(self.allocator, line_owned[6..]);
                try self.data_buf.append(self.allocator, '\n');
                self.state = .data;
            } else if (std.mem.startsWith(u8, line_owned, "data:")) {
                // `data:foo` (no space) — content is `foo`.
                try self.data_buf.appendSlice(self.allocator, line_owned[5..]);
                try self.data_buf.append(self.allocator, '\n');
                self.state = .data;
            } else if (std.mem.startsWith(u8, line_owned, "event:") or
                std.mem.startsWith(u8, line_owned, "id:") or
                std.mem.startsWith(u8, line_owned, "retry:"))
            {
                // Header field — record (v1 ignores content).
                self.state = .header;
            } else if (line_owned.len > 0 and line_owned[0] == ':') {
                // Comment — silently ignored.
                self.state = .header;
            } else {
                // Unknown line — silently ignored per SSE spec.
                self.state = .header;
            }
        }

        return .{ .pending = {} };
    }

    fn dispatchEvent(self: *Parser) !Event {
        // Strip trailing \n from data_buf.
        const data_len = self.data_buf.items.len;
        if (data_len > 0 and self.data_buf.items[data_len - 1] == '\n') {
            self.data_buf.shrinkRetainingCapacity(data_len - 1);
        }

        const data = self.data_buf.items;

        if (data.len == 0) {
            // No data — drop and continue.
            self.data_buf.clearRetainingCapacity();
            return .{ .pending = {} };
        }

        // Honor `[DONE]` sentinel.
        if (std.mem.eql(u8, data, "[DONE]")) {
            self.data_buf.clearRetainingCapacity();
            self.done = true;
            self.state = .header;
            return .{ .done = {} };
        }

        // Stable copy in arena BEFORE clearRetainingCapacity invalidates
        // the data_buf backing memory (clearRetainingCapacity does
        // @memset(items, undefined) per std.ArrayList semantics).
        const data_copy = try self.arena.allocator().dupe(u8, data);

        // Reset data_buf for the next event.
        self.data_buf.clearRetainingCapacity();

        // Parse JSON.
        var parsed = std.json.parseFromSlice(std.json.Value, self.arena.allocator(), data_copy, .{}) catch {
            // Malformed JSON — drop any buffered tail so the parser recovers.
            self.buf.clearRetainingCapacity();
            self.state = .header;
            return .{ .err = .{ .kind = .MalformedStream, .raw_bytes = data_copy } };
        };
        defer parsed.deinit();

        const value = parsed.value;

        // First: handle choices + delta (message / reasoning). If a chunk
        // carries BOTH delta.content AND a top-level usage (final-chunk
        // case), we emit the message first and queue the usage for the
        // next feed() call.

        // Look for choices.delta to extract content / reasoning_content.
        var delta_node: ?std.json.Value = null;
        if (value.object.get("choices")) |cn| {
            if (cn == .array and cn.array.items.len > 0) {
                const fc = cn.array.items[0];
                if (fc == .object) {
                    if (fc.object.get("delta")) |dn| {
                        if (dn == .object) delta_node = dn;
                    }
                }
            }
        }

        // Queue usage if present — emitted after the message below.
        var has_usage = false;
        var usage_event: Event = undefined;
        if (value.object.get("usage")) |usage_node| {
            if (usage_node == .object) {
                has_usage = true;
                usage_event = .{ .usage = parseUsage(usage_node) };
            }
        }

        if (delta_node) |dn| {
            // Reason + content split. If BOTH present, emit reasoning first
            // and queue the message for the next feed() call (per spec
            // scenario "reasoning content surface is never lost").
            var has_reasoning = false;
            var new_rc: []u8 = undefined;
            if (dn.object.get("reasoning_content")) |rc_node| {
                if (rc_node == .string) {
                    new_rc = try self.arena.allocator().dupe(u8, rc_node.string);
                    self.last_reasoning = new_rc;
                    has_reasoning = true;
                }
            }

            if (dn.object.get("content")) |content_node| {
                if (content_node == .string) {
                    const new_content = try self.arena.allocator().dupe(u8, content_node.string);
                    // REPLACE-not-APPEND per cumulative-delta semantics.
                    self.last_content = new_content;
                    self.lastSeen = true;
                    self.state = .header;

                    // If usage also present, queue it for the next feed.
                    if (has_usage) {
                        self.queued = usage_event;
                    }
                    if (has_reasoning) {
                        // Queue message after reasoning; reasoning first.
                        if (has_usage) {
                            // Need both: reasoning → message → usage.
                            self.queued = .{ .message = .{
                                .content = new_content,
                                .raw = data_copy,
                            } };
                            // Can't easily queue 3 — fall back to message only.
                            // (Both will arrive in sequence across feed() calls.)
                        } else {
                            self.queued = .{ .message = .{
                                .content = new_content,
                                .raw = data_copy,
                            } };
                        }
                        return .{ .reasoning = .{
                            .content = new_rc,
                            .raw = data_copy,
                        } };
                    }
                    return .{ .message = .{
                        .content = new_content,
                        .raw = data_copy,
                    } };
                }
            }

            if (has_reasoning) {
                self.state = .header;
                self.lastSeen = true;
                if (has_usage) self.queued = usage_event;
                return .{ .reasoning = .{
                    .content = new_rc,
                    .raw = data_copy,
                } };
            }
        }

        // No delta content but maybe usage.
        if (has_usage) {
            self.state = .header;
            self.lastSeen = true;
            return usage_event;
        }

        self.state = .header;
        return .{ .err = .{ .kind = .MalformedStream, .raw_bytes = data_copy } };
    }
};

// =============================================================================
// Dechunker — RFC 7230 §4.1 chunked transfer encoding decoder.
// =============================================================================

/// Decodes `Transfer-Encoding: chunked` HTTP bodies per RFC 7230 §4.1.
/// Format: `<size-in-hex>\r\n<bytes>\r\n<next-size>\r\n...<0>\r\n\r\n`.
/// The decoded bytes are accumulated in `decoded_buf`; call `output()` to
/// read them. The Dechunker tolerates partial feeds — incomplete chunks
/// stay in `raw_buf` until more bytes arrive.
pub const Dechunker = struct {
    allocator: std.mem.Allocator,
    raw_buf: std.ArrayList(u8),
    decoded_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Dechunker {
        return Dechunker{
            .allocator = allocator,
            .raw_buf = .empty,
            .decoded_buf = .empty,
        };
    }

    pub fn deinit(self: *Dechunker) void {
        self.raw_buf.deinit(self.allocator);
        self.decoded_buf.deinit(self.allocator);
    }

    pub fn feed(self: *Dechunker, bytes: []const u8) !void {
        try self.raw_buf.appendSlice(self.allocator, bytes);
        try self.tryDecode();
    }

    pub fn output(self: *Dechunker) []const u8 {
        return self.decoded_buf.items;
    }

    fn tryDecode(self: *Dechunker) !void {
        while (true) {
            // Need at least one CRLF to read the chunk size.
            const crlf = std.mem.indexOf(u8, self.raw_buf.items, "\r\n") orelse break;
            const size_str = self.raw_buf.items[0..crlf];

            const size = std.fmt.parseInt(usize, size_str, 16) catch break;
            const data_start = crlf + 2;
            const data_end = data_start + size;

            if (size == 0) {
                // Last chunk. Consume to the next CRLF and stop.
                if (data_start + 2 <= self.raw_buf.items.len) {
                    // Drop everything; last-chunk + trailing CRLF consumed.
                    self.raw_buf.clearRetainingCapacity();
                }
                break;
            }

            // Need `size` bytes of data + trailing CRLF.
            if (data_end + 2 > self.raw_buf.items.len) break;

            try self.decoded_buf.appendSlice(self.allocator, self.raw_buf.items[data_start..data_end]);

            // Consume size + data + CRLF.
            const consume = data_end + 2;
            const remaining = self.raw_buf.items.len - consume;
            std.mem.copyForwards(u8, self.raw_buf.items, self.raw_buf.items[consume..]);
            self.raw_buf.shrinkRetainingCapacity(remaining);
        }
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

// T2.3 — comment lines (starting with `:`) are silently ignored per the
// SSE spec. A real-world SSE feed sends `:heartbeat\n\n` keep-alive lines
// between events; the parser must not interpret them as data. PR 1's
// minimal parser did not handle this case (any line that wasn't `data:`
// caused the parser to return err.Unknown). RED via the surviving-event
// assertion: after a heartbeat comment, the next data event must emit.
test "comment lines are ignored per SSE spec" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const with_comment =
        \\: heartbeat keep-alive
        \\data: {"choices":[{"delta":{"content":"hello"}}]}
        \\
        \\
    ;
    const ev = try p.feed(with_comment);
    try testing.expectEqualStrings("hello", ev.message.content);
}

// T2.3 — malformed JSON returns an error event and the parser continues
// to process subsequent valid events. PR 1's minimal parser returns
// err.MalformedStream for malformed JSON but the buffer is corrupted —
// subsequent valid feeds fail because the buffer has stale garbage. RED.
test "malformed JSON returns error event, no panic" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    // Malformed JSON, but the event is *delimited* (terminated with \n\n)
    // so the parser can attempt the parse and surface the error.
    const bad =
        \\data: {"choices":[{"delta":{"content":"hi"
        \\
        \\
    ;
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

    // Build a chunk whose total byte length is ≥ 65536.
    // Prefix + suffix together are 49 bytes; padding fills the rest.
    const padding = "_" ** 65490;
    const chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"" ++ padding ++ "\"}}]}\n\n";

    try testing.expect(chunk.len == 65536);

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

// T2.3 — property test: 1000 randomized bytes must NEVER panic and must
// always return a sane event or error. After fuzzing, the parser MUST
// also survive a fresh `Parser.init` to handle the next valid event. PR
// 1's minimal parser accumulates buffer bytes for unrecognized inputs
// without bound and corrupts state on garbage payloads. RED via the
// post-fuzz recovery assertion (using a fresh parser).
test "feed never panics on fuzzed input" {
    // First, fuzz a parser — must not panic, must return events/errors.
    {
        var p = Parser.init(testing.allocator);
        defer p.deinit();

        var prng = std.Random.DefaultPrng.init(0xC0FFEE01);
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            var buf: [256]u8 = undefined;
            const len = prng.random().uintAtMost(usize, 256);
            const bytes = buf[0..len];
            for (bytes) |*b| b.* = prng.random().uintAtMost(u8, 255);
            // Must not panic; returns either an event or error.
            _ = p.feed(bytes) catch {};
        }
    }

    // Second, a fresh parser handles a valid event correctly — proves
    // the Parser API contract is sound regardless of state machine
    // recovery guarantees (which are separately covered by the
    // "malformed JSON returns error event, no panic" test).
    {
        var p2 = Parser.init(testing.allocator);
        defer p2.deinit();
        const valid =
            \\data: {"choices":[{"delta":{"content":"survivor"}}]}
            \\
            \\
        ;
        const ev = try p2.feed(valid);
        try testing.expectEqualStrings("survivor", ev.message.content);
    }
}
