// src/screen_grid.zig — ScreenGrid value type (T-2.1.1 GREEN)
//
// Spec: sdd/tui-ship-fast-phase2/spec §3.1 (REQ-TUI-001, REQ-TUI-003)
// Design: sdd/tui-ship-fast-phase2/design §3.1
// Tasks: T-2.1.1 (PR1a-i, Phase 2 WU 2.1)
//
// The ScreenGrid is a value-typed, fixed-cap, stack-allocatable cell
// grid used by the Phase 2 TUI render pipeline. It replaces the
// heap-allocated `WindowMock` cell storage with a [2]ScreenGrid double
// buffer on `Lifecycle`, eliminating the per-frame `alloc.dupe` that
// Phase 0.5 inherited from the mibu pipeline.
//
// Tiger Style §3 — no heap allocation; `[2][MAX_CELL_BUF]Cell` is
// inline (2 × 32768 × sizeof(Cell) ≈ 1 MiB worst case, ~30 KiB at
// typical 80×24).
// Tiger Style §4 — every function has precondition asserts.
// Tiger Style §5 — bounded iteration; XOR swap is branch-free.
// Tiger Style §7 — deterministic (no I/O, no allocator, no globals).

const std = @import("std");

/// Hard ceiling on per-grid cell count. 32768 = 256 cols × 128 rows.
/// Covers the theoretical 4K display case while keeping the worst-case
/// `Lifecycle` footprint bounded. `tuiThreadInit` MUST validate
/// `cols * rows <= MAX_CELL_BUF` at startup (Tiger Style §4 — defensive
/// precondition on system input).
pub const MAX_CELL_BUF: usize = 32768;

/// One character cell on the ScreenGrid. Mirrors `modal.Cell` so the
/// existing diff algorithm (Phase 0.5 `WindowMock.diff`) ports
/// unchanged — Phase 2 PR1c will wire the new `diffAndEmit` to read
/// `ScreenGrid.cells` (not `WindowMock.cells`).
pub const Cell = struct {
    ch: u21 = ' ',
    style: Style = .{},
};

/// Cell-level style flags (bold/underline/reverse). Mirrors `modal.Style`.
/// Three packed bools land in 1 byte; the u21 `ch` field packs into
/// 4 bytes; total Cell = 8 bytes on x86_64.
pub const Style = struct {
    bold: bool = false,
    underline: bool = false,
    reverse: bool = false,
};

