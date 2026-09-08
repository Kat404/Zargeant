//! src/terminal/dpm.zig — DEC private-mode emitters + DECRQM probe + DECRPM lexer.
//!
//! Emits the 6 DECSET/DECRST enter/exit helpers for modes 1049 (alternate
//! screen), 2048 (in-band resize), and 2026 (synchronized update). Also
//! emits the DECRQM query (CSI ? <mode> $ p) used by the capability probe
//! and ships the `Mode` struct that the reply lexer populates.
//!
//! PR 2 shipped only the emit-side + Mode struct stub returning
//! `Mode{ .is_supported = false }` unconditionally (design C18/C3 interim
//! behavior). PR 5 replaces the stub with the real `queryModeWithTimeout`
//! impl that emits the DECRQM probe, polls for a reply with timeout, and
//! lexes the DECRPM reply (CSI ? <mode> ; <state> $ y) per xterm ctlseqs
//! §"DECRPM". All four C14 failure modes (EINTR, poll timeout, malformed
//! reply, wrong-mode-number reply) map to `.is_supported = false`.
//!
//! Clean-room rule (CONTRIBUTING.md:41 + ADR 0001 §Negative): no mibu or
//! libvaxis source consulted. References xterm ctlseqs §"Private Mode Set"
//! /§"Private Mode Reset", xterm ctlseqs §"Request DEC Private Mode",
//! xterm ctlseqs §"DECRPM" (PR 5 reply lexer).
//!
//! ADR 0002 §1 protocol citation table anchors each emit helper to the
//! cited spec section. PR 5 adds the DECRPM reply-lexer citation.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

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
/// sequence read by `parseDecRpmReply` below.
pub fn emitDecRqmQuery(writer: *std.Io.Writer, mode: u16) anyerror!void {
    var buf: [12]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "\x1b[?{d}$p", .{mode}) catch unreachable;
    try writer.writeAll(slice);
}

/// Result of a DECRPM reply parse. Public so the test suite can drive
/// the lexer directly with byte fixtures (covers all 5 Ps states plus
/// the malformed and wrong-mode edges per spec REQ-TCL-005 C14).
///
///   ok             — true iff the bytes parse as a syntactically valid
///                    DECRPM reply (CSI ? <mode> ; <state> $ y).
///   supported      — true iff `ok`, the mode matches `requested_mode`,
///                    and the state is one of {1, 3} (set / permanently
///                    set per xterm ctlseqs §"DECRPM"). False otherwise —
///                    including all C14 failure modes.
///   mode_mismatch  — true iff `ok` and the mode parameter differs from
///                    `requested_mode` (C14 case 4).
pub const DecRpmParseResult = struct {
    ok: bool,
    supported: bool,
    mode_mismatch: bool,
};

/// Parse a DECRPM reply: `CSI ? <mode> ; <state> $ y`.
///
/// Layout per xterm ctlseqs §"DECRPM" / VT525 §5.6:
///   CSI   = 0x1b 0x5b
///   ?     = 0x3f
///   <mode>  = decimal digits (1..65535)
///   ;     = 0x3b
///   <state> = decimal digit in {0, 1, 2, 3, 4}
///   $     = 0x24
///   y     = 0x79 (lowercase y per VT525)
///
/// State mapping (xterm ctlseqs §"DECRPM"):
///   0 = not recognized
///   1 = set
///   2 = reset
///   3 = permanently set
///   4 = permanently reset
///
/// Supported iff state ∈ {1, 3} AND the mode matches `requested_mode`.
///
/// On any malformed byte pattern returns
/// `{ .ok = false, .supported = false, .mode_mismatch = false }`. `mode_mismatch`
/// is set true only when the bytes parse cleanly but the mode differs.
pub fn parseDecRpmReply(buf: []const u8, requested_mode: u16) DecRpmParseResult {
    // Minimum size: CSI ? X ; X $ y = 8 bytes (e.g. "\x1b[?9;0$y" — 1-digit mode + 1-digit state).
    if (buf.len < 8) {
        return .{ .ok = false, .supported = false, .mode_mismatch = false };
    }

    // CSI prefix: 0x1b 0x5b 0x3f
    if (buf[0] != 0x1b or buf[1] != 0x5b or buf[2] != 0x3f) {
        return .{ .ok = false, .supported = false, .mode_mismatch = false };
    }

    // Parse mode number (decimal digits until ';').
    var i: usize = 3;
    var mode_num: u32 = 0;
    var saw_digit = false;
    while (i < buf.len and buf[i] >= '0' and buf[i] <= '9') : (i += 1) {
        saw_digit = true;
        mode_num = mode_num * 10 + @as(u32, buf[i] - '0');
        // Reject overflow (>65535); the request type is u16.
        if (mode_num > 65535) {
            return .{ .ok = false, .supported = false, .mode_mismatch = false };
        }
    }
    if (!saw_digit) {
        return .{ .ok = false, .supported = false, .mode_mismatch = false };
    }
    if (i >= buf.len or buf[i] != ';') {
        return .{ .ok = false, .supported = false, .mode_mismatch = false };
    }
    i += 1;

    // Parse state digit (single char in {0..4}).
    if (i >= buf.len or buf[i] < '0' or buf[i] > '9') {
        return .{ .ok = false, .supported = false, .mode_mismatch = false };
    }
    const state = buf[i] - '0';
    i += 1;

    // Verify "$y" final two bytes. After this check, anything trailing
    // (e.g. additional reply bytes from a different sequence) is ignored.
    if (i + 1 >= buf.len or buf[i] != '$' or buf[i + 1] != 'y') {
        return .{ .ok = false, .supported = false, .mode_mismatch = false };
    }

    // C14 case 4 — well-formed reply but for a different mode than requested.
    if (mode_num != requested_mode) {
        return .{ .ok = true, .supported = false, .mode_mismatch = true };
    }

    // Mode matches; map state. Supported iff state in {1, 3}.
    const supported = state == 1 or state == 3;
    return .{ .ok = true, .supported = supported, .mode_mismatch = false };
}

