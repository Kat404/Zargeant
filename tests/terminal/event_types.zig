//! tests/terminal/event_types.zig — RED tests for src/terminal/event.zig PR 3 WU 3.1.
//!
//! Spec coverage: REQ-TCL-004 (CAP-33 terminal-event-parser) public type surface
//! and C23 `pollReadable` namespace canary. PR 3 land 2 (event_parser.zig) and
//! PR 3 land 3 (event_critical.zig) extend the test surface for streaming
//! behavior + C9/C11/C22/C28 contract lock-ins.
//!
//! Test count: 11 RED tests. With PR 1+2 baseline of 43, the running
//! test-terminal count climbs to 54 after this WU.
//!
//! Strict TDD (CONTRIBUTING.md:7): tests authored alongside src/terminal/event.zig
//! in the same commit; the WU's first commit contains the type-level surface
//! only — no parser logic yet (lands in WU 3.2).

const std = @import("std");
const testing = std.testing;

const event = @import("event");

// =============================================================================
// Scenario 1 — Mods default values (REQ-TCL-004 + C30).
//   GIVEN `Mods{}` constructed anonymously
//   WHEN accessed
//   THEN `mods.ctrl == false`
// =============================================================================

test "Mods default ctrl is false (C30)" {
    const m: event.Mods = .{};
    try testing.expectEqual(false, m.ctrl);
}

test "Mods explicit ctrl true round-trips" {
    const m: event.Mods = .{ .ctrl = true };
    try testing.expectEqual(true, m.ctrl);
}

// =============================================================================
// Scenario 2 — Key anonymous-struct-literal coercion without .mods (C30).
//   GIVEN `.{ .code = .{ .char = @as(u21, 'a') }, .event = .press }`
//   WHEN coerced into Key
//   THEN the missing `.mods` field takes its default value (Mods{} per C30)
//   AND `key.mods.ctrl == false`
// =============================================================================

test "Key anonymous struct coerces without .mods (C30 lock-in)" {
    const k: event.Key = .{ .code = .{ .char = @as(u21, 'a') }, .event = .press };
    try testing.expectEqual(false, k.mods.ctrl);
    try testing.expectEqual(event.EventKind.press, k.event);
    try testing.expect(k.code == .char);
}

test "Key with explicit mods overrides the default" {
    const k: event.Key = .{
        .code = .{ .char = @as(u21, 'c') },
        .mods = .{ .ctrl = true },
        .event = .press,
    };
    try testing.expectEqual(true, k.mods.ctrl);
}

// =============================================================================
// Scenario 3 — KeyCode union shape (CAP-33 public surface).
//   GIVEN KeyCode is a tagged union
//   WHEN @typeInfo is inspected
//   THEN there are >= 16 fields (char + backspace + enter + esc + tab + 4 arrows + 12 function keys)
// =============================================================================

test "KeyCode union has char + named keys" {
    const fields = @typeInfo(event.KeyCode).@"union".fields;
    try testing.expect(fields.len >= 16);

    // Spot-check the named tags exist by constructing each.
    const _backspace: event.KeyCode = .backspace;
    const _enter: event.KeyCode = .enter;
    const _esc: event.KeyCode = .esc;
    const _tab: event.KeyCode = .tab;
    const _up: event.KeyCode = .up;
    const _down: event.KeyCode = .down;
    const _left: event.KeyCode = .left;
    const _right: event.KeyCode = .right;
    const _f1: event.KeyCode = .f1;
    const _f12: event.KeyCode = .f12;
    _ = .{ _backspace, _enter, _esc, _tab, _up, _down, _left, _right, _f1, _f12 };
}

// =============================================================================
// Scenario 4 — Event union has the 8 variants src/tui.zig:541-585 switches on.
//   REQ-TCL-004 requires the variant set to be a superset of what the caller
//   switches on. Per src/tui.zig:584 the bare-match void tags are: resize,
//   timeout, none, invalid, paste_start, paste_end, mouse. Plus `.key` carries
//   a Key payload (captured as `|k|` at src/tui.zig:547, 575). Total = 8.
// =============================================================================

test "Event union has 8 variants (REQ-TCL-004 + src/tui.zig:541-585)" {
    try testing.expectEqual(@as(usize, 8), @typeInfo(event.Event).@"union".fields.len);

    // Each tag must be constructible; void tags compile without a payload,
    // the .key tag requires a Key.
    const _key: event.Event = .{ .key = .{ .code = .{ .char = @as(u21, 'q') }, .event = .press } };
    const _resize: event.Event = .resize;
    const _mouse: event.Event = .mouse;
    const _paste_start: event.Event = .paste_start;
    const _paste_end: event.Event = .paste_end;
    const _invalid: event.Event = .invalid;
    const _timeout: event.Event = .timeout;
    const _none: event.Event = .none;
    _ = .{ _key, _resize, _mouse, _paste_start, _paste_end, _invalid, _timeout, _none };
}

// =============================================================================
// Scenario 5 — Event.resize is a void tag (C21 lock-in).
//   GIVEN `.resize` is used as a bare match arm in src/tui.zig:578-583
//   WHEN constructed as `const ev: Event = .resize;`
//   THEN the value carries no payload (otherwise the bare match would fail
//   to compile).
// =============================================================================

test "Event.resize carries no payload (C21)" {
    // If `.resize` carried a payload, this would require `.resize = .{...}`
    // and the bare match in src/tui.zig would not compile.
    const ev: event.Event = .resize;
    try testing.expect(ev == .resize);
}

// =============================================================================
// Scenario 6 — EventKind enum has press/release/repeat.
//   Per design: press is the only phase emitted from the base parser in PR 3;
//   repeat/release arrive in PR 4 alongside kitty keyboard parsing.
// =============================================================================

test "EventKind enum has press, release, repeat" {
    const fields = @typeInfo(event.EventKind).@"enum".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);

    // Comptime name-presence check. f.name is a comptime string slice;
    // std.mem.eql requires comptime-known args when used here.
    const saw_press = comptime blk: {
        var found = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "press")) found = true;
        }
        break :blk found;
    };
    const saw_repeat = comptime blk: {
        var found = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "repeat")) found = true;
        }
        break :blk found;
    };
    const saw_release = comptime blk: {
        var found = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "release")) found = true;
        }
        break :blk found;
    };
    try testing.expect(saw_press);
    try testing.expect(saw_repeat);
    try testing.expect(saw_release);
}

// =============================================================================
// Scenario 7 — terminal.event namespace exposes pollReadable (C23).
//   Per design C23, the renamed smoke canary at tests/tui/terminal_smoke.zig:99-105
//   iterates the terminal.event namespace and asserts pollReadable is present.
// =============================================================================

test "terminal.event exposes pollReadable function (C23 canary)" {
    const info: std.builtin.Type = @typeInfo(event);
    const decls = info.@"struct".decls;
    var found = false;
    for (decls) |d| {
        if (std.mem.eql(u8, d.name, "pollReadable")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// =============================================================================
// Scenario 8 — KeyCode.char payload is u21 (UTF-8 scalar value).
//   RFC 3629 codepoints are u21; the payload type must accommodate 3-byte
//   sequences without narrowing to u8. The 3-byte EURO SIGN is the canonical
//   boundary case.
// =============================================================================

test "KeyCode.char stores a u21 scalar (RFC 3629 boundary case)" {
    const c: event.KeyCode = .{ .char = 0x20AC }; // €
    try testing.expect(c.char == 0x20AC);
    try testing.expect(@TypeOf(c.char) == u21);
}
