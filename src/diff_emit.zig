// src/diff_emit.zig — DiffEntry + diffAndEmit pure renderer (T-2.2.1 RED skeleton)
//
// Spec: sdd/tui-ship-fast-phase2/spec §3.2 (REQ-DE-001..003, REQ-DE-006, REQ-DE-010)
// Design: sdd/tui-ship-fast-phase2/design §3.2
// Tasks: T-2.2.1 (PR1b, Phase 2 WU 2.2)
//
// Pure renderer between two `[]const Cell` views (prev/active) that emits
// the byte stream: `<CUP><SGR><UTF-8><SGR reset>` per changed cell, plus an
// optional trailing CUP for the visible blink cursor. The function is the
// pure stage 2 of the Phase 2 three-stage render pipeline:
//
//   1. renderToGrid(State, *ScreenGrid) — modal draw fns (T-2.3.x)
//   2. diffAndEmit(prev, active, ...) — pure diff+emit (T-2.2.1, this file)
//   3. submitFrame(writer, bracketed) — orchestrator (T-2.6.1)
//
// Tiger Style §1 — fail fast on invariant violation; the assert macros
// below pin the function contracts.
// Tiger Style §3 — ZERO heap allocation; every buffer is stack-local
// (`[4]u8` for UTF-8, `[8]u8` for SGR, `[16]u8` for CUP).
// Tiger Style §4 — every function has precondition asserts.
// Tiger Style §5 — bounded iteration (`prev[0..prev.len]`); no recursion.
// Tiger Style §6 — domain error set (`DiffEmitError`); no `anyerror`
// swallowing.
// Tiger Style §7 — deterministic (no I/O, no allocator, no globals).
//
// ─── TDD STATE ─────────────────────────────────────────────────────────────
// This is the RED skeleton — type/function declarations are complete and
// compile cleanly, but the bodies return `error.SkeletonNotImplemented` so
// every test in tests/tui/screen_grid.zig (T-2.2.1 RED tests block) fails
// at runtime. The GREEN commit replaces these stub bodies with real impl.

const std = @import("std");
const screen_grid = @import("screen_grid");
const Cell = screen_grid.Cell;
const CURSOR_SKIP = screen_grid.CURSOR_SKIP;

/// Domain error set for diff_emit. Explicit (Tiger Style §6) so callers
/// can match on the concrete failure mode without an `anyerror` catch-all.
pub const DiffEmitError = error{
    /// Placeholder for the RED skeleton — replaced with `WriteFailed` and
    /// the propagated UTF-8 errors in the GREEN commit.
    SkeletonNotImplemented,
};

/// One entry in a diff between two cell grids. Mirrors `modal.DiffEntry`.
/// `(x, y)` are 0-indexed; the emitter translates them to 1-indexed CUP.
pub const DiffEntry = struct {
    x: u16,
    y: u16,
    cell: Cell,
};

/// Emit one diff entry's bytes: CUP `\x1b[<y+1>;<x+1>H` + SGR + UTF-8 +
/// SGR reset. RED skeleton — impl lands in GREEN commit.
pub fn emitDiffEntry(
    writer: *std.Io.Writer,
    entry: DiffEntry,
    cols: u16,
    rows: u16,
) DiffEmitError!void {
    _ = writer;
    _ = entry;
    _ = cols;
    _ = rows;
    return error.SkeletonNotImplemented;
}

/// Emit a trailing CUP at (cursor_col+1, cursor_row+1). When
/// `cursor_col == CURSOR_SKIP`, emits ZERO bytes. RED skeleton — impl
/// lands in GREEN commit.
pub fn emitTrailingCUP(
    writer: *std.Io.Writer,
    cursor_col: u16,
    cursor_row: u16,
    cols: u16,
    rows: u16,
) DiffEmitError!void {
    _ = writer;
    _ = cursor_col;
    _ = cursor_row;
    _ = cols;
    _ = rows;
    return error.SkeletonNotImplemented;
}

/// Compute the diff between `prev` and `current`, emit each changed cell
/// via `emitDiffEntry`, then optionally emit a trailing CUP via
/// `emitTrailingCUP`. RED skeleton — impl lands in GREEN commit.
pub fn diffAndEmit(
    writer: *std.Io.Writer,
    prev: []const Cell,
    current: []const Cell,
    cols: u16,
    rows: u16,
    cursor_col: u16,
    cursor_row: u16,
) DiffEmitError!void {
    _ = writer;
    _ = prev;
    _ = current;
    _ = cols;
    _ = rows;
    _ = cursor_col;
    _ = cursor_row;
    return error.SkeletonNotImplemented;
}

// ─── tests ───────────────────────────────────────────────────────────────────
// Single inline smoke test satisfies the project's strict-tdd guard
// (`just check-tdd` requires every src/*.zig to have ≥1 `test` block).
// Full coverage (11 cases) lives in tests/tui/screen_grid.zig.

test "diff_emit: DiffEntry is a compact value type (sizeof <= 16 bytes)" {
    // Smoke test — confirms the DiffEntry struct packs within 16 bytes
    // (2 × u16 + 8-byte Cell = 12 bytes typical, capped at 16).
    try std.testing.expect(@sizeOf(DiffEntry) <= 16);
}
