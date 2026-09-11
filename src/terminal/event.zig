//! src/terminal/event.zig — terminal event parser (PR 3 slice 5a — types + pollReadable).
//!
//! PR 3 land 1 of 3: public type surface + `pollReadable` only. PR 3 land 2
//! adds the streaming UTF-8 parser + `poll`/`read` plumbing; PR 3 land 3 adds
//! the C11 unconditional in-band resize, C9 EINTR-with-pending handling, and
//! the locked 4-arg `nextWithTimeout` signature. Per design C37 the parser's
//! internal ring buffer (PR 3 land 2) is per-parser-instance, never module-level.
//! PR 4 extends with the kitty kb CSI ... u parser (REQ-TCL-004 5b) and
//! extends Mods with shift/alt/super_ to carry the kitty kb modifier bitmask.
//!
//! Spec coverage:
//!   REQ-TCL-004 — CAP-33 `terminal-event-parser`
//!     C9  EINTR-with-pending yields void `.resize` event (PR 3 land 3)
//!     C11 in-band resize parsing is UNCONDITIONAL (PR 3 land 3)
//!     C21 `.resize` is a void tag (matches src/tui.zig:578-583 bare match)
//!     C22 4th parameter is `pending: *const std.atomic.Value(bool)` (PR 3 land 3)
//!     C23 `pollReadable` exposed on terminal.event namespace (PR 3 land 1)
//!     C28 returns `anyerror!Event` (so caller `catch continue` compiles, PR 3 land 3)
//!     C30 `Mods.ctrl = false` default + `Key.mods = .{}` default for anonymous-struct coercion
//!     C35 comptime-generic parser injection (PR 3 land 3)
//!     D1  `pending.load(.seq_cst)` inside the parser (matches SIGWINCH handler at src/tui.zig:156)
//!     5b  Kitty keyboard sub-capability (PR 4): CSI ... u press/repeat/release + modifier carry
//!
//! Protocol citations (clean-room per CONTRIBUTING.md:41 + ADR 0001 §Negative):
//!   - xterm ctlseqs §Resize Event / §CSI Ps;Ps;Ps t (in-band resize)
//!   - ECMA-48 §CSI / §SS3 dispatch
//!   - kitty keyboard protocol §Push / §Pop / §Query / §Event encoding (PR 4)
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

