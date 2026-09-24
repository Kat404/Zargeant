// tests/tui/screen_grid.zig — RED tests for ScreenGrid value type (T-2.1.1)
//
// Spec: sdd/tui-ship-fast-phase2/spec §3.1 (REQ-TUI-001, REQ-TUI-003)
// Design: sdd/tui-ship-fast-phase2/design §3.1
// Tasks: T-2.1.1 (PR1a-i)
//
// This file is the RED state for T-2.1.1 — it imports ScreenGrid from the
// new src/screen_grid.zig module and asserts the shape. The build will
// fail to compile because src/screen_grid.zig does not exist yet. The
// GREEN commit will add the impl, making all tests below pass.

const std = @import("std");
const testing = std.testing;
const screen_grid_mod = @import("screen_grid");
const diff_emit_mod = @import("diff_emit");

const ScreenGrid = screen_grid_mod.ScreenGrid;
const MAX_CELL_BUF = screen_grid_mod.MAX_CELL_BUF;
const Cell = screen_grid_mod.Cell;
const CursorIntent = screen_grid_mod.CursorIntent;
const CURSOR_SKIP = screen_grid_mod.CURSOR_SKIP;
const cursorFromIntent = screen_grid_mod.cursorFromIntent;
const DiffEntry = diff_emit_mod.DiffEntry;
const diffAndEmit = diff_emit_mod.diffAndEmit;
const emitDiffEntry = diff_emit_mod.emitDiffEntry;
const emitTrailingCUP = diff_emit_mod.emitTrailingCUP;

// REQ-TUI-001: ScreenGrid struct shape + invariants
// TDD RED: these tests fail because src/screen_grid.zig doesn't exist.
// TDD GREEN: passing after the impl lands.

test "ScreenGrid inits with deterministic buffer (REQ-TUI-001 happy path)" {
    const grid = try ScreenGrid.init(80, 24);
    defer grid.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 80), grid.cols);
    try testing.expectEqual(@as(u16, 24), grid.rows);
    try testing.expectEqual(@as(usize, 80 * 24), grid.active().len);
    // Every cell must be the canonical empty cell (ch=' ', style={}).
    for (grid.active()) |c| {
        try testing.expectEqual(@as(u21, ' '), c.ch);
        try testing.expect(!c.style.bold);
        try testing.expect(!c.style.underline);
        try testing.expect(!c.style.reverse);
    }
}

test "ScreenGrid rejects cols=0 (REQ-TUI-001 precondition)" {
    const result = ScreenGrid.init(0, 24);
    try testing.expectError(error.DimsTooLarge, result);
}

test "ScreenGrid rejects rows=0 (REQ-TUI-001 precondition)" {
    const result = ScreenGrid.init(80, 0);
    try testing.expectError(error.DimsTooLarge, result);
}

test "ScreenGrid rejects cols*rows > MAX_CELL_BUF (REQ-TUI-003 hard cap)" {
    // MAX_CELL_BUF is 32768 per the design. 256×128 = 32768 = at cap, OK.
    const atCap = try ScreenGrid.init(256, 128);
    defer atCap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 32768), atCap.active().len);

    // 257×128 = 32896 > MAX_CELL_BUF, should fail.
    const overCap = ScreenGrid.init(257, 128);
    try testing.expectError(error.DimsTooLarge, overCap);
}

// REQ-TUI-001: Bounds-checked writeCell — out-of-bounds drops, returns false.
test "ScreenGrid.writeCell at (col=cols, row=rows) drops cell (REQ-TUI-001 bounds)" {
    var grid = try ScreenGrid.init(80, 24);
    defer grid.deinit(testing.allocator);

    // Out-of-bounds write returns false.
    try testing.expect(!grid.writeCell(80, 0, 'X', .{})); // col=cols is OOB
    try testing.expect(!grid.writeCell(0, 24, 'X', .{})); // row=rows is OOB
    try testing.expect(!grid.writeCell(99, 99, 'X', .{})); // both OOB

    // In-bounds write returns true + sets the cell.
    try testing.expect(grid.writeCell(0, 0, 'X', .{}));
    try testing.expectEqual(@as(u21, 'X'), grid.active()[0].ch);
}

