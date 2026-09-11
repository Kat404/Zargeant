//! tests/terminal/kitty.zig — RED tests for src/terminal/kitty.zig.
//!
//! Spec: REQ-TCL-003 (CAP-32 terminal-kitty-kb) + REQ-TCL-005 (CAP-34
//! terminal-probe interim behavior for the kitty probe).
//!
//! Byte-exact assertions for push/pop with each flag combination +
//! KittyFlags.bits() bit-layout lock-in + probe stub returns false
//! (design C18/C3 interim, C34 kitty probe lives here not in dpm.zig).
//!
//! Strict TDD (CONTRIBUTING.md:7): tests authored before src/terminal/kitty.zig
//! GREEN impl.

const std = @import("std");
const testing = std.testing;

const kitty = @import("kitty");

// =============================================================================
// Scenario 1 — KittyFlags.bit layout (REQ-TCL-003 + design C32).
//   GIVEN KittyFlags{}
//   WHEN .bits() called
//   THEN it returns 0 (no flags set)
// =============================================================================

test "KittyFlags{} .bits() returns 0" {
    const flags = kitty.KittyFlags{};
    try testing.expectEqual(@as(u8, 0), flags.bits());
}

test "KittyFlags{ disambiguate=true } .bits() returns 1" {
    const flags = kitty.KittyFlags{ .disambiguate = true };
    try testing.expectEqual(@as(u8, 1), flags.bits());
}

test "KittyFlags{ report_events=true } .bits() returns 2" {
    const flags = kitty.KittyFlags{ .report_events = true };
    try testing.expectEqual(@as(u8, 2), flags.bits());
}

test "KittyFlags{ alternate_keys=true } .bits() returns 4" {
    const flags = kitty.KittyFlags{ .alternate_keys = true };
    try testing.expectEqual(@as(u8, 4), flags.bits());
}

test "KittyFlags{ disambiguate=true, report_events=true } .bits() returns 3" {
    const flags = kitty.KittyFlags{
        .disambiguate = true,
        .report_events = true,
    };
    try testing.expectEqual(@as(u8, 3), flags.bits());
}

test "KittyFlags all-three .bits() returns 7 (disambiguate|report_events|alternate_keys)" {
    const flags = kitty.KittyFlags{
        .disambiguate = true,
        .report_events = true,
        .alternate_keys = true,
    };
    try testing.expectEqual(@as(u8, 7), flags.bits());
}

// =============================================================================
// Scenario 2 — KittyFlags has at least one declaration (REQ-TCL-003 + design C32).
//   GIVEN @typeInfo(KittyFlags).@"struct".decls
//   WHEN iterated
//   THEN len > 0 (the bits() method counts as the required decl so the
//        renamed tests/tui/terminal_smoke.zig canary decls.len > 0 passes)
// =============================================================================

test "KittyFlags has at least one decl (C32 canary lock-in)" {
    const info: std.builtin.Type = @typeInfo(kitty.KittyFlags);
    const decls = info.@"struct".decls;
    try testing.expect(decls.len > 0);
    var saw_bits = false;
    for (decls) |d| {
        if (std.mem.eql(u8, d.name, "bits")) saw_bits = true;
    }
    try testing.expect(saw_bits);
}

// =============================================================================
// Scenario 3 — pushKittyKeyboard byte shape (REQ-TCL-003).
//   GIVEN pushKittyKeyboard with each flag combination
//   WHEN called
//   THEN it writes "CSI > <bits> u" (e.g. "\x1b[>7u" for all-three)
// =============================================================================

test "pushKittyKeyboard(0 flags) emits CSI > 0 u" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try kitty.pushKittyKeyboard(&w, .{});
    try testing.expectEqualStrings("\x1b[>0u", buf[0..w.end]);
}

test "pushKittyKeyboard(disambiguate) emits CSI > 1 u" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try kitty.pushKittyKeyboard(&w, .{ .disambiguate = true });
    try testing.expectEqualStrings("\x1b[>1u", buf[0..w.end]);
}

test "pushKittyKeyboard(all-three) emits CSI > 7 u" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try kitty.pushKittyKeyboard(&w, .{
        .disambiguate = true,
        .report_events = true,
        .alternate_keys = true,
    });
    try testing.expectEqualStrings("\x1b[>7u", buf[0..w.end]);
}

// =============================================================================
// Scenario 4 — popKittyKeyboard byte shape (REQ-TCL-003).
//   GIVEN popKittyKeyboard(writer)
//   WHEN called
//   THEN it writes "\x1b[<u" (CSI < u = pop; flags are stack-local)
// =============================================================================

test "popKittyKeyboard emits CSI < u" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try kitty.popKittyKeyboard(&w);
    try testing.expectEqualStrings("\x1b[<u", buf[0..w.end]);
}

// =============================================================================
// Scenario 5 — push/pop round-trip (REQ-TCL-003 adversarial).
//   GIVEN pushKittyKeyboard then popKittyKeyboard on the same writer
//   WHEN both called
//   THEN the bytes are exactly "\x1b[>7u\x1b[<u" (no padding between)
// =============================================================================

test "push then pop emits no padding (CSI > 7 u + CSI < u)" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try kitty.pushKittyKeyboard(&w, .{
        .disambiguate = true,
        .report_events = true,
        .alternate_keys = true,
    });
    try kitty.popKittyKeyboard(&w);
    try testing.expectEqualStrings("\x1b[>7u\x1b[<u", buf[0..w.end]);
}

// =============================================================================
// Scenario 6 — supportsKittyKeyboardWithTimeout stub returns false (REQ-TCL-005 + design C18/C34).
//   GIVEN kitty.supportsKittyKeyboardWithTimeout(io, file, writer, 50)
//   WHEN called (PR 2 stub; PR 5 lands the real ack parser)
//   THEN it returns false (interim behavior matches C18: false-on-failure)
// =============================================================================

test "supportsKittyKeyboardWithTimeout stub returns false (PR 2 interim)" {
    const supported = try kitty.supportsKittyKeyboardWithTimeout(
        undefined,
        undefined,
        undefined,
        50,
    );
    try testing.expect(supported == false);
}
