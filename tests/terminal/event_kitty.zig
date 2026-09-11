//! tests/terminal/event_kitty.zig — RED tests for src/terminal/event.zig PR 4 WU 4.1.
//!
//! Spec coverage: REQ-TCL-004 (CAP-33 terminal-event-parser) kitty keyboard
//! sub-capability (5b) + spec v2 §7 acceptance test:
//!   "Scenario: Kitty key event carries press/repeat/release and mods (happy path, 5b)"
//!
//! Per the kitty keyboard protocol spec
//! (https://sw.kovidgoyal.net/kitty/keyboard-protocol/) the key event format
//! when the `report_event_types` flag is enabled is:
//!     CSI codepoint[:shifted_key] ; modifiers [:[event_type]] u
//! where event_type detection for PR 4 follows the colon-shorthand form:
//!     - `:` after modifiers  → repeat
//!     - `:;` after modifiers → release
//!     - nothing after modifiers → press (default)
//!
//! Modifier bitmask mapping (kitty kb spec):
//!     shift=1, alt=2, ctrl=4, super=8, hyper=16, meta=32, capslock=64, numlock=128
//!
//! Tests drive the parser via the test-only entrypoints (Parser.feedBytes +
//! Parser.decode) so the state machine can be exercised deterministically
//! without going through poll(2)+read(2). Mirrors the PR 3 WU 3.2/3.3 pattern.
//!
//! Test count: 10 RED tests. PR 3 WU 3.3 baseline is 82; PR 4 WU 4.1 takes
//! the test-terminal total to 92.
//!
//! Strict TDD (CONTRIBUTING.md:7): tests authored alongside the WU 4.1 parser
//! additions in src/terminal/event.zig in the same commit.

const std = @import("std");
const testing = std.testing;

const event = @import("event");

// =============================================================================
// Scenario 1 — Press: CSI 97 ; 1 u (key 'a' + shift modifier).
//   GIVEN Parser.init() and a CSI ... u sequence with codepoint + shift modifier
//   WHEN feedBytes and decode() are called
//   THEN the parser emits .key with code=.char 'a', mods.shift=true, event=.press
// =============================================================================

test "kitty kb: CSI 97;1u decodes to .key press with shift modifier" {
    var parser = event.Parser.init();
    // CSI 97 ; 1 u  (plain 'a' press with shift held)
    parser.feedBytes("\x1b[97;1u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'a'), ev.key.code.char);
    try testing.expectEqual(true, ev.key.mods.shift);
    try testing.expectEqual(false, ev.key.mods.ctrl);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
    try testing.expectEqual(@as(usize, 0), parser.ring_len); // bytes consumed
}

// =============================================================================
// Scenario 2 — Repeat: CSI 97 ; 1 : u.
//   GIVEN the same key+mod combo with a trailing colon (event_type=repeat)
//   WHEN feedBytes and decode() are called
//   THEN the parser emits .key with event=.repeat
// =============================================================================

test "kitty kb: CSI 97;1:u decodes to .key repeat with shift modifier" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[97;1:u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'a'), ev.key.code.char);
    try testing.expectEqual(true, ev.key.mods.shift);
    try testing.expectEqual(event.EventKind.repeat, ev.key.event);
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

// =============================================================================
// Scenario 3 — Release: CSI 97 ; 1 :; u.
//   GIVEN the same key+mod combo with `:;` (colon-semicolon) trailing
//   WHEN feedBytes and decode() are called
//   THEN the parser emits .key with event=.release
// =============================================================================

test "kitty kb: CSI 97;1:;u decodes to .key release with shift modifier" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[97;1:;u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'a'), ev.key.code.char);
    try testing.expectEqual(true, ev.key.mods.shift);
    try testing.expectEqual(event.EventKind.release, ev.key.event);
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

// =============================================================================
// Scenario 4 — Combined modifiers: CSI 65 ; 5 u (shift + ctrl).
//   GIVEN the modifier bitmask = 5 = 1 (shift) + 4 (ctrl)
//   WHEN parsed
//   THEN both Mods.shift and Mods.ctrl are true; the key code is 'A' (65)
// =============================================================================

