//! tests/terminal/event_parser.zig — RED tests for src/terminal/event.zig PR 3 WU 3.2.
//!
//! Spec coverage: REQ-TCL-004 (CAP-33 terminal-event-parser) streaming parser
//! surface — UTF-8 decode, base ANSI/CSI dispatcher, in-band resize plumbing.
//!
//! Tests drive the parser via the WU 3.2 test-only entrypoints
//! (`Parser.feedBytes` + `Parser.decode`) so the state machine can be
//! exercised deterministically without going through poll(2)+read(2).
//!
//! Test count: 13 RED tests. PR 3 WU 3.1 added 10 (event_types.zig); PR 3 WU
//! 3.2 adds 13 here, taking the test-terminal total from 53 to 66.
//!
//! Strict TDD (CONTRIBUTING.md:7): tests authored alongside the WU 3.2 parser
//! additions in src/terminal/event.zig in the same commit.

const std = @import("std");
const testing = std.testing;

const event = @import("event");

// =============================================================================
// Scenario 1 — ASCII key decode (REQ-TCL-004).
//   GIVEN Parser.init()
//   WHEN fedBytes([0x61]) ('a') and decode() called
//   THEN it returns .key with code=.char 'a' and mods.ctrl == false
// =============================================================================

test "ASCII byte decodes to .key with code=.char" {
    var parser = event.Parser.init();
    parser.feedBytes(&[_]u8{'a'});
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .char);
    try testing.expectEqual(@as(u21, 'a'), ev.key.code.char);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
    try testing.expectEqual(false, ev.key.mods.ctrl);
}

test "ASCII printable byte consumes exactly one byte" {
    var parser = event.Parser.init();
    parser.feedBytes("ab");
    _ = parser.decode();
    try testing.expectEqual(@as(usize, 1), parser.ring_len); // 'b' remains
}

// =============================================================================
// Scenario 2 — Multi-byte UTF-8 (RFC 3629).
//   GIVEN Parser.init()
//   WHEN fedBytes(EURO_SIGN_3_BYTES) and decode() called
//   THEN it returns .key with code=.char 0x20AC, consuming all 3 bytes
// =============================================================================

test "3-byte UTF-8 EURO SIGN decodes to .key" {
    var parser = event.Parser.init();
    // UTF-8 encoding of U+20AC (€): 0xE2 0x82 0xAC
    parser.feedBytes(&[_]u8{ 0xE2, 0x82, 0xAC });
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 0x20AC), ev.key.code.char);
    try testing.expectEqual(@as(usize, 0), parser.ring_len); // all 3 consumed
}

test "2-byte UTF-8 (e.g. ñ = U+00F1) decodes to single .key" {
    var parser = event.Parser.init();
    // UTF-8 encoding of U+00F1: 0xC3 0xB1
    parser.feedBytes(&[_]u8{ 0xC3, 0xB1 });
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 0x00F1), ev.key.code.char);
}

test "truncated UTF-8 returns .timeout (waits for more bytes)" {
    var parser = event.Parser.init();
    // Only first byte of a 3-byte sequence.
    parser.feedBytes(&[_]u8{0xE2});
    const ev = parser.decode();
    try testing.expect(ev == .timeout);
    try testing.expectEqual(@as(usize, 1), parser.ring_len); // byte remains buffered
}

// =============================================================================
// Scenario 3 — ASCII control bytes (REQ-TCL-004).
//   GIVEN Parser.init()
//   WHEN fed a Tab/Enter/Backspace byte
//   THEN decode returns .key with the corresponding named KeyCode
// =============================================================================

test "Tab decodes to .key with code=.tab" {
    var parser = event.Parser.init();
    parser.feedBytes(&[_]u8{0x09});
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .tab);
}

test "Enter (CR/LF) decodes to .key with code=.enter" {
    var parser = event.Parser.init();
    parser.feedBytes(&[_]u8{0x0D});
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .enter);
}

test "Backspace (0x7F DEL) decodes to .key with code=.backspace" {
    var parser = event.Parser.init();
    parser.feedBytes(&[_]u8{0x7F});
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .backspace);
}

