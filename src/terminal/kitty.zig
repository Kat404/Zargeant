//! src/terminal/kitty.zig — kitty keyboard protocol push/pop + probe stub.
//!
//! Push: `CSI > <bits> u` — sets the kitty keyboard flags on a stack.
//! Pop:  `CSI < u` — restores the previous flags from the stack.
//!
//! The three flag bits correspond to the kitty keyboard protocol spec:
//!   bit 0 = disambiguate escape codes
//!   bit 1 = report event types (press/repeat/release)
//!   bit 2 = report alternate keys
//!
//! PR 2 ships the push/pop emitters and `KittyFlags.bits()`. The
//! `supportsKittyKeyboardWithTimeout` probe is a stub returning `false`
//! until PR 5 adds the ack parser. Per design C18 the interim behavior
//! is false-on-failure (matches REQ-TCL-005 C14).
//!
//! Clean-room rule (CONTRIBUTING.md:41 + ADR 0001 §Negative): no mibu or
//! libvaxis source consulted. References the kitty keyboard protocol
//! spec §Push / §Pop / §Query.
//!
//! ADR 0002 §1 protocol citation table anchors the byte shapes to the
//! kitty spec section.

const std = @import("std");

/// Bit layout for the kitty keyboard protocol's push flags. Three independent
/// boolean switches packed into a single byte for the `CSI > <bits> u` payload.
///
/// Per design C32 the `.bits()` method gives the struct the one declaration
/// the renamed `tests/tui/terminal_smoke.zig` canary requires (`decls.len > 0`).
pub const KittyFlags = struct {
    disambiguate: bool = false,
    report_events: bool = false,
    alternate_keys: bool = false,

    /// Pack the three flags into a single byte:
    ///   bit 0 = disambiguate, bit 1 = report_events, bit 2 = alternate_keys.
    /// Caller feeds the result to `pushKittyKeyboard` via the format string.
    pub fn bits(self: KittyFlags) u8 {
        // Cast each flag to u8 first; @intFromBool(false) is u0 which
        // cannot be shifted left by 1 (zig 0.16 strict bit ops).
        return (@as(u8, @intFromBool(self.disambiguate)) << 0) |
            (@as(u8, @intFromBool(self.report_events)) << 1) |
            (@as(u8, @intFromBool(self.alternate_keys)) << 2);
    }
};

/// Push the kitty keyboard flags onto the kitty keyboard protocol stack.
/// Writes `CSI > <bits> u` where `<bits>` is `KittyFlags.bits()` (0-7 for
/// our three flags; the protocol spec allows up to 31 for extensions).
pub fn pushKittyKeyboard(writer: *std.Io.Writer, flags: KittyFlags) anyerror!void {
    var buf: [16]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "\x1b[>{d}u", .{flags.bits()}) catch unreachable;
    try writer.writeAll(slice);
}

/// Pop the most recent kitty keyboard flags from the stack.
/// Writes `CSI < u`. The pop restores whatever was active before the
/// corresponding push; per protocol spec the writer does not pass flags.
pub fn popKittyKeyboard(writer: *std.Io.Writer) anyerror!void {
    try writer.writeAll("\x1b[<u");
}

/// Probe whether the terminal advertises the kitty keyboard protocol.
/// PR 2 ships a stub returning `false` unconditionally; PR 5 lands the
/// real ack parser (per design C18 interim behavior matches the four
/// C14 failure modes — all return `false`).
///
/// Per design C34 this probe lives in `kitty.zig` (NOT `dpm.zig`) because
/// kitty keyboard queries (`CSI ? u`) are a separate protocol from DEC
/// Private Modes; the proposal default of colocating DECRQM/DECRPM with
/// dpm.zig does not extend to kitty.
///
/// The `io`/`file`/`timeout_ms` parameters are accepted to preserve the
/// 4-argument signature `supportsKittyKeyboardWithTimeout(io, file, writer, timeout_ms)`
/// the caller at `src/tui.zig:121` uses; PR 5 will route them to a
/// `poll(2)` + `read(2)` driver that consumes the kitty ack bytes.
pub fn supportsKittyKeyboardWithTimeout(
    _: std.Io,
    _: std.Io.File,
    _: *std.Io.Writer,
    _: u32,
) anyerror!bool {
    // PR 2 stub: always false. PR 5 swaps to the real ack lexer.
    return false;
}

test "KittyFlags.bits() packs three flags independently" {
    // Parametric coverage at the lowest level; the public functions above
    // route through this method.
    try std.testing.expectEqual(@as(u8, 0), (KittyFlags{}).bits());
    try std.testing.expectEqual(@as(u8, 1), (KittyFlags{ .disambiguate = true }).bits());
    try std.testing.expectEqual(@as(u8, 2), (KittyFlags{ .report_events = true }).bits());
    try std.testing.expectEqual(@as(u8, 4), (KittyFlags{ .alternate_keys = true }).bits());
    try std.testing.expectEqual(
        @as(u8, 7),
        (KittyFlags{
            .disambiguate = true,
            .report_events = true,
            .alternate_keys = true,
        }).bits(),
    );
}
