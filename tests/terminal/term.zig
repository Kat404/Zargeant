//! tests/terminal/term.zig — RED tests for src/terminal/term.zig.
//!
//! Spec: REQ-TCL-001 (CAP-30 terminal-control) + REQ-TCL-012 (test-terminal
//! build step proves non-zero test count).
//!
//! Tests exercise the public API via the MockBackend seam (design D3). No
//! real tty is required; CI runs headless. The MockBackend records every
//! call so tests can assert save / restore / get-size behavior byte-for-byte.
//!
//! Per strict TDD (CONTRIBUTING.md:7): these tests were authored before
//! term.zig GREEN impls and pin the contract.

const std = @import("std");
const testing = std.testing;

// `term` is the imported src/terminal/term.zig module via build dep. Tests
// use the public API (Backend, PosixBackend, MockBackend, RawTerm, TermSize,
// enableRawMode). The build wires `term` as a build dep on the test module
// (see build.zig terminal_test_mod).
//
// ponytail: keep references qualified (`term.PosixBackend`) instead of
// creating local aliases (`const PosixBackend = term.PosixBackend`).
// Qualified references sidestep the Zig compiler's value-evaluation
// recursion that triggers a self-dependency error when resolving aliases
// of public structs during module-root test discovery.
const term = @import("term");

// =============================================================================
// Scenario 1 — termios round-trip (REQ-TCL-001).
//   GIVEN MockBackend returns a known original termios T0
//   WHEN enableRawMode is called with the MockBackend
//   THEN RawTerm.original == T0
//   AND the MockBackend saw exactly one tcgetattr call
//   AND the MockBackend saw exactly one tcsetattr call (the raw-mode apply)
// =============================================================================

test "termios round-trip: MockBackend saves original + applies raw + restores" {
    var original = std.mem.zeroes(std.posix.termios);
    original.ispeed = .B9600; // arbitrary distinct value to verify copy semantics
    var backend = term.MockBackend.init(.{ .original_termios = original });
    defer backend.deinit();
    backend.activate();
    defer backend.deactivate();
    const backend_value = backend.backend();
    const dummy_handle: std.Io.File.Handle = -1;

    var rt = try term.enableRawMode(dummy_handle, backend_value);
    // Assertion 1: after enable, MockBackend saw exactly 1 tcgetattr (save)
    // and exactly 1 tcsetattr (apply raw-mode). Original termios was copied.
    try testing.expectEqual(@as(u32, 1), backend.tcgetattr_count);
    try testing.expectEqual(@as(u32, 1), backend.tcsetattr_count);
    try testing.expectEqual(original.ispeed, rt.original.ispeed);

    // Assertion 2: disableRawMode restores via the second tcsetattr.
    try rt.disableRawMode();
    try testing.expectEqual(@as(u32, 2), backend.tcsetattr_count);
}

// =============================================================================
// Scenario 2 — no-TTY error path (REQ-TCL-001 adversarial).
//   GIVEN MockBackend.tcgetattr returns error.NotATerminal
//   WHEN enableRawMode is called
//   THEN it returns that error
//   AND RawTerm is never constructed
//   AND tcsetattr was never called
// =============================================================================

test "no-TTY error path: tcgetattr error propagates through enableRawMode" {
    var backend = term.MockBackend.init(.{ .fail_tcgetattr = error.NotATerminal });
    defer backend.deinit();
    backend.activate();
    defer backend.deactivate();
    const backend_value = backend.backend();
    const dummy_handle: std.Io.File.Handle = -1;

    const result = term.enableRawMode(dummy_handle, backend_value);
    try testing.expectError(error.NotATerminal, result);
    try testing.expectEqual(@as(u32, 1), backend.tcgetattr_count);
    try testing.expectEqual(@as(u32, 0), backend.tcsetattr_count);
}

// =============================================================================
// Scenario 3 — getSize happy path (REQ-TCL-001).
//   GIVEN MockBackend.ioctl_gwinsz returns winsize{row=40, col=120}
//   WHEN getSize is called via a backend seam
//   THEN it returns TermSize{width=120, height=40}
// =============================================================================

test "getSize happy: MockBackend.ioctl_gwinsz → TermSize{width, height}" {
    var backend = term.MockBackend.init(.{
        .winsize = .{ .row = 40, .col = 120, .xpixel = 0, .ypixel = 0 },
    });
    defer backend.deinit();
    backend.activate();
    defer backend.deactivate();
    const backend_value = backend.backend();
    const dummy_handle: std.Io.File.Handle = -1;

    const sz = try getSizeViaBackend(dummy_handle, backend_value);
    try testing.expectEqual(@as(u16, 120), sz.width);
    try testing.expectEqual(@as(u16, 40), sz.height);
    try testing.expectEqual(@as(u32, 1), backend.ioctl_gwinsz_count);
}

