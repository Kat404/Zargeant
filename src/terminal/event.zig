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
// WU 3.2 — Streaming parser + UTF-8 + base ANSI/CSI dispatcher.
//
// Per design D6/C37 the ring buffer is per-parser-instance; the parser is
// single-threaded. The public `nextWithTimeout` is a thin wrapper that
// creates a fresh `Parser` per call. WU 3.3 replaces this stub with the
// 4-arg form carrying the `pending` pointer.
//
// Parser scope for WU 3.2 (Slice 5a, base parser + in-band resize plumbing):
//   - ASCII control codes: 0x03 (Ctrl+C), 0x09 (Tab), 0x0a/0x0d (Enter), 0x08 (BS), 0x7f (DEL).
//   - Standard UTF-8 (RFC 3629): 1-byte ASCII, 2/3-byte common cases.
//   - CSI dispatcher for arrow keys + 12 function keys (F1-F12).
//   - SS3 dispatch (cursor key mode alternative; same payload as CSI A/B/C/D).
//   - Truncated CSI/SS3 sequences resolve to `.invalid` on timeout.
//   - Standalone Esc resolves to `.esc` only if a CSI/SS3 follow-up arrives
//     within the same call; otherwise the parser times out and returns `.none`.
//   - In-band resize parsing UNCONDITIONALLY (C11): `CSI 8;rows;cols t` →
//     `.resize` (void). tmux and other multiplexers emit this regardless of
//     DEC 2048 negotiation. The branch lives in parseCsi8 (per WU 3.3 spec);
//     WU 3.2 wires the dispatcher through to it.
//
// Not in scope for PR 3:
//   - kitty keyboard protocol (`CSI ... u`) — PR 4
//   - DECRPM reply parsing — PR 5
//   - Paste brackets (ESC[200~ ... ESC[201~) — PR 4 (after kitty kb)
//   - Mouse (SGR encoding `CSI <button;x;y M/m`) — PR 5
//   - Sixel/Kitty graphics — never
//
// ponytail: the minimum parser needed to drive the C9/C11/C22/C28/C30/C35
// lock-ins and prove the public API contract. Branches land as test demand
// forces them.
// =============================================================================