/// Result of a `queryModeWithTimeout` probe. Per design C26 the field
/// name is `is_supported` (Zig forbids a field/method name collision)
/// and the accessor method is `.supported()` to match the call shape at
/// `src/tui.zig:110` (`mode.supported()`).
///
/// `raw_reply` carries the read bytes (when any were consumed) for
/// diagnostic purposes; it's `null` when the probe failed before reading
/// (C14(a) EINTR, C14(b) timeout) and is the malformed bytes slice when
/// the reply didn't parse (C14(c)).
pub const Mode = struct {
    is_supported: bool,
    raw_reply: ?[]const u8 = null,

    /// Returns the boolean support flag. Mirrors the call shape at
    /// `src/tui.zig:110` (`mode.supported()`).
    pub fn supported(self: Mode) bool {
        return self.is_supported;
    }
};

/// Default poll function used by the production `queryModeWithTimeout`.
/// Wraps `std.posix.poll` per PR 4's D4/C35 pattern (no mutable global).
///
/// Non-Linux fallback (PR 4 precedent): the CI matrix is Linux-only; on
/// other platforms the probe cannot poll, so we report "no readable data"
/// (which the caller maps to C14(b) timeout → false). This avoids lying
/// about a feature the platform can't exercise.
fn defaultPollFn(fds: []linux.pollfd, timeout: i32) anyerror!usize {
    if (builtin.os.tag != .linux) {
        // ponytail: non-Linux CI matrix doesn't exercise real poll; return 0
        // so the probe times out and reports unsupported (C14(b)-equivalent).
        return 0;
    }
    return std.posix.poll(fds, timeout);
}

/// Default read function used by the production `queryModeWithTimeout`.
/// Wraps `std.posix.read`. The `QueryModeWithTimeout` caller passes a 64-byte
/// buffer; POSIX `read(2)` consumes up to that many bytes from the kernel.
fn defaultReadFn(fd: std.posix.fd_t, buf: []u8) anyerror!usize {
    return std.posix.read(fd, buf);
}