// REQ-TUI-001: snapshot is read-only view, no mutation.
test "ScreenGrid.snapshot returns const view of active grid" {
    var grid = try ScreenGrid.init(40, 12);
    defer grid.deinit(testing.allocator);

    _ = grid.writeCell(5, 5, 'Y', .{});
    const snap = grid.snapshot();
    try testing.expectEqual(@as(usize, 40 * 12), snap.len);
    try testing.expectEqual(@as(u21, 'Y'), snap[5 * 40 + 5].ch);
    // snap is []const Cell — type system enforces immutability.
}

// REQ-TUI-001: XOR swap cycles active_idx.
test "ScreenGrid.swap toggles active_idx" {
    var grid = try ScreenGrid.init(40, 12);
    defer grid.deinit(testing.allocator);

    try testing.expectEqual(@as(u1, 0), grid.active_idx);
    grid.swap();
    try testing.expectEqual(@as(u1, 1), grid.active_idx);
    grid.swap();
    try testing.expectEqual(@as(u1, 0), grid.active_idx);
}

// REQ-TUI-001: clear resets only active grid (not previous).
test "ScreenGrid.clear resets active but not previous" {
    var grid = try ScreenGrid.init(20, 10);
    defer grid.deinit(testing.allocator);

    // Write to active grid (idx 0).
    _ = grid.writeCell(0, 0, 'A', .{});
    // Swap so idx 0 becomes previous.
    grid.swap();
    // Write to new active (idx 1).
    _ = grid.writeCell(0, 0, 'B', .{});

    // Clear active.
    grid.clear();

    // Active (idx 1) is cleared.
    try testing.expectEqual(@as(u21, ' '), grid.active()[0].ch);
    // Previous (idx 0) still has 'A'.
    try testing.expectEqual(@as(u21, 'A'), grid.previous()[0].ch);
}

// REQ-TUI-003: MAX_CELL_BUF is a comptime u32 with reasonable value.
test "MAX_CELL_BUF is a comptime u32 in the 4096..65536 range" {
    try testing.expect(@as(u32, MAX_CELL_BUF) >= 4096); // covers 80×24 + room
    try testing.expect(@as(u32, MAX_CELL_BUF) <= 65536); // ultrawide ceiling
}

// REQ-LIFECYCLE-004 (T-2.5.x): Lifecycle struct size audit.
test "Cell is a compact value type (sizeof <= 16 bytes)" {
    // Cell = { ch: u21, style: Style } where Style = { 3 × bool }.
    // Packed: 3 (u21) + 3 (bools) + padding = ~8 bytes typical, capped at 16.
    try testing.expect(@sizeOf(Cell) <= 16);
}

// T-2.1.2: CursorIntent + CURSOR_SKIP + cursorFromIntent (REQ-TUI-001 §3.1,
// design §3.1 + §8.2). All seven cases live in one block so the build
// fails to compile while any required symbol is missing (RED guard).