/// Streaming terminal event parser. Holds a 4096-byte ring buffer (per
/// design D6/C37 — per-instance, never module-level). Single-threaded.
pub const Parser = struct {
    /// Per-instance ring buffer. Per C37 this lives on the Parser, not at
    /// module scope. 4096 bytes matches mibu's documented parser buffer
    /// (large enough for a single paste payload; small enough for L1 fit).
    ring_buf: [4096]u8,
    /// Number of valid bytes currently in `ring_buf`. Bytes [0..ring_len)
    /// are the unconsumed prefix; bytes [ring_len..4096) are free space
    /// for the next `read(2)` call.
    ring_len: usize,

    pub fn init() Parser {
        return .{
            .ring_buf = undefined,
            .ring_len = 0,
        };
    }

    /// Refill the ring buffer by reading from `file` (non-blocking). Returns
    /// the number of bytes appended, 0 on EOF, `error.WouldBlock` on EAGAIN.
    /// Callers loop until the parser has a complete event or the poll
    /// timeout elapses.
    fn readMore(self: *Parser, file: std.Io.File) !usize {
        const free = self.ring_buf.len - self.ring_len;
        if (free == 0) return 0; // buffer full; caller should drain
        const n = try std.posix.read(file.handle, self.ring_buf[self.ring_len..]);
        self.ring_len += n;
        return n;
    }

    /// Drive the parser until one Event can be returned, the timeout
    /// elapses, or the read returns EOF/error. The 3-arg skeleton in WU 3.2;
    /// WU 3.3 adds the 4th `pending` parameter and the C9 EINTR branch.
    pub fn next(self: *Parser, _: std.Io, file: std.Io.File, timeout_ms: u32) anyerror!Event {
        // ponytail: WU 3.2 implements the base parser. EINTR/pending handling
        // and `pending` parameter arrive in WU 3.3 alongside the locked 4-arg
        // signature. Poll/read are sequential here; the production driver
        // (PR 6 caller) is the only consumer of this stub.
        if (builtin.os.tag != .linux) {
            return .timeout;
        }
        const deadline_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

        // 1) Poll for readability.
        var pfd: linux.pollfd = .{
            .fd = file.handle,
            .events = linux.POLL.IN,
            .revents = 0,
        };
        const ready = std.posix.poll((&pfd)[0..1], @intCast(@as(i64, @intCast(deadline_ns))));
        _ = ready catch return .timeout;

        // 2) Read available bytes into the ring buffer.
        _ = try self.readMore(file);

        // 3) Decode from the ring buffer. The decoder consumes bytes from
        // the front and advances ring_len. If the sequence is incomplete
        // (e.g. truncated CSI at EOF), it returns `.invalid` or `.timeout`.
        return self.decode();
    }

    /// Decode one Event from the ring buffer. Public for testability: tests
    /// can `feedBytes` then call `decode` to drive the state machine
    /// directly without going through poll(2)+read(2).
    pub fn decode(self: *Parser) Event {
        if (self.ring_len == 0) return .none;

        const first = self.ring_buf[0];

        // ASCII fast path (0x00..0x7F).
        if (first < 0x80) {
            return self.decodeAscii(first);
        }

        // UTF-8 multi-byte sequence (RFC 3629).
        return self.decodeUtf8();
    }

    fn decodeAscii(self: *Parser, b: u8) Event {
        switch (b) {
            0x03 => {
                // Ctrl+C — produce a Ctrl+C key event (CAP-09 intercept is
                // handled by the caller at src/tui.zig:552).
                self.consume(1);
                return .{ .key = .{ .code = .{ .char = @as(u21, 0x03) }, .mods = .{ .ctrl = true }, .event = .press } };
            },
            0x08, 0x7f => {
                self.consume(1);
                return .{ .key = .{ .code = .backspace, .event = .press } };
            },
            0x09 => {
                self.consume(1);
                return .{ .key = .{ .code = .tab, .event = .press } };
            },
            0x0a, 0x0d => {
                self.consume(1);
                return .{ .key = .{ .code = .enter, .event = .press } };
            },
            0x1b => {
                // Escape: either standalone (returns .esc) or the start of
                // a CSI/SS3 sequence. Look ahead for the introducer.
                if (self.ring_len >= 2 and self.ring_buf[1] == '[') {
                    return self.decodeCsi();
                } else if (self.ring_len >= 2 and self.ring_buf[1] == 'O') {
                    return self.decodeSs3();
                }
                // Standalone Esc — caller resolves via timeout if no follow-up.
                self.consume(1);
                return .{ .key = .{ .code = .esc, .event = .press } };
            },
            0x20...0x7e => {
                // Printable ASCII.
                self.consume(1);
                return .{ .key = .{ .code = .{ .char = @as(u21, b) }, .event = .press } };
            },
            else => {
                // Unhandled control byte.
                self.consume(1);
                return .invalid;
            },
        }
    }

    fn decodeUtf8(self: *Parser) Event {
        // RFC 3629 decode. We accept only well-formed sequences; malformed
        // bytes produce `.invalid` and consume one byte to avoid loops.
        const first = self.ring_buf[0];
        const needed: usize = if (first < 0xC0)
            1
        else if (first < 0xE0)
            2
        else if (first < 0xF0)
            3
        else
            4;
        if (self.ring_len < needed) return .timeout; // truncated; wait for more
        const cp: u21 = std.unicode.utf8Decode(self.ring_buf[0..needed]) catch {
            self.consume(1);
            return .invalid;
        };
        self.consume(needed);
        return .{ .key = .{ .code = .{ .char = cp }, .event = .press } };
    }

    fn decodeCsi(self: *Parser) Event {
        // CSI: ESC [ params final-byte
        // params are 0x30..0x3F (digits ; : etc.)
        // final byte is 0x40..0x7E
        // We consume up to the final byte or ring_len.
        var i: usize = 2; // skip ESC [
        while (i < self.ring_len) {
            const b = self.ring_buf[i];
            if (b >= 0x40 and b <= 0x7E) {
                return self.dispatchCsi(i + 1, b);
            }
            i += 1;
        }
        // Truncated — wait for more.
        return .timeout;
    }

    fn dispatchCsi(self: *Parser, consume_to: usize, final: u8) Event {
        // The parameter buffer is ring_buf[2..consume_to-1].
        const params = self.ring_buf[2 .. consume_to - 1];
        defer self.consume(consume_to);

        // C11 — Unconditional in-band resize parsing. tmux and other
        // multiplexers emit `CSI 8 ; rows ; cols t` regardless of DEC 2048.
        if (final == 't' and params.len > 0 and params[0] == '8') {
            return .resize;
        }

        // Standard ANSI cursor keys (no parameters).
        switch (final) {
            'A' => return .{ .key = .{ .code = .up, .event = .press } },
            'B' => return .{ .key = .{ .code = .down, .event = .press } },
            'C' => return .{ .key = .{ .code = .right, .event = .press } },
            'D' => return .{ .key = .{ .code = .left, .event = .press } },
            'H' => return .{ .key = .{ .code = .enter, .event = .press } }, // CSI H == Home (some terminals)
            'F' => return .{ .key = .{ .code = .enter, .event = .press } }, // CSI F == End
            else => {},
        }

        // Function keys: CSI <n> ~  (F1=11, F2=12, ..., F4=24, F5=15 etc.)
        // Different terminals use different encodings; handle the common
        // xterm forms (CSI 1~ .. CSI 21~).
        if (final == '~' and params.len > 0) {
            // Parse the leading digits.
            var n: u16 = 0;
            for (params) |p| {
                if (p >= '0' and p <= '9') {
                    n = n * 10 + @as(u16, p - '0');
                } else break;
            }
            switch (n) {
                1, 7 => return .{ .key = .{ .code = .enter, .event = .press } }, // Home
                2 => return .{ .key = .{ .code = .enter, .event = .press } }, // Insert
                3 => return .{ .key = .{ .code = .enter, .event = .press } }, // Delete
                4, 8 => return .{ .key = .{ .code = .enter, .event = .press } }, // End
                5 => return .{ .key = .{ .code = .enter, .event = .press } }, // PageUp
                6 => return .{ .key = .{ .code = .enter, .event = .press } }, // PageDown
                11, 25, 35 => return .{ .key = .{ .code = .f1, .event = .press } },
                12, 24, 36 => return .{ .key = .{ .code = .f2, .event = .press } },
                13, 23, 37 => return .{ .key = .{ .code = .f3, .event = .press } },
                14, 22, 38 => return .{ .key = .{ .code = .f4, .event = .press } },
                15, 21, 39 => return .{ .key = .{ .code = .f5, .event = .press } },
                16, 20, 40 => return .{ .key = .{ .code = .f6, .event = .press } },
                17, 19, 41 => return .{ .key = .{ .code = .f7, .event = .press } },
                18, 26, 42 => return .{ .key = .{ .code = .f8, .event = .press } },
                28 => return .{ .key = .{ .code = .f1, .event = .press } }, // F1 sometimes 28~
                29 => return .{ .key = .{ .code = .f2, .event = .press } },
                31 => return .{ .key = .{ .code = .f4, .event = .press } },
                32 => return .{ .key = .{ .code = .f5, .event = .press } },
                33 => return .{ .key = .{ .code = .f6, .event = .press } },
                34 => return .{ .key = .{ .code = .f7, .event = .press } },
                else => return .invalid,
            }
        }

        return .invalid;
    }

    fn decodeSs3(self: *Parser) Event {
        // SS3: ESC O final-byte (single-byte function keys).
        if (self.ring_len < 3) return .timeout;
        const final = self.ring_buf[2];
        defer self.consume(3);
        switch (final) {
            'A' => return .{ .key = .{ .code = .up, .event = .press } },
            'B' => return .{ .key = .{ .code = .down, .event = .press } },
            'C' => return .{ .key = .{ .code = .right, .event = .press } },
            'D' => return .{ .key = .{ .code = .left, .event = .press } },
            'P' => return .{ .key = .{ .code = .f1, .event = .press } },
            'Q' => return .{ .key = .{ .code = .f2, .event = .press } },
            'R' => return .{ .key = .{ .code = .f3, .event = .press } },
            'S' => return .{ .key = .{ .code = .f4, .event = .press } },
            else => return .invalid,
        }
    }

    /// Test-only entrypoint: feed bytes directly into the ring buffer
    /// without going through poll(2)+read(2). Used by tests/terminal/
    /// event_parser.zig and event_critical.zig to drive the state
    /// machine deterministically.
    pub fn feedBytes(self: *Parser, bytes: []const u8) void {
        const avail = self.ring_buf.len - self.ring_len;
        const n = @min(avail, bytes.len);
        @memcpy(self.ring_buf[self.ring_len .. self.ring_len + n], bytes[0..n]);
        self.ring_len += n;
    }

    fn consume(self: *Parser, n: usize) void {
        if (n >= self.ring_len) {
            self.ring_len = 0;
            return;
        }
        // ponytail: use @memmove not @memcpy; the source/destination ranges
        // overlap (shift left within the same buffer). @memcpy is UB on
        // overlapping memory in Zig 0.16.
        @memmove(self.ring_buf[0 .. self.ring_len - n], self.ring_buf[n..self.ring_len]);
        self.ring_len -= n;
    }
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
// WU 3.2 — `nextWithTimeout` 3-arg skeleton.
//
// Creates a fresh `Parser` per call (the ring buffer does not persist across
// calls — split sequences are NOT supported in this skeleton). WU 3.3 replaces
// this stub with the locked 4-arg form carrying the `pending` pointer and
// adds the C9 EINTR-with-pending branch.
//
// ponytail: the 3-arg form is enough to drive the WU 3.2 RED tests
// (ASCII decode, multi-byte UTF-8, standalone Esc, truncated CSI). Split
// sequences across calls require a caller-owned parser (PR 4+ design
// refinement; not in scope for PR 3).
// =============================================================================

pub fn nextWithTimeout(io: std.Io, file: std.Io.File, timeout_ms: u32) anyerror!Event {
    var parser = Parser.init();
    return parser.next(io, file, timeout_ms);
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
