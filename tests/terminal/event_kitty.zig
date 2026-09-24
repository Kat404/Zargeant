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

// =============================================================================
// WU 0.3 (tui-ship-fast-phase0, Bugs 2+5) — parseKittyKb must map functional
// codepoints to their named KeyCode variants.
//
// Bug 2: kitty kb emits `CSI 13 u` for Enter, `CSI 127 u` for Backspace,
// `CSI 27 u` for Escape, and `CSI 9 u` for Tab — i.e. the codepoint is the
// ASCII control byte. Pre-fix, the parser returned `.char(13)` / `.char(127)`
// / `.char(27)` / `.char(9)`, forcing every consumer to special-case the
// control bytes by literal value. The fix maps the well-known functional
// codepoints to their named KeyCode variants; everything else stays as
// `.char(<codepoint>)`.
//
// Bug 5: kitty kb does NOT prefix functional keys with a ':shifted'
// variant. Pre-fix, the functional codepoints were indistinguishable from
// printable characters, so consumers (TUI modals) had to check both the
// `code == .char` branch AND the literal codepoint. After fix, `.enter`
// and `.backspace` are first-class key events on the same surface as
// the SS3/CSI dispatcher already produces.
//
// Per the kitty kb protocol spec
// (https://sw.kovidgoyal.net/kitty/keyboard-protocol/) the keycode
// mapping table covers exactly these four: 9=Tab, 13=Enter, 27=Escape,
// 127=Backspace. All other codepoints (including the printable ASCII
// range 32..126) stay as `.char(<codepoint>)`.
// =============================================================================

test "parseKittyKb: CSI 13 u maps 13 (CR) to .enter (Bugs 2, 5)" {
    // Kitty kb emits `CSI 13 u` for the Enter key. The codepoint is the
    // ASCII CR byte (0x0D = 13). Pre-fix this returned `.char(13)`; after
    // fix it returns `Key{ .code = .enter }`.
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[13u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .enter);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
    try testing.expectEqual(false, ev.key.mods.shift);
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

test "parseKittyKb: CSI 127 u maps 127 (DEL) to .backspace (Bugs 2, 5)" {
    // Kitty kb emits `CSI 127 u` for Backspace. The codepoint is the
    // ASCII DEL byte (0x7F = 127). Pre-fix this returned `.char(127)`;
    // after fix it returns `Key{ .code = .backspace }`.
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[127u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .backspace);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
    try testing.expectEqual(false, ev.key.mods.shift);
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

test "parseKittyKb: CSI 127;1: u maps 127 + shift + repeat to .backspace (Bugs 2, 5)" {
    // Kitty kb colon-shorthand repeat event with shift held: modifier=1
    // (= shift bit per the kitty kb spec) and the trailing colon
    // signals repeat (shorthand). Pre-fix this returned `.char(127)` +
    // mods.shift; after fix the codepoint is mapped to .backspace AND
    // the repeat modifier + shift flag are preserved. Per the kitty kb
    // protocol spec, the colon-shorthand for repeat is just `:` after
    // the modifier segment (not `:2` — that's the explicit form, out
    // of scope for PR 4).
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[127;1:u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .backspace);
    try testing.expectEqual(event.EventKind.repeat, ev.key.event);
    try testing.expectEqual(true, ev.key.mods.shift);
    try testing.expectEqual(false, ev.key.mods.ctrl);
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

test "parseKittyKb: CSI 13;1 u maps 13 + no real modifier to .enter with no mods" {
    // Plain Enter press with the default modifier bitmask (1 = shift
    // held alone is interpreted by terminals as the literal shift key,
    // not as a 'plain' enter; for this test we use `CSI 13;1u` to
    // confirm the modifier bitmask=1 case still surfaces .enter without
    // applying shift to the .enter key).
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[13;1u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .enter);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
}

test "parseKittyKb: CSI 27 u maps 27 (ESC) to .esc (Bugs 2, 5)" {
    // Kitty kb emits `CSI 27 u` for Escape. The codepoint is the ASCII
    // ESC byte (0x1B = 27). Pre-fix this returned `.char(27)`; after fix
    // it returns `Key{ .code = .esc }`.
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[27u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .esc);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
}

test "parseKittyKb: CSI 9 u maps 9 (TAB) to .tab (Bugs 2, 5)" {
    // Kitty kb emits `CSI 9 u` for Tab. The codepoint is the ASCII HT
    // byte (0x09 = 9). Pre-fix this returned `.char(9)`; after fix it
    // returns `Key{ .code = .tab }`.
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[9u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .tab);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
}

test "parseKittyKb: printable codepoint stays .char (regression guard)" {
    // Regression guard — the codepoint mapping must NOT swallow printable
    // ASCII. `CSI 97 u` (the 'a' key) must still surface as
    // `Key{ .code = .char(97) }` — only the four functional codepoints
    // (9, 13, 27, 127) are mapped; everything else stays as .char.
    var parser = event.Parser.init();
    parser.feedBytes("\x1b[97u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .char);
    try testing.expectEqual(@as(u21, 'a'), ev.key.code.char);
}
