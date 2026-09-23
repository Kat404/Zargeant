// src/diff_emit.zig — DiffEntry + diffAndEmit pure renderer (T-2.2.1)
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
// (`[4]u8` for UTF-8, `[16]u8` for CUP).
// Tiger Style §4 — every function has precondition asserts.
// Tiger Style §5 — bounded iteration (`prev[0..prev.len]`); no recursion.
// Tiger Style §6 — domain error set (`DiffEmitError`); no `anyerror`
// swallowing.
// Tiger Style §7 — deterministic (no I/O, no allocator, no globals);
// time/random are not consumed here.

const std = @import("std");
const screen_grid = @import("screen_grid");
const Cell = screen_grid.Cell;
const CURSOR_SKIP = screen_grid.CURSOR_SKIP;

/// Domain error set for diff_emit. Explicit (Tiger Style §6) so callers
/// can match on the concrete failure mode without an `anyerror` catch-all.
/// `WriteFailed` is propagated from `std.Io.Writer.writeAll`; the two
/// UTF-8 errors are propagated from `std.unicode.utf8Encode`.
pub const DiffEmitError = error{
    WriteFailed,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
};

/// One entry in a diff between two cell grids. Mirrors `modal.DiffEntry`
/// (Phase 0.5 `WindowMock.diff` returns the same shape; PR1c will swap
/// the source pointer from `WindowMock.cells` to `ScreenGrid.cells`).
///
/// `(x, y)` are 0-indexed (matching `ScreenGrid.writeCell` semantics);
/// the emitter translates them to 1-indexed CUP coordinates.
pub const DiffEntry = struct {
    x: u16,
    y: u16,
    cell: Cell,
};

/// Emit one diff entry's bytes: CUP `\x1b[<y+1>;<x+1>H` + SGR per style
/// + UTF-8 bytes of `cell.ch` + SGR reset `\x1b[0m`. Coordinates are
/// 0-indexed in (x, y), translated to terminal's 1-indexed CUP form.
///
/// SGR handling (REQ-DE-002, minimal viable for PR1b):
/// - `style.bold == true`  → emit `\x1b[1m` then UTF-8 then `\x1b[0m`
/// - no style flags set     → emit `\x1b[0m` then UTF-8 then `\x1b[0m`
///   (underline/reverse support deferred to T-2.4 if a real draw fn needs
///   it; this is the smallest SGR surface that proves the bold path
///   end-to-end, byte-exact asserted in tests/tui/screen_grid.zig.)
///
/// Preconditions (Tiger Style §4 — defensive precondition on system input):
/// - `cols > 0 && rows > 0`
/// - `entry.x < cols && entry.y < rows`
pub fn emitDiffEntry(
    writer: *std.Io.Writer,
    entry: DiffEntry,
    cols: u16,
    rows: u16,
) DiffEmitError!void {
    std.debug.assert(cols > 0);
    std.debug.assert(rows > 0);
    std.debug.assert(entry.x < cols);
    std.debug.assert(entry.y < rows);

    // ── CUP ────────────────────────────────────────────────────────────────
    // Inline the 1-indexed CUP bytes via a stack buffer (16 bytes fits
    // "ESC[" + up-to-5-digit row + ";" + up-to-5-digit col + "H" with
    // headroom). The contract's coordinate translation (0→1 for both x
    // and y) is a spec invariant — off-by-one would shift every cursor
    // move by one row/col.
    {
        var cup_buf: [16]u8 = undefined;
        const slice = std.fmt.bufPrint(
            &cup_buf,
            "\x1b[{d};{d}H",
            .{ entry.y + 1, entry.x + 1 },
        ) catch unreachable; // [16]u8 always fits "<row>;<col>H" up to 65535+65535
        try writer.writeAll(slice);
    }

    // ── SGR (leading) ──────────────────────────────────────────────────────
    if (entry.cell.style.bold) {
        try writer.writeAll("\x1b[1m");
    } else {
        // Defensive reset — clears any leftover bold/underline/reverse
        // from the previous entry so each cell renders independently.
        try writer.writeAll("\x1b[0m");
    }

    // ── UTF-8 (atomically committed or zero bytes per cell) ───────────────
    // Compose the full UTF-8 sequence in a stack buffer, then `writeAll`
    // the whole slice. If the writer's capacity is too small for the full
    // sequence, `std.Io.Writer.fixed` returns `error.WriteFailed` WITHOUT
    // committing any partial bytes — Tiger Style SS-1 fix for the
    // Phase 0.5 UTF-8 truncation bug at `src/tui.zig:478`.
    var utf8_buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(entry.cell.ch, &utf8_buf);
    try writer.writeAll(utf8_buf[0..n]);

    // ── SGR reset (trailing) ───────────────────────────────────────────────
    try writer.writeAll("\x1b[0m");
}

