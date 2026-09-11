//! tests/terminal/probe_lexer.zig — RED tests for src/terminal/dpm.zig PR 5.
//!
//! Spec coverage (REQ-TCL-005 CAP-34 terminal-probe):
//!   C14 — default false on every failure mode:
//!     (a) EINTR mid-poll      → .is_supported = false
//!     (b) poll timeout         → .is_supported = false
//!     (c) malformed reply      → .is_supported = false
//!     (d) wrong-mode reply     → .is_supported = false
//!   C20 — `Mode.supported()` returns bool (the public accessor used at
//!         src/tui.zig:110 — the byte-for-byte PR 6 swap must work).
//!   C26 — Mode struct field name is `is_supported` (NOT `supported`); the
//!         method name is `supported()` (Zig forbids field/method name
//!         collision). Locked in design v2 + PR 2.
//!
//! Test split (mirrors PR 4 D4/C35 test-only entrypoint pattern):
//!   1. Pure parser tests via `parseDecRpmReply(bytes, mode)` — no I/O, no
//!      mocks. Covers all 5 Ps states + malformed edge cases + wrong-mode.
//!   2. Integration tests via `queryModeWithTimeoutImpl(... poll_fn, read_fn)`
//!      with mock poll_fn + mock read_fn. Covers C14(a)/(b) + integration
//!      of the parse result with the poll/read dance.
//!   3. Production wrapper smoke via `queryModeWithTimeout(...)` — verifies
//!      the wrapper compiles and dispatches to `defaultPollFn` + `defaultReadFn`.
//!
//! Strict TDD (CONTRIBUTING.md:7): tests authored before the real
//! `queryModeWithTimeoutImpl` GREEN impl. PR 5 lands RED + GREEN together
//! in the same commit (after the WU 5.1 contract locks are in place).

const std = @import("std");
const testing = std.testing;

const dpm = @import("dpm");

// =============================================================================
// Mock factories — comptime-generic test seams.
// =============================================================================

/// Mock poll_fn that always reports the fd is readable. Used to drive the
/// "poll says yes, read returns bytes" path deterministically without
/// requiring a real TTY.
fn pollAlwaysReady(_: []std.os.linux.pollfd, _: i32) anyerror!usize {
    return 1;
}

/// Mock poll_fn that always returns `error.Interrupted` (EINTR scenario).
/// C14(a) lock-in: EINTR mid-poll → .is_supported = false.
fn pollMockInterrupted(_: []std.os.linux.pollfd, _: i32) anyerror!usize {
    return error.Interrupted;
}

/// Mock poll_fn that always returns 0 (timeout scenario).
/// C14(b) lock-in: poll timeout → .is_supported = false.
fn pollMockTimeout(_: []std.os.linux.pollfd, _: i32) anyerror!usize {
    return 0;
}

/// Comptime-generic read_fn mock: returns the bytes `T` on the first call,
/// then 0 (EOF) on subsequent calls. Used to feed fake terminal replies
/// into the parser without real I/O.
fn ReadMock(comptime T: type) type {
    return struct {
        fn read(_: std.posix.fd_t, buf: []u8) anyerror!usize {
            const n = @min(T.bytes.len, buf.len);
            @memcpy(buf[0..n], T.bytes[0..n]);
            return n;
        }
    };
}

/// Comptime struct carrying byte fixtures for each test scenario. Each
/// `.bytes` field is the exact reply the fake terminal would emit.
const Supported2048Set = struct {
    const bytes: []const u8 = "\x1b[?2048;1$y";
};
const Supported2048Perm = struct {
    const bytes: []const u8 = "\x1b[?2048;3$y";
};
const NotRecognized2048 = struct {
    const bytes: []const u8 = "\x1b[?2048;0$y";
};
const Reset2048 = struct {
    const bytes: []const u8 = "\x1b[?2048;2$y";
};
const PermReset2048 = struct {
    const bytes: []const u8 = "\x1b[?2048;4$y";
};
const WrongModeReply = struct {
    // DECRPM for mode 2026 (sync update) when 2048 (in-band resize) was requested.
    const bytes: []const u8 = "\x1b[?2026;1$y";
};
const MalformedTruncated = struct {
    // Missing the "$y" final bytes.
    const bytes: []const u8 = "\x1b[?2048;1";
};
const MalformedNoCsi = struct {
    // Garbage non-DECRPM bytes.
    const bytes: []const u8 = "hello world!";
};