test "cursorFromIntent resolves CursorIntent to (col, row) or CURSOR_SKIP" {
    // Case 1: .hide ignores cursor_col/cursor_row/cols and returns
    // CURSOR_SKIP for both axes. Even out-of-range args are ignored.
    {
        const r = cursorFromIntent(.hide, 99, 50, 80);
        try testing.expectEqual(@as(u16, CURSOR_SKIP), r.col);
        try testing.expectEqual(@as(u16, CURSOR_SKIP), r.row);
    }
    {
        // .hide with zero-sized grid still returns CURSOR_SKIP.
        const r = cursorFromIntent(.hide, 0, 0, 0);
        try testing.expectEqual(@as(u16, CURSOR_SKIP), r.col);
        try testing.expectEqual(@as(u16, CURSOR_SKIP), r.row);
    }

    // Case 2: .show returns cursor_col/cursor_row verbatim when in bounds.
    {
        const r = cursorFromIntent(.show, 5, 3, 80);
        try testing.expectEqual(@as(u16, 5), r.col);
        try testing.expectEqual(@as(u16, 3), r.row);
    }

    // Case 3: .show at boundary (0, 0) returns (0, 0).
    {
        const r = cursorFromIntent(.show, 0, 0, 80);
        try testing.expectEqual(@as(u16, 0), r.col);
        try testing.expectEqual(@as(u16, 0), r.row);
    }

    // Case 4: .show near max — col=cols-1 (and row=rows-1) passes
    // the bounds assert and returns verbatim.
    {
        const r = cursorFromIntent(.show, 79, 0, 80);
        try testing.expectEqual(@as(u16, 79), r.col);
        try testing.expectEqual(@as(u16, 0), r.row);
    }
    {
        const r = cursorFromIntent(.show, 79, 23, 80);
        try testing.expectEqual(@as(u16, 79), r.col);
        try testing.expectEqual(@as(u16, 23), r.row);
    }

    // Case 5: CursorIntent has exactly 2 variants and the switch is
    // exhaustive. Adding/removing a variant breaks compile (RED guard).
    {
        const fields = @typeInfo(CursorIntent).@"enum".fields;
        try testing.expectEqual(@as(usize, 2), fields.len);
        // Exhaustive switch — no `else` prong. If a 3rd variant is
        // added, this block fails to compile.
        const tag_hide: u8 = switch (CursorIntent.hide) {
            .hide => 0,
            .show => 1,
        };
        const tag_show: u8 = switch (CursorIntent.show) {
            .show => 1,
            .hide => 0,
        };
        try testing.expectEqual(@as(u8, 0), tag_hide);
        try testing.expectEqual(@as(u8, 1), tag_show);
    }

    // Case 6: cursorFromIntent is a module-level pub fn (compile-time
    // symbol existence guard). Note: the design places it at module
    // scope (not on ScreenGrid), so we test on `screen_grid_mod`.
    try testing.expect(@hasDecl(screen_grid_mod, "cursorFromIntent"));

    // Case 7: CURSOR_SKIP sentinel is exactly u16 max. Stable surface
    // for the `if (cursor_col != CURSOR_SKIP)` gate in src/tui.zig:443.
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), CURSOR_SKIP);
}

// T-2.2.1: diffAndEmit + DiffEntry + emitDiffEntry + emitTrailingCUP
// (REQ-DE-001..003, REQ-DE-006, REQ-DE-010, design §3.2). Each scenario
// is a separate test block so the test runner reports the exact failing
// case. RED state: src/diff_emit.zig stubs return
// `error.SkeletonNotImplemented` so every diffAndEmit call below fails
// with that error. GREEN state: all 11 tests pass.
//
// Reference byte encoding (asserted byte-exact in tests below):
//   CUP         "ESC [ <row+1> ; <col+1> H"      (1-indexed)
//   SGR bold    "ESC [ 1 m"
//   SGR reset   "ESC [ 0 m"
//   UTF-8 'A'   0x41
//   UTF-8 'é'   0xc3 0xa9   (U+00E9)
//   UTF-8 '€'   0xe2 0x82 0xac (U+20AC)
//   UTF-8 '😀'  0xf0 0x9f 0x98 0x80 (U+1F600)

test "diffAndEmit identical grids emit zero entries and zero trailing CUP" {
    // Empty buffer: identical prev/current + CURSOR_SKIP → nothing to emit.
    var prev: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    var current: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try diffAndEmit(&w, &prev, &current, 4, 1, CURSOR_SKIP, 0);

    try testing.expectEqual(@as(usize, 0), w.end);
}

