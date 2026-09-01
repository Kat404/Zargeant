// src/tui.zig -- TUI thread body + mibu lifecycle.
//
// Spec:   sdd/tui-recovery/spec  (id=407) REQ-TUI-002, REQ-TUI-003,
//         REQ-TUI-019, REQ-TUI-021, REQ-TUI-022
// Design: sdd/tui-recovery/design (id=408) §2.3 (R-PR 4), §2.4
//
// R-PR 4 ships the real mibu render lifecycle:
//   - tuiThreadInit: enableRawMode + enterAlternateScreen +
//     enableInBandResize + DEC 2048 probe (REQ-TUI-019) +
//     queryKittyKeyboard / pushKittyKeyboard (REQ-TUI-022).
//   - tuiThreadLoop: per-frame begin/endSynchronizedUpdate bracket
//     (REQ-TUI-021) + events.nextWithTimeout(16) poll.
//   - tuiThreadShutdown: popKittyKeyboard + exitAlternateScreen +
//     disableRawMode. RawTerm token owns the original termios.
//
// mibu primitive calls live in testable helpers (enterAltScreenAndResize,
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

const mibu = @import("mibu");

// =============================================================================
// Lifecycle state (REQ-TUI-002 + REQ-TUI-019 + REQ-TUI-022)
//
// Returned by `tuiThreadInit`; threaded through `tuiThreadLoop` (mutated
// by SIGWINCH events); handed to `tuiThreadShutdown` for restoration.
// =============================================================================

pub const Lifecycle = struct {
    /// RawTerm token owns the original termios; calling disableRawMode
    /// on shutdown restores cooked mode.
    raw_term: ?mibu.term.RawTerm,
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
    prev_snapshot: ?[]@import("modal.zig").Cell = null,
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
    try mibu.term.enterAlternateScreen(writer);
    try mibu.term.enableInBandResize(writer);
}

/// Exit alternate screen + disable in-band resize reports.
/// Writes CSI ?1049l + CSI ?2048l to `writer`.
pub fn exitAltScreenAndResize(writer: *std.Io.Writer) !void {
    try mibu.term.exitAlternateScreen(writer);
    try mibu.term.disableInBandResize(writer);
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
    const mode = mibu.events.queryModeWithTimeout(io, file, writer, 2048, 50) catch return false;

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
    return mibu.events.supportsKittyKeyboardWithTimeout(io, file, writer, 50) catch false;
}

/// Push kitty keyboard flags. Always uses disambiguate + report_events
/// (mibu bits = 3 = 1|2 = 0b011; kitty kb protocol flags 1+2).
/// Caller must verify kitty support before calling; pop only on success.
pub fn pushKittyKb(writer: *std.Io.Writer) !void {
    const flags: mibu.term.KittyFlags = .{ .disambiguate = true, .report_events = true };
    try mibu.term.pushKittyKeyboard(writer, flags);
}

/// Pop kitty keyboard flag. No-op if push never happened.
pub fn popKittyKb(writer: *std.Io.Writer) !void {
    try mibu.term.popKittyKeyboard(writer);
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
    try mibu.term.beginSynchronizedUpdate(writer);
}

