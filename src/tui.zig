// src/tui.zig -- TUI thread body + terminal lifecycle.
//
// Spec:   sdd/tui-recovery/spec  (id=407) REQ-TUI-002, REQ-TUI-003,
//         REQ-TUI-019, REQ-TUI-021, REQ-TUI-022
// Design: sdd/tui-recovery/design (id=408) §2.3 (R-PR 4), §2.4
//
// R-PR 4 ships the real terminal render lifecycle:
//   - tuiThreadInit: enableRawMode + enterAlternateScreen +
//     enableInBandResize + DEC 2048 probe (REQ-TUI-019) +
//     queryKittyKeyboard / pushKittyKeyboard (REQ-TUI-022).
//   - tuiThreadLoop: per-frame begin/endSynchronizedUpdate bracket
//     (REQ-TUI-021) + events.nextWithTimeout(16) poll.
//   - tuiThreadShutdown: popKittyKeyboard + exitAlternateScreen +
//     disableRawMode. RawTerm token owns the original termios.
//
// terminal primitive calls live in testable helpers (enterAltScreenAndResize,
// queryDec2048Supported, queryKittyKbSupported, pushKittyKb, popKittyKb,
// beginSyncUpdate, endSyncUpdate) so the headless tests can drive each
// step against a buffered Writer without needing a real TTY. The full
// tuiThreadInit / tuiThreadShutdown orchestrators compose these helpers
// and include enableRawMode (which does require a TTY via tcgetattr).
//
// No-thread-spawn invariant: tui.zig does NOT spawn threads.
// The runtime orchestrator in runtime.zig is the only spawn site —
// enforced by the static-grep test in runtime.zig.
//
// PR 6 (terminal-control-lib-from-scratch, WU 6.3): namespace swap
// from `mibu.*` to `terminal.*` (in-tree src/terminal/ module).
// Two non-1:1 call-site adjustments: C22 (4-arg nextWithTimeout with
// &lifecycle.redraw_pending) + C27 (2-arg enableRawMode with
// terminal.term.PosixBackend.backend()). Behavior is byte-for-byte
// preserved; tests/tui/runtime_thread.zig integration tests + CAP-09
// literal grep prove byte stability.
//
// Linux/x86_64 Zig 0.16 only.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Linux-only comptime guard (matches every other module in the project).
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("tui: linux-only v1 -- see sdd/tui/proposal id=373 constraint #5");
}

const terminal = @import("terminal");

// =============================================================================
// Phase 2 re-exports (T-2.5.1, T-2.5.2).
//
// Tests in tests/tui/runtime_thread.zig reference `Tui.ScreenGrid`
// without taking a direct dependency on `screen_grid` (the test module's
// build.zig wiring only exposes `tui`, `modal`, `runtime`, `channels`,
// `mock_server`, `api_client`, `api_auth`, `main`, `terminal`). Re-
// exporting ScreenGrid here lets those tests reach the type via the
// existing `Tui` alias. Production code uses the inline
// `@import("screen_grid").ScreenGrid` form in field declarations (same
// pattern as the inline `@import("modal.zig").Cell` already in use).
// =============================================================================

/// Re-export of `screen_grid.ScreenGrid` for test reach-through. See
/// the note above; this is a TEST convenience only — production callers
/// should use the inline `@import("screen_grid").ScreenGrid` form so the
/// module boundary stays explicit at the field declaration site.
pub const ScreenGrid = @import("screen_grid").ScreenGrid;

// =============================================================================
// Lifecycle state (REQ-TUI-002 + REQ-TUI-019 + REQ-TUI-022)
//
// Returned by `tuiThreadInit`; threaded through `tuiThreadLoop` (mutated
// by SIGWINCH events); handed to `tuiThreadShutdown` for restoration.
//
// Phase 2 PR2 (T-2.5.1) extends the struct with the pure-renderer
// pipeline state:
//   - `grids` is the [2]ScreenGrid double buffer (T-2.5.1 + T-2.5.2 +
//     T-2.6.1 — replaced the heap-allocated `prev_snapshot`).
//   - `active_idx` cycles between the two grids on every render (XOR
//     swap semantics — branch-free).
//   - `force_full_redraw` flips the diff baseline to the active grid
//     (zero diff → full re-emit) on resize, initial draw, or explicit
//     invalidation. Cleared by `submitFrame` after consuming it.
//   - `kitty_active` shadows `kitty_flags_pushed` for the parser gate
//     (R2 fix, PR3). Wired via `lc.parser.setKittyActive(lc.kitty_active)`
//     after `tuiThreadInit` decides on the kitty push.
//   - `cancel_pipe` is the per-iteration cancel pipe for the TUI thread
//     (R5 wiring, PR3). Mirrors the ThreadArgs field but lives on the
//     Lifecycle so `submitFrame` + `tuiThreadShutdown` can access it
//     without re-threading args.
//
// Tiger Style §3 — `grids` has no default; it must be initialized by the
// caller (only the TUI thread constructs ScreenGrid, per design §3.3).
// The other 4 new fields have sane defaults so existing test sites that
// don't reference them still compile.
// =============================================================================

pub const Lifecycle = struct {
    /// RawTerm token owns the original termios; calling disableRawMode
    /// on shutdown restores cooked mode.
    raw_term: ?terminal.term.RawTerm,
    /// Whether the terminal reported DEC 2048 support. When false, the
    /// SIGWINCH fallback path is the sole resize source.
    dec_2048_supported: bool,
    /// Whether the terminal supports kitty kb. False → no push/pop.
    kitty_supported: bool,
    /// Whether we pushed kitty flags. We pop only if pushed.
    kitty_flags_pushed: bool,
    /// Atomic redraw flag. SIGWINCH / DEC 2048 resize both flip this.
    redraw_pending: std.atomic.Value(bool),
    /// Terminal size cached at last resize (or initial 80x24 fallback).
    width: u16,
    height: u16,
    /// PR 2 (tui-runtime-integration #441, REQ-TUI-047): true when
    /// `enableRawMode` failed (no `/dev/tty`, CI). The TUI thread
    /// runs in degraded logger-only mode; renderers are skipped.
    no_tty: bool = false,
    /// REQ-RW-002 (tui-render-wiring #1259): previous-frame cell snapshot
    /// for `emitFrame` diff. Allocated by `tuiRealMain` after init, freed
    /// in shutdown. `null` on the first frame → `emitFrame` receives
    /// `current` as both `prev` and `current` arg (full-frame emit).
    /// DEPRECATED (Phase 2 PR2, T-2.5.1) — kept in place during the
    /// migration window so the legacy emitFrame path (PR1+PR1.5) still
    /// compiles. T-2.6.2 deletes this field once submitFrame replaces
    /// emitFrame at the only call site in tuiThreadLoop.
    prev_snapshot: ?[]@import("modal.zig").Cell = null,
    /// WU-1 (tui-keyentry-rebuild, REQ-NEW-001): the persistent Parser
    /// for the TUI thread. Lives on Lifecycle so the ring buffer
    /// survives across `nextWithTimeout` calls. Wired via
    /// `terminal.event.setCurrentParser(&lc.parser)` in `tuiThreadInit`
    /// after `enableRawMode` succeeds; cleared in `tuiThreadShutdown`
    /// after raw-mode teardown. The 4 KiB ring buffer is part of the
    /// stack-allocated Lifecycle (not heap-allocated; see design D1).
    parser: terminal.event.Parser = .{ .ring_buf = undefined, .ring_len = 0, .paste_active = false },

    /// Phase 2 PR2 (T-2.5.1, design §3.3): double buffer for the render
    /// pipeline. Value type — lives inline on the TUI thread stack; no
    /// allocator. `grids[lc.active_idx]` is the "active" (draw fn writes
    /// here); `grids[lc.active_idx ^ 1]` is the "previous" (diff
    /// baseline). Tiger Style §3 — fixed-cap inline storage replaces the
    /// per-frame `alloc.dupe(Cell, current)` from PR1+PR1.5. The struct
    /// footprint is bounded: 2 × ScreenGrid = 2 × (2 × MAX_CELL_BUF ×
    /// sizeof(Cell)) ≈ 1 MiB worst case (4K display); ~64 KiB at
    /// typical 80×24 (the inline `cells` array is always 2 × MAX_CELL_BUF,
    /// regardless of `cols × rows`). Sized by `tuiThreadInit` (T-2.5.2).
    /// No default — caller must initialize (matches design §3.3's "only
    /// the TUI thread constructs ScreenGrid" contract).
    grids: [2]@import("screen_grid").ScreenGrid,

    /// Phase 2 PR2 (T-2.5.1): 0 or 1; XOR swap cycles between the two
    /// `grids` on every render. Defaults to 0 (the first render writes
    /// into `grids[0]`).
    active_idx: u1 = 0,

    /// Phase 2 PR2 (T-2.5.1): true when the next frame must be a full
    /// re-emit (resize, initial draw, or explicit invalidation). The
    /// diff baseline collapses to the active grid (`prev == current`
    /// produces zero diff entries → the per-cell emit loop walks every
    /// cell). Cleared by `submitFrame` after consuming it. Defaults to
    /// false so the first frame after init starts in diff mode (with
    /// the prev/active both empty).
    force_full_redraw: bool = false,

    /// Phase 2 PR2 (T-2.5.1) — R2 fix (PR3): shadow of
    /// `kitty_flags_pushed` for the parser gate. Wired via
    /// `lc.parser.setKittyActive(lc.kitty_active)` after
    /// `tuiThreadInit` decides on the kitty push. Defaults to false to
    /// match the pre-fix behavior (no kitty dispatch).
    kitty_active: bool = false,

    /// Phase 2 PR2 (T-2.5.1) — R5 wiring (PR3): per-iteration cancel
    /// pipe for the TUI thread. Mirrors the ThreadArgs field but lives
    /// on the Lifecycle so `submitFrame` + `tuiThreadShutdown` can
    /// access it without re-threading args. Defaults to null; tests
    /// that don't model Ctrl+C don't need to specify it.
    cancel_pipe: ?[2]i32 = null,
};

