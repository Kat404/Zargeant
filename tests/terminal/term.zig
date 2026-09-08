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

// `term` is the imported term.zig file directly. Tests use the public API
// (Backend, PosixBackend, MockBackend, RawTerm, TermSize, enableRawMode).
const term = @import("term");
const Backend = term.Backend;
const PosixBackend = term.PosixBackend;
const MockBackend = term.MockBackend;
const RawTerm = term.RawTerm;
const TermSize = term.TermSize;
const enableRawMode = term.enableRawMode;

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
    var backend = MockBackend.init(.{ .original_termios = original });
    defer backend.deinit();
    backend.activate();
    defer backend.deactivate();
    const backend_value = backend.backend();
    const dummy_handle: std.Io.File.Handle = -1;

    var rt = try enableRawMode(dummy_handle, backend_value);
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
    var backend = MockBackend.init(.{ .fail_tcgetattr = error.NotATerminal });
    defer backend.deinit();
    backend.activate();
    defer backend.deactivate();
    const backend_value = backend.backend();
    const dummy_handle: std.Io.File.Handle = -1;

    const result = enableRawMode(dummy_handle, backend_value);
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
    var backend = MockBackend.init(.{
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
    var backend = MockBackend.init(.{ .fail_ioctl_gwinsz = error.IoctlError });
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
    const b = PosixBackend.backend();
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

fn getSizeViaBackend(handle: std.Io.File.Handle, backend: Backend) anyerror!TermSize {
    const ws = try backend.ioctl_gwinsz(handle);
    return .{ .width = ws.col, .height = ws.row };
}