test "kitty kb: CSI 65;5u decodes shift+ctrl modifier bitmask" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[65;5u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'A'), ev.key.code.char);
    try testing.expectEqual(true, ev.key.mods.shift);
    try testing.expectEqual(true, ev.key.mods.ctrl);
    try testing.expectEqual(false, ev.key.mods.alt);
    try testing.expectEqual(false, ev.key.mods.super_);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
}

// =============================================================================
// Scenario 5 — Base-vs-shifted: CSI 99:67 ; 4 u.
//   GIVEN a sequence with codepoint=99 (lowercase 'c') and shifted=67 (uppercase 'C')
//   WHEN parsed
//   THEN the parser uses the BASE codepoint ('c', 99), not the shifted variant
// =============================================================================

test "kitty kb: CSI 99:67;4u uses base codepoint (not shifted variant)" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[99:67;4u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'c'), ev.key.code.char); // base, not shifted 'C' (67)
    try testing.expectEqual(true, ev.key.mods.ctrl); // modifier 4 = ctrl
    try testing.expectEqual(event.EventKind.press, ev.key.event);
}

// =============================================================================
// Scenario 6 — Adversarial: CSI 97 ; 1 v (NOT a kitty kb final byte).
//   GIVEN a CSI sequence whose final byte is 'v' (not 'u')
//   WHEN parsed
//   THEN the parser returns .invalid (existing dispatch logic handles it)
// =============================================================================

test "kitty kb: CSI 97;1v returns .invalid (not a kitty kb final byte)" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[97;1v");
    const ev = parser.decode();
    try testing.expect(ev == .invalid);
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

// =============================================================================
// Scenario 7 — Push format: CSI > 1 u (NOT a key event).
//   GIVEN a CSI sequence whose first param is '>' (kitty kb push command)
//   WHEN parsed
//   THEN the parser returns .invalid (we don't parse our own push commands)
// =============================================================================

test "kitty kb: CSI > 1 u (push format) returns .invalid" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[>1u");
    const ev = parser.decode();
    try testing.expect(ev == .invalid);
}

// =============================================================================
// Scenario 8 — Modifier bitmask: CSI 97 ; 0 u (no modifiers).
//   GIVEN modifier bitmask = 0
//   WHEN parsed
//   THEN all Mods fields are false
// =============================================================================

test "kitty kb: CSI 97;0u decodes to .key press with no modifiers" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[97;0u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'a'), ev.key.code.char);
    try testing.expectEqual(false, ev.key.mods.ctrl);
    try testing.expectEqual(false, ev.key.mods.shift);
    try testing.expectEqual(false, ev.key.mods.alt);
    try testing.expectEqual(false, ev.key.mods.super_);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
}

// =============================================================================
// Scenario 9 — Ctrl-only: CSI 97 ; 4 u.
//   GIVEN modifier bitmask = 4 = ctrl (no shift, no alt, no super)
//   WHEN parsed
//   THEN Mods.ctrl is true and other Mods fields are false
// =============================================================================

test "kitty kb: CSI 97;4u decodes ctrl-only modifier (bit 4)" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[97;4u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'a'), ev.key.code.char);
    try testing.expectEqual(true, ev.key.mods.ctrl);
    try testing.expectEqual(false, ev.key.mods.shift);
    try testing.expectEqual(false, ev.key.mods.alt);
    try testing.expectEqual(false, ev.key.mods.super_);
}

// =============================================================================
// Scenario 10 — Super-only: CSI 97 ; 8 u.
//   GIVEN modifier bitmask = 8 = super (Windows key / Cmd)
//   WHEN parsed
//   THEN Mods.super_ is true and other Mods fields are false
// =============================================================================

test "kitty kb: CSI 97;8u decodes super-only modifier (bit 8)" {
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[97;8u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'a'), ev.key.code.char);
    try testing.expectEqual(true, ev.key.mods.super_);
    try testing.expectEqual(false, ev.key.mods.ctrl);
    try testing.expectEqual(false, ev.key.mods.shift);
}
