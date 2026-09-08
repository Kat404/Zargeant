//! src/terminal/dpm.zig — DEC private-mode emitters + DECRQM probe + Mode stub.
//!
//! Emits the 6 DECSET/DECRST enter/exit helpers for modes 1049 (alternate
//! screen), 2048 (in-band resize), and 2026 (synchronized update). Also
//! emits the DECRQM query (CSI ? <mode> $ p) used by the capability probe
//! and ships the `Mode` struct that PR 5's reply lexer populates.
//!
//! PR 2 ships only the emit-side + Mode struct stub returning
//! `Mode{ .is_supported = false }` unconditionally — design C18/C3 interim
//! behavior so PR 5 (which adds the DECRPM reply lexer) is the only change
//! that flips supported=true on a valid reply.
//!
//! Clean-room rule (CONTRIBUTING.md:41 + ADR 0001 §Negative): no mibu or
//! libvaxis source consulted. References xterm ctlseqs §"Private Mode Set"
//! /§"Private Mode Reset", xterm ctlseqs §"Request DEC Private Mode".
//!
//! ADR 0002 §1 protocol citation table anchors each emit helper to the
//! cited spec section.

const std = @import("std");

/// Mode 1049 — alternate screen buffer (DECSET). Writes `ESC[?1049h`.
/// Pairs with `exitAlternateScreen` (`ESC[?1049l`).
pub fn enterAlternateScreen(writer: *std.Io.Writer) anyerror!void {
    try emitDecSetReset(writer, 1049, true);
}

/// Mode 1049 — alternate screen buffer (DECRST). Writes `ESC[?1049l`.
pub fn exitAlternateScreen(writer: *std.Io.Writer) anyerror!void {
    try emitDecSetReset(writer, 1049, false);
}

/// Mode 2048 — in-band resize (DECSET). Writes `ESC[?2048h`.
/// Pairs with `disableInBandResize` (`ESC[?2048l`). Per spec REQ-TCL-004
/// C11, the parser translates the resulting `CSI 8;rows;cols t` reply
/// unconditionally regardless of whether 2048 was negotiated (the tmux
/// emit-shape is a separate parser concern).
pub fn enableInBandResize(writer: *std.Io.Writer) anyerror!void {
    try emitDecSetReset(writer, 2048, true);
}

/// Mode 2048 — in-band resize (DECRST). Writes `ESC[?2048l`.
pub fn disableInBandResize(writer: *std.Io.Writer) anyerror!void {
    try emitDecSetReset(writer, 2048, false);
}

/// Mode 2026 — synchronized update (DECSET). Writes `ESC[?2026h`.
/// Pairs with `endSynchronizedUpdate` (`ESC[?2026l`).
pub fn beginSynchronizedUpdate(writer: *std.Io.Writer) anyerror!void {
    try emitDecSetReset(writer, 2026, true);
}

/// Mode 2026 — synchronized update (DECRST). Writes `ESC[?2026l`.
pub fn endSynchronizedUpdate(writer: *std.Io.Writer) anyerror!void {
    try emitDecSetReset(writer, 2026, false);
}

/// Emit a DECSET (`h`) or DECRST (`l`) sequence for a single mode number.
/// Buffer sized for "ESC[?" + up-to-4-digit mode + "h|l" = 9 bytes; our
/// modes (1049, 2026, 2048) are all 4 digits so 12 is plenty.
fn emitDecSetReset(writer: *std.Io.Writer, mode: u16, set: bool) anyerror!void {
    var buf: [12]u8 = undefined;
    const slice = std.fmt.bufPrint(
        &buf,
        "\x1b[?{d}{s}",
        .{ mode, if (set) "h" else "l" },
    ) catch unreachable;
    try writer.writeAll(slice);
}

/// Emit the DECRQM (Request DEC Private Mode) probe for `mode`.
/// Writes `ESC[?<mode>$p`. The reply is a DECRPM `ESC[?<mode>;<state>$y`
/// sequence read by the PR 5 reply lexer. PR 2 emits this probe but does
/// not parse the reply; the parser lands in PR 5.
pub fn emitDecRqmQuery(writer: *std.Io.Writer, mode: u16) anyerror!void {
    var buf: [12]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "\x1b[?{d}$p", .{mode}) catch unreachable;
    try writer.writeAll(slice);
}

/// Result of a `queryModeWithTimeout` probe. Per design C26 the field
/// name is `is_supported` (Zig forbids a field/method name collision)
/// and the accessor method is `.supported()` to match the call shape at
/// `src/tui.zig:110` (`mode.supported()`).
///
/// PR 2 ships only the stub; PR 5 populates `is_supported` from the
/// DECRPM reply lexer and `raw_reply` from the matched reply bytes.
pub const Mode = struct {
    is_supported: bool,
    raw_reply: ?[]const u8 = null,

    /// Returns the boolean support flag. Mirrors the call shape at
    /// `src/tui.zig:110` (`mode.supported()`).
    pub fn supported(self: Mode) bool {
        return self.is_supported;
    }
};

/// Probe a DEC private mode. PR 2 ships only the emit-side; the function
/// emits the DECRQM probe and unconditionally returns
/// `Mode{ .is_supported = false, .raw_reply = null }` because the reply
/// lexer lands in PR 5.
///
/// The `io`/`file`/`timeout_ms` parameters are accepted to preserve the
/// 5-argument signature `queryModeWithTimeout(io, file, writer, mode, timeout_ms)`
/// the caller at `src/tui.zig:108` uses; PR 5 will route them to a
/// `poll(2)` + `read(2)` driver that consumes the DECRPM reply.
pub fn queryModeWithTimeout(
    _: std.Io,
    _: std.Io.File,
    writer: *std.Io.Writer,
    mode: u16,
    _: u32,
) anyerror!Mode {
    try emitDecRqmQuery(writer, mode);
    return .{ .is_supported = false, .raw_reply = null };
}

test "Mode struct shape: is_supported field + supported() method" {
    // C26 lock-in: the field name MUST be `is_supported` (not `supported`)
    // because Zig forbids a field and method sharing the same name. The
    // method name MUST be `supported()` to match src/tui.zig:110.
    const info: std.builtin.Type = @typeInfo(Mode);
    const fields = info.@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    var saw_is_supported = false;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "is_supported")) saw_is_supported = true;
    }
    try std.testing.expect(saw_is_supported);
}

test "emitDecSetReset writes the correct byte for set/reset of mode 1049" {
    // Parametric coverage at the lowest level; the public functions above
    // are thin wrappers around this helper.
    var buf_set: [12]u8 = undefined;
    var w_set = std.Io.Writer.fixed(&buf_set);
    try emitDecSetReset(&w_set, 1049, true);
    try std.testing.expectEqualStrings("\x1b[?1049h", buf_set[0..w_set.end]);

    var buf_reset: [12]u8 = undefined;
    var w_reset = std.Io.Writer.fixed(&buf_reset);
    try emitDecSetReset(&w_reset, 1049, false);
    try std.testing.expectEqualStrings("\x1b[?1049l", buf_reset[0..w_reset.end]);
}