test "diffAndEmit one changed cell emits CUP+SGR+UTF-8+SGR reset" {
    // Single change at (col=5, row=2) with 'A' and no style.
    // 0-indexed (5, 2) → 1-indexed CUP "ESC[3;6H".
    // No style → leading SGR reset "ESC[0m", char "A", trailing SGR reset.
    // Expected: \x1b[3;6H \x1b[0m \x41 \x1b[0m
    var prev: [24]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 24;
    var current: [24]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 24;
    // (col=5, row=2) with cols=8 → idx = 2*8 + 5 = 21
    current[21] = .{ .ch = 'A', .style = .{} };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try diffAndEmit(&w, &prev, &current, 8, 3, CURSOR_SKIP, 0);

    const expected = "\x1b[3;6H\x1b[0m\x41\x1b[0m";
    try testing.expectEqualStrings(expected, buf[0..w.end]);
}

test "diffAndEmit two adjacent changes emit two entries" {
    // 2 cells changed in the same row at col=2 and col=3.
    // Expected: two entries with growing column coordinates.
    //   entry 1: CUP "\x1b[1;3H" + "\x1b[0m" + "X" + "\x1b[0m"
    //   entry 2: CUP "\x1b[1;4H" + "\x1b[0m" + "Y" + "\x1b[0m"
    var prev: [8]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 8;
    var current: [8]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 8;
    current[2] = .{ .ch = 'X', .style = .{} };
    current[3] = .{ .ch = 'Y', .style = .{} };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try diffAndEmit(&w, &prev, &current, 8, 1, CURSOR_SKIP, 0);

    const expected = "\x1b[1;3H\x1b[0m\x58\x1b[0m" ++
        "\x1b[1;4H\x1b[0m\x59\x1b[0m";
    try testing.expectEqualStrings(expected, buf[0..w.end]);
}

test "diffAndEmit bold style emits bold SGR (\\x1b[1m) and reset (\\x1b[0m)" {
    // style.bold=true → output contains "\x1b[1m" and ends with "\x1b[0m".
    var prev: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    var current: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    current[0] = .{ .ch = 'B', .style = .{ .bold = true } };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try diffAndEmit(&w, &prev, &current, 4, 1, CURSOR_SKIP, 0);

    const actual = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, actual, "\x1b[1m") != null);
    // Each entry ends with SGR reset.
    try testing.expect(std.mem.endsWith(u8, actual, "\x1b[0m"));
    // Byte-exact: CUP "\x1b[1;1H" + bold "\x1b[1m" + "B" + reset "\x1b[0m"
    try testing.expectEqualStrings(
        "\x1b[1;1H\x1b[1m\x42\x1b[0m",
        actual,
    );
}

test "diffAndEmit trailing CUP at cursor position when cursor_col != CURSOR_SKIP" {
    // cursor_col=10, cursor_row=4 → trailing CUP "\x1b[5;11H". Grid is
    // sized 20×10 so the precondition `cursor_col < cols && cursor_row < rows`
    // holds (10 < 20, 4 < 10). One cell change to force the function past
    // the loop body; then emitTrailingCUP appends the trailing CUP.
    var prev: [200]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 200;
    var current: [200]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 200;
    current[0] = .{ .ch = 'Z', .style = .{} };

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try diffAndEmit(&w, &prev, &current, 20, 10, 10, 4);

    // Trailing bytes after the last entry are exactly "\x1b[5;11H".
    const actual = buf[0..w.end];
    try testing.expect(std.mem.endsWith(u8, actual, "\x1b[5;11H"));
}

test "diffAndEmit trailing CUP skipped when cursor_col == CURSOR_SKIP" {
    // Output ends after the last diff entry, no trailing CUP appended.
    var prev: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    var current: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    current[0] = .{ .ch = 'Z', .style = .{} };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try diffAndEmit(&w, &prev, &current, 4, 1, CURSOR_SKIP, 0);

    // Byte-exact: one entry ending in "\x1b[0m", no trailing CUP.
    try testing.expectEqualStrings(
        "\x1b[1;1H\x1b[0m\x5a\x1b[0m",
        buf[0..w.end],
    );
}