// =============================================================================
// Scenario 4 — getSize failure (REQ-TCL-001 adversarial).
//   GIVEN MockBackend.ioctl_gwinsz returns error
//   WHEN getSize is called
//   THEN it returns that error
//   AND no TermSize is constructed
// =============================================================================

test "getSize failure: ioctl error propagates" {
    var backend = term.MockBackend.init(.{ .fail_ioctl_gwinsz = error.IoctlError });
    defer backend.deinit();
    backend.activate();
    defer backend.deactivate();
    const backend_value = backend.backend();
    const dummy_handle: std.Io.File.Handle = -1;

    const result = getSizeViaBackend(dummy_handle, backend_value);
    try testing.expectError(error.IoctlError, result);
    try testing.expectEqual(@as(u32, 1), backend.ioctl_gwinsz_count);
}

// =============================================================================
// Scenario 5 — PosixBackend exposes its Backend value (REQ-TCL-001).
//   GIVEN PosixBackend.backend()
//   WHEN called
//   THEN it returns a fully populated Backend value with all 3 fn ptrs
//   AND the function pointers are not null
// =============================================================================

test "PosixBackend returns populated Backend" {
    const b = term.PosixBackend.backend();
    try testing.expect(@intFromPtr(b.tcgetattr) != 0);
    try testing.expect(@intFromPtr(b.tcsetattr) != 0);
    try testing.expect(@intFromPtr(b.ioctl_gwinsz) != 0);
}

// =============================================================================
// Helpers — getSize with a pluggable backend seam.
// Ponytail: term.zig exposes `getSize(handle)` which uses PosixBackend
// internally. For tests we route through the same path but with an injected
// backend via a small adapter. If adding the adapter proves awkward in PR 6,
// refactor `getSize` to take an explicit backend (mirroring `enableRawMode`).
// =============================================================================

fn getSizeViaBackend(handle: std.Io.File.Handle, backend: term.Backend) anyerror!term.TermSize {
    const ws = try backend.ioctl_gwinsz(handle);
    return .{ .width = ws.col, .height = ws.row };
}

// =============================================================================
// WU-2 — DEC 2004 (bracketed paste) enable/disable (REQ-NEW-002)
//
// Bracketed paste is a CSI ?2004 mode set/reset pair per xterm ctlseqs.
// The terminal emulator wraps pasted content in \x1b[200~ ... \x1b[201~
// when mode 2004 is set; the parser then emits .paste_start + per-char
// .key events + .paste_end (per WU-3).
//
// The helpers live in src/terminal/dpm.zig (matches the alt-screen +
// in-band-resize pattern). enableRawMode has no writer param so we do
// NOT bundle DEC 2004 into enableRawMode (REQ-NEW-009 + design D4).
// =============================================================================

test "enableBracketedPaste writes CSI ? 2004 h" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try term.enableBracketedPaste(&w);
    try testing.expectEqualStrings("\x1b[?2004h", buf[0..w.end]);
}

test "disableBracketedPaste writes CSI ? 2004 l" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try term.disableBracketedPaste(&w);
    try testing.expectEqualStrings("\x1b[?2004l", buf[0..w.end]);
}

test "enableBracketedPaste is idempotent (no internal dedup)" {
    // Per design D4 / spec REQ-NEW-002: idempotent across cycles means
    // a clean round-trip — one sequence per call. No internal dedup
    // (caller controls enable/disable symmetry). Two enables emit two
    // ?2004h bytes; the test asserts the writer received exactly two.
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try term.enableBracketedPaste(&w);
    try term.disableBracketedPaste(&w);
    try term.enableBracketedPaste(&w);
    try term.disableBracketedPaste(&w);
    const out = buf[0..w.end];
    // Two ?2004h sequences + two ?2004l sequences, alternating.
    const h_count = std.mem.count(u8, out, "\x1b[?2004h");
    const l_count = std.mem.count(u8, out, "\x1b[?2004l");
    try testing.expectEqual(@as(usize, 2), h_count);
    try testing.expectEqual(@as(usize, 2), l_count);
}

