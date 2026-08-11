// src/password_input.zig — tui-recovery R-PR 2 scaffold (NO-OP stub).
//
// Spec:    sdd/tui-recovery/spec  (id=407) REQ-TUI-005, REQ-TUI-007
// Design:  sdd/tui-recovery/design (id=408) §2.3 R-PR 2
//
// R-PR 2 ships the type + struct shape only. `read` is a no-op that
// returns an empty passphrase `""` in headless tests (consumes the
// channels but does NOT read raw stdin). Real impl (raw-mode read,
// Ctrl+R reveal toggle, Esc cancel, Backspace delete) lands in R-PR 3
// (T3.8 per tasks#410).
//
// Linux/x86_64 Zig 0.16 only.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Linux-only comptime guard (matches every other module in the project).
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("password_input: linux-only v1");
}

// =============================================================================
// Public types
// =============================================================================

/// Stub state. R-PR 3 adds fields for the draft buffer, reveal toggle,
/// cursor position, and history. The R-PR 2 stub has no fields — the
/// `read` function returns an empty passphrase without consulting state.
pub const State = struct {};

/// No-op passphrase read. Returns an empty passphrase `""` so the
/// downstream Agent receives an empty unlock payload (which fails
/// cleanly per the auth flow's error path). R-PR 3 replaces the body
/// with the real raw-mode masked input.
pub fn read(prompt: []const u8, state: *State) ![]u8 {
    _ = prompt;
    _ = state;
    return "";
}

// =============================================================================
// Tests (2 per design#408 §2.3 R-PR 2: read returns empty, read does not block)
// =============================================================================

const testing = std.testing;

test "State struct is zero-initialized" {
    // R-PR 2 scaffold — State has no fields (zero-init is trivial).
    // The ZIR proves the type exists; runtime assertion is that the
    // struct literal is valid Zig.
    const state: State = .{};
    _ = state;
}

test "read returns empty passphrase in headless" {
    // R-PR 2 scenario — the stub returns "" instead of an empty-string
    // literal. The assertion is on the length, not the content ("" is
    // the literal empty-passphrase contract per the orchestrator spec).
    var state: State = .{};
    const passphrase = try read("prompt: ", &state);
    try testing.expectEqual(@as(usize, 0), passphrase.len);
}

test "read does not block on stdin" {
    // R-PR 2 scenario — the stub must NOT read stdin. The function
    // returns within microseconds (no I/O). Assert: total elapsed time
    // is well under 1 ms, which is the budget for a function call
    // without I/O on Linux.
    var state: State = .{};
    const start = std.Io.Timestamp.now(testing.io, .real);
    const passphrase = try read("", &state);
    const elapsed = std.Io.Timestamp.now(testing.io, .real);
    const elapsed_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start, elapsed).nanoseconds);
    try testing.expectEqual(@as(usize, 0), passphrase.len);
    try testing.expect(elapsed_ns < std.time.ns_per_ms);
}