test "diffAndEmit emits 3-byte UTF-8 (€) intact" {
    // U+20AC (€) encodes to 3 bytes: 0xe2 0x82 0xac.
    var prev: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    var current: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    current[0] = .{ .ch = 0x20AC, .style = .{} };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try diffAndEmit(&w, &prev, &current, 4, 1, CURSOR_SKIP, 0);

    const actual = buf[0..w.end];
    // The 3-byte UTF-8 sequence must appear intact (NOT truncated to "\xac").
    try testing.expect(std.mem.indexOf(u8, actual, "\xe2\x82\xac") != null);
    // Byte-exact: CUP + SGR reset + € + SGR reset
    try testing.expectEqualStrings(
        "\x1b[1;1H\x1b[0m\xe2\x82\xac\x1b[0m",
        actual,
    );
}

test "diffAndEmit emits 4-byte UTF-8 (😀) intact" {
    // U+1F600 (😀) encodes to 4 bytes: 0xf0 0x9f 0x98 0x80.
    var prev: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    var current: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    current[0] = .{ .ch = 0x1F600, .style = .{} };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try diffAndEmit(&w, &prev, &current, 4, 1, CURSOR_SKIP, 0);

    const actual = buf[0..w.end];
    // Full 4-byte sequence must appear (SS-1 fix — no truncation).
    try testing.expect(std.mem.indexOf(u8, actual, "\xf0\x9f\x98\x80") != null);
    // Byte-exact: CUP + SGR reset + 😀 + SGR reset
    try testing.expectEqualStrings(
        "\x1b[1;1H\x1b[0m\xf0\x9f\x98\x80\x1b[0m",
        actual,
    );
}

test "diffAndEmit atomic 4-byte UTF-8 (full sequence or zero bytes per cell)" {
    // Buffer sized to fit CUP (8 bytes "ESC[1;1H") + SGR reset
    // (4 bytes "ESC[0m") = 12 bytes. The 4-byte emoji requires 4 more
    // bytes; with the buffer full after the leading SGR reset, the
    // `writeAll` of the UTF-8 slice fails cleanly with
    // `error.WriteFailed`. The function propagates the error without
    // crashing (Tiger Style §1 — fail fast, propagate cleanly).
    var buf: [12]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    var prev: [1]Cell = .{.{ .ch = ' ', .style = .{} }};
    var current: [1]Cell = .{.{ .ch = 0x1F600, .style = .{} }};

    const result = diffAndEmit(&w, &prev, &current, 1, 1, CURSOR_SKIP, 0);
    try testing.expectError(error.WriteFailed, result);
}

test "diffAndEmit zero allocations under testing.allocator" {
    // Tiger Style §3 — zero allocations in the hot path.
    // diffAndEmit's signature has no `Allocator` parameter (compile-time
    // guard). We use a FixedBufferAllocator as a sentinel counter — the
    // `end_index` is checked before/after; any allocation would bump it.
    var fba_buf: [4096]u8 = undefined;
    const fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const before = fba.end_index;

    var prev: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    var current: [4]Cell = .{Cell{ .ch = ' ', .style = .{} }} ** 4;
    current[0] = .{ .ch = 'A', .style = .{} };
    current[2] = .{ .ch = 'X', .style = .{ .bold = true } };

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try diffAndEmit(&w, &prev, &current, 4, 1, CURSOR_SKIP, 0);

    try testing.expectEqual(before, fba.end_index);
}

test "@hasDecl(diff_emit_mod, \"diffAndEmit\" + \"emitDiffEntry\" + \"emitTrailingCUP\")" {
    // Compile-time symbol guards. The contract places all three at
    // module scope (not on ScreenGrid or DiffEntry), so we test on
    // `diff_emit_mod` directly.
    try testing.expect(@hasDecl(diff_emit_mod, "diffAndEmit"));
    try testing.expect(@hasDecl(diff_emit_mod, "emitDiffEntry"));
    try testing.expect(@hasDecl(diff_emit_mod, "emitTrailingCUP"));
    try testing.expect(@hasDecl(diff_emit_mod, "DiffEntry"));
}