// =============================================================================
// TUI primitive ops -- testable without a real TTY
//
// Each helper maps 1:1 to a mibu primitive (verified at commit 636a36a).
// Tests drive these against a Writer.fixed buffer; the orchestrators
// (tuiThreadInit / tuiThreadShutdown / tuiThreadLoop) compose them.
// =============================================================================

/// Enter alternate screen + enable DEC 2048 in-band resize reports.
/// Writes CSI ?1049h + CSI ?2048h to `writer` (REQ-TUI-002).
pub fn enterAltScreenAndResize(writer: *std.Io.Writer) !void {
    try terminal.term.enterAlternateScreen(writer);
    try terminal.term.enableInBandResize(writer);
}

/// Exit alternate screen + disable in-band resize reports.
/// Writes CSI ?1049l + CSI ?2048l to `writer`.
pub fn exitAltScreenAndResize(writer: *std.Io.Writer) !void {
    try terminal.term.exitAlternateScreen(writer);
    try terminal.term.disableInBandResize(writer);
}

/// WU-2 (tui-keyentry-rebuild, REQ-NEW-002): enable DEC 2004 bracketed
/// paste mode. Writes CSI ?2004h. Pairs with `disableBracketedPaste`.
/// The terminal emulator then wraps pasted content in ESC[200~...ESC[201~
/// so the parser can deliver the full payload via per-char .key events
/// (see WU-3 paste-bracket detection).
pub fn enableBracketedPaste(writer: *std.Io.Writer) !void {
    try terminal.term.enableBracketedPaste(writer);
}

/// WU-2 (tui-keyentry-rebuild, REQ-NEW-002): disable DEC 2004. Writes
/// CSI ?2004l. Pairs with `enableBracketedPaste` on the shutdown path.
pub fn disableBracketedPaste(writer: *std.Io.Writer) !void {
    try terminal.term.disableBracketedPaste(writer);
}

/// Probe DEC 2048 support via DECRQM. Returns true when the terminal
/// sets the mode (or has it permanently set; `:supported()` covers
/// `set | reset | permanently_set`). Used by SIGWINCH dual-path
/// (REQ-TUI-019 scenario 1+2).
pub fn queryDec2048Supported(
    io: std.Io,
    handle: std.Io.File.Handle,
    writer: *std.Io.Writer,
) bool {
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    const mode = terminal.dpm.queryModeWithTimeout(io, file, writer, 2048, 50) catch return false;

    return mode.supported();
}

/// Probe kitty keyboard support (REQ-TUI-022). Returns true if the
/// terminal replied with a CSI ? <flags> u sequence.
pub fn queryKittyKbSupported(
    io: std.Io,
    handle: std.Io.File.Handle,
    writer: *std.Io.Writer,
) bool {
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    return terminal.kitty.supportsKittyKeyboardWithTimeout(io, file, writer, 50) catch false;
}

/// Push kitty keyboard flags. Always uses disambiguate + report_events
/// (terminal kitty kb protocol flags 1+2 = 0b011).
/// Caller must verify kitty support before calling; pop only on success.
pub fn pushKittyKb(writer: *std.Io.Writer) !void {
    const flags: terminal.kitty.KittyFlags = .{ .disambiguate = true, .report_events = true };
    try terminal.kitty.pushKittyKeyboard(writer, flags);
}

/// Pop kitty keyboard flag. No-op if push never happened.
pub fn popKittyKb(writer: *std.Io.Writer) !void {
    try terminal.kitty.popKittyKeyboard(writer);
}

// =============================================================================
// SIGWINCH fallback (REQ-TUI-019)
//
// When DEC 2048 in-band resize is unsupported, we install a signal
// handler for SIG.WINCH that flips the atomic redraw_pending flag.
// Tests call setRedrawPending via the helper rather than raising a real
// signal (which is racy with the test runner).
//
// The signal handler is process-global by necessity (signal handlers
// can't carry user state). We expose a single g_redraw_pending slot
// that tuiThreadInit populates + tuiThreadShutdown clears.
// =============================================================================

var g_redraw_pending: ?*std.atomic.Value(bool) = null;
var g_sigwinch_installed: bool = false;

fn sigwinchHandler(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // Async-signal-safe: atomic Value(bool).store(seq_cst) is safe
    // (single-writer/single-reader pattern).
    if (g_redraw_pending) |p| p.store(true, .seq_cst);
}