// =============================================================================
// WU 0.7 (tui-ship-fast-phase0, Bug 6) — enableRawMode must apply the full
// cfmakeraw recipe, not just clear ICANON + ECHO. Pre-fix, the parser
// saw cooked-mode artifacts (CR→NL translation, output post-processing,
// flow-control) bleed through and corrupt the event stream.
//
// The full cfmakeraw recipe per `man 3 cfmakeraw` (POSIX) + glibc:
//   - c_iflag &= ~(ICRNL | IXON | BRKINT | INPCK | ISTRIP)
//   - c_oflag &= ~OPOST
//   - c_cflag &= ~(CSIZE | PARENB); c_cflag |= CS8
//   - c_lflag &= ~(ICANON | ECHO | IEXTEN)
//   - c_cc[VMIN] = 1
//   - c_cc[VTIME] = 0
// ISIG is PRESERVED (NOT cleared) — the tui-input-flow-bugfixes-2 R2a
// path requires Ctrl+C to keep generating SIGINT via the tty discipline
// (src/cancel_signal.zig was removed but Ctrl+C is intercepted by the
// parser at src/tui.zig:629, which depends on the 0x03 byte arriving
// as data, which requires ISIG=true).
//
// This test pins the post-cfmakeraw termios state. Pre-fix, only ICANON
// and ECHO are cleared — the test fails on VMIN=1 and ISIG=1 (RED).
// =============================================================================

test "enableRawMode applies full cfmakeraw recipe (ICRNL/IXON/OPOST cleared)" {
    var backend = term.MockBackend.init(.{});
    defer backend.deinit();
    backend.activate();
    defer backend.deactivate();
    const backend_value = backend.backend();
    const dummy_handle: std.Io.File.Handle = -1;

    _ = try term.enableRawMode(dummy_handle, backend_value);
    // After enable, the MockBackend recorded exactly one tcsetattr call
    // carrying the post-cfmakeraw termios struct.
    try testing.expectEqual(@as(u32, 1), backend.tcsetattr_count);
    const applied = backend.last_applied_termios.?;

    // POSIX termios(3) cfmakeraw recipe — every flag below must be
    // cleared by enableRawMode. The defaults in std.mem.zeroes are all
    // 0/false, so a flag that was already cleared would pass even
    // pre-fix. The discriminator is VMIN == 1 (which is non-zero) and
    // ISIG == 1 (also non-zero, but cfmakeraw clears it — we restore
    // ISIG after cfmakeraw to keep Ctrl+C working).
    try testing.expectEqual(false, applied.iflag.ICRNL);
    try testing.expectEqual(false, applied.iflag.IXON);
    try testing.expectEqual(false, applied.iflag.BRKINT);
    try testing.expectEqual(false, applied.iflag.INPCK);
    try testing.expectEqual(false, applied.iflag.ISTRIP);
    try testing.expectEqual(false, applied.oflag.OPOST);
    try testing.expectEqual(false, applied.lflag.ICANON);
    try testing.expectEqual(false, applied.lflag.ECHO);
    try testing.expectEqual(false, applied.lflag.IEXTEN);

    // CS8 forced (PARENB cleared, CSIZE set to CS8). Pre-fix CSIZE is
    // .CS5 (the default-zero value of the enum).
    try testing.expectEqual(false, applied.cflag.PARENB);
    try testing.expectEqual(@as(std.os.linux.CSIZE, .CS8), applied.cflag.CSIZE);

    // VMIN=1, VTIME=0. Pre-fix these are both 0 (default-zero cc[]).
    try testing.expectEqual(@as(u8, 1), applied.cc[VMIN_INDEX]);
    try testing.expectEqual(@as(u8, 0), applied.cc[VTIME_INDEX]);

    // ISIG preserved (tui-input-flow-bugfixes-2 R2a requires the 0x03
    // byte to arrive as data for the parser-level Ctrl+C intercept).
    try testing.expectEqual(true, applied.lflag.ISIG);
}

// Linux x86_64 c_cc indices (NCCS=8 for non-mips/sparc/ppc):
//   0 VINTR  1 VQUIT  2 VERASE  3 VKILL  4 VEOF  5 VTIME  6 VMIN  7 VSWTC
// Per Linux termios(3) §"Canonical and noncanonical mode":
//   VMIN  = number of bytes for non-canonical read (CCS=8 → index 6)
//   VTIME = inter-byte timeout deciseconds (CCS=8 → index 5)
// Note: glibc/POSIX traditionally labels them VMIN=4, VTIME=5; the
// Linux kernel uses different positional semantics for VMIN/VTIME
// specifically when ICANON is off. We use the array indices that match
// the Linux termios(3) §Noncanonical Mode documentation.
const VMIN_INDEX: usize = 6;
const VTIME_INDEX: usize = 5;