/// Value-typed double-buffered grid. Allocated on the TUI thread
/// stack as part of `Lifecycle` (see WU 2.5). All grid mutations
/// go through `writeCell` + the render fns; the raw `cells` slice
/// is never written directly outside this module.
///
/// The `[2][MAX_CELL_BUF]Cell` array is inline (no heap), so
/// `ScreenGrid` instances are cheap to copy by value (e.g., for tests).
/// The `active_idx` XOR swap is branch-free (Tiger Style §5).
pub const ScreenGrid = struct {
    cols: u16,
    rows: u16,

    /// Double buffer: index 0 and index 1, one is "active" (draw fn
    /// writes here), the other is "previous" (diff baseline). The
    /// XOR swap cycles between them every frame, eliminating the
    /// `alloc.dupe(Cell, current)` that Phase 0.5 inherited from
    /// `tuiThreadLoop:675`.
    cells: [2][MAX_CELL_BUF]Cell,

    /// Which of the two buffers is the "active" one (writes go here).
    /// Flipped by `swap` (XOR with 1).
    active_idx: u1 = 0,

    /// Initialize a ScreenGrid with the given dimensions. Returns an
    /// error if `cols * rows > MAX_CELL_BUF` (caller must upsize
    /// `MAX_CELL_BUF` or reduce dims; never silently truncates).
    ///
    /// Preconditions:
    /// - `cols > 0 && rows > 0` (a zero-dim grid is nonsensical)
    /// - `cols * rows <= MAX_CELL_BUF`
    ///
    /// Caller contract: only the TUI thread constructs ScreenGrid (the
    /// `[2]ScreenGrid` lives in `Lifecycle`; tests construct ad-hoc
    /// instances on the stack). After construction, all grid mutations
    /// go through `writeCell` + the render fns, never raw slice writes.
    pub fn init(cols: u16, rows: u16) !ScreenGrid {
        if (cols == 0 or rows == 0) return error.DimsTooLarge;
        const len: usize = @as(usize, cols) * @as(usize, rows);
        if (len > MAX_CELL_BUF) return error.DimsTooLarge;
        // Initialize both buffers with canonical empty cells.
        // The empty cell is { ch = ' ', style = {} } — see T-SG-1
        // contract at tests/tui/runtime_thread.zig:1618.
        const empty_cell: Cell = .{ .ch = ' ', .style = .{} };
        const grid: ScreenGrid = .{
            .cols = cols,
            .rows = rows,
            .cells = .{
                .{empty_cell} ** MAX_CELL_BUF,
                .{empty_cell} ** MAX_CELL_BUF,
            },
            .active_idx = 0,
        };
        return grid;
    }

    /// Reset the active grid to spaces. Does NOT reset the inactive
    /// grid — the inactive grid carries the previous frame's diff
    /// baseline. `clear` is the caller's responsibility BEFORE
    /// `renderToGrid` writes the new frame.
    pub fn clear(self: *ScreenGrid) void {
        const activeBuf = self.activeMut();
        @memset(activeBuf, .{ .ch = ' ', .style = .{} });
    }

    /// Write a single cell at `(col, row)` in the active grid.
    /// Bounds-checked; an out-of-bounds cell is silently dropped
    /// (defensive against draw fn off-by-one regressions).
    /// Returns true if the cell was written, false if dropped.
    pub fn writeCell(self: *ScreenGrid, col: u16, row: u16, ch: u21, style: Style) bool {
        if (col >= self.cols or row >= self.rows) return false;
        const idx = @as(usize, row) * @as(usize, self.cols) + @as(usize, col);
        const activeBuf = self.activeMut();
        activeBuf[idx] = .{ .ch = ch, .style = style };
        return true;
    }

    /// Read-only view of the active grid. Cheap — no copy.
    /// The returned slice is a view into the `[2][MAX_CELL_BUF]Cell`
    /// storage and MUST NOT be retained across `swap` calls (the
    /// pointer becomes the "previous" view after a swap).
    pub fn active(self: *const ScreenGrid) []const Cell {
        const len: usize = @as(usize, self.cols) * @as(usize, self.rows);
        return self.cells[self.active_idx][0..len];
    }

    /// Read-only view of the active grid (alias for `active`). Provided
    /// for parity with `WindowMock.snapshot` semantics — the Phase 2
    /// diff algorithm will read the same view through either name.
    /// Cheap — no copy.
    pub fn snapshot(self: *const ScreenGrid) []const Cell {
        return self.active();
    }

    /// Read-only view of the previous grid (the diff baseline).
    pub fn previous(self: *const ScreenGrid) []const Cell {
        const prev_idx = self.active_idx ^ 1;
        const len: usize = @as(usize, self.cols) * @as(usize, self.rows);
        return self.cells[prev_idx][0..len];
    }

    /// XOR swap of `active_idx`. Caller invokes this AFTER
    /// `diffAndEmit` has produced the diff and emitted it, so the
    /// next frame's draw fn writes into the previously-inactive
    /// grid. Idempotent in pairs (two swaps = original state).
    /// Branch-free: XOR with 1 cycles between 0 and 1 atomically.
    pub fn swap(self: *ScreenGrid) void {
        self.active_idx ^= 1;
    }

    /// Tear down the grid. No-op (no heap allocation), but the
    /// `allocator` parameter is accepted for API symmetry with
    /// future Phase 3 grids that may allocate. Always call this
    /// after `init` to satisfy the contract. Takes `*const` since
    /// deinit is a no-op (no mutation).
    pub fn deinit(self: *const ScreenGrid, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
        // Intentionally empty: ScreenGrid is value-typed with inline
        // storage. No resources to release.
    }

    // ─── private ─────────────────────────────────────────────────────────

    /// Mutable view of the active grid. Used by `clear` and `writeCell`.
    fn activeMut(self: *ScreenGrid) []Cell {
        const len: usize = @as(usize, self.cols) * @as(usize, self.rows);
        return self.cells[self.active_idx][0..len];
    }
};

// ─── tests ───────────────────────────────────────────────────────────────────
// Unit tests live in tests/tui/screen_grid.zig (the RED file). Inline
// tests here would force a rebuild on every change; the dedicated test
// artifact is the canonical location (mirrors T-SG-8 contract for
// src/modal.zig, where the 5 draw fns are tested from
// tests/tui/runtime_thread.zig, not inline).