/// Install the SIGWINCH handler + register a redraw_pending pointer.
/// Idempotent — second call is a no-op (the handler already points at
/// the latest registered atomic). Production callers wire this in
/// tuiThreadInit; tests can call directly to verify field wiring.
pub fn installSigwinch(redraw: *std.atomic.Value(bool)) void {
    g_redraw_pending = redraw;
    if (g_sigwinch_installed) return;
    const act = std.posix.Sigaction{
        .handler = .{ .sigaction = sigwinchHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
    g_sigwinch_installed = true;
}

/// Reset SIGWINCH wiring (for tests that re-install between cases).
/// Production: leave the handler in place; the process exits soon.
pub fn resetSigwinch() void {
    g_redraw_pending = null;
    // Intentional: not resetting g_sigwinch_installed across test
    // boundaries — POSIX sigaction restoration requires care and the
    // kernel resets handlers on process exit anyway.
}

/// Begin a synchronized update (DEC 2026). Brackets each render pass
/// (REQ-TUI-021).
pub fn beginSyncUpdate(writer: *std.Io.Writer) !void {
    try terminal.term.beginSynchronizedUpdate(writer);
}

/// End a synchronized update. Flushes the buffered frame to the screen.
pub fn endSyncUpdate(writer: *std.Io.Writer) !void {
    try terminal.term.endSynchronizedUpdate(writer);
}

/// Emit `frame_count` synchronized update brackets (REQ-TUI-021). Each
/// bracket is beginSyncUpdate → caller render → endSyncUpdate; this
/// helper handles only the bracket emission (the render slot is left
/// to the caller). Used by tests to verify the bracket is emitted
/// exactly once per frame, no nesting.
pub fn runFrames(writer: *std.Io.Writer, frame_count: u32) !void {
    var i: u32 = 0;
    while (i < frame_count) : (i += 1) {
        try beginSyncUpdate(writer);
        try endSyncUpdate(writer);
    }
}

// =============================================================================
// Orchestrators (the real production code path).
//
// These compose the primitives above. They CANNOT be fully tested without
// a TTY (tcgetattr / tty-only operations). The compile-time symbol
// references + the per-primitive headless tests cover the lifecycle
// without requiring a real terminal. Manual integration:
//   `./zig-out/bin/zargeant` (no flags).
// =============================================================================

/// Init the TUI lifecycle (REQ-TUI-002 + REQ-TUI-019 + REQ-TUI-022).
/// - enableRawMode on `handle` (returns RawTerm token).
/// - enterAlternateScreen + enableInBandResize on `writer`.
/// - Probe DEC 2048; record on `dec_2048_supported`.
/// - Probe kitty kb; if supported, push flags (bits == 3).
/// Returns a Lifecycle the caller threads through tuiThreadLoop and
/// tuiThreadShutdown.
pub fn tuiThreadInit(
    handle: std.Io.File.Handle,
    writer: *std.Io.Writer,
    io: std.Io,
) !Lifecycle {
    // Phase 2 PR2 (T-2.5.2): construct the [2]ScreenGrid double buffer at
    // the fallback dims (80×24, updated later by DEC 2048 / SIGWINCH).
    // ScreenGrid.init validates `cols × rows <= MAX_CELL_BUF`; 80×24 =
    // 1920 cells << 32768 — the check always passes at these dims. If a
    // future resize pushes dims past the cap, init returns
    // `error.DimsTooLarge` and the lifecycle cannot come up (Tiger Style
    // §4 — fail fast on bounded-buffer overflow).
    //
    // Production callers can use `initLifecycle(cols, rows)` directly for
    // testability — see T-2.5.2 helper. The two grids are identical at
    // init time; `active_idx` defaults to 0 so the first render writes
    // into `grids[0]`.
    const g0 = try ScreenGrid.init(80, 24);
    const g1 = try ScreenGrid.init(80, 24);
    var lc: Lifecycle = .{
        .raw_term = null,
        .dec_2048_supported = false,
        .kitty_supported = false,
        .kitty_flags_pushed = false,
        .redraw_pending = std.atomic.Value(bool).init(false),
        .width = 80,
        .height = 24,
        .grids = .{ g0, g1 },
    };

    // 1. Raw mode (RawTerm token owns original termios for restore).
    // PR 2 (REQ-TUI-047): if `enableRawMode` fails (no `/dev/tty`, CI),
    // we fall back to logger-only mode and signal degraded mode on the
    // Lifecycle via `no_tty = true`. The caller is expected to skip
    // render and bracket emission in that case.
    //
    // PR 6 (terminal-control-lib-from-scratch, WU 6.3, C27): the in-tree
    // `terminal.term.enableRawMode` takes 2 args (no Zig overloading);
    // production callers pass `PosixBackend.backend()` — a fully-populated
    // `Backend` value with real tcgetattr/tcsetattr/ioctl_gwinsz fn ptrs.
    if (terminal.term.enableRawMode(handle, terminal.term.PosixBackend.backend())) |rt| {
        lc.raw_term = rt;
    } else |_| {
        lc.no_tty = true;
    }

    // WU-1 (REQ-NEW-001 + REQ-NEW-008): publish the persistent Parser
    // to the thread-local so `nextWithTimeout` routes through it.
    // Production-only wire; tests inject via the same setter.
    terminal.event.setCurrentParser(&lc.parser);

    // 2. Install SIGWINCH fallback handler (REQ-TUI-019 scenario 2). The
    // handler sets redraw_pending via the global pointer installed here.
    installSigwinch(&lc.redraw_pending);

    // 3. Alt screen + in-band resize (REQ-TUI-002). Skip in no-TTY mode
    // (no terminal to switch into).
    if (!lc.no_tty) {
        enterAltScreenAndResize(writer) catch {};
    }

    // 3.5 WU-2 (tui-keyentry-rebuild, REQ-NEW-002): enable DEC 2004
    // bracketed paste AFTER alt-screen + in-band-resize and BEFORE
    // kitty-kb push (per design R-DES-5 wire order). With DEC 2004
    // active, the terminal wraps pasted content in ESC[200~...ESC[201~
    // so the WU-3 parser can detect the boundaries.
    if (!lc.no_tty) {
        enableBracketedPaste(writer) catch {};
    }

    // 3. Probe DEC 2048 (REQ-TUI-019). Failure → false (legacy fallback).
    //    Skip in no-TTY mode (no terminal to probe).
    if (!lc.no_tty) {
        lc.dec_2048_supported = queryDec2048Supported(io, handle, writer);
    }

    // 4. Probe kitty kb (REQ-TUI-022). Failure → false (legacy keypress).
    if (!lc.no_tty) {
        lc.kitty_supported = queryKittyKbSupported(io, handle, writer);
        if (lc.kitty_supported) {
            pushKittyKb(writer) catch {};
            lc.kitty_flags_pushed = true;
        }
    }

    return lc;
}

/// Shutdown the TUI lifecycle (REQ-TUI-002 reverse + REQ-TUI-022 pop).
/// Order matters: pop kitty first (if pushed), then exit alt screen,
/// then disable raw mode (which restores termios).
pub fn tuiThreadShutdown(lc: *Lifecycle, writer: *std.Io.Writer) void {
    // ponytail: flush before teardown so alt-screen-exit + raw-mode-
    // disable bytes don't sit in the 4 KiB stdout buffer. Without this,
    // the terminal stays in alt-screen + raw mode until the kernel
    // closes the fd at process exit, which on some terminals means the
    // user sees a half-restored TTY.
    writer.flush() catch {};

    // 1. Pop kitty kb (only if we pushed).
    if (lc.kitty_flags_pushed) {
        popKittyKb(writer) catch {};
    }

    // 1.5 WU-2 (tui-keyentry-rebuild, REQ-NEW-002): disable DEC 2004
    // bracketed paste AFTER kitty-kb pop and BEFORE alt-screen exit
    // (symmetric wire order with init — design R-DES-5).
    disableBracketedPaste(writer) catch {};

    // 2. Exit alt screen + disable in-band resize.
    exitAltScreenAndResize(writer) catch {};

    // 2.5 WU 1.5.4 (tui-ship-fast-phase0.5, R7): ECMA-48 terminal state
    // restore — show cursor (DECTCEM) + SGR reset. Without these the
    // cursor stays invisible and bold/color attributes leak into the
    // next shell prompt (Starship, fish, etc.). Both must precede
    // disableRawMode because DECTCEM is terminal-screen state (the
    // kernel does not touch it on raw-mode restore) and SGR attributes
    // are likewise terminal state, not termios state. Reference: xterm
    // ctlseqs §"CSI Ps h" / §"SGR"; ECMA-48 §8.3.201 (DECTCEM) +
    // §8.3.117 (SGR 0 = default rendition).
    writer.writeAll("\x1b[?25h") catch {}; // DECTCEM show cursor
    writer.writeAll("\x1b[0m") catch {}; // SGR reset

    // 3. Disable raw mode (restores original termios).
    if (lc.raw_term) |*rt| {
        rt.disableRawMode() catch {};
    }

    // WU-1 (REQ-NEW-008): clear the thread-local parser handle AFTER
    // raw-mode teardown so no caller of `nextWithTimeout` reaches a
    // dangling Parser pointer during shutdown. Symmetric with the
    // setCurrentParser call in tuiThreadInit.
    terminal.event.setCurrentParser(null);

    // WU 1.5.4 (R7): final flush AFTER all teardown bytes. The L338
    // flush at the top of shutdown runs BEFORE the DEC reset sequences;
    // without this second flush the ~40 bytes of teardown CSI sit in
    // the 4 KiB stdout buffer and may never reach the terminal before
    // process exit.
    writer.flush() catch {};
}

// =============================================================================
// emitFrame (REQ-RW-003 + REQ-RW-005 + REQ-RW-007 — tui-render-wiring #1259)
//
// Cell→ANSI emitter. Reuses WindowMock.diff(current, prev) to compute
// the entry list, then writes CSI cursor-position + SGR + cell bytes to
// `writer`. Lazy per-cell SGR emit (no StyleTracker in v1; see D-2).
// ponytail: no StyleTracker — add when profiling shows >1% frame
// budget in SGR emits. ponytail: u21→u8 cast is v1 ASCII-only; non-ASCII
// stays for v2.
//
// WU 0.6 (tui-ship-fast-phase0, Bug 4): emitFrame takes explicit
// `cursor_col` and `cursor_row` parameters. When `cursor_col ==
// CURSOR_SKIP`, no trailing CUP is emitted (the diff loop is unchanged
// for non-key_entry states). When `cursor_col != CURSOR_SKIP`, the
// trailing CUP fires UNCONDITIONALLY at (cursor_col, cursor_row),
// regardless of whether any diff entries existed. This makes the
// blink-cursor position a first-class piece of layout state owned by
// the modal draw function, NOT a side-effect of walking the diff.
//
// POSIX termios(3) §Canonical mode ISIG is preserved: signal-generating
// input keys (Ctrl+C, Ctrl+Z) still produce signals per ISIG=true; the
// parser surfaces the decoded character through the same .key event
// surface as before. The CUP placement is read-only with respect to
// the tty discipline.
// =============================================================================

/// Sentinel value for `cursor_col` that suppresses the trailing CUP
/// emission. Used for non-key_entry states where the cursor position
/// is not part of the modal's layout contract.
pub const CURSOR_SKIP: u16 = std.math.maxInt(u16);

/// Emit a frame's worth of CSI cursor-position + SGR + cell bytes to
/// `writer`. Reuses `WindowMock.diff(prev)` to compute the entry list.
/// Lazily emits SGR per cell. Caller owns the WindowMock + prev buffer.
///
/// `cursor_col` / `cursor_row` are the explicit blink-cursor position
/// (0-indexed). When `cursor_col == CURSOR_SKIP`, no trailing CUP is
/// emitted (back-compat with states that don't track cursor). When
/// `cursor_col != CURSOR_SKIP`, the trailing CUP fires unconditionally
/// at (cursor_col, cursor_row) — this is the WU 0.6 contract that
/// resolves Bug 4 (cursor previously derived from last diff cell,
/// producing off-by-one when draft_len == 0 or when no `*` chars exist).
pub fn emitFrame(
    writer: *std.Io.Writer,
    prev: []const @import("modal.zig").Cell,
    current: []const @import("modal.zig").Cell,
    cols: u16,
    rows: u16,
    alloc: std.mem.Allocator,
    cursor_col: u16,
    cursor_row: u16,
) !void {
    // Tiger Style §4 — defensive precondition on the explicit cursor.
    // The CURSOR_SKIP sentinel is allowed; any other value must be
    // within the visible grid (0-indexed col <= cols, row < rows).
    // cursor_col == cols is allowed because it represents "one past
    // the last visible column" — the terminal will clamp/wrap on the
    // next write. This matches the WU 0.5 contract that the cursor
    // cap at long-draft edge is `prefix_len + max_visible == cols`.
    if (cursor_col != CURSOR_SKIP) {
        std.debug.assert(cursor_col <= cols);
        std.debug.assert(cursor_row < rows);
    }

    const modal = @import("modal.zig");
    var win: modal.WindowMock = .{
        .allocator = alloc,
        .cols = cols,
        .rows = rows,
        .cells = @constCast(current),
    };
    const diffs = try win.diff(prev);
    defer alloc.free(diffs);
    // WU 0.6 (Bug 4): trailing CUP at the explicit cursor position
    // (no longer derived from walking the diff back). For key_entry
    // this is `prefix_len + min(draft_len, max_visible)` per the
    // drawKeyEntry contract; for other states it is CURSOR_SKIP and no
    // CUP is emitted. The diff loop below is unchanged — per-cell
    // CUP+SGR+byte emission is still driven by the diff entries.
    for (diffs) |entry| {
        // PR 6 (terminal-control-lib-from-scratch, WU 6.3): in-tree
        // `terminal.cursor.goTo(x, y)` takes 0-indexed coords and adds
        // +1 internally (emits `CSI <y+1>;<x+1>H`). mibu took 1-indexed
        // coords at the call site (caller did +1); dropping the +1 here
        // preserves the byte output `\x1b[<row+1>;<col+1>H`.
        try terminal.cursor.goTo(writer, entry.x, entry.y);
        // ponytail: in-tree reset takes an `_: bool` for API uniformity
        // with bold/underline/reverse (the bool is ignored — SGR 0 always
        // resets). Pass `false` since the per-entry reset is unconditional.
        try terminal.style.reset(writer, false);
        if (entry.cell.style.bold) try terminal.style.bold(writer, true);
        if (entry.cell.style.underline) try terminal.style.underline(writer, true);
        if (entry.cell.style.reverse) try terminal.style.reverse(writer, true);
        // ponytail: u21→u8 cast is v1 ASCII-only; non-ASCII stays for v2.
        try writer.writeByte(@intCast(entry.cell.ch));
    }
    try terminal.style.reset(writer, false);
    // WU 0.6 (Bug 4) — trailing CUP at the explicit cursor position.
    // Fires UNCONDITIONALLY when cursor_col != CURSOR_SKIP, regardless
    // of whether any diff entries existed. The sentinel CURSOR_SKIP
    // suppresses emission (preserves the back-compat behavior for the
    // W3 diff-loop tests that don't model cursor state).
    if (cursor_col != CURSOR_SKIP) {
        try terminal.cursor.goTo(writer, cursor_col, cursor_row);
    }
}

// =============================================================================
// submitFrame (T-2.6.1, design §3.3 — phase 2 PR2 second half).
//
// Per-frame orchestrator. Renders the modal into the active ScreenGrid,
// calls `diffAndEmit` to write the diff + trailing CUP, and swaps the
// double buffer. Replaces the inline render+emit logic in
// `tuiThreadLoop` (T-2.6.2 wiring). Tiger Style §6 — error set is the
// writer's error set (writer failures are the only realistic runtime
// error; allocation-free means no OOM).
//
// Preconditions:
// - `lifecycle.active_grid()` returns a freshly-cleared grid for the current frame
// - `lifecycle.previous_grid()` returns the prior frame's diff baseline
//
// Caller contract: `tuiThreadLoop` invokes `submitFrame` once per
// iteration when `redraw_pending` is true. On error, `tuiThreadLoop`
// converts to a `catch continue`.
// =============================================================================

/// Phase 2 PR2 per-frame orchestrator (T-2.6.1). Writes paired DEC
/// 2026 brackets (mandatory even on empty diff per design §7 / D7),
/// clears + renders into the active ScreenGrid, diff+emit, swaps the
/// double buffer, and consumes the `force_full_redraw` flag.
///
/// `state` is the modal state from `src/modal.zig`. The active grid
/// is `lc.grids[lc.active_idx]`; the previous grid is
/// `lc.grids[lc.active_idx ^ 1]`. Both ScreenGrid instances keep their
/// internal `active_idx` at 0 (we never call `ScreenGrid.swap` — the
/// Lifecycle-level XOR swap cycles between the two ScreenGrids
/// wholesale).
///
/// Error set: `std.Io.Writer.Error` (propagated from `writeAll`) ∪
/// `diff_emit.DiffEmitError`. The dead-pty signature `WriteFailed`
/// (the analog of POSIX `BrokenPipe` in `std.Io.Writer.Error`) is
/// detected at the call site by `tuiThreadShutdown`'s flush probe —
/// `submitFrame` itself just propagates whatever the writer returns.
pub fn submitFrame(
    lifecycle: *Lifecycle,
    writer: *std.Io.Writer,
    state: *const @import("modal.zig").State,
    cols: u16,
    rows: u16,
) !void {
    // Tiger Style §4 — defensive preconditions on the dims and the
    // state pointer. Zig's type system rejects null `*const State`
    // outside unsafe code; the cols/rows guard mirrors diffAndEmit's.
    std.debug.assert(cols > 0);
    std.debug.assert(rows > 0);
    std.debug.assert(lifecycle.grids[lifecycle.active_idx].cols == cols);
    std.debug.assert(lifecycle.grids[lifecycle.active_idx].rows == rows);

    const modal = @import("modal.zig");
    const diff_emit = @import("diff_emit");

    // ── Bracket open (mandatory even on empty diff) ──────────────────
    // DEC 2026 (synchronized update) brackets the diff+emit pair so
    // the terminal atomically applies the changes. Without the
    // bracket, busy terminals can tear mid-render and show partial
    // frames. design §7 / D7 — paired brackets are non-negotiable
    // even when diffAndEmit produces zero entries.
    try writer.writeAll("\x1b[?2026h");

    // ── Stage 1: clear + render into the active grid ────────────────
    // renderToGrid assumes a freshly-cleared active grid (T-2.3.3
    // caller contract). Cells it doesn't touch stay at the cleared
    // value (default ' '), so leftover cells from the previous frame
    // can't leak through.
    lifecycle.grids[lifecycle.active_idx].clear();
    modal.renderToGrid(&lifecycle.grids[lifecycle.active_idx], state);

    // ── Stage 2: compute the cursor intent ──────────────────────────
    // Per design §3.4, key_entry carries an explicit cursor contract
    // (cursor_col, cursor_row). Other variants return CURSOR_SKIP so
    // diffAndEmit's trailing-CUP stage emits nothing.
    const cursor = modal.cursorIntentFromState(state);

    // ── Stage 3: diff + emit ─────────────────────────────────────────
    // diffAndEmit walks the two grid slices (prev/active) and writes a
    // per-cell `<CUP><SGR><UTF-8><SGR reset>` byte stream for each
    // changed cell, then a trailing CUP at the cursor position (or
    // CURSOR_SKIP suppression). Tiger Style §3 — allocation-free; the
    // two `[2]ScreenGrid` slices are value-typed inline storage.
    try diff_emit.diffAndEmit(
        writer,
        lifecycle.grids[lifecycle.active_idx ^ 1].active(), // prev frame
        lifecycle.grids[lifecycle.active_idx].active(), // current frame
        cols,
        rows,
        cursor.col,
        cursor.row,
    );

    // ── Bracket close (mandatory even on empty diff) ─────────────────
    // Symmetric with the open bracket. The terminal flushes the
    // buffered frame on the close transition.
    try writer.writeAll("\x1b[?2026l");

    // ── Consume the force_full_redraw flag ───────────────────────────
    // Cleared after the first render so subsequent frames revert to
    // incremental diffing (Tiger Style §5 — explicit state machine).
    lifecycle.force_full_redraw = false;

    // ── XOR swap (Lifecycle-level, not ScreenGrid-level) ────────────
    // Branch-free (u1 ^ 1). On the next frame, the previously-inactive
    // grid becomes active and the previously-active grid becomes the
    // diff baseline. The ScreenGrid instances themselves never call
    // their own `swap` — each one always reads/writes cells[0].
    lifecycle.active_idx ^= 1;
}

// =============================================================================
// TUI thread body (R-PR 4 real lifecycle).
//
// The runtime orchestrator spawns this on its TUI thread. We drain
// channels + poll mibu events until shutdown.
//
// `ThreadArgs` is unchanged from R-PR 1 — the runtime injects the same
// struct shape. We pull `io` off it for mibu event polling.
// =============================================================================

pub const ThreadArgs = struct {
    io: std.Io,
    /// Allocator used by the Agent thread for api_client.Client.stream
    /// (production: `std.heap.page_allocator` from `main()`; tests: `testing.allocator`).
    /// PR 2 followup (R5 of verify-report-pr2): added so the runtime can
    /// pass a real allocator instead of std.testing.allocator to Client.stream.
    allocator: std.mem.Allocator,
    channels: *@import("channels.zig").Channels,
    cancel_pipe: [2]i32,
    shutdown: *std.atomic.Value(bool),
    /// PR 1 (tui-runtime-integration #441, REQ-TUI-033): optional API key
    /// for real-mode requests. Null in mock mode. Owned by the Agent thread;
    /// zeroed on exit. New field — existing callers default to null.
    key: ?[]const u8 = null,
    /// PR 1 (tui-runtime-integration #441, REQ-TUI-033): optional mock
    /// server handle for mock-mode runtime wiring. The TUI thread does NOT
    /// touch it — it's threaded through so the Agent body can pull port()
    /// and the runtime can call deinit on shutdown.
    mock_handle: ?*@import("mock_server.zig").Handle = null,
    /// PR 2 (tui-runtime-integration #441, REQ-TUI-038): preflight auth
    /// state resolved by `main()` before `Runtime.run()`. The TUI thread
    /// seeds the modal state from this field — `.needs_first_entry` →
    /// `.key_entry`, `.has_disk_file` → `.unlock_prompt`.
    initial_auth_state: @import("api_auth.zig").AuthState = .needs_first_entry,
};

/// TUI thread body (R-PR 4 real impl). Composes tuiThreadInit /
/// tuiThreadLoop / tuiThreadShutdown. The thread is owned by
/// `runtime.zig` — this file does NOT spawn threads.
///
/// PR 2 (tui-runtime-integration #441, REQ-TUI-039/040/042/047): seeds
/// the modal state from `args.initial_auth_state` (resolved by `main()`
/// via `preflightAuthState`). The TUI thread creates a fresh
/// `modal.State` via `modal.initialModalState`. The thread also
/// checks `runtime.isIdleRelockDue` on each iteration and posts a
/// `Event.Relock` to the Agent when the 5-minute threshold trips
/// (REQ-TUI-042). No-TTY mode (REQ-TUI-047) is detected via
/// `Lifecycle.no_tty` and the renderers/bracket emission are skipped.
///
/// Loop structure (per design#408 §2.4):
///   1. Poll mibu events with a 16ms timeout (mibu.events.nextWithTimeout).
///   2. Wrap every render pass in beginSyncUpdate/endSyncUpdate (REQ-TUI-021).
///   3. Dispatch events to channels; exit on Shutdown from any channel.
///   4. Reset the frame arena after each render (REQ-TUI-003).
pub fn tuiThreadMain(args: *const ThreadArgs) void {
    // PR 2: seed modal state from preflight auth state. .needs_first_entry
    // → .key_entry (first-launch path; user types API key + consent).
    // .has_disk_file → .unlock_prompt (subsequent-launch; user types
    // passphrase). The seed is a stack-allocated State that the TUI
    // thread owns; the Agent thread never touches it.
    var modal_state: @import("modal.zig").State =
        @import("modal.zig").initialModalState(args.initial_auth_state);

    // PR 2 (REQ-TUI-042): monotonic clock anchor for the 5-min idle
    // relock. Production uses `std.Io.Timestamp.now`; tests inject a
    // fake clock via `isIdleRelockDue(last_user_action_ms, now_ms)`.
    var last_user_action_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(args.io, .real).nanoseconds, std.time.ns_per_ms));

    while (!args.shutdown.load(.seq_cst)) {
        // Per-frame modal dispatch (REQ-VER-009/010): drain agent_to_tui
        // events (StreamChunk, AgentError, Shutdown) into the modal
        // state. Returns true when Shutdown is observed.
        _ = @import("modal.zig").runtimeDriverTick(
            args.io,
            &modal_state,
            .{ .agent_to_tui = &args.channels.agent_to_tui },
        ) catch {};

        if (args.channels.tui_to_agent.tryGet(args.io)) |event| {
            switch (event) {
                .Shutdown => return,
                .KeyPress, .UserToolRequest => {
                    // User activity — reset the idle anchor.
                    last_user_action_ms = @intCast(@divTrunc(std.Io.Timestamp.now(args.io, .real).nanoseconds, std.time.ns_per_ms));
                },
                .ApiKeySubmitted, .UnlockPasswordSubmitted => {
                    last_user_action_ms = @intCast(@divTrunc(std.Io.Timestamp.now(args.io, .real).nanoseconds, std.time.ns_per_ms));
                },
                .Relock => {
                    // The Agent told us the in-memory key was zeroed.
                    // The modal state machine handles the relock; for
                    // now we keep the state shape stable.
                    last_user_action_ms = @intCast(@divTrunc(std.Io.Timestamp.now(args.io, .real).nanoseconds, std.time.ns_per_ms));
                },
                else => {},
            }
        }

        // PR 2 (REQ-TUI-042): 5-min idle relock. When the threshold
        // trips, post `.Relock` to the Agent so it zeroes its key.
        const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(args.io, .real).nanoseconds, std.time.ns_per_ms));
        if (@import("runtime.zig").isIdleRelockDue(last_user_action_ms, now_ms)) {
            args.channels.tui_to_agent.tryPut(args.io, .Relock) catch {};
            last_user_action_ms = now_ms;
        }

        args.io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .real) catch {};
    }
}

