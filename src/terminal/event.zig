//! src/terminal/event.zig — terminal event parser (PR 3 slice 5a — types + pollReadable).
//!
//! PR 3 land 1 of 3: public type surface + `pollReadable` only. PR 3 land 2
//! adds the streaming UTF-8 parser + `poll`/`read` plumbing; PR 3 land 3 adds
//! the C11 unconditional in-band resize, C9 EINTR-with-pending handling, and
//! the locked 4-arg `nextWithTimeout` signature. Per design C37 the parser's
//! internal ring buffer (PR 3 land 2) is per-parser-instance, never module-level.
//!
//! Spec coverage:
//!   REQ-TCL-004 — CAP-33 `terminal-event-parser`
//!     C9  EINTR-with-pending yields void `.resize` event (PR 3 land 3)
//!     C11 in-band resize parsing is UNCONDITIONAL (PR 3 land 3)
//!     C21 `.resize` is a void tag (matches src/tui.zig:578-583 bare match)
//!     C22 4th parameter is `pending: *const std.atomic.Value(bool)` (PR 3 land 3)
//!     C23 `pollReadable` exposed on terminal.event namespace (THIS LAND)
//!     C28 returns `anyerror!Event` (so caller `catch continue` compiles, PR 3 land 3)
//!     C30 `Mods.ctrl = false` default + `Key.mods = .{}` default for anonymous-struct coercion
//!     C35 comptime-generic parser injection (PR 3 land 3)
//!     D1  `pending.load(.seq_cst)` inside the parser (matches SIGWINCH handler at src/tui.zig:156)
//!
//! Protocol citations (clean-room per CONTRIBUTING.md:41 + ADR 0001 §Negative):
//!   - xterm ctlseqs §Resize Event / §CSI Ps;Ps;Ps t (in-band resize)
//!   - ECMA-48 §CSI / §SS3 dispatch
//!   - kitty keyboard protocol §Push / §Pop / §Query
//!   - POSIX termios(3) for the underlying tty discipline (parser is termios-agnostic)
//!   - RFC 3629 (UTF-8) §Decoding (PR 3 land 2)

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// =============================================================================
// C30 — Type defaults for anonymous-struct-literal coercion.
//
// Anonymous key literals at tests/tui/runtime_thread.zig:2117, 2167 omit `.mods`:
//     .code = .{ .char = 'a' }, .event = .press
// Without a default for `Key.mods`, anonymous-struct-literal coercion fails
// at compile time. Same for CAP-09 literal grep at tests/termios_sim.zig:69
// (`if (k.code == .char and k.mods.ctrl)`) which depends on `mods.ctrl`.
// =============================================================================

/// Modifier set carried in `Key.mods`. Only `ctrl` lives here for PR 3; the
/// protocol carries shift/alt/super in later slices (kitty kb in PR 4).
pub const Mods = struct {
    ctrl: bool = false,
    // ponytail: future expansion fields (shift, alt, super) when consumers need them
};

/// Key code identifying the physical key pressed. `char` carries a Unicode
/// scalar (u21; UTF-8 decoded in PR 3 land 2). Named codes for keys with
/// no printable glyph or with multi-char ANSI sequences.
pub const KeyCode = union(enum) {
    char: u21,
    backspace,
    enter,
    esc,
    tab,
    up,
    down,
    left,
    right,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    // ponytail: kitty kb extended keys (key_sym encoded) arrive in PR 4
};

/// Lifecycle phase of a key event. PR 3 emits only `.press` from the base
/// parser; kitty kb in PR 4 rounds out `.repeat` and `.release`.
pub const EventKind = enum {
    press,
    release,
    repeat,
};

/// A key event payload. C30: `mods` defaults to `Mods{}` so anonymous struct
/// literals without `.mods` coerce (tests/tui/runtime_thread.zig:2117, 2167).
pub const Key = struct {
    code: KeyCode,
    mods: Mods = .{},
    event: EventKind,
};

// =============================================================================
// C21 — Void variants for non-key events.
//
// `.resize` is intentionally a void tag. Per peer-review C21, src/tui.zig:578-583
// uses a bare match (`resize => { ... getSize ... }`) which would fail to
// compile if `.resize` carried dimensions. The caller's `getSize` call refreshes
// `lifecycle.width` / `lifecycle.height`; the parser's sole job is to surface
// `.resize` instead of swallowing the EINTR as `.none` (see C9 below).
// =============================================================================