/// Modifier set carried in `Key.mods`. PR 3 carries only `ctrl` (CAP-09 +
/// Ctrl+C intercept at src/tui.zig:552); PR 4 extends with shift/alt/super_
/// to carry the kitty kb modifier bitmask (REQ-TCL-004 5b).
///
/// Per the kitty keyboard protocol spec the modifier bitmask is:
///     shift=1, alt=2, ctrl=4, super=8, hyper=16, meta=32, capslock=64, numlock=128.
/// PR 4 decodes the common 4 (shift/alt/ctrl/super); hyper/meta/capslock/
/// numlock remain undecoded until a consumer needs them. Ponytail: ship the
/// minimum field set the byte-level protocol needs, expand on consumer demand.
///
/// All fields default to false (C30 lock-in) so `Key{ .code = ..., .event =
/// .press }` continues to coerce without specifying `.mods` (preserves
/// anonymous-struct-literal coercion at tests/tui/runtime_thread.zig:2117, 2167
/// and the CAP-09 literal grep at tests/termios_sim.zig:69).
pub const Mods = struct {
    ctrl: bool = false,
    // PR 4 extension (C30): shift/alt/super_ carry the kitty kb modifier bits.
    // Populated only when kitty kb mode is active (caller-side check in PR 6
    // via lifecycle.kitty_flags_pushed); PR 4 unconditionally parses `u`
    // sequences as kitty kb key events.
    shift: bool = false,
    alt: bool = false,
    // ponytail: 'super' would be the natural name (matches kitty kb spec)
    // but the apply prompt flagged it as a potential Zig keyword. PR 4 uses
    // `super_`; PR 6+ can rename to `super` if Zig confirms it's free.
    super_: bool = false,
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
    /// elapses, or the read returns EOF/error. The WU 3.3 form takes the
    /// `pending` atomic pointer (C22, C9) and an injected `poll_fn`
    /// (D4/C35 fix). Production callers use the free function
    /// `nextWithTimeout`; tests use this method directly with a mock
    /// `poll_fn` to drive C9 EINTR scenarios deterministically.
    ///
    /// C9 contract: when `poll_fn` returns `error.Interrupted` (EINTR from
    /// SIGWINCH), the parser checks `pending.load(.seq_cst)` (D1). If the
    /// caller stored `true` in the atomic (the SIGWINCH handler at
    /// src/tui.zig:153-157 does this), the parser returns the void
    /// `.resize` event. Otherwise it returns `.none`. The parser does NOT
    /// call `getSize` — the caller at src/tui.zig:578-583 handles
    /// dimension refresh in the `.resize` arm.
    pub fn next(
        self: *Parser,
        _: std.Io,
        file: std.Io.File,
        timeout_ms: u32,
        pending: *const std.atomic.Value(bool),
        poll_fn: *const fn (fds: []linux.pollfd, timeout: i32) anyerror!usize,
    ) anyerror!Event {
        if (builtin.os.tag != .linux) {
            return .timeout;
        }

        // 1) Poll for readability. On EINTR (C9), check `pending` and
        // return early — the parser does not retry the poll (the SIGWINCH
        // handler has already stored into the atomic).
        var pfd: linux.pollfd = .{
            .fd = file.handle,
            .events = linux.POLL.IN,
            .revents = 0,
        };
        const timeout_i32: i32 = std.math.cast(i32, timeout_ms) orelse std.math.maxInt(i32);
        const ready = poll_fn((&pfd)[0..1], timeout_i32) catch |err| switch (err) {
            // C9 — EINTR after SIGWINCH delivery. Per design D1, load
            // with `.seq_cst` to match the handler's `.seq_cst` store at
            // src/tui.zig:153-157. On x86_64 and AArch64, `.seq_cst` and
            // `.acquire` emit identical instructions; `.seq_cst` is the
            // chosen safety margin (peer-review C33).
            error.Interrupted => {
                if (pending.load(.seq_cst)) {
                    return .resize;
                }
                return .none;
            },
            else => return .timeout,
        };

        // 2) Read available bytes only if poll(2) indicated readability.
        // Reading unconditionally would block on a fd with no data (e.g.
        // stdin when the test runner redirected it). poll(2) returning 0
        // means timeout; we report `.none` (no event arrived in the window).
        if (ready == 0) return .none;
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

    // =============================================================================
    // PR 4 — Kitty keyboard protocol parser (REQ-TCL-004 5b).
    //
    // Per the kitty keyboard protocol spec
    // (https://sw.kovidgoyal.net/kitty/keyboard-protocol/) the key event
    // format when `report_event_types` flag is enabled is:
    //
    //     CSI codepoint[:shifted_key] ; modifiers [:[event_type]] u
    //
    // PR 4 implements the colon-shorthand event_type detection:
    //     - nothing after modifiers → press (default)
    //     - `:`  (no semicolon) after modifiers → repeat
    //     - `:;` (colon-semicolon) after modifiers → release
    //
    // Modifier bitmask (kitty kb spec): shift=1, alt=2, ctrl=4, super=8,
    // hyper=16, meta=32, capslock=64, numlock=128. PR 4 decodes the common 4
    // (shift/alt/ctrl/super); hyper/meta/capslock/numlock remain undecoded
    // until a consumer needs them.
    //
    // PR 4 only uses the BASE codepoint (before the optional `:` shifted-key
    // separator); the shifted variant is intentionally dropped. PR 6 may
    // surface it via a separate field if a TUI consumer needs the distinction.
    //
    // For PR 4 we assume kitty kb mode is ACTIVE for all `u` sequences (the
    // caller-side gating flag `lifecycle.kitty_flags_pushed` lands in PR 6
    // per the apply prompt's PR 6 caller check). The push format `CSI > N u`
    // is rejected explicitly (params starts with `>`) so we never interpret
    // our own push commands as key events.
    // =============================================================================

    /// Parse kitty kb parameter buffer `codepoint[:shifted] ; modifiers [:[event]]`.
    /// Returns the parsed `Key` on success, or `null` if the buffer is malformed,
    /// empty, or represents a push command (`>` first param).
    ///
    /// The returned `Key.code` is always `KeyCode.char` carrying the BASE
    /// codepoint (the part before `:` in `codepoint[:shifted]`). `Key.event`
    /// carries press/repeat/release per the event_type detection above.
    /// `Key.mods` carries the decoded shift/alt/ctrl/super bits.
    fn parseKittyKb(params: []const u8) ?Key {
        // Reject empty params (defensive — the dispatcher already checks).
        if (params.len == 0) return null;
        // Reject push format: `CSI > N u` has params starting with `>`.
        if (params[0] == '>') return null;

        // Split on `;` — first segment is `codepoint[:shifted]`, second is
        // `modifiers[:event]`. Ignore any third+ segment (text_as_code_points
        // in the full kitty kb spec; out of scope for PR 4).
        var iter = std.mem.splitScalar(u8, params, ';');
        const key_str = iter.next() orelse return null;
        const mods_str_raw = iter.next() orelse return null;

        // Parse base codepoint from "codepoint[:shifted]". Take the slice
        // BEFORE the first `:` if present — that's the base layout key.
        const colon_in_key = std.mem.indexOfScalar(u8, key_str, ':');
        const codepoint_slice = if (colon_in_key) |i| key_str[0..i] else key_str;
        const codepoint_trimmed = std.mem.trim(u8, codepoint_slice, " ");
        const key_code = std.fmt.parseInt(u21, codepoint_trimmed, 10) catch return null;

        // Parse modifiers and detect event type.
        //
        // Detection rules (apply prompt §"Implementation requirements" item 3):
        //     - params ends with `:;` → release
        //     - params ends with `:` (but not `:;`) → repeat
        //     - params doesn't end with `:` or `:;` → press (default)
        //
        // We look at the END of the full params buffer (not just the mods
        // segment after the `;` split) because the trailing `:;` release
        // signal spans the `;` separator — splitting on `;` would put the
        // trailing `:` in segments[1] and the empty remainder in segments[2],
        // making the release indicator invisible from mods_str_raw alone.
        //
        // Modifier VALUE parsing: take the slice of mods_str_raw BEFORE the
        // `:` (if any). This handles the press/repeat cases correctly; for
        // release, mods_str_raw still has the `:` prefix which we strip.
        const mods_trimmed = std.mem.trim(u8, mods_str_raw, " ");
        const colon_in_mods = std.mem.indexOfScalar(u8, mods_trimmed, ':');
        const mods_val_slice = if (colon_in_mods) |i| mods_trimmed[0..i] else mods_trimmed;
        const mods_val_trimmed = std.mem.trim(u8, mods_val_slice, " ");
        const mods_val = std.fmt.parseInt(u8, mods_val_trimmed, 10) catch 0;

        const event_kind: EventKind = if (std.mem.endsWith(u8, params, ":;"))
            .release
        else if (std.mem.endsWith(u8, params, ":"))
            .repeat
        else
            .press;

        return Key{
            .code = .{ .char = key_code },
            .mods = .{
                .shift = (mods_val & 1) != 0,
                .alt = (mods_val & 2) != 0,
                .ctrl = (mods_val & 4) != 0,
                .super_ = (mods_val & 8) != 0,
            },
            .event = event_kind,
        };
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

        // PR 4 — Kitty keyboard protocol (REQ-TCL-004 5b). When the terminal
        // emits a CSI ... u sequence, parse it as a modified key event with
        // press/repeat/release distinction + shift/alt/ctrl/super modifiers.
        //
        // For PR 4 we assume kitty kb mode is ACTIVE for every `u` sequence
        // (the caller-side `lifecycle.kitty_flags_pushed` gate lands in PR 6
        // per the apply prompt's PR 6 caller check). The push format
        // `CSI > N u` is rejected inside parseKittyKb (params[0] == '>').
        // If parseKittyKb returns null (malformed input), control falls
        // through to the existing dispatch logic which returns `.invalid`.
        if (final == 'u' and params.len > 0) {
            if (parseKittyKb(params)) |key| {
                return .{ .key = key };
            }
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
// WU 3.3 — locked `nextWithTimeout` 4-arg signature (C22) + `anyerror!Event`
// return (C28) + C9 EINTR-with-pending branch (D1 `.seq_cst` load).
//
// The 4th argument is the caller's atomic pointer (NOT a private module-level
// atomic). PR 6 updates src/tui.zig:540 from `mibu.events.nextWithTimeout(io,
// file, 16)` to `terminal.event.nextWithTimeout(io, file, 16, &lifecycle.
// redraw_pending)`. This is the ONLY non-1:1 PR 6 call-site adjustment
// alongside C27 at src/tui.zig:245 (enableRawMode 2-arg).
//
// The `pending` pointer is loaded with `.seq_cst` (D1) to match the
// SIGWINCH handler's `.seq_cst` store at src/tui.zig:153-157. The parser
// does NOT call `getSize` — the caller at src/tui.zig:578-582 handles
// dimension refresh in the `.resize` arm. Returning `.resize` (void) on
// EINTR+pending is the C9 lock-in; returning `.none` on EINTR-no-pending
// is the C9 complement.
//
// ponytail: the wrapper creates a fresh Parser per call (the ring buffer
// does not persist across calls). Split sequences across calls require a
// caller-owned parser instance — out of scope for PR 3 (the apply-prompt
// spec lands this as a PR 4+ design refinement).
// =============================================================================

/// Default poll function used by the public `nextWithTimeout`. Tests inject
/// their own mock via `Parser.nextWithPoll` (D4/C35 fix — no mutable global).
fn defaultPollFn(fds: []linux.pollfd, timeout: i32) anyerror!usize {
    return std.posix.poll(fds, timeout);
}

pub fn nextWithTimeout(
    io: std.Io,
    file: std.Io.File,
    timeout_ms: u32,
    pending: *const std.atomic.Value(bool),
) anyerror!Event {
    var parser = Parser.init();
    return parser.next(io, file, timeout_ms, pending, &defaultPollFn);
}

// =============================================================================
// Inline tests — document the public API contracts at the type level.
// Tests in tests/terminal/event_types.zig cover the same ground with RED
// signatures so they're discoverable through the test-terminal build step.
// =============================================================================

test "Mods default value is all-false (PR 3 ctrl + PR 4 shift/alt/super_)" {
    // PR 3 carried only `ctrl`; PR 4 extends with shift/alt/super_ for the
    // kitty kb modifier bitmask. All four default to false (C30 lock-in).
    // Field-by-field assertions here because the cross-field-struct equality
    // shorthand `Mods{} == .{ .ctrl = false }` no longer captures the
    // extended struct shape.
    try testing.expect((Mods{}).ctrl == false);
    try testing.expect((Mods{}).shift == false);
    try testing.expect((Mods{}).alt == false);
    try testing.expect((Mods{}).super_ == false);
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