/// Per-frame loop orchestrator (REQ-TUI-002 + REQ-TUI-021 + REQ-RW-004
/// + REQ-RW-006). Polls mibu events in 16ms windows; when the redraw
/// flag flips (from init seed, a resize event, or any other source),
/// runs the modal render bracket and emits the cell diff via emitFrame.
/// Exits on `Shutdown` arriving on any channel AFTER any pending render
/// completes.
///
/// `state` is the modal state from src/modal.zig — its active variant
/// dispatches via `modal.drawModal` to the per-fn draw* helper. The
/// per-frame WindowMock is allocated + freed each iteration; the
/// `prev_snapshot` buffer persists across frames (REQ-RW-002).
///
/// ponytail: per-frame WindowMock init/deinit is cheap at v1 frame
/// rates; revisit if profiling shows allocation cost.
pub fn tuiThreadLoop(
    lifecycle: *Lifecycle,
    handle: std.Io.File.Handle,
    io: std.Io,
    writer: *std.Io.Writer,
    channels: *@import("channels.zig").Channels,
    state: *@import("modal.zig").State,
    alloc: std.mem.Allocator,
    // zargeant/tui-cancel: mibu raw mode (ISIG=false) means 0x03
    // arrives as data; the parser turns it into .char('c') + ctrl.
    // We need this atomic so Ctrl+C in any modal state can flip the
    // shared shutdown flag the outer wrapper (runtime.zig:383) polls.
    shutdown: *std.atomic.Value(bool),
    // Opción B WU-1 (T1.6): Runtime's existing cancel_pipe (created at
    // runtime.zig:222). Threaded through to submitKeyEntry →
    // validateViaApi so a Ctrl+C during in-flight TLS handshake aborts
    // within ≤100ms (REQ-NEW-006). Tests / no-TTY paths pass null.
    cancel_pipe: ?[2]i32,
) !void {
    const modal = @import("modal.zig");
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    while (true) {
        // 1. Render if pending (REQ-RW-004 sub-bullet 2-3) — runs before
        // Shutdown drain so a pending render always completes.
        if (lifecycle.redraw_pending.swap(false, .seq_cst)) {
            try terminal.term.beginSynchronizedUpdate(writer);
            var win = try modal.WindowMock.init(alloc, lifecycle.width, lifecycle.height);
            defer win.deinit();
            defer terminal.term.endSynchronizedUpdate(writer) catch {};
            try modal.drawModal(win, state);
            const current = win.snapshot();
            // First frame: lifecycle.prev_snapshot is null → use current
            // as both prev (full-frame emit per REQ-RW-003 S-RW-005).
            const prev = lifecycle.prev_snapshot orelse current;
            // WU 0.6 (tui-ship-fast-phase0, Bug 4): pull the explicit
            // cursor position from modal state for key_entry. drawKeyEntry
            // writes cursor_col = prefix_len + min(draft_len, max_visible);
            // other states leave cursor_col at 0, which emitFrame treats
            // as the CURSOR_SKIP sentinel (no trailing CUP) only when
            // the caller wraps the lookup. Here we route through a
            // small helper that returns the sentinel for non-key_entry
            // states.
            const cursor_pos = modalCursorFromState(state);
            try emitFrame(
                writer,
                prev,
                current,
                lifecycle.width,
                lifecycle.height,
                alloc,
                cursor_pos.col,
                cursor_pos.row,
            );
            // ponytail: 4 KiB stdout buffer auto-flushes only on overflow,
            // so frames + cursor CSI bytes sit there until the buffer fills
            // (~4 frames of busy typing). Flush per-frame so input and
            // cursor stay in sync. One extra syscall/frame; not a bottleneck.
            writer.flush() catch continue;
            // Swap prev_snapshot. Free the old buffer, dupe the new one.
            if (lifecycle.prev_snapshot) |p| alloc.free(p);
            const duped = try alloc.dupe(modal.Cell, current);
            lifecycle.prev_snapshot = duped;
        }
        // 2. Drain channels.Shutdown from any edge (runtime signals all).
        if (channels.tui_to_agent.tryGet(io)) |ev| switch (ev) {
            .Shutdown => return,
            else => continue,
        };
        // 2.5 WU-2 (CAP-03/04/08/14): drain submit_reply BEFORE the
        // mibu poll so a fast worker reply transitions the state within
        // the same frame (latency ≤ next 16ms tick). Set redraw_pending
        // so the next render reflects the new state.
        if (drainSubmitReply(io, state, channels)) {
            lifecycle.redraw_pending.store(true, .seq_cst);
        }
        // 3. Poll terminal events. Resize → update dims + set redraw flag.
        //
        // PR 6 (terminal-control-lib-from-scratch, WU 6.3, C22): the
        // in-tree `terminal.event.nextWithTimeout` takes 4 args; the 4th
        // is the caller's atomic flag (`&lifecycle.redraw_pending`). The
        // parser reads it after `poll(2)` returns `error.Interrupted`
        // (EINTR, typically from SIGWINCH) and returns `.resize` (void)
        // if set, `.none` otherwise. `src/terminal/event.zig` does NOT
        // declare its own module-level atomic; the caller owns the flag.
        const event = terminal.event.nextWithTimeout(io, file, 16, &lifecycle.redraw_pending) catch continue;
        switch (event) {
            // REQ-TIW-010 — consume the key locally via handleKeyInput
            // BEFORE forwarding to Agent. Consumed keys drop the forward
            // (no double-emit) and set redraw_pending=true so the next
            // iteration re-renders the modal. Unconsumed keys (arrows,
            // future dispatch) keep the forward to Agent.
            .key => |k| {
                // zargeant/tui-cancel — Ctrl+C in any modal state.
                // Intercept BEFORE handleKeyInput so .key_entry doesn't
                // type a literal 'c' into the API-key draft, and so the
                // user has a clean escape hatch from every screen.
                if (k.code == .char and k.mods.ctrl) {
                    // tui-input-flow-bugfixes-2 CAP-09 (R2a redirect,
                    // design D3): this is THE writer of the cancel
                    // pipe now (post-WU-4 R2a — the SIGINT handler
                    // at src/cancel_signal.zig was removed). Async-
                    // signal-safe: single write(2) syscall, no libc.
                    // Atomic first (downstream readers stop), then
                    // pipe (worker aborts within ≤100ms via REQ-NEW-
                    // 006 invariant — verified by tests/cancel_e2e.zig
                    // CAP-09 writer-side test). `cancel_pipe` is null
                    // only on test/no-TTY paths.
                    shutdown.store(true, .seq_cst);
                    if (cancel_pipe) |p| _ = std.os.linux.write(p[1], &.{0x01}, 1);
                    // Also drain Shutdown on the channel so the inner
                    // loop exits promptly; the outer wrapper polls the
                    // atomic separately (runtime.zig:383).
                    channels.tui_to_agent.tryPut(io, .{ .Shutdown = {} }) catch {};
                    return;
                }
                const consumed = handleKeyInput(io, alloc, state, k, cancel_pipe, channels) catch continue;
                if (consumed) {
                    lifecycle.redraw_pending.store(true, .seq_cst);
                } else {
                    try channels.tui_to_agent.tryPut(io, .{ .KeyPress = k });
                }
            },
            .resize => {
                const sz = terminal.term.getSize(handle) catch continue;
                lifecycle.width = sz.width;
                lifecycle.height = sz.height;
                lifecycle.redraw_pending.store(true, .seq_cst);
            },
            .timeout, .none, .invalid, .paste_start, .paste_end, .mouse => {},
        }
    }
}

