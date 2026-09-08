//! tests/terminal/style.zig — RED tests for src/terminal/style.zig.
//!
//! Spec: REQ-TCL-002 (CAP-31 terminal-emit) — SGR byte sequences.
//!
//! All assertions are byte-exact against `std.Io.Writer.fixed` because SGR
//! parameter drift causes attribute leaks (bold stuck on, reverse stuck on)
//! that are hard to debug once they manifest as rendering bugs.
//! ECMA-48 §SGR parameter table: 0=reset, 1=bold, 4=underline, 7=reverse,
//! 22=normal-intensity, 24=no-underline, 27=no-reverse.
//!
//! Strict TDD (CONTRIBUTING.md:7): tests authored before src/terminal/style.zig
//! GREEN impl. PR 6 swaps src/tui.zig:345-352 from mibu.style.* to
//! terminal.style.*.

const std = @import("std");
const testing = std.testing;

const style = @import("style");

// =============================================================================
// Scenario 1 — reset ignores on (REQ-TCL-002).
//   GIVEN style.reset(writer, true) or style.reset(writer, false)
//   WHEN called
//   THEN it writes "\x1b[0m" (SGR 0 = reset-all; no on/off pair)
// =============================================================================

test "reset(true) emits CSI 0m (reset-all, ignores on)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try style.reset(&w, true);
    try testing.expectEqualStrings("\x1b[0m", buf[0..w.end]);
}

test "reset(false) emits CSI 0m (reset-all, ignores on)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try style.reset(&w, false);
    try testing.expectEqualStrings("\x1b[0m", buf[0..w.end]);
}

// =============================================================================
// Scenario 2 — bold on/off (REQ-TCL-002).
//   GIVEN style.bold(writer, true) or style.bold(writer, false)
//   WHEN called
//   THEN bold(true) writes "\x1b[1m" (SGR 1 = bold)
//   AND  bold(false) writes "\x1b[22m" (SGR 22 = normal-intensity)
// =============================================================================

test "bold(true) emits CSI 1m (SGR 1 = bold)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try style.bold(&w, true);
    try testing.expectEqualStrings("\x1b[1m", buf[0..w.end]);
}

test "bold(false) emits CSI 22m (SGR 22 = normal-intensity)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try style.bold(&w, false);
    try testing.expectEqualStrings("\x1b[22m", buf[0..w.end]);
}

// =============================================================================
// Scenario 3 — underline on/off (REQ-TCL-002).
//   GIVEN style.underline(writer, true|false)
//   WHEN called
//   THEN underline(true) writes "\x1b[4m" (SGR 4 = underline)
//   AND  underline(false) writes "\x1b[24m" (SGR 24 = no-underline)
// =============================================================================

test "underline(true) emits CSI 4m (SGR 4 = underline)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try style.underline(&w, true);
    try testing.expectEqualStrings("\x1b[4m", buf[0..w.end]);
}

test "underline(false) emits CSI 24m (SGR 24 = no-underline)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try style.underline(&w, false);
    try testing.expectEqualStrings("\x1b[24m", buf[0..w.end]);
}

// =============================================================================
// Scenario 4 — reverse on/off (REQ-TCL-002).
//   GIVEN style.reverse(writer, true|false)
//   WHEN called
//   THEN reverse(true) writes "\x1b[7m" (SGR 7 = reverse)
//   AND  reverse(false) writes "\x1b[27m" (SGR 27 = no-reverse)
// =============================================================================

test "reverse(true) emits CSI 7m (SGR 7 = reverse)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try style.reverse(&w, true);
    try testing.expectEqualStrings("\x1b[7m", buf[0..w.end]);
}

test "reverse(false) emits CSI 27m (SGR 27 = no-reverse)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try style.reverse(&w, false);
    try testing.expectEqualStrings("\x1b[27m", buf[0..w.end]);
}

// =============================================================================
// Scenario 5 — adversarial: empty on is treated as false (REQ-TCL-002).
//   GIVEN style.bold(writer, true) then style.bold(writer, false)
//   WHEN both called on the same writer
//   THEN the bytes are exactly "\x1b[1m\x1b[22m" (no inter-element padding)
// =============================================================================

test "bold round-trip emits no padding between on and off" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try style.bold(&w, true);
    try style.bold(&w, false);
    try testing.expectEqualStrings("\x1b[1m\x1b[22m", buf[0..w.end]);
}