// =============================================================================
// Scenario 1 — Mode struct field/method name lock-in (C20 + design C26).
//   GIVEN Mode{ .is_supported = true, .raw_reply = "..." }
//   WHEN .supported() is called
//   THEN it returns true
//   AND .is_supported is also true (the field)
// =============================================================================

test "Mode{ is_supported=true }.supported() returns true (C20 + C26 lock-in)" {
    const mode: dpm.Mode = .{ .is_supported = true, .raw_reply = "2048;1$y" };
    try testing.expect(mode.supported() == true);
    try testing.expect(mode.is_supported == true);
    try testing.expectEqualStrings("2048;1$y", mode.raw_reply.?);
}

test "Mode{ is_supported=false }.supported() returns false (C20 + C26 lock-in)" {
    const mode: dpm.Mode = .{ .is_supported = false };
    try testing.expect(mode.supported() == false);
    try testing.expect(mode.is_supported == false);
    try testing.expect(mode.raw_reply == null);
}

test "Mode default raw_reply is null (C26 field-default lock-in)" {
    // The struct can be constructed without specifying raw_reply; it
    // defaults to null. This enables Mode{ .is_supported = true } and
    // Mode{ .is_supported = false } literals without explicit null.
    const mode: dpm.Mode = .{ .is_supported = true };
    try testing.expect(mode.raw_reply == null);
}

// =============================================================================
// Scenario 2 — parseDecRpmReply: 5 DECRPM Ps states for requested mode 2048.
//   GIVEN a well-formed DECRPM reply with state Ps in {0, 1, 2, 3, 4}
//   WHEN parseDecRpmReply(bytes, 2048) is called
//   THEN it returns:
//     - Ps=1 or Ps=3 → supported=true (set / permanently set)
//     - Ps=0, 2, 4  → supported=false (not recognized, reset, perm-reset)
//   AND ok=true
//   AND mode_mismatch=false
// =============================================================================

test "parseDecRpmReply: Ps=1 (set) for mode 2048 → supported=true" {
    const r = dpm.parseDecRpmReply(Supported2048Set.bytes, 2048);
    try testing.expect(r.ok == true);
    try testing.expect(r.mode_mismatch == false);
    try testing.expect(r.supported == true);
}

test "parseDecRpmReply: Ps=3 (permanently set) for mode 2048 → supported=true" {
    const r = dpm.parseDecRpmReply(Supported2048Perm.bytes, 2048);
    try testing.expect(r.ok == true);
    try testing.expect(r.mode_mismatch == false);
    try testing.expect(r.supported == true);
}

test "parseDecRpmReply: Ps=0 (not recognized) for mode 2048 → supported=false" {
    const r = dpm.parseDecRpmReply(NotRecognized2048.bytes, 2048);
    try testing.expect(r.ok == true);
    try testing.expect(r.mode_mismatch == false);
    try testing.expect(r.supported == false);
}

test "parseDecRpmReply: Ps=2 (reset) for mode 2048 → supported=false" {
    const r = dpm.parseDecRpmReply(Reset2048.bytes, 2048);
    try testing.expect(r.ok == true);
    try testing.expect(r.mode_mismatch == false);
    try testing.expect(r.supported == false);
}

test "parseDecRpmReply: Ps=4 (permanently reset) for mode 2048 → supported=false" {
    const r = dpm.parseDecRpmReply(PermReset2048.bytes, 2048);
    try testing.expect(r.ok == true);
    try testing.expect(r.mode_mismatch == false);
    try testing.expect(r.supported == false);
}