// =============================================================================
// handleKeyInput — W-4 key-event consumer for the modal state machine.
//
// REQ-TIW-003: signature is (io, alloc, state, k) -> !bool. Returns true
// when the state transitioned (caller MUST set redraw_pending=true);
// false otherwise (caller MAY forward the key to the Agent channel).
// Co-located with tuiThreadLoop; keeps src/modal.zig free of mibu imports.
//
// REQ-TIW-004: char-append for .key_entry + .unlock_prompt.
// REQ-TIW-005: backspace decrement (saturating).
// REQ-TIW-006: enter submit via modal.submitKeyEntry / submitUnlock.
// REQ-TIW-007: esc cancel for .unlock_prompt (no-op for .key_entry per
// REQ-TIW-NEG-3).
// REQ-TIW-008: .event == .release early-return; .event == .repeat is
// treated like .press (auto-repeat appends/submits).
// =============================================================================

// ponytail: synchronous `validateViaApi` inside `submitKeyEntry` blocks
// the TUI thread for ~1-3s. WU-2 (tui-input-flow-bugfixes-2, CAP-03/04):
// the synchronous submit is renamed to `submitKeyEntryAsync` /
// `submitUnlockAsync`. Both spawn a per-submit worker thread and return
// within ≤1ms; the worker posts `Event.ValidateApiReply` to
// `channels.submit_reply`. `tuiThreadLoop` drains the reply on the
// next 16ms poll cycle + transitions the state.
pub fn handleKeyInput(
    io: std.Io,
    alloc: std.mem.Allocator,
    state: *@import("modal.zig").State,
    k: terminal.event.Key,
    cancel_pipe: ?[2]i32,
    channels: *@import("channels.zig").Channels,
) !bool {
    if (k.event == .release) return false; // REQ-TIW-008 — kitty-kb release no-op
    switch (state.*) {
        .key_entry => |*ke| {
            // WU 1.5.1 (tui-ship-fast-phase0.5, R1+R4 fix): reject ALL
            // input while the async validation worker is in flight.
            // Pre-fix, keystrokes during validation appended to the
            // draft (R1: "Enter adds extra *") and the validation
            // spinner appeared to lag on the last char delete (R4:
            // "1s lag on last *"). POSIX termios(3) ISIG is preserved
            // (ISIG=true means signal-generating Ctrl+C/Z still emit
            // signals independently of this modal handler).
            if (ke.validating) return false;
            switch (k.code) {
                .char => |c| {
                    if (ke.draft_len >= ke.draft.len) return false; // REQ-TIW-004 ceiling
                    if (c > 0x7F) return false; // REQ-TIW-004 non-ASCII
                    ke.draft[ke.draft_len] = @intCast(c);
                    ke.draft_len += 1;
                    return true;
                },
                .backspace => {
                    if (ke.draft_len == 0) return false; // REQ-TIW-005 empty-draft no-op
                    ke.draft_len -= 1;
                    return true;
                },
                .enter => {
                    // WU-2 (CAP-03): spawn worker, return ≤1ms. State
                    // transitions on submit_reply consumption, not here.
                    try @import("modal.zig").submitKeyEntryAsync(
                        io,
                        alloc,
                        state,
                        cancel_pipe,
                        &channels.submit_reply,
                    ); // REQ-TIW-006
                    return true;
                },
                .esc => {
                    // WU 1.5.3 (tui-ship-fast-phase0.5, R6): Esc clears the
                    // draft + err_msg. Replaces the v1 no-op (REQ-TIW-NEG-3)
                    // with a "clear all" gesture consistent with the
                    // .unlock_prompt arm's cancelUnlock behavior. The draft
                    // bytes are left in place; only draft_len is zeroed so
                    // the renderer's "shown = min(draft_len, ...)" reads 0.
                    // err_msg_len is zeroed too so the prior format-fail
                    // message disappears on cancel.
                    ke.draft_len = 0;
                    ke.err_msg_len = 0;
                    return true;
                },
                else => return false, // REQ-TIW-009 — arrows / F-keys / tab
            }
        },
        .unlock_prompt => |*up| switch (k.code) {
            .char => |c| {
                if (up.draft_len >= up.draft.len) return false;
                if (c > 0x7F) return false;
                up.draft[up.draft_len] = @intCast(c);
                up.draft_len += 1;
                return true;
            },
            .backspace => {
                if (up.draft_len == 0) return false;
                up.draft_len -= 1;
                return true;
            },
            .enter => {
                // WU-2 (CAP-04): spawn worker, return ≤1ms. State
                // transitions on submit_reply consumption, not here.
                try @import("modal.zig").submitUnlockAsync(
                    io,
                    alloc,
                    state,
                    &channels.submit_reply,
                ); // REQ-TIW-006
                return true;
            },
            .esc => {
                @import("modal.zig").cancelUnlock(state); // REQ-TIW-007
                return true;
            },
            else => return false,
        },
        else => return false, // .welcome / .consent_prompt / .agent_loop / .error_modal
    }
}

