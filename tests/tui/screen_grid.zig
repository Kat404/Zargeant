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

const ScreenGrid = screen_grid_mod.ScreenGrid;
const MAX_CELL_BUF = screen_grid_mod.MAX_CELL_BUF;
const Cell = screen_grid_mod.Cell;

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