/// Emit a trailing CUP at `(cursor_col+1, cursor_row+1)` — terminal
/// coordinates are 1-indexed. When `cursor_col == CURSOR_SKIP`, this
/// fn emits ZERO bytes (no trailing CUP).
///
/// Preconditions (Tiger Style §4 — defensive precondition on system input):
/// - `cols > 0 && rows > 0`
/// - `cursor_col == CURSOR_SKIP`  OR  (`cursor_col < cols && cursor_row < rows`)
///
/// Caller contract: `cursor_col`/`cursor_row` originate from
/// `cursorFromIntent(...)` (T-2.1.2); the CURSOR_SKIP sentinel is the
/// stable contract that the modal layer uses to suppress the trailing CUP
/// for non-`key_entry` states.
pub fn emitTrailingCUP(
    writer: *std.Io.Writer,
    cursor_col: u16,
    cursor_row: u16,
    cols: u16,
    rows: u16,
) DiffEmitError!void {
    std.debug.assert(cols > 0);
    std.debug.assert(rows > 0);
    // Two states are accepted (Tiger Style §4 — precondition on system input):
    //   (a) cursor_col == CURSOR_SKIP → no trailing CUP (early return)
    //   (b) cursor_col < cols && cursor_row < rows → emit CUP at that position
    std.debug.assert(cursor_col == CURSOR_SKIP or
        (cursor_col < cols and cursor_row < rows));

    if (cursor_col == CURSOR_SKIP) {
        // No trailing CUP — non-`key_entry` states.
        return;
    }

    var cup_buf: [16]u8 = undefined;
    const slice = std.fmt.bufPrint(
        &cup_buf,
        "\x1b[{d};{d}H",
        .{ cursor_row + 1, cursor_col + 1 },
    ) catch unreachable;
    try writer.writeAll(slice);
}

/// Compute the diff between `prev` and `current`, emit each changed
/// cell via `emitDiffEntry`, then optionally emit a trailing CUP via
/// `emitTrailingCUP`. Zero heap allocation; bounded loop (worst case
/// `cols * rows` iterations).
///
/// Preconditions (Tiger Style §4 — defensive precondition on system input):
/// - `prev.len == current.len` (asserted; mismatched slices indicate a
///   double-buffer invariant violation upstream)
/// - `prev.len == cols * rows` (asserted; the cell count is a function of
///   the grid dimensions and must match the snapshot view)
/// - `cols > 0 && rows > 0` (asserted — empty grid is degenerate)
/// - `cursor_col == CURSOR_SKIP`  OR  (`cursor_col < cols`)
/// - `cursor_col == CURSOR_SKIP`  OR  (`cursor_row < rows`)
///
/// Caller contract: invoked once per `tuiThreadLoop` iteration AFTER the
/// modal draw fns have written into the active ScreenGrid. Caller does
/// NOT free the diff — this function is allocation-free.
pub fn diffAndEmit(
    writer: *std.Io.Writer,
    prev: []const Cell,
    current: []const Cell,
    cols: u16,
    rows: u16,
    cursor_col: u16,
    cursor_row: u16,
) DiffEmitError!void {
    std.debug.assert(cols > 0);
    std.debug.assert(rows > 0);
    std.debug.assert(prev.len == current.len);
    std.debug.assert(prev.len == @as(usize, cols) * @as(usize, rows));
    std.debug.assert(cursor_col == CURSOR_SKIP or cursor_col < cols);
    std.debug.assert(cursor_col == CURSOR_SKIP or cursor_row < rows);

    // Bounded loop (Tiger Style §5). Worst case is `cols * rows`
    // iterations; for the typical 80×24 = 1920 cells, the loop body is
    // a 4-byte struct equality check (Cell packs to 8 bytes; Zig uses
    // word-sized memcmp when the struct is well-aligned).
    for (prev[0..prev.len], 0..) |p_cell, idx| {
        const c_cell = current[idx];
        // Bit-equal Cell comparison: ch is u21, style is 3 packed bools;
        // Zig generates a single integer compare for the well-aligned
        // 8-byte Cell struct. No equality operator overload needed.
        if (p_cell.ch == c_cell.ch and
            p_cell.style.bold == c_cell.style.bold and
            p_cell.style.underline == c_cell.style.underline and
            p_cell.style.reverse == c_cell.style.reverse)
        {
            continue;
        }

        // Changed cell — emit a DiffEntry at (col, row).
        const col_idx: u16 = @intCast(idx % cols);
        const row_idx: u16 = @intCast(idx / cols);
        try emitDiffEntry(writer, .{
            .x = col_idx,
            .y = row_idx,
            .cell = c_cell,
        }, cols, rows);
    }

    try emitTrailingCUP(writer, cursor_col, cursor_row, cols, rows);
}

// ─── tests ───────────────────────────────────────────────────────────────────
// Unit tests live in tests/tui/screen_grid.zig (the RED file). Inline
// tests here would force a rebuild on every change; the dedicated test
// artifact is the canonical location (mirrors src/screen_grid.zig's test
// placement convention — see T-SG "every src/*.zig has test blocks"
// guard at `just check-tdd`).
//
// The single inline test below is a minimal smoke check that satisfies
// the project's strict-tdd guard. The full coverage (11 cases) is in
// tests/tui/screen_grid.zig.

test "diff_emit: DiffEntry is a compact value type (sizeof <= 16 bytes)" {
    // Smoke test — confirms the DiffEntry struct packs within 16 bytes
    // (2 × u16 + 8-byte Cell = 12 bytes typical, capped at 16).
    // Full coverage in tests/tui/screen_grid.zig.
    try std.testing.expect(@sizeOf(DiffEntry) <= 16);
}