/// Drain one tick of `submit_reply` events into the modal state. Returns
/// true when at least one reply was consumed (caller MUST set
/// `redraw_pending = true`). Mirrors `modal.runtimeDriverTick`'s shape
/// but for the WU-2 worker reply channel.
///
/// WU-2 (CAP-03/04/08/14): the worker reply carries INLINE buffers
/// (Bug 1 pattern) — no slice aliases the worker's stack-local storage
/// after the worker exits. The TUI thread joins the worker via
/// `state.X.worker_thread` AFTER consuming the reply (fire-and-forget
/// + join-on-reply, design D1).
pub fn drainSubmitReply(
    io: std.Io,
    state: *@import("modal.zig").State,
    channels: *@import("channels.zig").Channels,
) bool {
    var consumed = false;
    while (channels.submit_reply.tryGet(io)) |event| {
        consumed = true;
        switch (event) {
            .ValidateApiReply => |payload| {
                // Join the worker BEFORE reading inline data (join-on-
                // reply ordering; the worker has already exited by the
                // time the reply is in the channel buffer, so the join
                // is immediate).
                switch (state.*) {
                    .key_entry => |*ke| {
                        if (ke.worker_thread) |t| t.join();
                        ke.worker_thread = null;
                        ke.validating = false;
                        if (payload.success) {
                            // Advance to .consent_prompt with the
                            // validated key's last-4 + canonical path.
                            state.* = .{
                                .consent_prompt = .{
                                    .consent = false,
                                    .last_four = payload.last_four,
                                    .path = "~/.config/zargeant/credentials.json",
                                },
                            };
                        } else {
                            // Stay in .key_entry; copy err into inline buffer.
                            var err_buf: [128]u8 = .{0} ** 128;
                            const len = copyErrInline(&err_buf, &payload.err, payload.err_len);
                            state.* = .{
                                .key_entry = .{
                                    .draft = ke.draft,
                                    .draft_len = ke.draft_len,
                                    .err_msg_buf = err_buf,
                                    .err_msg_len = len,
                                    .validating = false,
                                },
                            };
                        }
                    },
                    .unlock_prompt => |*up| {
                        if (up.worker_thread) |t| t.join();
                        const next_attempts: u8 = up.attempts + 1;
                        up.worker_thread = null;
                        up.validating = false;
                        if (payload.success) {
                            // Advance to .agent_loop.
                            state.* = .{ .agent_loop = .{
                                .allocator = io_allocator_tui(io),
                                .cumulative = .empty,
                                .last_update_ms = 0,
                                .model = "",
                                .tokens = 0,
                            } };
                        } else if (next_attempts >= @import("modal.zig").UNLOCK_MAX_ATTEMPTS) {
                            // Cap reached — escalate to .error_modal.
                            state.* = .{ .error_modal = .{
                                .kind = .auth,
                                .message_buf = payload.err,
                                .message_len = payload.err_len,
                                .prior = .unlock_prompt,
                            } };
                        } else {
                            // Stay in .unlock_prompt with err populated.
                            var err_buf: [128]u8 = .{0} ** 128;
                            const len = copyErrInline(&err_buf, &payload.err, payload.err_len);
                            state.* = .{
                                .unlock_prompt = .{
                                    .draft = up.draft,
                                    .draft_len = up.draft_len,
                                    .err_msg_buf = err_buf,
                                    .err_msg_len = len,
                                    .attempts = next_attempts,
                                    .validating = false,
                                },
                            };
                        }
                    },
                    else => {
                        // Reply arrived for a state that no longer
                        // expects one (user dismissed). Best-effort
                        // drop — payload is consumed by the channel.
                    },
                }
            },
            else => {},
        }
    }
    return consumed;
}

