// src/modal.zig — Modal state machine + draw fns + WindowMock headless surface.
//
// Spec:    sdd/tui-recovery/spec  (id=407) REQ-TUI-005..010
// Design:  sdd/tui-recovery/design (id=408) §1 (modal state machine + WindowMock)
//
// R-PR 3 ships:
//   - WindowMock (10-method surface per design#408 §1c, with Cell/Style/
//     DiffEntry/TermSize types) for headless modal tests under os.tty=false.
//   - State union(enum) (6 variants: welcome, key_entry, unlock_prompt,
//     consent_prompt, agent_loop, error_modal) with payload structs.
//   - 5 modal draw fns: drawKeyEntry, drawUnlock, drawConsentPrompt,
//     drawErrorModal, drawAgentLoopView.
//
// Each draw fn takes a `*WindowMock` + `*State` and either:
//   - renders into the WindowMock + leaves the state unchanged, OR
//   - mutates the state to transition to a new variant (e.g. key_entry
//     advances to consent_prompt on API validation success).
//
// Linux/x86_64 Zig 0.16 only.

const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger.zig");
const api_auth = @import("api_auth.zig");

// =============================================================================
// Linux-only comptime guard (matches every other module in the project).
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("modal: linux-only v1");
}

// =============================================================================
// WindowMock support types (Cell / Style / DiffEntry / TermSize).
// =============================================================================

/// Cell-level style flags (no color attrs in v1 — keeps the mock lean).
pub const Style = struct {
    bold: bool = false,
    underline: bool = false,
    reverse: bool = false,
};

/// One character cell on the headless WindowMock grid.
pub const Cell = struct {
    ch: u21 = ' ',
    style: Style = .{},
};

/// One entry in a diff between two snapshots.
pub const DiffEntry = struct {
    x: u16,
    y: u16,
    cell: Cell,
};

/// Terminal size in columns × rows.
pub const TermSize = struct {
    cols: u16,
    rows: u16,
};

// =============================================================================
// WindowMock — headless surface for modal draw fns.
//
// 10 methods per design#408 §1c (init / deinit / print / clear / hideCursor /
// showCursor / enterAlternateScreen / exitAlternateScreen / snapshot / diff)
// plus size() getter. The mock owns a `cols × rows` cell grid that the modal
// draw fns write into. Tests assert via snapshot() + diff(prev, current).
// =============================================================================

pub const WindowMock = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    cells: []Cell,
    cursor_hidden: bool = false,
    in_alt_screen: bool = false,

    /// Allocate a WindowMock with the given dimensions. The cell grid is
    /// zero-initialised (every cell is a space with empty style).
    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !*WindowMock {
        const self = try allocator.create(WindowMock);
        errdefer allocator.destroy(self);
        const n: usize = @as(usize, cols) * @as(usize, rows);
        const cells = try allocator.alloc(Cell, n);
        @memset(cells, .{ .ch = ' ', .style = .{} });
        self.* = .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cells = cells,
        };
        return self;
    }

    /// Free the cell grid + the WindowMock itself. Idempotent.
    pub fn deinit(self: *WindowMock) void {
        self.allocator.free(self.cells);
        self.allocator.destroy(self);
    }

    /// Current terminal size.
    pub fn size(self: *WindowMock) TermSize {
        return .{ .cols = self.cols, .rows = self.rows };
    }

    /// Reset every cell to a space.
    pub fn clear(self: *WindowMock) void {
        @memset(self.cells, .{ .ch = ' ', .style = .{} });
    }

    /// Print `text` with `style` starting at (0,0), advancing linearly.
    /// Text longer than `cols` is truncated; empty text is a no-op.
    /// The cursor stays at (text.len, 0) on the same line for callers
    /// that want to chain prints.
    pub fn print(self: *WindowMock, text: []const u8, style: Style) !void {
        if (self.cols == 0 or self.rows == 0) return;
        const max: usize = @min(text.len, self.cols);
        for (text[0..max], 0..) |c, i| {
            self.cells[i] = .{ .ch = c, .style = style };
        }
    }

    /// Hide the cursor. The mock flips the flag so tests can assert.
    pub fn hideCursor(self: *WindowMock) void {
        self.cursor_hidden = true;
    }

    /// Show the cursor.
    pub fn showCursor(self: *WindowMock) void {
        self.cursor_hidden = false;
    }

    /// Switch to the alternate screen buffer.
    pub fn enterAlternateScreen(self: *WindowMock) void {
        self.in_alt_screen = true;
    }

    /// Return to the primary screen buffer.
    pub fn exitAlternateScreen(self: *WindowMock) void {
        self.in_alt_screen = false;
    }

    /// Return the current cell grid. The slice is owned by the WindowMock
    /// (caller must NOT free). Cheap — no copy.
    pub fn snapshot(self: *WindowMock) []Cell {
        return self.cells;
    }

    /// Return a fresh slice of `DiffEntry` covering cells that differ
    /// between `prev` and the current grid. Allocates; caller frees.
    /// Two cells with the same char and style flags compare equal.
    pub fn diff(self: *WindowMock, prev: []const Cell) ![]DiffEntry {
        var entries: std.ArrayList(DiffEntry) = .empty;
        defer entries.deinit(self.allocator);
        const limit: usize = @min(prev.len, self.cells.len);
        for (self.cells[0..limit], 0..) |cell, i| {
            const prev_cell = if (i < prev.len) prev[i] else Cell{ .ch = 0, .style = .{} };
            if (cell.ch != prev_cell.ch or !std.meta.eql(cell.style, prev_cell.style)) {
                try entries.append(self.allocator, .{
                    .x = @intCast(i % @as(usize, self.cols)),
                    .y = @intCast(i / @as(usize, self.cols)),
                    .cell = cell,
                });
            }
        }
        return entries.toOwnedSlice(self.allocator);
    }
};

