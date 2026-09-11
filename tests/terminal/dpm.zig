//! tests/terminal/dpm.zig — RED tests for src/terminal/dpm.zig.
//!
//! Spec: REQ-TCL-002 (CAP-31 terminal-emit DEC private modes) +
//! REQ-TCL-005 (CAP-34 terminal-probe interim behavior).
//!
//! 6 enter/exit byte-exact assertions + DECRQM emit shape + Mode struct stub
//! returning `supported == false` (PR 2 interim window per design C18/C3).
//!
//! Strict TDD (CONTRIBUTING.md:7): tests authored before src/terminal/dpm.zig
//! GREEN impl. PR 5 replaces the `queryModeWithTimeout` stub with the real
//! DECRPM reply lexer; this PR ships only the emit-side + Mode struct.

const std = @import("std");
const testing = std.testing;

const dpm = @import("dpm");

// =============================================================================
// Scenario 1 — alternate screen (REQ-TCL-002).
//   GIVEN dpm.enterAlternateScreen(writer)
//   WHEN called
//   THEN it writes "\x1b[?1049h" (DECSET mode 1049 = alt-screen)
// =============================================================================

test "enterAlternateScreen emits CSI ? 1049 h" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dpm.enterAlternateScreen(&w);
    try testing.expectEqualStrings("\x1b[?1049h", buf[0..w.end]);
}

test "exitAlternateScreen emits 2J H before 1049l (REQ-TIRFIX-001)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dpm.exitAlternateScreen(&w);
    // Byte-exact sequence: 2J (4) + H (3) + 1049l (8) = 15 bytes.
    try testing.expectEqualStrings("\x1b[2J\x1b[H\x1b[?1049l", buf[0..w.end]);
    try testing.expectEqual(@as(usize, 15), w.end);
}

test "exitAlternateScreen is idempotent (REQ-TIRFIX-001 S2)" {
    var buf1: [16]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&buf1);
    try dpm.exitAlternateScreen(&w1);

    var buf2: [16]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try dpm.exitAlternateScreen(&w2);

    try testing.expectEqualSlices(u8, buf1[0..w1.end], buf2[0..w2.end]);
}

// =============================================================================
// Scenario 2 — in-band resize (REQ-TCL-002).
//   GIVEN dpm.enableInBandResize(writer) or dpm.disableInBandResize(writer)
//   WHEN called
//   THEN enable writes "\x1b[?2048h" (DECSET mode 2048 = in-band resize)
//   AND  disable writes "\x1b[?2048l" (DECRST mode 2048)
// =============================================================================

test "enableInBandResize emits CSI ? 2048 h" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dpm.enableInBandResize(&w);
    try testing.expectEqualStrings("\x1b[?2048h", buf[0..w.end]);
}

test "disableInBandResize emits CSI ? 2048 l" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dpm.disableInBandResize(&w);
    try testing.expectEqualStrings("\x1b[?2048l", buf[0..w.end]);
}

// =============================================================================
// Scenario 3 — synchronized update (REQ-TCL-002).
//   GIVEN dpm.beginSynchronizedUpdate(writer) or dpm.endSynchronizedUpdate(writer)
//   WHEN called
//   THEN begin writes "\x1b[?2026h" (DECSET mode 2026 = sync-update)
//   AND  end writes "\x1b[?2026l" (DECRST mode 2026)
// =============================================================================

test "beginSynchronizedUpdate emits CSI ? 2026 h" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dpm.beginSynchronizedUpdate(&w);
    try testing.expectEqualStrings("\x1b[?2026h", buf[0..w.end]);
}

test "endSynchronizedUpdate emits CSI ? 2026 l" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dpm.endSynchronizedUpdate(&w);
    try testing.expectEqualStrings("\x1b[?2026l", buf[0..w.end]);
}

// =============================================================================
// Scenario 4 — DECRQM probe emit shape (REQ-TCL-005).
//   GIVEN dpm.emitDecRqmQuery(writer, 2048)
//   WHEN called
//   THEN it writes "\x1b[?2048$p" (DECRQM query for mode 2048)
// =============================================================================

test "emitDecRqmQuery(2048) emits CSI ? 2048 $ p" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dpm.emitDecRqmQuery(&w, 2048);
    try testing.expectEqualStrings("\x1b[?2048$p", buf[0..w.end]);
}

test "emitDecRqmQuery(1049) emits CSI ? 1049 $ p" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dpm.emitDecRqmQuery(&w, 1049);
    try testing.expectEqualStrings("\x1b[?1049$p", buf[0..w.end]);
}

// =============================================================================
// Scenario 5 — Mode struct + interim queryModeWithTimeout stub (REQ-TCL-005).
//   GIVEN dpm.queryModeWithTimeout(io, file, writer, 2048, 50) (PR 2 stub)
//   WHEN called
//   THEN it writes the DECRQM probe (handled by Scenario 4)
//   AND  returns Mode{ .is_supported = false, .raw_reply = null }
//   AND  .supported() returns false (per design C18 interim behavior)
// =============================================================================

test "queryModeWithTimeout stub returns Mode{ supported = false } (PR 2 interim)" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const mode = try dpm.queryModeWithTimeout(
        undefined,
        undefined,
        &w,
        2048,
        50,
    );
    try testing.expectEqualStrings("\x1b[?2048$p", buf[0..w.end]);
    try testing.expect(mode.is_supported == false);
    try testing.expect(mode.supported() == false);
    try testing.expect(mode.raw_reply == null);
}

// =============================================================================
// Scenario 6 — Mode struct field/method name lock-in (REQ-TCL-005 + design C26).
//   GIVEN Mode{ .is_supported = true, .raw_reply = "raw" }
//   WHEN .supported() is called
//   THEN it returns true (field name `is_supported` per design C26, method
//        `supported()` matching the byte-for-byte pattern at src/tui.zig:110)
// =============================================================================

test "Mode{ is_supported=true }.supported() returns true (C26 name lock-in)" {
    const mode: dpm.Mode = .{ .is_supported = true, .raw_reply = "2048;1$y" };
    try testing.expect(mode.supported() == true);
    try testing.expect(mode.is_supported == true);
    try testing.expectEqualStrings("2048;1$y", mode.raw_reply.?);
}

test "Mode{ is_supported=false }.supported() returns false" {
    const mode: dpm.Mode = .{ .is_supported = false };
    try testing.expect(mode.supported() == false);
    try testing.expect(mode.is_supported == false);
    try testing.expect(mode.raw_reply == null);
}
