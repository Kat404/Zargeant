//! src/terminal/style.zig — SGR (Select Graphic Rendition) emitters.
//!
//! ECMA-48 §SGR parameters: 0 = reset-all, 1 = bold, 4 = underline,
//! 7 = reverse, 22 = normal-intensity, 24 = no-underline, 27 = no-reverse.
//!
//! Uniform `on: bool` signature across all four helpers (even `reset`,
//! where `on` is ignored) lets callers use the same call shape at every
//! site — src/tui.zig:345-348 already passes `true|false` per entry.style.
//!
//! Clean-room rule (CONTRIBUTING.md:41 + ADR 0001 §Negative): no mibu or
//! libvaxis source consulted. References ECMA-48 §SGR parameter table.

const std = @import("std");

/// Emit SGR reset (CSI 0 m). `on` is ignored because SGR 0 always resets
/// every attribute; the parameter exists for API uniformity with `bold`,
/// `underline`, and `reverse`. 4-byte output: "ESC[0m".
pub fn reset(writer: *std.Io.Writer, _: bool) anyerror!void {
    // ponytail: caller passes `on` but SGR 0 always resets. The on-flag is
    // a uniform call shape, not a behavior switch. We still emit the bytes.
    try emitSgr(writer, 0);
}

/// Emit SGR 1 (bold) when `on`, otherwise SGR 22 (normal intensity).
/// "ESC[1m" or "ESC[22m" — 5 bytes per branch.
pub fn bold(writer: *std.Io.Writer, on: bool) anyerror!void {
    try emitSgr(writer, if (on) 1 else 22);
}

/// Emit SGR 4 (underline) when `on`, otherwise SGR 24 (no underline).
/// "ESC[4m" or "ESC[24m" — 5 or 6 bytes per branch.
pub fn underline(writer: *std.Io.Writer, on: bool) anyerror!void {
    try emitSgr(writer, if (on) 4 else 24);
}

/// Emit SGR 7 (reverse) when `on`, otherwise SGR 27 (no reverse).
/// "ESC[7m" or "ESC[27m" — 5 or 6 bytes per branch.
pub fn reverse(writer: *std.Io.Writer, on: bool) anyerror!void {
    try emitSgr(writer, if (on) 7 else 27);
}

/// Emit a single SGR parameter. Buffer sized for "ESC[" + up-to-3-digit
/// param + "m" = 7 bytes; all our params fit in 2 digits so 8 is plenty.
fn emitSgr(writer: *std.Io.Writer, param: u8) anyerror!void {
    var buf: [8]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "\x1b[{d}m", .{param}) catch unreachable;
    try writer.writeAll(slice);
}

test "reset emits CSI 0m (on ignored)" {
    var buf_true: [8]u8 = undefined;
    var w_true = std.Io.Writer.fixed(&buf_true);
    try reset(&w_true, true);
    try std.testing.expectEqualStrings("\x1b[0m", buf_true[0..w_true.end]);

    var buf_false: [8]u8 = undefined;
    var w_false = std.Io.Writer.fixed(&buf_false);
    try reset(&w_false, false);
    try std.testing.expectEqualStrings("\x1b[0m", buf_false[0..w_false.end]);
}

test "bold/underline/reverse byte-exact" {
    // Parameter mapping is a spec invariant; this single test pins all
    // four off/on pairs.
    var buf: [8]u8 = undefined;
    {
        var w = std.Io.Writer.fixed(&buf);
        try bold(&w, true);
        try std.testing.expectEqualStrings("\x1b[1m", buf[0..w.end]);
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try bold(&w, false);
        try std.testing.expectEqualStrings("\x1b[22m", buf[0..w.end]);
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try underline(&w, true);
        try std.testing.expectEqualStrings("\x1b[4m", buf[0..w.end]);
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try underline(&w, false);
        try std.testing.expectEqualStrings("\x1b[24m", buf[0..w.end]);
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try reverse(&w, true);
        try std.testing.expectEqualStrings("\x1b[7m", buf[0..w.end]);
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try reverse(&w, false);
        try std.testing.expectEqualStrings("\x1b[27m", buf[0..w.end]);
    }
}