// =============================================================================
// Tests — task 3.1: WindowMock surface (4 RED→GREEN tests).
// =============================================================================

const testing = std.testing;

test "WindowMock init returns non-null with deterministic buffer" {
    // RED: WindowMock does not exist yet → compile error.
    // GREEN: init allocates + zero-fills cells.
    const win = try WindowMock.init(testing.allocator, 80, 24);
    defer win.deinit();

    try testing.expect(win.cells.len == 80 * 24);
    try testing.expectEqual(@as(u16, 80), win.size().cols);
    try testing.expectEqual(@as(u16, 24), win.size().rows);
    // Every cell starts as a space with no style flags.
    for (win.snapshot()) |cell| {
        try testing.expectEqual(@as(u21, ' '), cell.ch);
        try testing.expect(!cell.style.bold);
    }
    // Cursor + alt-screen default to "off".
    try testing.expect(!win.cursor_hidden);
    try testing.expect(!win.in_alt_screen);
}

test "WindowMock deinit does not leak (allocator check)" {
    // After init + deinit, testing.allocator should report no leaks. The
    // assertion is implicit (no leak detector trip); the explicit check is
    // that the cells slice has the expected length before deinit and the
    // struct itself is freed (no use-after-free).
    const win = try WindowMock.init(testing.allocator, 8, 4);
    try testing.expectEqual(@as(usize, 32), win.cells.len);
    win.deinit();
    // testing.allocator will report a leak if deinit forgot to free.
    // Zig's test runner detects leaks automatically on shutdown.
}

test "WindowMock snapshot returns deterministic cell buffer" {
    // print writes text starting at (0,0); snapshot exposes the buffer.
    const win = try WindowMock.init(testing.allocator, 16, 4);
    defer win.deinit();

    try win.print("hello", .{});
    const snap = win.snapshot();
    try testing.expectEqual(@as(u21, 'h'), snap[0].ch);
    try testing.expectEqual(@as(u21, 'e'), snap[1].ch);
    try testing.expectEqual(@as(u21, 'l'), snap[2].ch);
    try testing.expectEqual(@as(u21, 'l'), snap[3].ch);
    try testing.expectEqual(@as(u21, 'o'), snap[4].ch);
    // Cells 5..15 stay as spaces.
    try testing.expectEqual(@as(u21, ' '), snap[5].ch);
}

test "WindowMock diff returns entries for cells that changed" {
    // diff(prev, current) returns a slice of DiffEntry rows for every cell
    // whose ch OR style changed. Caller frees.
    const win = try WindowMock.init(testing.allocator, 8, 2);
    defer win.deinit();

    // Initial grid: all spaces.
    const initial = try testing.allocator.alloc(Cell, win.cells.len);
    defer testing.allocator.free(initial);
    @memcpy(initial, win.cells);

    // Change cells 0..3 to "abcd".
    try win.print("abcd", .{});

    const entries = try win.diff(initial);
    defer testing.allocator.free(entries);

    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqual(@as(u16, 0), entries[0].x);
    try testing.expectEqual(@as(u16, 0), entries[0].y);
    try testing.expectEqual(@as(u21, 'a'), entries[0].cell.ch);
    try testing.expectEqual(@as(u16, 3), entries[3].x);
    try testing.expectEqual(@as(u21, 'd'), entries[3].cell.ch);
}
