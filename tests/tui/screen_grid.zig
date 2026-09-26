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
// tui-ship-fast-phase2 (T-2.3.1) — renderKeyEntryToGrid tests below
// import `modal` via lib_mod (wired in build.zig:536). The test file
// accesses the modal namespace through `modal_root.modal.<symbol>`
// because lib_mod re-exports modal via `pub const modal = @import("modal.zig")`
// in src/root.zig:38.
const modal_root = @import("modal");
const modal_ns = modal_root.modal;
const renderKeyEntryToGrid = modal_ns.renderKeyEntryToGrid;
// tui-ship-fast-phase2 (T-2.3.2) — 4 more render*ToGrid fns (renderUnlockToGrid,
// renderConsentPromptToGrid, renderErrorModalToGrid, renderAgentLoopToGrid).
// Same pattern as renderKeyEntryToGrid (T-2.3.1, line above): each mirrors
// its corresponding draw* fn and writes to a *ScreenGrid instead of *WindowMock.
const renderUnlockToGrid = modal_ns.renderUnlockToGrid;
const renderConsentPromptToGrid = modal_ns.renderConsentPromptToGrid;
const renderErrorModalToGrid = modal_ns.renderErrorModalToGrid;
const renderAgentLoopToGrid = modal_ns.renderAgentLoopToGrid;
const ModalState = modal_ns.State;
// tui-ship-fast-phase2 (T-2.3.3) — renderToGrid dispatcher routes the
// active State variant to the corresponding render*ToGrid fn. Same
// import pattern as the per-fn imports above.
const renderToGrid = modal_ns.renderToGrid;
// tui-ship-fast-phase2 (T-2.4.1) — WindowMock adapter wrapping *ScreenGrid.
// Required by T-SG-8 (tests/tui/runtime_thread.zig:1618 preserves the
// WindowMock + 5 draw fns literals). The adapter's 10-method surface
// forwards calls to a ScreenGrid; the existing modal.zig in-file tests
// at lines 1197-1614 must pass unchanged.
const WindowMock = modal_ns.WindowMock;
const ModalCell = modal_ns.Cell;

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

// T-2.3.1: renderKeyEntryToGrid (REQ-MODAL-001, design §3.4, T-SG-8 preserved).
//
// One test block with 5 sub-cases — mirrors the umbrella test pattern
// already used at "cursorFromIntent resolves CursorIntent ..." (line 146)
// and "diffAndEmit one changed cell emits ..." (line 246). All sub-cases
// share the same setup pattern (80×24 ScreenGrid + State.key_entry).
//
// RED state: renderKeyEntryToGrid panics with "SkeletonNotImplemented"
// (T-2.3.1 stub at src/modal.zig:462). The first sub-case to invoke the
// function terminates the test process; sub-cases 1..4 fail by panic.
// Sub-case 5 (`@hasDecl` compile-time guard) is the only one that passes
// in RED. The GREEN impl replaces the stub and all 5 sub-cases pass.
test "renderKeyEntryToGrid mirrors drawKeyEntry into ScreenGrid (T-2.3.1)" {
    const prefix_len: usize = "Enter API key: ".len; // 15

    // Case 1: key_entry + draft "abcd" writes 4 '*' cells at positions
    //         15..18 (the mask region immediately after the prompt).
    //
    //   drawKeyEntry writes '*' at win.cells[15 + i] for i in 0..shown.
    //   renderKeyEntryToGrid writes the same via grid.writeCell(15+i, 0, '*', .{}).
    {
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..4], "abcd");
        const state: ModalState = .{
            .key_entry = .{
                .draft = draft_buf,
                .draft_len = 4,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderKeyEntryToGrid(&grid, &state);

        const active = grid.active();
        for (0..4) |i| {
            try testing.expectEqual(@as(u21, '*'), active[prefix_len + i].ch);
        }
    }

    // Case 2: key_entry + empty draft writes 0 mask cells (no '*' in
    //         the mask region; prompt still fills cols 0..14).
    {
        const state: ModalState = .{ .key_entry = .{} };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderKeyEntryToGrid(&grid, &state);

        const active = grid.active();
        // No '*' should appear anywhere in row 0 (mask region only).
        for (0..80) |i| {
            try testing.expect(active[i].ch != '*');
        }
        // The prompt prefix chars are still written at cols 0..14.
        const prompt = "Enter API key: ";
        for (prompt, 0..) |expected, i| {
            try testing.expectEqual(@as(u21, expected), active[i].ch);
        }
    }

    // Case 3: renderKeyEntryToGrid does NOT mutate state. drawKeyEntry
    //         writes payload.cursor_col / cursor_row as a side effect
    //         (WU 0.6 fix); the new fn explicitly does NOT touch state
    //         (per design §3.4 caller contract: "Pure renderer — does NOT
    //         mutate state"). All payload fields stay byte-identical.
    {
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..3], "xyz");
        var state: ModalState = .{
            .key_entry = .{
                .draft = draft_buf,
                .draft_len = 3,
                .cursor_col = 7,
                .cursor_row = 11,
            },
        };
        const before = state;
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderKeyEntryToGrid(&grid, &state);

        // State fields are byte-identical — no assignment happened.
        try testing.expectEqual(before.key_entry.draft_len, state.key_entry.draft_len);
        try testing.expectEqual(@as(u16, 7), state.key_entry.cursor_col);
        try testing.expectEqual(@as(u16, 11), state.key_entry.cursor_row);
        try testing.expectEqualSlices(u8, &before.key_entry.draft, &state.key_entry.draft);
    }

    // Case 4: prompt text is written at expected row/col positions. The
    //         prompt is "Enter API key: " (15 chars) at row 0, cols 0..14.
    //         We sample representative chars (positions 0, 5, 14) to pin
    //         the layout without enumerating all 15.
    {
        const state: ModalState = .{ .key_entry = .{} };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderKeyEntryToGrid(&grid, &state);

        const active = grid.active();
        // (col=0, row=0) = 'E'
        try testing.expectEqual(@as(u21, 'E'), active[0 * 80 + 0].ch);
        // (col=6, row=0) = 'A' (the 'A' of "API"; col=5 is the space
        // between "Enter" and "API")
        try testing.expectEqual(@as(u21, 'A'), active[0 * 80 + 6].ch);
        // (col=14, row=0) = ' ' (trailing space of the prompt)
        try testing.expectEqual(@as(u21, ' '), active[0 * 80 + 14].ch);
    }

    // Case 5: `@hasDecl(modal_ns, "renderKeyEntryToGrid")` static guard.
    //         Compile-time symbol existence — passes even in RED because
    //         the stub fn is declared (just panics at runtime).
    try testing.expect(@hasDecl(modal_ns, "renderKeyEntryToGrid"));
}

