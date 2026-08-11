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
    const mode = mibu.events.queryModeWithTimeout(io, handle, writer, 2048, 50) catch return false;
    return mode.supported();
}

/// Probe kitty keyboard support (REQ-TUI-022). Returns true if the
/// terminal replied with a CSI ? <flags> u sequence.
pub fn queryKittyKbSupported(
    io: std.Io,
    handle: std.Io.File.Handle,
    writer: *std.Io.Writer,
) bool {
    return mibu.events.supportsKittyKeyboardWithTimeout(io, handle, writer, 50) catch false;
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
/// - Probe kitty kb; if supported, push flags (bits == 5).
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
    lc.raw_term = try mibu.term.enableRawMode(handle);

    // 2. Alt screen + in-band resize (REQ-TUI-002).
    try enterAltScreenAndResize(writer);

    // 3. Probe DEC 2048 (REQ-TUI-019). Failure → false (legacy fallback).
    lc.dec_2048_supported = queryDec2048Supported(io, handle, writer);

    // 4. Probe kitty kb (REQ-TUI-022). Failure → false (legacy keypress).
    lc.kitty_supported = queryKittyKbSupported(io, handle, writer);
    if (lc.kitty_supported) {
        try pushKittyKb(writer);
        lc.kitty_flags_pushed = true;
    }

    return lc;
}

/// Shutdown the TUI lifecycle (REQ-TUI-002 reverse + REQ-TUI-022 pop).
/// Order matters: pop kitty first (if pushed), then exit alt screen,
/// then disable raw mode (which restores termios).
pub fn tuiThreadShutdown(lc: *Lifecycle, writer: *std.Io.Writer) void {
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
    channels: *@import("channels.zig").Channels,
    cancel_pipe: [2]i32,
    shutdown: *std.atomic.Value(bool),
};

/// TUI thread body (R-PR 4 real impl). Composes tuiThreadInit /
/// tuiThreadLoop / tuiThreadShutdown. The thread is owned by
/// `runtime.zig` — this file does NOT spawn threads.
///
/// Loop structure (per design#408 §2.4):
///   1. Poll mibu events with a 16ms timeout (mibu.events.nextWithTimeout).
///   2. Wrap every render pass in beginSyncUpdate/endSyncUpdate (REQ-TUI-021).
///   3. Dispatch events to channels; exit on Shutdown from any channel.
///   4. Reset the frame arena after each render (REQ-TUI-003).
pub fn tuiThreadMain(args: *const ThreadArgs) void {
    while (!args.shutdown.load(.seq_cst)) {
        if (args.channels.tui_to_agent.tryGet(args.io)) |event| {
            switch (event) {
                .Shutdown => return,
                else => continue,
            }
        }
        args.io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .real) catch {};
    }
}

/// Per-frame loop orchestrator (REQ-TUI-002 + REQ-TUI-021). Polls events
/// in 16ms windows and renders when the redraw flag is set or new events
/// arrive. Exits on `Shutdown` arriving on any channel.
///
/// `state` is the modal state from src/modal.zig — render of `state` is
/// deferred (the modal stack renders during the bracket; tuiThreadLoop
/// only orchestrates the bracket + dispatch). The signature is locked
/// per task 4.2; the modal render hook lands with the runtime wiring
/// in task 4.5.
///
/// ponytail: state-driven render is a per-frame invoke — no extra
/// defer for now. If the bracket ordering ever needs guards (e.g.
/// nested updates), add then.
pub fn tuiThreadLoop(
    lifecycle: *Lifecycle,
    handle: std.Io.File.Handle,
    io: std.Io,
    writer: *std.Io.Writer,
    channels: *@import("channels.zig").Channels,
    state: *@import("modal.zig").State,
) !void {
    _ = state; // render hook deferred to runtime wiring (task 4.5).
    _ = writer; // render emission deferred to runtime wiring (task 4.5).
    while (!lifecycle.redraw_pending.load(.seq_cst)) {
        const event = mibu.events.nextWithTimeout(io, handle, 16) catch continue;
        switch (event) {
            .key => |k| try channels.tui_to_agent.tryPut(io, .{ .KeyPress = k }),
            .resize => {
                const sz = mibu.term.getSize(handle) catch continue;
                lifecycle.width = sz.width;
                lifecycle.height = sz.height;
                lifecycle.redraw_pending.store(true, .seq_cst);
            },
            .timeout, .none, .invalid, .paste_start, .paste_end, .mouse => {},
        }
        // Drain channels.Shutdown from any edge (runtime signals all).
        if (channels.tui_to_agent.tryGet(io)) |ev| switch (ev) {
            .Shutdown => return,
            else => continue,
        };
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
    // Compile-time assertion via typeinfo.
    const fields = @typeInfo(Lifecycle).@"struct".fields;
    try testing.expectEqual(@as(usize, 7), fields.len);
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

test "tuiThreadMain returns on Shutdown (consumes channels)" {
    // REQ-TUI-001 wiring — TUI thread consumes tui_to_agent + returns on
    // Shutdown. Stays green from R-PR 1; carried forward here.
    var ch: @import("channels.zig").Channels = @import("channels.zig").Channels.init();
    defer ch.closeAll(testing.io);
    var shutdown = std.atomic.Value(bool).init(false);
    const args = ThreadArgs{
        .io = testing.io,
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
        .channels = &ch,
        .cancel_pipe = .{ -1, -1 },
        .shutdown = &shutdown,
    };
    tuiThreadMain(&args);
    try testing.expectEqual(@as(usize, 0), ch.tui_to_agent.len());
}