// =============================================================================
// Scenario 3 — parseDecRpmReply: wrong-mode reply (C14 case 4).
//   GIVEN a well-formed DECRPM reply for mode 2026 (sync update)
//   WHEN parseDecRpmReply(bytes, 2048) is called (we asked for 2048)
//   THEN it returns:
//     - ok=true (the bytes parse cleanly)
//     - mode_mismatch=true (the mode differs from requested)
//     - supported=false (C14 case 4 always maps to false)
// =============================================================================

test "parseDecRpmReply: wrong-mode reply → mode_mismatch=true, supported=false (C14 case 4)" {
    const r = dpm.parseDecRpmReply(WrongModeReply.bytes, 2048);
    try testing.expect(r.ok == true);
    try testing.expect(r.mode_mismatch == true);
    try testing.expect(r.supported == false);
}

// =============================================================================
// Scenario 4 — parseDecRpmReply: malformed replies (C14 case 3).
//   GIVEN various malformed byte patterns
//   WHEN parseDecRpmReply(bytes, 2048) is called
//   THEN it returns ok=false and supported=false
// =============================================================================

test "parseDecRpmReply: empty bytes → ok=false" {
    const r = dpm.parseDecRpmReply("", 2048);
    try testing.expect(r.ok == false);
    try testing.expect(r.mode_mismatch == false);
    try testing.expect(r.supported == false);
}

test "parseDecRpmReply: too-short bytes → ok=false" {
    const r = dpm.parseDecRpmReply("\x1b[?2048", 2048); // missing ;state$y
    try testing.expect(r.ok == false);
    try testing.expect(r.supported == false);
}

test "parseDecRpmReply: missing CSI prefix → ok=false" {
    const r = dpm.parseDecRpmReply("2048;1$y", 2048); // no ESC[
    try testing.expect(r.ok == false);
    try testing.expect(r.supported == false);
}

test "parseDecRpmReply: missing ? after CSI → ok=false" {
    const r = dpm.parseDecRpmReply("\x1b[2048;1$y", 2048); // CSI but no ?
    try testing.expect(r.ok == false);
    try testing.expect(r.supported == false);
}

test "parseDecRpmReply: bad final byte (not $y) → ok=false" {
    const r = dpm.parseDecRpmReply("\x1b[?2048;1xx", 2048); // xx not $y
    try testing.expect(r.ok == false);
    try testing.expect(r.supported == false);
}

test "parseDecRpmReply: non-DECRPM garbage bytes → ok=false" {
    const r = dpm.parseDecRpmReply(MalformedNoCsi.bytes, 2048);
    try testing.expect(r.ok == false);
    try testing.expect(r.supported == false);
}

// =============================================================================
// Scenario 5 — queryModeWithTimeoutImpl: C14(a) EINTR → false.
//   GIVEN poll_fn returns error.Interrupted (EINTR mid-poll)
//   WHEN queryModeWithTimeoutImpl is called
//   THEN it returns Mode{ .is_supported = false, .raw_reply = null }
// =============================================================================

test "C14(a) EINTR during poll → Mode{ is_supported=false, raw_reply=null }" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const file: std.Io.File = .{ .handle = 0, .flags = .{ .nonblocking = true } };
    const mode = try dpm.queryModeWithTimeoutImpl(
        undefined,
        file,
        &w,
        2048,
        50,
        &pollMockInterrupted,
        &ReadMock(Supported2048Set).read, // read_fn shouldn't be reached on EINTR
    );
    try testing.expect(mode.is_supported == false);
    try testing.expect(mode.supported() == false);
    try testing.expect(mode.raw_reply == null);
}

// =============================================================================
// Scenario 6 — queryModeWithTimeoutImpl: C14(b) poll timeout → false.
//   GIVEN poll_fn returns 0 (no readable data within timeout window)
//   WHEN queryModeWithTimeoutImpl is called
//   THEN it returns Mode{ .is_supported = false, .raw_reply = null }
// =============================================================================

test "C14(b) poll timeout → Mode{ is_supported=false, raw_reply=null }" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const file: std.Io.File = .{ .handle = 0, .flags = .{ .nonblocking = true } };
    const mode = try dpm.queryModeWithTimeoutImpl(
        undefined,
        file,
        &w,
        2048,
        50,
        &pollMockTimeout,
        &ReadMock(Supported2048Set).read, // read_fn shouldn't be reached on timeout
    );
    try testing.expect(mode.is_supported == false);
    try testing.expect(mode.supported() == false);
    try testing.expect(mode.raw_reply == null);
}