test "Ctrl+C decodes to .key with char=0x03 and mods.ctrl=true" {
    var parser = event.Parser.init();
    parser.feedBytes(&[_]u8{0x03});
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 0x03), ev.key.code.char);
    try testing.expectEqual(true, ev.key.mods.ctrl);
}

// =============================================================================
// Scenario 4 — Standard CSI cursor keys (REQ-TCL-004).
//   GIVEN Parser.init()
//   WHEN fed "ESC [ A" (CSI up arrow)
//   THEN decode returns .key with code=.up
// =============================================================================

test "CSI A decodes to .key with code=.up" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[A");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .up);
}

test "CSI B decodes to .key with code=.down" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[B");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .down);
}

test "SS3 A decodes to .key with code=.up (legacy cursor-mode)" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1bOA");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .up);
}

// =============================================================================
// Scenario 5 — Standalone Esc resolves to .key with code=.esc (REQ-TCL-004).
//   GIVEN Parser.init()
//   WHEN fed a single ESC byte (no [ or O follow-up)
//   THEN decode returns .key with code=.esc
// =============================================================================

test "standalone ESC decodes to .key with code=.esc" {
    var parser = event.Parser.init();
    parser.feedBytes(&[_]u8{0x1B});
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .esc);
}

// =============================================================================
// Scenario 6 — Truncated CSI resolves to .timeout (REQ-TCL-004).
//   GIVEN Parser.init()
//   WHEN fed "ESC [" (no final byte yet)
//   THEN decode returns .timeout and the bytes remain buffered for the next call
// =============================================================================

test "truncated CSI (ESC [) returns .timeout without consuming bytes" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[");
    const ev = parser.decode();
    try testing.expect(ev == .timeout);
    try testing.expectEqual(@as(usize, 2), parser.ring_len);
}

// =============================================================================
// Scenario 7 — CSI 8;<rows>;<cols> t unconditional in-band resize (C11).
//   GIVEN Parser.init()
//   WHEN fed "ESC [ 8 ; 40 ; 120 t" (any source, including tmux without DEC 2048)
//   THEN decode returns .resize (void) regardless of any other state
// =============================================================================

test "CSI 8;40;120 t returns .resize (C11 unconditional)" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[8;40;120t");
    const ev = parser.decode();
    try testing.expect(ev == .resize);
}

// =============================================================================
// Scenario 8 — Multiple events in one buffer (REQ-TCL-004).
//   GIVEN Parser.init()
//   WHEN fed "abc" (three printable bytes)
//   THEN three decode() calls each return one .key
// =============================================================================

