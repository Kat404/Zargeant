//! tests/terminal/cursor.zig — RED tests for src/terminal/cursor.zig.
//!
//! Spec: REQ-TCL-002 (CAP-31 terminal-emit) — CSI CUP byte sequence.
//!
//! All assertions are byte-exact against `std.Io.Writer.fixed` because the
//! 1-indexed coordinate translation is a spec invariant; off-by-one would
//! silently shift every cursor move by one row. ECMA-48 §CSI <row>;<col>H
//! parameter order — row first, column second.
//!
//! Strict TDD (CONTRIBUTING.md:7): tests authored before src/terminal/cursor.zig
//! GREEN impl. PR 6 swaps src/tui.zig:344,355 from mibu.cursor.goTo to
//! terminal.cursor.goTo.

const std = @import("std");
const testing = std.testing;

const cursor = @import("cursor");

// =============================================================================
// Scenario 1 — 1-indexed coordinate translation (REQ-TCL-002).
//   GIVEN cursor.goTo(writer, 0, 0)
//   WHEN called
//   THEN it writes "\x1b[1;1H" (top-left, 1-indexed per ECMA-48 CUP)
// =============================================================================

test "goTo(0, 0) emits CSI 1;1 H (top-left, 1-indexed)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cursor.goTo(&w, 0, 0);
    try testing.expectEqualStrings("\x1b[1;1H", buf[0..w.end]);
}

// =============================================================================
// Scenario 2 — arbitrary coordinates (REQ-TCL-002).
//   GIVEN cursor.goTo(writer, 4, 7)
//   WHEN called
//   THEN it writes "\x1b[8;5H" (y+1, x+1, row-then-column)
// =============================================================================

test "goTo(4, 7) emits CSI 8;5 H (1-indexed, row-then-column)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cursor.goTo(&w, 4, 7);
    try testing.expectEqualStrings("\x1b[8;5H", buf[0..w.end]);
}

// =============================================================================
// Scenario 3 — large coordinates (REQ-TCL-002 boundary).
//   GIVEN cursor.goTo(writer, 119, 39)
//   WHEN called
//   THEN it writes "\x1b[40;120H" (multi-digit, 1-indexed)
// =============================================================================

test "goTo(119, 39) emits CSI 40;120 H (multi-digit coordinates)" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cursor.goTo(&w, 119, 39);
    try testing.expectEqualStrings("\x1b[40;120H", buf[0..w.end]);
}

// =============================================================================
// Scenario 4 — no trailing bytes after the H (REQ-TCL-002 adversarial).
//   GIVEN cursor.goTo is the only write
//   WHEN measured
//   THEN the byte length equals exactly 7 (ESC[1;1H)
// =============================================================================

test "goTo emits exactly 6 bytes for origin (no trailing garbage)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cursor.goTo(&w, 0, 0);
    try testing.expectEqual(@as(usize, 6), w.end);
}
