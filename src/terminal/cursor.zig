//! src/terminal/cursor.zig — CSI CUP (Cursor Position) emitter.
//!
//! ECMA-48 §CSI <row>;<col>H — emits the Cursor Position (CUP) sequence
//! with 1-indexed coordinates (row first, column second). The caller
//! passes 0-indexed coordinates; we add 1 to each before writing.
//!
//! Spec-citation invariant: src/tui.zig:344,355 already feeds `entry.x + 1`
//! and `entry.y + 1`; our function preserves that 1-indexed convention so
//! PR 6's call-site swap stays a 1:1 byte change.
//!
//! Clean-room rule (CONTRIBUTING.md:41 + ADR 0001 §Negative): no mibu or
//! libvaxis source consulted. References POSIX termios(3) (unrelated — CUP
//! is a write-only output sequence), ECMA-48 §CSI, xterm ctlseqs §Cursor
//! positioning.

const std = @import("std");

/// Move the cursor to `(x, y)` (0-indexed). Writes the CSI CUP sequence
/// `ESC [ <y+1> ; <x+1> H` — 1-indexed, row-then-column per ECMA-48.
///
/// Caller feeds 0-indexed coordinates because src/tui.zig's diff entries
/// are 0-indexed (see `mibu.cursor.goTo` call sites at `src/tui.zig:344,355`
/// which add 1 before calling). The 1-indexed translation is a spec
/// invariant; off-by-one would shift every cursor move by one row.
pub fn goTo(writer: *std.Io.Writer, x: u16, y: u16) anyerror!void {
    // Buffer fits "ESC[" + up-to-5-digit row + ";" + up-to-5-digit col + "H" = 14.
    var buf: [16]u8 = undefined;
    const slice = std.fmt.bufPrint(
        &buf,
        "\x1b[{d};{d}H",
        .{ y + 1, x + 1 },
    ) catch unreachable;
    try writer.writeAll(slice);
}

test "goTo(0, 0) emits CSI 1;1 H" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try goTo(&w, 0, 0);
    try std.testing.expectEqualStrings("\x1b[1;1H", buf[0..w.end]);
}

test "goTo(4, 7) emits CSI 8;5 H" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try goTo(&w, 4, 7);
    try std.testing.expectEqualStrings("\x1b[8;5H", buf[0..w.end]);
}