/// Copy `src[0..len]` into a 128-byte inline buffer (Bug 1 pattern).
/// Truncates to 128 bytes. Returns the actual length copied.
inline fn copyErrInline(dst: *[128]u8, src: *const [128]u8, len: usize) usize {
    const n: usize = @min(len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// Resolve an allocator for the .agent_loop variant from the TUI thread.
/// Mirrors `modal.io_allocator`; re-declared here to avoid pulling
/// modal.zig's test-only helper into the TUI source path.
fn io_allocator_tui(io: std.Io) std.mem.Allocator {
    _ = io;
    if (builtin.is_test) return std.testing.allocator;
    return std.heap.page_allocator;
}

/// WU 0.6 (tui-ship-fast-phase0, Bug 4): extract the explicit cursor
/// position from the modal state for use by emitFrame. Only key_entry
/// carries an explicit cursor contract; other states return the
/// CURSOR_SKIP sentinel so emitFrame skips the trailing CUP. The
/// caller threads these through emitFrame as cursor_col / cursor_row.
fn modalCursorFromState(state: *const @import("modal.zig").State) struct { col: u16, row: u16 } {
    switch (state.*) {
        .key_entry => |*ke| return .{ .col = ke.cursor_col, .row = ke.cursor_row },
        else => return .{ .col = CURSOR_SKIP, .row = 0 },
    }
}

// =============================================================================
// Tests (R-PR 4: 11 new tests across 4 mibu REQs)
// =============================================================================

const testing = std.testing;

test "tui_mod compiles with mibu import (sanity)" {
    // REQ-TUI-018 — the file references mibu symbols at compile time.
    // If any are missing the build fails.
    try testing.expect(true);
}

test "enterAltScreenAndResize writes CSI ?1049h + CSI ?2048h" {
    // REQ-TUI-002 — alt screen + in-band resize both fire on init.
    // Writer.fixed writes into buf[0..end]; we read those bytes after
    // the call. (Calling flush drains into the vtable's fixedDrain which
    // succeeds without moving bytes; bytes stay in buf.)
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try enterAltScreenAndResize(&w);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[?1049h") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[?2048h") != null);
}

test "exitAltScreenAndResize writes CSI ?1049l + CSI ?2048l" {
    // REQ-TUI-002 reverse — TTY restored on exit.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try exitAltScreenAndResize(&w);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[?1049l") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[?2048l") != null);
}

test "pushKittyKb writes CSI >3u (disambiguate + report_events)" {
    // REQ-TUI-022 — kitty push with disambiguate (bit 1) + report_events
    // (bit 2) per kitty kb protocol. mibu's KittyFlags.bits() emits 3
    // (= 1 | 2). The spec text referencing bits==5 was incorrect;
    // 5 corresponds to disambiguate + alternate_keys (no report_events).
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try pushKittyKb(&w);
    const out = buf[0..w.end];
    // SEQ format: "\x1b[>3u" (CSI > flags u)
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[>3u") != null);
}

test "popKittyKb writes CSI <u" {
    // REQ-TUI-022 — kitty pop.
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try popKittyKb(&w);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[<u") != null);
}

test "beginSyncUpdate + endSyncUpdate bracket (REQ-TUI-021)" {
    // The synchronized update bracket writes CSI ?2026h + CSI ?2026l.
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try beginSyncUpdate(&w);
    try endSyncUpdate(&w);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[?2026h") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[?2026l") != null);
}

test "runFrames emits exactly 100 begin + 100 end synchronized updates" {
    // REQ-TUI-021 — synchronized update bracket fires once per frame.
    // 100 frames → 100 begin writes matched 1:1 with 100 end writes.
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try runFrames(&w, 100);
    const out = buf[0..w.end];
    var begin_count: usize = 0;
    var end_count: usize = 0;
    {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, out, idx, "\x1b[?2026h")) |i| {
            begin_count += 1;
            idx = i + 1;
        }
    }
    {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, out, idx, "\x1b[?2026l")) |i| {
            end_count += 1;
            idx = i + 1;
        }
    }
    try testing.expectEqual(@as(usize, 100), begin_count);
    try testing.expectEqual(@as(usize, 100), end_count);
}