/// Event variant returned by the parser. Eight variants:
///   - key          (payload `Key`)        — src/tui.zig:547, 575 captures as `|k|`
///   - resize       (void)                  — src/tui.zig:578 bare match (C21)
///   - mouse        (void)                  — src/tui.zig:584
///   - paste_start  (void)                  — src/tui.zig:584
///   - paste_end    (void)                  — src/tui.zig:584
///   - invalid      (void)                  — src/tui.zig:584
///   - timeout      (void)                  — src/tui.zig:584
///   - none         (void)                  — src/tui.zig:584
pub const Event = union(enum) {
    key: Key,
    resize: void,
    mouse: void,
    paste_start: void,
    paste_end: void,
    invalid: void,
    timeout: void,
    none: void,
};

// =============================================================================
// C23 — pollReadable.
//
// Thin wrapper around `poll(2)` with `timeout=0` (non-blocking). Returns
// `true` iff the file descriptor has readable data (`revents & POLL.IN`),
// `false` on timeout or any error. The renamed smoke canary at
// tests/tui/terminal_smoke.zig:99-105 (formerly tests/tui/mibu_smoke.zig)
// asserts the symbol exists on `terminal.event`; this implementation gives
// it a real, CI-runnable body.
//
// ponytail: this is the minimum that satisfies C23 (existence) plus a real
// poll(2) round-trip on Linux. Other Unix variants defer to TODO if
// `builtin.os.tag != .linux`. The `_io` parameter is accepted for API
// symmetry with `nextWithTimeout` but not consulted here; callers may
// pass a real or `undefined` `std.Io`.
// =============================================================================

pub fn pollReadable(io: std.Io, file: std.Io.File) bool {
    _ = io;
    if (builtin.os.tag != .linux) {
        // ponytail: only Linux is in the CI matrix (Arch + ubuntu-latest);
        // return true as a non-lying best-effort on other platforms.
        return true;
    }
    var pfd: linux.pollfd = .{
        .fd = file.handle,
        .events = linux.POLL.IN,
        .revents = 0,
    };
    const rc = std.posix.poll((&pfd)[0..1], 0);
    if (rc) |ready| {
        return ready > 0 and (pfd.revents & linux.POLL.IN) != 0;
    } else |_| {
        // On error, treat as not-readable; the caller's `nextWithTimeout`
        // returns `.timeout` and the event loop spins another iteration.
        return false;
    }
}

// =============================================================================
// Inline tests — document the public API contracts at the type level.
// Tests in tests/terminal/event_types.zig cover the same ground with RED
// signatures so they're discoverable through the test-terminal build step.
// =============================================================================

test "Mods default value is all-false" {
    try std.testing.expect(Mods{} == .{ .ctrl = false });
    try std.testing.expect((Mods{}).ctrl == false);
}

test "Key anonymous-struct coercion omits mods (C30)" {
    const k: Key = .{ .code = .{ .char = 'a' }, .event = .press };
    try std.testing.expect(k.mods.ctrl == false);
    try std.testing.expect(k.event == .press);
    try std.testing.expect(k.code == .char);
}

test "key char payload is u21" {
    try std.testing.expect(@typeInfo(KeyCode).@"union".fields.len > 0);
    const kc: KeyCode = .{ .char = '€' };
    try std.testing.expect(kc.char == 0x20AC);
}

test "Event union has 8 variants matching src/tui.zig switch arms" {
    try testing.expectEqual(@as(usize, 8), @typeInfo(Event).@"union".fields.len);
    // Spot-check the bare-match void tags exist with void payloads.
    const ev: Event = .resize;
    _ = ev;
    try testing.expectEqual(Event.resize, .resize);
    try testing.expectEqual(Event.none, .none);
    try testing.expectEqual(Event.timeout, .timeout);
}

test "Event.resize is a void tag (C21)" {
    // The bare match `resize => { ... }` at src/tui.zig:578 requires no payload.
    // Tag-only construction proves there is no payload to construct.
    const ev: Event = .resize;
    _ = ev;
}

test "pollReadable exists on terminal.event namespace (C23)" {
    const info: std.builtin.Type = @typeInfo(@import("event.zig"));
    const decls = info.@"struct".decls;
    var found = false;
    for (decls) |d| {
        if (std.mem.eql(u8, d.name, "pollReadable")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

const testing = std.testing;