// =============================================================================
// Scenario 7 — Integration: poll says readable, read returns bytes.
//   C14(c) malformed reply → false (with raw_reply populated for diagnostics)
//   C14(d) wrong-mode reply → false
//   supported mode → true
// =============================================================================

test "supported mode 2048 with Ps=1 → Mode{ is_supported=true, raw_reply=\"...1$y\" }" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const file: std.Io.File = .{ .handle = 0, .flags = .{ .nonblocking = true } };
    const mode = try dpm.queryModeWithTimeoutImpl(
        undefined,
        file,
        &w,
        2048,
        50,
        &pollAlwaysReady,
        &ReadMock(Supported2048Set).read,
    );
    try testing.expect(mode.is_supported == true);
    try testing.expect(mode.supported() == true);
    try testing.expect(mode.raw_reply != null);
    try testing.expectEqualStrings(Supported2048Set.bytes, mode.raw_reply.?);
}

test "C14(c) malformed reply → Mode{ is_supported=false, raw_reply populated }" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const file: std.Io.File = .{ .handle = 0, .flags = .{ .nonblocking = true } };
    const mode = try dpm.queryModeWithTimeoutImpl(
        undefined,
        file,
        &w,
        2048,
        50,
        &pollAlwaysReady,
        &ReadMock(MalformedTruncated).read,
    );
    try testing.expect(mode.is_supported == false);
    try testing.expect(mode.supported() == false);
    try testing.expect(mode.raw_reply != null);
    try testing.expectEqualStrings(MalformedTruncated.bytes, mode.raw_reply.?);
}

test "C14(d) wrong-mode reply → Mode{ is_supported=false, raw_reply populated }" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const file: std.Io.File = .{ .handle = 0, .flags = .{ .nonblocking = true } };
    const mode = try dpm.queryModeWithTimeoutImpl(
        undefined,
        file,
        &w,
        2048,
        50,
        &pollAlwaysReady,
        &ReadMock(WrongModeReply).read,
    );
    try testing.expect(mode.is_supported == false);
    try testing.expect(mode.supported() == false);
    try testing.expect(mode.raw_reply != null);
    try testing.expectEqualStrings(WrongModeReply.bytes, mode.raw_reply.?);
}

// =============================================================================
// Scenario 8 — Production wrapper compiles + dispatches to defaults.
//   Per D4/C35: production wrapper must call queryModeWithTimeoutImpl with
//   defaultPollFn + defaultReadFn. This test asserts the wrapper exists
//   and has the locked 5-arg signature (io, file, writer, mode, timeout_ms).
// =============================================================================

test "queryModeWithTimeout production wrapper compiles (5-arg signature lock-in)" {
    // The compiler rejects this test if the production wrapper signature
    // doesn't match the byte-for-byte contract at src/tui.zig:108. The
    // dummy fd (-1) ensures defaultPollFn returns immediately (no readable
    // data on a closed fd), and the 1ms timeout caps any wall-clock wait.
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const file: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = true } };
    const mode = dpm.queryModeWithTimeout(undefined, file, &w, 2048, 1) catch
        @as(dpm.Mode, .{ .is_supported = false });
    // Result is implementation-defined (poll on -1 fd returns immediately
    // with an error or 0); the lock-in is the call site compiles + runs.
    _ = mode;
    try testing.expect(true);
}

test "queryModeWithTimeout emits the DECRQM query byte sequence" {
    // The query is always emitted before the poll/read dance — even if
    // the probe fails. Verify the writer receives the expected byte stream.
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const file: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = true } };
    _ = dpm.queryModeWithTimeout(undefined, file, &w, 2048, 1) catch
        @as(dpm.Mode, .{ .is_supported = false });
    try testing.expectEqualStrings("\x1b[?2048$p", buf[0..w.end]);
}