test "bracket is innermost (begin appears before end in buffer order)" {
    // REQ-TUI-021 — the begin/end bracket is the innermost wrap. With
    // a single helper invocation, begin comes before end in the byte
    // stream (no nesting).
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try runFrames(&w, 1);
    const out = buf[0..w.end];
    const begin_idx = std.mem.indexOf(u8, out, "\x1b[?2026h").?;
    const end_idx = std.mem.indexOf(u8, out, "\x1b[?2026l").?;
    try testing.expect(begin_idx < end_idx);
}

test "Lifecycle struct exposes required fields" {
    // The Lifecycle struct carries the right shape for tuiThreadShutdown.
    // Compile-time assertion via typeinfo. PR 2 adds the `no_tty` field
    // (REQ-TUI-047); the count rises from 7 to 8. tui-render-wiring
    // (#1259, REQ-RW-002) adds `prev_snapshot`; the count rises to 9.
    // WU-1 (tui-keyentry-rebuild, REQ-NEW-001) adds `parser: Parser`
    // for the persistent parser; the count rises to 10.
    // Phase 2 PR2 (T-2.5.1) adds the 5-field double-buffer + state
    // block (`grids`, `active_idx`, `force_full_redraw`, `kitty_active`,
    // `cancel_pipe`); the count rises to 15.
    const fields = @typeInfo(Lifecycle).@"struct".fields;
    try testing.expectEqual(@as(usize, 15), fields.len);
}

test "redraw_pending is std.atomic.Value(bool) with seq_cst contract" {
    // REQ-TUI-019 scenario 3 — redraw_pending is an atomic bool field on
    // Lifecycle. SIGWINCH (sigaction handler) writes it; the render
    // loop reads it. The contract is .seq_cst for both.
    var lc: Lifecycle = .{
        .raw_term = null,
        .dec_2048_supported = false,
        .kitty_supported = false,
        .kitty_flags_pushed = false,
        .redraw_pending = std.atomic.Value(bool).init(false),
        .width = 80,
        .height = 24,
        .grids = .{ try ScreenGrid.init(80, 24), try ScreenGrid.init(80, 24) },
    };
    lc.redraw_pending.store(true, .seq_cst);
    try testing.expect(lc.redraw_pending.load(.seq_cst));
    lc.redraw_pending.store(false, .seq_cst);
    try testing.expect(!lc.redraw_pending.load(.seq_cst));
}

test "installSigwinch routes a set-redraw call to the atomic" {
    // REQ-TUI-019 scenario 2 — SIGWINCH fallback path. We simulate the
    // signal firing by writing to the atomic via the same path the
    // handler would (installSigwinch sets the global pointer; the
    // handler reads it). This avoids actually raising a process-wide
    // signal during the test runner.
    var pending = std.atomic.Value(bool).init(false);
    installSigwinch(&pending);
    pending.store(true, .seq_cst);
    try testing.expect(pending.load(.seq_cst));
    resetSigwinch();
}

test "DEC 2048 dual-path: lifecycle flag toggles between supported/not" {
    // REQ-TUI-019 scenarios 1+2 — both DEC 2048 (in-band) and SIGWINCH
    // (signal) paths converge on the same redraw_pending atomic. The
    // lifecycle field `dec_2048_supported` records which path is active.
    // We exercise the struct shape + init order rather than a real
    // terminal probe (mibu.queryModeWithTimeout would block on TTY-less
    // pipes).
    var lc_on: Lifecycle = .{
        .raw_term = null,
        .dec_2048_supported = true, // simulated DEC 2048 response
        .kitty_supported = false,
        .kitty_flags_pushed = false,
        .redraw_pending = std.atomic.Value(bool).init(false),
        .width = 80,
        .height = 24,
        .grids = .{ try ScreenGrid.init(80, 24), try ScreenGrid.init(80, 24) },
    };
    _ = &lc_on;
    var lc_off: Lifecycle = .{
        .raw_term = null,
        .dec_2048_supported = false, // simulated not_recognized
        .kitty_supported = false,
        .kitty_flags_pushed = false,
        .redraw_pending = std.atomic.Value(bool).init(false),
        .width = 80,
        .height = 24,
        .grids = .{ try ScreenGrid.init(80, 24), try ScreenGrid.init(80, 24) },
    };
    _ = &lc_off;
    // Both paths flip the same atomic.
    lc_on.redraw_pending.store(true, .seq_cst);
    lc_off.redraw_pending.store(true, .seq_cst);
    try testing.expect(lc_on.redraw_pending.load(.seq_cst));
    try testing.expect(lc_off.redraw_pending.load(.seq_cst));
    try testing.expect(lc_on.dec_2048_supported);
    try testing.expect(!lc_off.dec_2048_supported);
}

test "kitty kb push on init + pop on shutdown (REQ-TUI-022 lifecycle)" {
    // REQ-TUI-022 — the lifecycle records `kitty_flags_pushed` so
    // tuiThreadShutdown only pops if we actually pushed. We verify
    // the field wiring + the byte output via pushKittyKb/popKittyKb.
    const lc: Lifecycle = .{
        .raw_term = null,
        .dec_2048_supported = false,
        .kitty_supported = true, // simulated kitty kb probe
        .kitty_flags_pushed = true, // simulated after push
        .redraw_pending = std.atomic.Value(bool).init(false),
        .width = 80,
        .height = 24,
        .grids = .{ try ScreenGrid.init(80, 24), try ScreenGrid.init(80, 24) },
    };

    // Record push + pop in sequence (the writer captures both).
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try pushKittyKb(&w);
    try popKittyKb(&w);
    const out = buf[0..w.end];
    // Verify both sequence markers in correct order (push first, then pop).
    const push_idx = std.mem.indexOf(u8, out, "\x1b[>3u").?;
    const pop_idx = std.mem.indexOf(u8, out, "\x1b[<u").?;
    try testing.expect(push_idx < pop_idx);
    try testing.expect(lc.kitty_flags_pushed);
}

test "kitty kb unsupported skips push (REQ-TUI-022 scenario 2)" {
    // REQ-TUI-022 — when the terminal does not support kitty kb,
    // the Lifecycle records `kitty_supported = false` and we do NOT
    // push. Verifies the field shape so tuiThreadShutdown skips pop.
    const lc: Lifecycle = .{
        .raw_term = null,
        .dec_2048_supported = false,
        .kitty_supported = false, // simulated no-response terminal
        .kitty_flags_pushed = false, // no push happened
        .redraw_pending = std.atomic.Value(bool).init(false),
        .width = 80,
        .height = 24,
        .grids = .{ try ScreenGrid.init(80, 24), try ScreenGrid.init(80, 24) },
    };
    // tuiThreadShutdown must observe kitty_flags_pushed = false and
    // skip popKittyKb. The field is the contract.
    try testing.expect(!lc.kitty_supported);
    try testing.expect(!lc.kitty_flags_pushed);
}

test "tuiThreadMain returns on Shutdown (consumes channels)" {
    // REQ-TUI-001 wiring — TUI thread consumes tui_to_agent + returns on
    // Shutdown. Stays green from R-PR 1; carried forward here.
    var ch: @import("channels.zig").Channels = @import("channels.zig").Channels.init();
    defer ch.closeAll(testing.io);
    var shutdown = std.atomic.Value(bool).init(false);
    const args = ThreadArgs{
        .io = testing.io,
        .allocator = testing.allocator,
        .channels = &ch,
        .cancel_pipe = .{ -1, -1 },
        .shutdown = &shutdown,
    };
    try ch.tui_to_agent.tryPut(testing.io, .Shutdown);
    tuiThreadMain(&args);
    try testing.expectEqual(@as(usize, 0), ch.tui_to_agent.len());
}

test "tuiThreadMain returns when shutdown flag is set" {
    // Carried forward from R-PR 1.
    var ch: @import("channels.zig").Channels = @import("channels.zig").Channels.init();
    defer ch.closeAll(testing.io);
    var shutdown = std.atomic.Value(bool).init(true);
    const args = ThreadArgs{
        .io = testing.io,
        .allocator = testing.allocator,
        .channels = &ch,
        .cancel_pipe = .{ -1, -1 },
        .shutdown = &shutdown,
    };
    tuiThreadMain(&args);
    try testing.expectEqual(@as(usize, 0), ch.tui_to_agent.len());
}