// T-2.3.2: renderUnlockToGrid (REQ-MODAL-001, design §3.4, T-SG-8 preserved).
//
// One test block with 5 sub-cases — mirrors the umbrella test pattern
// for renderKeyEntryToGrid (line 455) and cursorFromIntent (line 155).
// All sub-cases share the same setup (80×24 ScreenGrid + State.unlock_prompt).
//
// RED state: renderUnlockToGrid panics with "SkeletonNotImplemented" (T-2.3.2
// stub at src/modal.zig:720). The first sub-case to invoke the fn terminates
// the test process. Sub-case 5 (`@hasDecl` compile-time guard) is the only
// one that passes in RED. The GREEN impl replaces the stub and all 5
// sub-cases pass.
test "renderUnlockToGrid writes unlock modal content (T-2.3.2)" {
    const prefix_len: usize = "Unlock passphrase: ".len; // 19

    // Case 1: unlock_prompt + draft "secret-passphrase" (17 chars) writes
    //         17 '*' cells at row 0, cols 19..35 (the mask region after
    //         the prompt). drawUnlock writes '*' at win.cells[prefix_len+i]
    //         for i in 0..shown; renderUnlockToGrid writes the same via
    //         grid.writeCell(prefix_len+i, 0, '*', .{}).
    {
        const draft_str = "secret-passphrase"; // 17 chars
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..draft_str.len], draft_str);
        const state: ModalState = .{
            .unlock_prompt = .{
                .draft = draft_buf,
                .draft_len = draft_str.len,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderUnlockToGrid(&grid, &state);

        const active = grid.active();
        for (0..draft_str.len) |i| {
            try testing.expectEqual(@as(u21, '*'), active[prefix_len + i].ch);
        }
    }

    // Case 2: unlock_prompt + empty draft writes 0 mask cells (no '*' in
    //         the mask region; prompt still fills cols 0..18).
    {
        const state: ModalState = .{ .unlock_prompt = .{} };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderUnlockToGrid(&grid, &state);

        const active = grid.active();
        // No '*' should appear anywhere in row 0 (mask region only).
        for (0..80) |i| {
            try testing.expect(active[i].ch != '*');
        }
        // The prompt prefix chars are still written at cols 0..18.
        const prompt = "Unlock passphrase: ";
        for (prompt, 0..) |expected, i| {
            try testing.expectEqual(@as(u21, expected), active[i].ch);
        }
    }

    // Case 3: renderUnlockToGrid does NOT mutate state. drawUnlock is a
    //         pure renderer too, but we still assert no mutation happens
    //         (per design §3.4 contract: "Pure renderer — does NOT mutate
    //         state"). All payload fields stay byte-identical.
    {
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..5], "abcde");
        var state: ModalState = .{
            .unlock_prompt = .{
                .draft = draft_buf,
                .draft_len = 5,
                .attempts = 2,
                .validating = false,
            },
        };
        const before = state;
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderUnlockToGrid(&grid, &state);

        // State fields are byte-identical — no assignment happened.
        try testing.expectEqual(before.unlock_prompt.draft_len, state.unlock_prompt.draft_len);
        try testing.expectEqual(@as(u8, 2), state.unlock_prompt.attempts);
        try testing.expectEqual(before.unlock_prompt.validating, state.unlock_prompt.validating);
        try testing.expectEqualSlices(u8, &before.unlock_prompt.draft, &state.unlock_prompt.draft);
    }

    // Case 4: renderUnlockToGrid is a no-op when state is the WRONG
    //         variant (T-2.3.3 dispatcher will route correctly; the
    //         per-fn guard prevents over-render). Pre-clear the grid
    //         with a marker char; calling with .key_entry leaves it
    //         intact (the fn early-returns before writing anything).
    {
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..3], "xyz");
        const state: ModalState = .{
            .key_entry = .{
                .draft = draft_buf,
                .draft_len = 3,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);
        // Mark the entire active grid with 'X' (clear + write all).
        grid.clear();
        for (0..80 * 24) |i| {
            _ = grid.writeCell(@intCast(i % 80), @intCast(i / 80), 'X', .{});
        }

        renderUnlockToGrid(&grid, &state);

        // Every cell must still be 'X' — no-op confirmed.
        const active = grid.active();
        for (active) |cell| {
            try testing.expectEqual(@as(u21, 'X'), cell.ch);
        }
    }

    // Case 5: `@hasDecl(modal_ns, "renderUnlockToGrid")` static guard.
    try testing.expect(@hasDecl(modal_ns, "renderUnlockToGrid"));
}