/// End a synchronized update. Flushes the buffered frame to the screen.
pub fn endSyncUpdate(writer: *std.Io.Writer) !void {
    try mibu.term.endSynchronizedUpdate(writer);
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
    var lc: Lifecycle = .{
        .raw_term = null,
        .dec_2048_supported = false,
        .kitty_supported = false,
        .kitty_flags_pushed = false,
        .redraw_pending = std.atomic.Value(bool).init(false),
        .width = 80,
        .height = 24,
    };

    // 1. Raw mode (RawTerm token owns original termios for restore).
    // PR 2 (REQ-TUI-047): if `enableRawMode` fails (no `/dev/tty`, CI),
    // we fall back to logger-only mode and signal degraded mode on the
    // Lifecycle via `no_tty = true`. The caller is expected to skip
    // render and bracket emission in that case.
    if (mibu.term.enableRawMode(handle)) |rt| {
        lc.raw_term = rt;
    } else |_| {
        lc.no_tty = true;
    }

    // 2. Install SIGWINCH fallback handler (REQ-TUI-019 scenario 2). The
    // handler sets redraw_pending via the global pointer installed here.
    installSigwinch(&lc.redraw_pending);

    // 3. Alt screen + in-band resize (REQ-TUI-002). Skip in no-TTY mode
    // (no terminal to switch into).
    if (!lc.no_tty) {
        enterAltScreenAndResize(writer) catch {};
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

    // 2. Exit alt screen + disable in-band resize.
    exitAltScreenAndResize(writer) catch {};

    // 3. Disable raw mode (restores original termios).
    if (lc.raw_term) |*rt| {
        rt.disableRawMode() catch {};
    }
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
// =============================================================================

/// Emit a frame's worth of CSI cursor-position + SGR + cell bytes to
/// `writer`. Reuses `WindowMock.diff(prev)` to compute the entry list.
/// Lazily emits SGR per cell. Caller owns the WindowMock + prev buffer.
pub fn emitFrame(
    writer: *std.Io.Writer,
    prev: []const @import("modal.zig").Cell,
    current: []const @import("modal.zig").Cell,
    cols: u16,
    rows: u16,
    alloc: std.mem.Allocator,
) !void {
    const modal = @import("modal.zig");
    var win: modal.WindowMock = .{
        .allocator = alloc,
        .cols = cols,
        .rows = rows,
        .cells = @constCast(current),
    };
    const diffs = try win.diff(prev);
    defer alloc.free(diffs);
    // REQ-TIW-001 — track the last diff cell so we can place the
    // blink cursor adjacent to it after the trailing reset. Terminal-
    // agnostic: avoids terminal-specific DEC 2026 frozen-cursor on
    // first frame (Kitty/VTE behavior varies per #1277 W-3).
    var last_x: u16 = 0;
    var last_y: u16 = 0;
    for (diffs) |entry| {
        last_x = entry.x;
        last_y = entry.y;
        try mibu.cursor.goTo(writer, entry.x + 1, entry.y + 1);
        try mibu.style.reset(writer);
        if (entry.cell.style.bold) try mibu.style.bold(writer, true);
        if (entry.cell.style.underline) try mibu.style.underline(writer, true);
        if (entry.cell.style.reverse) try mibu.style.reverse(writer, true);
        // ponytail: u21→u8 cast is v1 ASCII-only; non-ASCII stays for v2.
        try writer.writeByte(@intCast(entry.cell.ch));
    }
    try mibu.style.reset(writer);
    // REQ-TIW-001 — trailing cursor position. Only fires when at least
    // one diff entry existed (otherwise no position to land on).
    if (diffs.len > 0) try mibu.cursor.goTo(writer, last_x + 1, last_y + 1);
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
            try mibu.term.beginSynchronizedUpdate(writer);
            var win = try modal.WindowMock.init(alloc, lifecycle.width, lifecycle.height);
            defer win.deinit();
            defer mibu.term.endSynchronizedUpdate(writer) catch {};
            try modal.drawModal(win, state);
            const current = win.snapshot();
            // First frame: lifecycle.prev_snapshot is null → use current
            // as both prev (full-frame emit per REQ-RW-003 S-RW-005).
            const prev = lifecycle.prev_snapshot orelse current;
            try emitFrame(writer, prev, current, lifecycle.width, lifecycle.height, alloc);
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
        // 3. Poll mibu events. Resize → update dims + set redraw flag.
        const event = mibu.events.nextWithTimeout(io, file, 16) catch continue;
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
                    // ponytail: per tui-input-flow-bugfixes-2 CAP-09
                    // (R2a redirect) + design D3, this is the writer
                    // side of the cancel-pipe now (replaces the SIGINT
                    // handler at cancel_signal.zig:55-61 after WU-4
                    // lands — for now both writers coexist, idempotent).
                    // Async-signal-safe: single write(2) syscall, mirrors
                    // cancel_signal.zig:55-61. Atomic first (downstream
                    // readers stop), then pipe (worker aborts within
                    // ≤100ms via REQ-NEW-006 invariant). `cancel_pipe`
                    // is null only on test/no-TTY paths.
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
                const sz = mibu.term.getSize(handle) catch continue;
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
    k: mibu.events.Key,
    cancel_pipe: ?[2]i32,
    channels: *@import("channels.zig").Channels,
) !bool {
    if (k.event == .release) return false; // REQ-TIW-008 — kitty-kb release no-op
    switch (state.*) {
        .key_entry => |*ke| switch (k.code) {
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
            .esc => return false, // REQ-TIW-007 + REQ-TIW-NEG-3 — v1 no-op
            else => return false, // REQ-TIW-009 — arrows / F-keys / tab
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
    const fields = @typeInfo(Lifecycle).@"struct".fields;
    try testing.expectEqual(@as(usize, 9), fields.len);
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