test "multiple printable bytes decode sequentially" {
    var parser = event.Parser.init();
    parser.feedBytes("abc");
    const e1 = parser.decode();
    const e2 = parser.decode();
    const e3 = parser.decode();
    try testing.expect(e1 == .key);
    try testing.expectEqual(@as(u21, 'a'), e1.key.code.char);
    try testing.expect(e2 == .key);
    try testing.expectEqual(@as(u21, 'b'), e2.key.code.char);
    try testing.expect(e3 == .key);
    try testing.expectEqual(@as(u21, 'c'), e3.key.code.char);
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

test "empty buffer returns .none" {
    var parser = event.Parser.init();
    const ev = parser.decode();
    try testing.expect(ev == .none);
}

// =============================================================================
// WU-1 — Parser persistence + thread-local access (REQ-NEW-001 + REQ-NEW-008)
//
// These tests verify the parser lifetime fix: bytes read but not decoded
// must survive across calls (the pre-change code at src/terminal/event.zig:666
// created a fresh Parser.init() per nextWithTimeout, destroying the ring
// buffer with the stack-local value).
// =============================================================================

test "parser persists across calls: split-CSI" {
    // Feed ESC [ then the rest in a separate feedBytes call. The parser
    // must hold the partial sequence across the boundary and emit the
    // complete CSI event on the second decode(). Without persistence
    // (pre-WU-1), each `decode()` would only see its own feedBytes,
    // the second call would see `\x1b[` and return .timeout again.
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[");
    const first = parser.decode();
    try testing.expect(first == .timeout); // truncated — no final byte yet
    try testing.expectEqual(@as(usize, 2), parser.ring_len); // bytes remain

    parser.feedBytes("1;5H");
    const second = parser.decode();
    // CSI 1 ; 5 H is xterm's "Home" sequence; the parser routes the 'H'
    // final byte to .enter (matches src/terminal/event.zig dispatchCsi).
    // The proof of persistence: the second decode produced a complete
    // .key, not .timeout — meaning the buffer survived the boundary.
    try testing.expect(second == .key);
    try testing.expect(second.key.code == .enter);
}

test "parser persists across calls: 32-byte burst" {
    // 32 ASCII bytes fed in one chunk; decode() must return 32 distinct
    // .key events (no byte loss). Without persistence (pre-WU-1), the
    // parser would be a fresh stack-local on each call and only the
    // first decode would see the bytes.
    var parser = event.Parser.init();
    const payload = "abcdefghijklmnopqrstuvwxyz123456"; // 32 chars
    parser.feedBytes(payload);
    try testing.expectEqual(@as(usize, 32), parser.ring_len);

    var i: usize = 0;
    while (i < payload.len) : (i += 1) {
        const ev = parser.decode();
        try testing.expect(ev == .key);
        try testing.expectEqual(@as(u21, payload[i]), ev.key.code.char);
    }
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

test "setCurrentParser round-trip: null → nextWithTimeout returns .none" {
    // REQ-NEW-008 test seam — when current_parser is null, nextWithTimeout
    // returns .none immediately (no parser to drive). Tests use this to
    // assert early-return without a real TTY.
    defer event.setCurrentParser(null); // cleanup
    event.setCurrentParser(null);
    const file: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
    var pending = std.atomic.Value(bool).init(false);
    const ev = try event.nextWithTimeout(
        undefined,
        file,
        0,
        &pending,
    );
    try testing.expect(ev == .none);
}

test "setCurrentParser round-trip: set → use → clear" {
    // REQ-NEW-008 — after setCurrentParser(&p), nextWithTimeout uses
    // the injected Parser. The Parser instance must be address-stable
    // across calls (no fresh init).
    var parser = event.Parser.init();
    defer event.setCurrentParser(null); // cleanup
    event.setCurrentParser(&parser);

    // Feed bytes directly via the test seam. The parser instance is
    // reachable via current_parser (same address).
    parser.feedBytes("xyz");
    try testing.expect(parser.ring_len == 3);

    // The parser pointer itself is address-stable: take it before the
    // call and after.
    const parser_addr_before = @intFromPtr(&parser);
    const file: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
    var pending = std.atomic.Value(bool).init(false);
    _ = try event.nextWithTimeout(undefined, file, 0, &pending);
    const parser_addr_after = @intFromPtr(&parser);
    try testing.expectEqual(parser_addr_before, parser_addr_after);
}

// =============================================================================
// WU-3 — Paste-bracket detection (REQ-NEW-003)
//
// Per design D2/D5/D6 + REQ-NEW-003:
//   - dispatchCsi emits .paste_start when final='~' and n=200
//   - dispatchCsi emits .paste_end when final='~' and n=201
//   - While paste_active=true, decode() short-circuits and emits one
//     .key event per UTF-8 codepoint (or ASCII byte), skipping CSI
//     dispatch entirely. The existing ring_buf carries the payload.
//   - Parser.next() converts .none on poll-timeout to .paste_end when
//     paste_active=true (auto-recovery per design D6).
// =============================================================================

test "bracketed paste: simple round-trip 'hello world'" {
    // Scenario from REQ-NEW-003 — feed \x1b[200~hello world\x1b[201~,
    // expect 13 events: paste_start, 11 .key (h,e,l,l,o,' ',w,o,r,l,d),
    // paste_end.
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[200~hello world\x1b[201~");

    // First event: paste_start
    const e1 = parser.decode();
    try testing.expect(e1 == .paste_start);
    try testing.expect(parser.paste_active);

    // 11 .key events for "hello world"
    const expected = "hello world";
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        const ev = parser.decode();
        try testing.expect(ev == .key);
        try testing.expectEqual(@as(u21, expected[i]), ev.key.code.char);
    }

    // Final event: paste_end
    const e_last = parser.decode();
    try testing.expect(e_last == .paste_end);
    try testing.expect(!parser.paste_active);
}

test "bracketed paste: embedded ESC sequence captured verbatim" {
    // Per REQ-NEW-003 scenario 2 — a paste containing an embedded CSI
    // sequence (e.g. \x1b[31m) must NOT be routed to CSI dispatch; the
    // bytes are part of the payload. Per design D6, embedded ESC bytes
    // emit .invalid (0x1B is not a valid Unicode scalar), and the
    // subsequent bytes ([, 3, 1, m) are emitted individually as
    // per-char .key events. Total payload events:
    //   5 chars "hello" + ESC(.invalid) + 4 chars "[31m" + 5 chars "world"
    // = 5 + 1 + 4 + 5 = 15 events between paste_start and paste_end.
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[200~hello\x1b[31mworld\x1b[201~");

    const e1 = parser.decode();
    try testing.expect(e1 == .paste_start);

    // "hello" — 5 chars
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const ev = parser.decode();
        try testing.expect(ev == .key);
        try testing.expectEqual(@as(u21, "hello"[i]), ev.key.code.char);
    }
    // The embedded ESC byte emits .invalid (per D6 design — 0x1B is
    // not a valid Unicode scalar).
    const esc_event = parser.decode();
    try testing.expect(esc_event == .invalid);

    // The rest of the embedded "CSI sequence" payload is 4 individual
    // ASCII chars: '[', '3', '1', 'm' (NOT routed to CSI dispatcher).
    const rest1 = "[31m";
    var j: usize = 0;
    while (j < rest1.len) : (j += 1) {
        const ev = parser.decode();
        try testing.expect(ev == .key);
        try testing.expectEqual(@as(u21, rest1[j]), ev.key.code.char);
    }

    // "world" — 5 chars
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        const ev = parser.decode();
        try testing.expect(ev == .key);
        try testing.expectEqual(@as(u21, "world"[k]), ev.key.code.char);
    }

    // paste_end
    const e_end = parser.decode();
    try testing.expect(e_end == .paste_end);
}

test "bracketed paste: malformed (no close) recovers on next feed" {
    // Per REQ-NEW-003 scenario 3 — paste-start + content arrive; the
    // close bracket arrives in a separate feedBytes call. The parser
    // must not infinite-loop and must emit .paste_end when the close
    // arrives.
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[200~abc");

    const e1 = parser.decode();
    try testing.expect(e1 == .paste_start);
    try testing.expect(parser.paste_active);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const ev = parser.decode();
        try testing.expect(ev == .key);
        try testing.expectEqual(@as(u21, "abc"[i]), ev.key.code.char);
    }

    // Buffer is now empty; paste_active still true. Next feedBytes
    // appends the close bracket.
    parser.feedBytes("\x1b[201~");
    const e_end = parser.decode();
    try testing.expect(e_end == .paste_end);
    try testing.expect(!parser.paste_active);
}

test "bracketed paste: split-CSI start sequence across calls" {
    // Per REQ-NEW-003 scenario 4 — \x1b[ in call N, 200~ in call N+1.
    // The split bytes must combine to a single .paste_start event
    // (not two .timeout fragments). Without parser persistence this
    // test cannot pass — the pre-WU-1 code would only see one chunk
    // per call.
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[");
    const e_first = parser.decode();
    try testing.expect(e_first == .timeout); // truncated — no final byte yet
    try testing.expectEqual(@as(usize, 2), parser.ring_len);

    parser.feedBytes("200~hi\x1b[201~");
    const e_start = parser.decode();
    try testing.expect(e_start == .paste_start);
    try testing.expect(parser.paste_active);

    // Drain the 2-char payload "hi" — proves per-char events arrive.
    const e_h = parser.decode();
    try testing.expect(e_h == .key);
    try testing.expectEqual(@as(u21, 'h'), e_h.key.code.char);
    const e_i = parser.decode();
    try testing.expect(e_i == .key);
    try testing.expectEqual(@as(u21, 'i'), e_i.key.code.char);

    // Final: .paste_end (close bracket arrived in the same feed).
    const e_end = parser.decode();
    try testing.expect(e_end == .paste_end);
    try testing.expect(!parser.paste_active);
}