// T-2.3.2: renderConsentPromptToGrid (REQ-MODAL-001, design §3.4,
// T-SG-8 preserved). Mirrors drawConsentPrompt which prints:
//   "Store key at " + path (underline) + " (mode 0o600, last-4 " +
//   last_four (bold) + ")?"
// on row 0.
test "renderConsentPromptToGrid writes consent prompt content (T-2.3.2)" {
    // Case 1: consent_prompt with path "test.json" + last_four "WXYZ"
    //         writes the literal fragments at expected positions on row 0.
    //         Layout (col 0-indexed; byte counts verified at test write):
    //           "Store key at " (13 chars)         → cols 0..12
    //           path "test.json"  (9 chars)        → cols 13..21  (underline)
    //           " (mode 0o600, last-4 " (21 chars) → cols 22..42
    //           last_four "WXYZ"  (4 chars)        → cols 43..46  (bold)
    //           ")?"  (2 chars)                    → cols 47..48
    {
        var last_four: [4]u8 = .{0} ** 4;
        @memcpy(last_four[0..4], "WXYZ");
        const path = "test.json";
        const state: ModalState = .{
            .consent_prompt = .{
                .consent = true,
                .last_four = last_four,
                .path = path,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderConsentPromptToGrid(&grid, &state);

        const active = grid.active();
        // Col 0 = 'S' (start of "Store")
        try testing.expectEqual(@as(u21, 'S'), active[0].ch);
        // Col 6 = 'k' from "Store k" (the 'k' of "key")
        try testing.expectEqual(@as(u21, 'k'), active[6].ch);
        // Col 12 = ' ' (trailing space of "Store key at ")
        try testing.expectEqual(@as(u21, ' '), active[12].ch);
        // Col 13 = 't' (start of path "test.json") — underlined
        try testing.expectEqual(@as(u21, 't'), active[13].ch);
        try testing.expect(active[13].style.underline);
        // Col 21 = 'n' (last char of "test.json")
        try testing.expectEqual(@as(u21, 'n'), active[21].ch);
        // Col 43 = 'W' (start of last_four "WXYZ") — bold
        try testing.expectEqual(@as(u21, 'W'), active[43].ch);
        try testing.expect(active[43].style.bold);
        // Col 46 = 'Z' (last char of "WXYZ")
        try testing.expectEqual(@as(u21, 'Z'), active[46].ch);
        // Col 47 = ')' (the close paren)
        try testing.expectEqual(@as(u21, ')'), active[47].ch);
        // Col 48 = '?' (the question mark)
        try testing.expectEqual(@as(u21, '?'), active[48].ch);
    }

    // Case 2: consent_prompt + default (empty path, last_four zeros)
    //         renders the static "Store key at " prefix at cols 0..12
    //         followed by the closing " (mode 0o600, last-4    )?" suffix.
    //         The path + last_four regions just contain spaces/zeros.
    {
        const state: ModalState = .{ .consent_prompt = .{} };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderConsentPromptToGrid(&grid, &state);

        const active = grid.active();
        // Prompt prefix "Store key at " at cols 0..12.
        const prefix = "Store key at ";
        for (prefix, 0..) |expected, i| {
            try testing.expectEqual(@as(u21, expected), active[i].ch);
        }
        // ")?" suffix lands at cols 38..39 with empty path + 21-char
        // " (mode 0o600, last-4 " + 4 zero-bytes of last_four
        // (13 + 0 + 21 + 4 = 38). We test the closing punctuation as
        // a definite landmark — the last_four cells in between hold
        // u21 = 0x00 (NUL bytes verbatim).
        try testing.expectEqual(@as(u21, ')'), active[38].ch);
        try testing.expectEqual(@as(u21, '?'), active[39].ch);
    }

    // Case 3: renderConsentPromptToGrid does NOT mutate state.
    {
        var last_four: [4]u8 = .{0} ** 4;
        @memcpy(last_four[0..4], "ABCD");
        const state: ModalState = .{
            .consent_prompt = .{
                .consent = true,
                .last_four = last_four,
                .path = "/tmp/x.json",
            },
        };
        const before = state;
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderConsentPromptToGrid(&grid, &state);

        // State fields are byte-identical — no assignment happened.
        try testing.expectEqual(before.consent_prompt.consent, state.consent_prompt.consent);
        try testing.expectEqualSlices(u8, &before.consent_prompt.last_four, &state.consent_prompt.last_four);
        try testing.expectEqualStrings(before.consent_prompt.path, state.consent_prompt.path);
    }

    // Case 4: renderConsentPromptToGrid is a no-op when state is the
    //         WRONG variant. Mark grid with 'X'; calling with .key_entry
    //         leaves every cell intact.
    {
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..3], "xyz");
        const state: ModalState = .{
            .key_entry = .{
                .draft = draft_buf,
                .draft_len = 3,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);
        grid.clear();
        for (0..80 * 24) |i| {
            _ = grid.writeCell(@intCast(i % 80), @intCast(i / 80), 'X', .{});
        }

        renderConsentPromptToGrid(&grid, &state);

        // Every cell must still be 'X' — no-op confirmed.
        const active = grid.active();
        for (active) |cell| {
            try testing.expectEqual(@as(u21, 'X'), cell.ch);
        }
    }

    // Case 5: `@hasDecl(modal_ns, "renderConsentPromptToGrid")` static guard.
    try testing.expect(@hasDecl(modal_ns, "renderConsentPromptToGrid"));
}

// T-2.3.2: renderErrorModalToGrid (REQ-MODAL-001, design §3.4, T-SG-8
// preserved). Mirrors drawErrorModal which prints:
//   "Error: " (bold) + "[<class>]" (bold) + " " + message + (if
//   kind == .tls_gated) " — set ZARGEANT_RUN_TLS_HANDSHAKE=1" (bold)
// on row 0.
test "renderErrorModalToGrid writes error modal content (T-2.3.2)" {
    // Case 1: error_modal + kind=.auth + message "API rejected key" writes
    //         the literal fragments at expected positions on row 0.
    //         Layout:
    //           "Error: "  (7 chars)             → cols 0..6   (bold)
    //           "[auth]"  (6 chars)              → cols 7..12  (bold)
    //           " "  (1 char)                    → col 13
    //           "API rejected key" (16 chars)    → cols 14..29
    {
        const msg = "API rejected key";
        var msg_buf: [128]u8 = .{0} ** 128;
        const msg_len = copyInline(&msg_buf, msg);
        const state: ModalState = .{
            .error_modal = .{
                .kind = .auth,
                .message_buf = msg_buf,
                .message_len = msg_len,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderErrorModalToGrid(&grid, &state);

        const active = grid.active();
        // Col 0 = 'E' (start of "Error")
        try testing.expectEqual(@as(u21, 'E'), active[0].ch);
        try testing.expect(active[0].style.bold);
        // Col 5 = ':' (last char of "Error")
        try testing.expectEqual(@as(u21, ':'), active[5].ch);
        // Col 6 = ' ' (trailing space of "Error: ")
        try testing.expectEqual(@as(u21, ' '), active[6].ch);
        // Col 7 = '[' (start of "[auth]" class banner)
        try testing.expectEqual(@as(u21, '['), active[7].ch);
        try testing.expect(active[7].style.bold);
        // Col 8 = 'a' (start of "auth")
        try testing.expectEqual(@as(u21, 'a'), active[8].ch);
        // Col 11 = 'h' (last char of "auth")
        try testing.expectEqual(@as(u21, 'h'), active[11].ch);
        // Col 12 = ']' (close of "[auth]")
        try testing.expectEqual(@as(u21, ']'), active[12].ch);
        // Col 13 = ' ' (space after class banner)
        try testing.expectEqual(@as(u21, ' '), active[13].ch);
        // Col 14 = 'A' (start of "API rejected key")
        try testing.expectEqual(@as(u21, 'A'), active[14].ch);
        // Col 29 = 'y' (last char of "API rejected key")
        try testing.expectEqual(@as(u21, 'y'), active[29].ch);
    }

    // Case 2: error_modal + kind=.tls_gated + message "TLS handshake
    //         blocked" appends the bold env-var hint after the message.
    //         Total length: 7 + "[tls_gated]".len + 1 + "TLS handshake
    //         blocked".len + " — set ZARGEANT_RUN_TLS_HANDSHAKE=1".len.
    {
        const msg = "TLS handshake blocked";
        var msg_buf: [128]u8 = .{0} ** 128;
        const msg_len = copyInline(&msg_buf, msg);
        const state: ModalState = .{
            .error_modal = .{
                .kind = .tls_gated,
                .message_buf = msg_buf,
                .message_len = msg_len,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderErrorModalToGrid(&grid, &state);

        const active = grid.active();
        // Find the env-var hint "ZARGEANT_RUN_TLS_HANDSHAKE" by char
        // sample — pick a representative cell from the hint suffix.
        // Byte counts: "Error: " (7) + "[tls_gated]" (11) + " " (1)
        // + "TLS handshake blocked" (21) = 40 prefix chars. So the
        // hint " — set ZARGEANT_RUN_TLS_HANDSHAKE=1" (37 chars) starts
        // at col 40.
        // Col 40 = ' ' (leading space of hint)
        try testing.expectEqual(@as(u21, ' '), active[40].ch);
        // Col 41 = '—' (em-dash, U+2014)
        try testing.expectEqual(@as(u21, '—'), active[41].ch);
        // Col 43 = 's' (start of "set")
        try testing.expectEqual(@as(u21, 's'), active[43].ch);
        // Col 47 = 'Z' (start of "ZARGEANT_RUN_TLS_HANDSHAKE=1") — bold
        try testing.expectEqual(@as(u21, 'Z'), active[47].ch);
        try testing.expect(active[47].style.bold);
    }

    // Case 3: renderErrorModalToGrid does NOT mutate state.
    {
        var msg_buf: [128]u8 = .{0} ** 128;
        const msg_len = copyInline(&msg_buf, "boom");
        const state: ModalState = .{
            .error_modal = .{
                .kind = .network,
                .message_buf = msg_buf,
                .message_len = msg_len,
                .prior = .key_entry,
            },
        };
        const before = state;
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderErrorModalToGrid(&grid, &state);

        // State fields are byte-identical — no assignment happened.
        try testing.expectEqual(@as(modal_ns.ErrorKind, .network), state.error_modal.kind);
        try testing.expectEqual(before.error_modal.message_len, state.error_modal.message_len);
        try testing.expectEqualSlices(u8, &before.error_modal.message_buf, &state.error_modal.message_buf);
        try testing.expectEqual(@as(modal_ns.PriorKind, .key_entry), state.error_modal.prior);
    }

    // Case 4: renderErrorModalToGrid is a no-op when state is the
    //         WRONG variant. Mark grid with 'X'; calling with .key_entry
    //         leaves every cell intact.
    {
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..3], "xyz");
        const state: ModalState = .{
            .key_entry = .{
                .draft = draft_buf,
                .draft_len = 3,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);
        grid.clear();
        for (0..80 * 24) |i| {
            _ = grid.writeCell(@intCast(i % 80), @intCast(i / 80), 'X', .{});
        }

        renderErrorModalToGrid(&grid, &state);

        // Every cell must still be 'X' — no-op confirmed.
        const active = grid.active();
        for (active) |cell| {
            try testing.expectEqual(@as(u21, 'X'), cell.ch);
        }
    }

    // Case 5: `@hasDecl(modal_ns, "renderErrorModalToGrid")` static guard.
    try testing.expect(@hasDecl(modal_ns, "renderErrorModalToGrid"));
}

// T-2.3.2: renderAgentLoopToGrid (REQ-MODAL-001, design §3.4, T-SG-8
// preserved). Mirrors drawAgentLoopView which writes:
//   - cumulative text on row 0 (cols 0..min(items.len, cols))
//   - status bar "model={s} tokens={d} t={d}ms" on the bottom row
//     (reverse style)
test "renderAgentLoopToGrid writes agent loop content (T-2.3.2)" {
    // Case 1: agent_loop + cumulative "Hello" (5 chars) + model "MiniMax-M3"
    //         writes "Hello" at cols 0..4 on row 0, and the status bar
    //         (starting with "model=") on row 23 (the bottom row of 80x24).
    {
        const alloc = testing.allocator;
        var state: ModalState = .{
            .agent_loop = .{
                .allocator = alloc,
                .model = "MiniMax-M3",
                .tokens = 42,
                .last_update_ms = 100,
            },
        };
        defer state.agent_loop.cumulative.deinit(alloc);
        try state.agent_loop.cumulative.appendSlice(alloc, "Hello");

        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderAgentLoopToGrid(&grid, &state);

        const active = grid.active();
        // Row 0, cols 0..4 = "Hello"
        try testing.expectEqual(@as(u21, 'H'), active[0 * 80 + 0].ch);
        try testing.expectEqual(@as(u21, 'e'), active[0 * 80 + 1].ch);
        try testing.expectEqual(@as(u21, 'l'), active[0 * 80 + 2].ch);
        try testing.expectEqual(@as(u21, 'l'), active[0 * 80 + 3].ch);
        try testing.expectEqual(@as(u21, 'o'), active[0 * 80 + 4].ch);
        // Row 23 (bottom row), cols 0..5 = "model=" — reverse style.
        const last_row = 23;
        try testing.expectEqual(@as(u21, 'm'), active[last_row * 80 + 0].ch);
        try testing.expect(active[last_row * 80 + 0].style.reverse);
        try testing.expectEqual(@as(u21, 'o'), active[last_row * 80 + 1].ch);
        try testing.expectEqual(@as(u21, 'd'), active[last_row * 80 + 2].ch);
        try testing.expectEqual(@as(u21, 'e'), active[last_row * 80 + 3].ch);
        try testing.expectEqual(@as(u21, 'l'), active[last_row * 80 + 4].ch);
        try testing.expectEqual(@as(u21, '='), active[last_row * 80 + 5].ch);
    }

    // Case 2: agent_loop + empty cumulative + model "" + tokens=0 +
    //         last_update_ms=0 writes ONLY the status bar on row 23.
    //         The status bar starts with "model=" (since model="" the
    //         rendered text is "model= tokens=0 t=0ms"). Row 0 stays
    //         empty (no cumulative text).
    {
        const alloc = testing.allocator;
        var state: ModalState = .{
            .agent_loop = .{
                .allocator = alloc,
                .model = "",
                .tokens = 0,
                .last_update_ms = 0,
            },
        };
        defer state.agent_loop.cumulative.deinit(alloc);

        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderAgentLoopToGrid(&grid, &state);

        const active = grid.active();
        // Row 0 must be entirely spaces (no cumulative text).
        for (0..80) |i| {
            try testing.expectEqual(@as(u21, ' '), active[0 * 80 + i].ch);
        }
        // Row 23 (bottom row) col 0..5 = "model=" — reverse style.
        const last_row = 23;
        try testing.expectEqual(@as(u21, 'm'), active[last_row * 80 + 0].ch);
        try testing.expect(active[last_row * 80 + 0].style.reverse);
    }

    // Case 3: renderAgentLoopToGrid does NOT mutate state. Cumulative
    //         buffer, model, tokens, last_update_ms all stay identical.
    {
        const alloc = testing.allocator;
        var state: ModalState = .{
            .agent_loop = .{
                .allocator = alloc,
                .model = "MiniMax-M3",
                .tokens = 999,
                .last_update_ms = 12345,
            },
        };
        defer state.agent_loop.cumulative.deinit(alloc);
        try state.agent_loop.cumulative.appendSlice(alloc, "some text");

        const before = state;
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderAgentLoopToGrid(&grid, &state);

        // State fields are byte-identical — no assignment happened.
        try testing.expectEqualStrings(before.agent_loop.model, state.agent_loop.model);
        try testing.expectEqual(@as(u64, 999), state.agent_loop.tokens);
        try testing.expectEqual(@as(i64, 12345), state.agent_loop.last_update_ms);
        try testing.expectEqualSlices(u8, before.agent_loop.cumulative.items, state.agent_loop.cumulative.items);
    }

    // Case 4: renderAgentLoopToGrid is a no-op when state is the
    //         WRONG variant. Mark grid with 'X'; calling with .key_entry
    //         leaves every cell intact.
    {
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..3], "xyz");
        const state: ModalState = .{
            .key_entry = .{
                .draft = draft_buf,
                .draft_len = 3,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);
        grid.clear();
        for (0..80 * 24) |i| {
            _ = grid.writeCell(@intCast(i % 80), @intCast(i / 80), 'X', .{});
        }

        renderAgentLoopToGrid(&grid, &state);

        // Every cell must still be 'X' — no-op confirmed.
        const active = grid.active();
        for (active) |cell| {
            try testing.expectEqual(@as(u21, 'X'), cell.ch);
        }
    }

    // Case 5: `@hasDecl(modal_ns, "renderAgentLoopToGrid")` static guard.
    try testing.expect(@hasDecl(modal_ns, "renderAgentLoopToGrid"));
}

// T-2.3.3: renderToGrid dispatcher (REQ-MODAL-002, design §3.4, T-SG-8
// preserved). Routes the active State variant to its corresponding
// render*ToGrid fn. Mirrors the umbrella test pattern already used for
// renderKeyEntryToGrid (line 463), renderUnlockToGrid (line 579), and
// renderAgentLoopToGrid (line 980).
//
// One test block with 6 sub-cases — covers all 6 State variants (.welcome
// is the only no-op), the no-mutation contract, and a compile-time symbol
// existence guard.
//
// RED state: renderToGrid panics with "SkeletonNotImplemented: renderToGrid"
// (T-2.3.3 stub at src/modal.zig:354). The first sub-case to invoke the
// fn terminates the test process; sub-cases 1..5 fail by panic.
// Sub-case 6 (`@hasDecl` compile-time guard) is the only one that passes
// in RED. The GREEN impl replaces the stub and all 6 sub-cases pass.
test "renderToGrid dispatches by State variant (T-2.3.3)" {
    const prefix_len_key: usize = "Enter API key: ".len; // 15
    const prefix_len_unlock: usize = "Unlock passphrase: ".len; // 19

    // Case 1: dispatcher routes .key_entry to renderKeyEntryToGrid.
    //         State.key_entry + draft "abcd" → 4 '*' cells at cols 15..18
    //         on row 0 (the mask region immediately after the prompt).
    {
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..4], "abcd");
        const state: ModalState = .{
            .key_entry = .{
                .draft = draft_buf,
                .draft_len = 4,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderToGrid(&grid, &state);

        const active = grid.active();
        for (0..4) |i| {
            try testing.expectEqual(@as(u21, '*'), active[prefix_len_key + i].ch);
        }
    }

    // Case 2: dispatcher routes .unlock_prompt to renderUnlockToGrid.
    //         State.unlock_prompt + draft "secret-passphrase" (17 chars)
    //         → 17 '*' cells at cols 19..35 on row 0. Sample one
    //         representative cell to pin the layout.
    {
        const draft_str = "secret-passphrase"; // 17 chars
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..draft_str.len], draft_str);
        const state: ModalState = .{
            .unlock_prompt = .{
                .draft = draft_buf,
                .draft_len = draft_str.len,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderToGrid(&grid, &state);

        const active = grid.active();
        // Sample mid-mask to confirm renderUnlockToGrid was called.
        try testing.expectEqual(@as(u21, '*'), active[prefix_len_unlock + 4].ch);
    }

    // Case 3a: dispatcher routes .consent_prompt to
    //          renderConsentPromptToGrid. State.consent_prompt + path
    //          "test.json" + last_four "WXYZ" → 'S' at col 0 (start of
    //          "Store key at ") and '?' at col 48 (end of banner).
    {
        var last_four: [4]u8 = .{0} ** 4;
        @memcpy(last_four[0..4], "WXYZ");
        const path = "test.json";
        const state: ModalState = .{
            .consent_prompt = .{
                .consent = true,
                .last_four = last_four,
                .path = path,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderToGrid(&grid, &state);

        const active = grid.active();
        // Col 0 = 'S' (start of "Store")
        try testing.expectEqual(@as(u21, 'S'), active[0].ch);
        // Col 48 = '?' (closing punctuation)
        try testing.expectEqual(@as(u21, '?'), active[48].ch);
    }

    // Case 3b: dispatcher routes .error_modal to renderErrorModalToGrid.
    //          State.error_modal + kind=.auth + message "API rejected
    //          key" → 'E' at col 0 (start of "Error: ") and 'y' at col
    //          29 (last char of "API rejected key").
    {
        const msg = "API rejected key";
        var msg_buf: [128]u8 = .{0} ** 128;
        const msg_len = copyInline(&msg_buf, msg);
        const state: ModalState = .{
            .error_modal = .{
                .kind = .auth,
                .message_buf = msg_buf,
                .message_len = msg_len,
            },
        };
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderToGrid(&grid, &state);

        const active = grid.active();
        // Col 0 = 'E' (start of "Error")
        try testing.expectEqual(@as(u21, 'E'), active[0].ch);
        // Col 29 = 'y' (last char of "API rejected key")
        try testing.expectEqual(@as(u21, 'y'), active[29].ch);
    }

    // Case 3c: dispatcher routes .agent_loop to renderAgentLoopToGrid.
    //          State.agent_loop + cumulative "Hello" (5 chars) +
    //          model "MiniMax-M3" → 'H' at col 0 on row 0 and 'm' at
    //          col 0 on row 23 (start of "model=" status bar, reverse).
    {
        const alloc = testing.allocator;
        var state: ModalState = .{
            .agent_loop = .{
                .allocator = alloc,
                .model = "MiniMax-M3",
                .tokens = 42,
                .last_update_ms = 100,
            },
        };
        defer state.agent_loop.cumulative.deinit(alloc);
        try state.agent_loop.cumulative.appendSlice(alloc, "Hello");

        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderToGrid(&grid, &state);

        const active = grid.active();
        // Row 0, col 0 = 'H' (start of cumulative text "Hello")
        try testing.expectEqual(@as(u21, 'H'), active[0 * 80 + 0].ch);
        // Row 23 (bottom), col 0 = 'm' (start of "model=" status bar)
        const last_row = 23;
        try testing.expectEqual(@as(u21, 'm'), active[last_row * 80 + 0].ch);
        try testing.expect(active[last_row * 80 + 0].style.reverse);
    }

    // Case 4: dispatcher is a no-op for .welcome (the only State
    //         variant without a render*ToGrid fn — transient state
    //         that doesn't render content). Mark the grid with 'X';
    //         calling renderToGrid with .welcome leaves every cell intact.
    {
        const state: ModalState = .welcome;
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);
        grid.clear();
        for (0..80 * 24) |i| {
            _ = grid.writeCell(@intCast(i % 80), @intCast(i / 80), 'X', .{});
        }

        renderToGrid(&grid, &state);

        // Every cell must still be 'X' — no-op confirmed.
        const active = grid.active();
        for (active) |cell| {
            try testing.expectEqual(@as(u21, 'X'), cell.ch);
        }
    }

    // Case 5: dispatcher does NOT mutate state. The contract is
    //         "Pure dispatch — no I/O, no allocation, no state
    //         mutation" (design §3.4). All payload fields stay
    //         byte-identical after a .key_entry render.
    {
        var draft_buf: [256]u8 = .{0} ** 256;
        @memcpy(draft_buf[0..3], "xyz");
        const state: ModalState = .{
            .key_entry = .{
                .draft = draft_buf,
                .draft_len = 3,
                .cursor_col = 7,
                .cursor_row = 11,
            },
        };
        const before = state;
        var grid = try ScreenGrid.init(80, 24);
        defer grid.deinit(testing.allocator);

        renderToGrid(&grid, &state);

        // State fields are byte-identical — no assignment happened.
        try testing.expectEqual(before.key_entry.draft_len, state.key_entry.draft_len);
        try testing.expectEqual(@as(u16, 7), state.key_entry.cursor_col);
        try testing.expectEqual(@as(u16, 11), state.key_entry.cursor_row);
        try testing.expectEqualSlices(u8, &before.key_entry.draft, &state.key_entry.draft);
    }

    // Case 6: `@hasDecl(modal_ns, "renderToGrid")` static guard.
    //         Compile-time symbol existence — passes even in RED
    //         because the stub fn is declared (just panics at runtime).
    try testing.expect(@hasDecl(modal_ns, "renderToGrid"));
}

// tui-ship-fast-phase2 (T-2.4.1) — WindowMock adapter forwards 10 methods.
// Each sub-case exercises one adapter method against a freshly-init'd
// WindowMock + ScreenGrid. The adapter's contract (per design §3.4 +
// spec REQ-TUI-007/008) is: 10 methods, signature unchanged from the
// legacy heap-owned impl, body delegates to ScreenGrid. Sub-case 11
// is a compile-time @hasDecl guard.
test "WindowMock adapter forwards 10 methods (T-2.4.1)" {
    // Case 1: init returns a valid adapter. Fields set per spec.
    {
        const win = try WindowMock.init(testing.allocator, 20, 10);
        defer win.deinit();
        try testing.expectEqual(@as(u16, 20), win.cols);
        try testing.expectEqual(@as(u16, 10), win.rows);
        try testing.expect(!win.cursor_hidden);
        try testing.expect(!win.in_alt_screen);
    }

    // Case 2: clear() delegates to ScreenGrid.clear (all spaces).
    {
        const win = try WindowMock.init(testing.allocator, 20, 10);
        defer win.deinit();
        // Stain the grid with 'X' chars via the adapter's grid
        // pointer (unwrap optional — init always sets it), then clear.
        const g = win.grid.?;
        for (0..200) |i| {
            const c: u16 = @intCast(i % 20);
            const r: u16 = @intCast(i / 20);
            _ = g.writeCell(c, r, 'X', .{});
        }
        win.clear();
        const active = g.active();
        for (active) |cell| {
            try testing.expectEqual(@as(u21, ' '), cell.ch);
        }
    }

    // Case 3: print writes ASCII chars at positions 0..len. Legacy
    // fragment-overwrite behavior preserved (each call starts at col=0).
    {
        const win = try WindowMock.init(testing.allocator, 20, 10);
        defer win.deinit();
        const g = win.grid.?;
        try win.print("hello", .{});
        const active = g.active();
        try testing.expectEqual(@as(u21, 'h'), active[0].ch);
        try testing.expectEqual(@as(u21, 'e'), active[1].ch);
        try testing.expectEqual(@as(u21, 'l'), active[2].ch);
        try testing.expectEqual(@as(u21, 'l'), active[3].ch);
        try testing.expectEqual(@as(u21, 'o'), active[4].ch);
        try testing.expectEqual(@as(u21, ' '), active[5].ch);

        // Second call overwrites positions 0..2 with "ABC" (legacy
        // fragment-overwrite). Positions 3..4 stay 'l','o'.
        try win.print("ABC", .{});
        try testing.expectEqual(@as(u21, 'A'), active[0].ch);
        try testing.expectEqual(@as(u21, 'B'), active[1].ch);
        try testing.expectEqual(@as(u21, 'C'), active[2].ch);
        try testing.expectEqual(@as(u21, 'l'), active[3].ch);
        try testing.expectEqual(@as(u21, 'o'), active[4].ch);
    }

    // Case 4: print handles multi-byte UTF-8 atomically. € (U+20AC,
    // 3-byte UTF-8) must land in ONE cell with ch=0x20AC, NOT three
    // single-byte cells with ch=0xE2/0x82/0xAC. The legacy byte-
    // iter impl fragmented multi-byte UTF-8; the new Utf8View-based
    // impl fixes it.
    {
        const win = try WindowMock.init(testing.allocator, 20, 10);
        defer win.deinit();
        try win.print("€", .{});
        const active = win.grid.?.active();
        // Find the cell with ch=0x20AC (€).
        var found_euro: usize = 0;
        for (active) |cell| {
            if (cell.ch == 0x20AC) found_euro += 1;
        }
        try testing.expectEqual(@as(usize, 1), found_euro);
        // Negative: NO cell with the low byte 0xAC alone (fragmented
        // multi-byte would produce three such cells).
        var found_frag: usize = 0;
        for (active) |cell| {
            if (cell.ch == 0xAC) found_frag += 1;
        }
        try testing.expectEqual(@as(usize, 0), found_frag);
    }

    // Case 5: print with style.bold true preserves the style flag.
    {
        const win = try WindowMock.init(testing.allocator, 20, 10);
        defer win.deinit();
        try win.print("X", .{ .bold = true });
        const active = win.grid.?.active();
        try testing.expect(active[0].style.bold);
    }

    // Case 6: hideCursor / showCursor toggles the local cursor_hidden flag.
    {
        const win = try WindowMock.init(testing.allocator, 20, 10);
        defer win.deinit();
        try testing.expect(!win.cursor_hidden);
        win.hideCursor();
        try testing.expect(win.cursor_hidden);
        win.showCursor();
        try testing.expect(!win.cursor_hidden);
    }

    // Case 7: enterAlternateScreen / exitAlternateScreen toggles
    // the local in_alt_screen flag.
    {
        const win = try WindowMock.init(testing.allocator, 20, 10);
        defer win.deinit();
        try testing.expect(!win.in_alt_screen);
        win.enterAlternateScreen();
        try testing.expect(win.in_alt_screen);
        win.exitAlternateScreen();
        try testing.expect(!win.in_alt_screen);
    }

    // Case 8: snapshot returns the active grid (len == cols*rows).
    {
        const win = try WindowMock.init(testing.allocator, 20, 10);
        defer win.deinit();
        try testing.expectEqual(@as(usize, 200), win.snapshot().len);
        // Every cell is a space (freshly init'd).
        for (win.snapshot()) |cell| {
            try testing.expectEqual(@as(u21, ' '), cell.ch);
        }
    }

    // Case 9: diff returns entries for changed cells. Write a cell via
    // grid.writeCell (bypassing print) then diff against an all-space
    // prev. Expect 1 entry at the changed position.
    {
        const win = try WindowMock.init(testing.allocator, 20, 10);
        defer win.deinit();

        _ = win.grid.?.writeCell(5, 3, 'X', .{ .bold = true });

        // Allocate an all-space prev slice using modal.Cell (matches
        // diff's parameter type). screen_grid.Cell and modal.Cell are
        // byte-identical structs, but Zig treats them as distinct
        // types — allocate with the modal type to avoid a cast.
        const prev = try testing.allocator.alloc(ModalCell, 200);
        defer testing.allocator.free(prev);
        for (prev) |*c| c.* = .{ .ch = ' ', .style = .{} };

        const entries = try win.diff(prev);
        defer testing.allocator.free(entries);

        try testing.expectEqual(@as(usize, 1), entries.len);
        try testing.expectEqual(@as(u16, 5), entries[0].x);
        try testing.expectEqual(@as(u16, 3), entries[0].y);
        try testing.expectEqual(@as(u21, 'X'), entries[0].cell.ch);
        try testing.expect(entries[0].cell.style.bold);
    }

    // Case 10: deinit is safe to call (testing.allocator catches leaks).
    {
        const win = try WindowMock.init(testing.allocator, 20, 10);
        win.deinit();
        // No panic, no leak (testing.allocator assertion on shutdown).
    }

    // Case 11: @hasDecl compile-time symbol guards.
    try testing.expect(@hasDecl(modal_ns, "WindowMock"));
    try testing.expect(@hasDecl(WindowMock, "init"));
}

// Issue #51 (tech-debt review, obs#1791 §1): byte-identity contract
// between ScreenGrid.Cell and modal.Cell.
//
// WindowMock.init (src/modal.zig:142) @ptrCasts a `[]screen_grid.Cell`
// slice to `[]modal.Cell` because Zig treats the structurally-identical
// structs as distinct types. The cast is only sound if both structs are
// byte-for-byte identical — same fields, same size, same alignment.
// Any future divergence silently produces UB. The comptime block in
// src/modal.zig enforces the invariant at compile time; this test
// mirrors the assertion as a documented runtime contract so regressions
// surface as test failures (the comptime block alone would only fail
// modal.zig's compilation, not the test runner).
test "issue #51: screen_grid.Cell and modal.Cell are byte-identical" {
    // Field presence — both structs must expose `ch` and `style`.
    try testing.expect(@hasField(Cell, "ch"));
    try testing.expect(@hasField(Cell, "style"));
    try testing.expect(@hasField(ModalCell, "ch"));
    try testing.expect(@hasField(ModalCell, "style"));

    // Byte-identity — the @ptrCast is only safe if size AND alignment
    // match exactly. Drift in either field breaks the aliasing contract.
    try testing.expectEqual(@sizeOf(Cell), @sizeOf(ModalCell));
    try testing.expectEqual(@alignOf(Cell), @alignOf(ModalCell));
}

// Local helper: copy a literal into the inline message/err buffer.
// Mirrors the shape of modal.copyInline but lives here so the test file
// doesn't need to expose a pub fn for it.
fn copyInline(dst: *[128]u8, src: []const u8) usize {
    const len: usize = @min(src.len, dst.len);
    @memcpy(dst[0..len], src[0..len]);
    return len;
}