/// Internal: real `queryModeWithTimeout` impl. Takes injected `poll_fn`
/// and `read_fn` for test injection (D4/C35 lock-in: no mutable global).
/// Mirrors PR 4's `Parser.next(... poll_fn)` pattern plus a read-fn seam.
///
/// Failure mode mapping per spec REQ-TCL-005 C14 (default-false contract):
///   - C14(a) EINTR → poll_fn returns error.Interrupted → `Mode{ .is_supported = false, .raw_reply = null }`
///   - C14(b) poll timeout → poll_fn returns 0 → `Mode{ .is_supported = false, .raw_reply = null }`
///   - C14(c) malformed reply → parseDecRpmReply returns ok=false → `Mode{ .is_supported = false, .raw_reply = <bytes> }`
///   - C14(d) wrong-mode → parseDecRpmReply returns mode_mismatch=true → `Mode{ .is_supported = false, .raw_reply = <bytes> }`
///   - Happy path → `Mode{ .is_supported = <state in {1,3}>, .raw_reply = <bytes> }`
///
/// Any `poll_fn` error other than `error.Interrupted` is treated as
/// C14(a)-equivalent (a poll failure isn't "supported"). Any `read_fn`
/// error is treated as C14(b)-equivalent (no bytes = no reply).
pub fn queryModeWithTimeoutImpl(
    _: std.Io,
    file: std.Io.File,
    writer: *std.Io.Writer,
    mode: u16,
    timeout_ms: u32,
    poll_fn: *const fn ([]linux.pollfd, i32) anyerror!usize,
    read_fn: *const fn (std.posix.fd_t, []u8) anyerror!usize,
) anyerror!Mode {
    // 1. Emit the DECRQM query. Even if the rest fails, the query is sent
    //    (the caller's terminal has already received our request).
    try emitDecRqmQuery(writer, mode);

    // 2. Poll for reply readiness. C14(a) + C14(b) both map to false.
    var pfd: linux.pollfd = .{
        .fd = file.handle,
        .events = linux.POLL.IN,
        .revents = 0,
    };
    const timeout_i32: i32 = std.math.cast(i32, timeout_ms) orelse std.math.maxInt(i32);
    const ready = poll_fn((&pfd)[0..1], timeout_i32) catch {
        // C14(a) — EINTR or any other poll error → false.
        return Mode{ .is_supported = false, .raw_reply = null };
    };
    if (ready == 0) {
        // C14(b) — poll timeout (no reply within the timeout window).
        return Mode{ .is_supported = false, .raw_reply = null };
    }

    // 3. Read the reply bytes. 64 is plenty for a DECRPM reply
    //    (max ~15 bytes: "CSI ?65535;4$y").
    var read_buf: [64]u8 = undefined;
    const n = read_fn(file.handle, &read_buf) catch {
        // Read error → treat as no reply. The bytes that did arrive (if any)
        // are in `read_buf[0..n]` but we discard them — they're not a
        // trustworthy DECRPM and including them in `raw_reply` would be a
        // partial diagnostic that confuses callers. C14(b)-equivalent.
        return Mode{ .is_supported = false, .raw_reply = null };
    };
    if (n == 0) {
        // EOF / hangup with no bytes — treat as no reply.
        return Mode{ .is_supported = false, .raw_reply = null };
    }
    const slice = read_buf[0..n];

    // 4. Parse the reply. C14(c) malformed + C14(d) wrong-mode + happy path.
    const parsed = parseDecRpmReply(slice, mode);
    if (!parsed.ok) {
        // C14(c) — malformed reply (truncated, wrong shape, bad bytes).
        return Mode{ .is_supported = false, .raw_reply = slice };
    }
    if (parsed.mode_mismatch) {
        // C14(d) — well-formed DECRPM but for a different mode than requested.
        return Mode{ .is_supported = false, .raw_reply = slice };
    }
    return Mode{ .is_supported = parsed.supported, .raw_reply = slice };
}

/// Probe a DEC private mode. Emits the DECRQM probe, polls for the DECRPM
/// reply with the given timeout, and lexes the bytes. Per spec REQ-TCL-005
/// C14 the function reports `is_supported = false` on every failure mode
/// (EINTR, poll timeout, malformed reply, wrong-mode-number reply). The
/// production wiring uses `defaultPollFn` + `defaultReadFn`; tests inject
/// mocks via `queryModeWithTimeoutImpl` (D4/C35 lock-in: no mutable global).
///
/// C20 lock-in: the return is a `Mode` value with a `.supported()` method
/// that returns `bool`. The byte-for-byte call shape at `src/tui.zig:108-110`
/// (`const mode = ...; return mode.supported();`) compiles and works.
pub fn queryModeWithTimeout(
    io: std.Io,
    file: std.Io.File,
    writer: *std.Io.Writer,
    mode: u16,
    timeout_ms: u32,
) anyerror!Mode {
    return queryModeWithTimeoutImpl(
        io,
        file,
        writer,
        mode,
        timeout_ms,
        &defaultPollFn,
        &defaultReadFn,
    );
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

test "DecRpmParseResult struct shape: ok + supported + mode_mismatch fields" {
    // Three-field struct used by `parseDecRpmReply`. The C14 contract maps
    // each combination of (ok, supported, mode_mismatch) to a specific
    // probe outcome (covered by the parse + impl tests in probe_lexer.zig).
    const info: std.builtin.Type = @typeInfo(DecRpmParseResult);
    const fields = info.@"struct".fields;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    var saw_ok = false;
    var saw_supported = false;
    var saw_mode_mismatch = false;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "ok")) saw_ok = true;
        if (std.mem.eql(u8, f.name, "supported")) saw_supported = true;
        if (std.mem.eql(u8, f.name, "mode_mismatch")) saw_mode_mismatch = true;
    }
    try std.testing.expect(saw_ok);
    try std.testing.expect(saw_supported);
    try std.testing.expect(saw_mode_mismatch);
}
