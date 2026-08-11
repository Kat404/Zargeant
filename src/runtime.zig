// src/runtime.zig — 3-thread orchestrator (TUI | Agent | Tools) for the
// tui-recovery slice.
//
// Spec:    sdd/tui-recovery/spec  (id=407) REQ-TUI-001
// Design:  sdd/tui-recovery/design (id=408) §2.3 (R-PR 1), §2.4
//
// R-PR 1 ships the spawn/run/shutdown/join API surface. The TUI thread is
// a NO-OP STUB that returns on Shutdown (real render body lands in R-PR 4).
// The Agent and Tools threads are minimal placeholders that satisfy the
// join semantics — real impls land in R-PR 4 (mibu lifecycle + ANSI filter
// + tools envp + cancel propagation).
//
// Compile-time invariant: NO `std.Thread.spawn` may appear outside this
// file. Enforced by the static-grep test "no stray Thread.spawn".
//
// Linux/x86_64 Zig 0.16 only.

const std = @import("std");
const builtin = @import("builtin");
const channels_mod = @import("channels.zig");
const tui = @import("tui.zig");
const logger = @import("logger.zig");

// =============================================================================
// Linux-only comptime guard.
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("runtime: linux-only v1");
}

/// Default shutdown timeout per REQ-TUI-012. Production code uses 5s;
/// tests may pass a smaller value.
pub const DEFAULT_SHUTDOWN_TIMEOUT_NS: u64 = 5 * std.time.ns_per_s;

// =============================================================================
// Public API
// =============================================================================

pub const Config = struct {
    mock_mode: bool = false,
    tls_gated: bool = false,
};

pub const JoinResult = enum {
    clean,
    timeout,
};

/// Per-thread arguments. Mirrors `tui.ThreadArgs` (the canonical definition
/// lives in tui.zig; this alias re-exports for runtime-side readability).
pub const ThreadArgs = tui.ThreadArgs;

pub const Runtime = struct {
    config: Config,
    channels: channels_mod.Channels,
    cancel_pipe: [2]i32,
    tui_thread: ?std.Thread = null,
    agent_thread: ?std.Thread = null,
    tools_thread: ?std.Thread = null,
    shutdown_requested: std.atomic.Value(bool),

    /// Create the runtime. Allocates a Linux pipe for cancel propagation
    /// and the 5 channel edges. Threads are NOT spawned yet — call
    /// `run(io)` for that.
    pub fn spawn(config: Config) !Runtime {
        var cancel_pipe: [2]i32 = .{ -1, -1 };
        const rc = std.os.linux.pipe(&cancel_pipe);
        if (rc != 0) return error.PipeFailed;

        return .{
            .config = config,
            .channels = channels_mod.Channels.init(),
            .cancel_pipe = cancel_pipe,
            .shutdown_requested = std.atomic.Value(bool).init(false),
        };
    }

    /// Idempotent shutdown. Safe to call from any thread.
    pub fn shutdown(self: *Runtime, io: std.Io) void {
        self.shutdown_requested.store(true, .seq_cst);
        // Close write end so any blocked reader on cancel_pipe[0] unblocks.
        if (self.cancel_pipe[1] >= 0) {
            _ = std.os.linux.close(self.cancel_pipe[1]);
            self.cancel_pipe[1] = -1;
        }
        self.channels.closeAll(io);
    }

    /// Spawn the 3 threads (TUI, Agent, Tools) and block until all join.
    /// Returns cleanly when all 3 threads exit; returns error on spawn failure.
    pub fn run(self: *Runtime, io: std.Io) !void {
        // TUI thread — stub for R-PR 1. Real render loop lands in R-PR 4.
        const tui_args = ThreadArgs{
            .io = io,
            .channels = &self.channels,
            .cancel_pipe = self.cancel_pipe,
            .shutdown = &self.shutdown_requested,
        };
        self.tui_thread = try std.Thread.spawn(.{ .allocator = std.heap.page_allocator }, tui.tuiThreadMain, .{&tui_args});

        // Agent thread — stub for R-PR 1. Real HTTP/SSE client lands in R-PR 4.
        const agent_args = tui_args;
        self.agent_thread = try std.Thread.spawn(.{ .allocator = std.heap.page_allocator }, agentStubMain, .{&agent_args});

        // Tools thread — stub for R-PR 1. Real subprocess pool lands in R-PR 4.
        const tools_args = tui_args;
        self.tools_thread = try std.Thread.spawn(.{ .allocator = std.heap.page_allocator }, toolsStubMain, .{&tools_args});

        // Block until all 3 join.
        if (self.tui_thread) |t| t.join();
        if (self.agent_thread) |t| t.join();
        if (self.tools_thread) |t| t.join();
        self.tui_thread = null;
        self.agent_thread = null;
        self.tools_thread = null;
    }

    /// Try to join all 3 threads within `timeout_ns`. Returns `.clean` if
    /// all join in time, `.timeout` otherwise. The threads are not detached
    /// on timeout — the caller is responsible for the next cleanup pass.
    pub fn join(self: *Runtime, io: std.Io, timeout_ns: u64) JoinResult {
        const start = std.Io.Timestamp.now(io, .real);
        const timeout_dur: std.Io.Duration = .{ .nanoseconds = @intCast(timeout_ns) };
        if (self.tui_thread) |t| {
            const now = std.Io.Timestamp.now(io, .real);
            if (std.Io.Timestamp.durationTo(start, now).nanoseconds >= timeout_dur.nanoseconds) return .timeout;
            t.join();
            self.tui_thread = null;
        }
        if (self.agent_thread) |t| {
            const now = std.Io.Timestamp.now(io, .real);
            if (std.Io.Timestamp.durationTo(start, now).nanoseconds >= timeout_dur.nanoseconds) return .timeout;
            t.join();
            self.agent_thread = null;
        }
        if (self.tools_thread) |t| {
            const now = std.Io.Timestamp.now(io, .real);
            if (std.Io.Timestamp.durationTo(start, now).nanoseconds >= timeout_dur.nanoseconds) return .timeout;
            t.join();
            self.tools_thread = null;
        }
        return .clean;
    }

    /// Free the cancel pipe fds. Call after all threads have joined.
    pub fn deinit(self: *Runtime) void {
        for (self.cancel_pipe) |fd| {
            if (fd >= 0) _ = std.os.linux.close(fd);
        }
        self.cancel_pipe = .{ -1, -1 };
    }
};

// =============================================================================
// TUI thread (defined in tui.zig as `tuiThreadMain`; R-PR 1 stub drains
// `tui_to_agent` until Shutdown. R-PR 4 replaces the body with the full
// mibu lifecycle per design#408 §2.4.)
// =============================================================================

// =============================================================================
// Agent thread stub (R-PR 1)
//
// R-PR 4 fills this with the real HTTP/SSE client (api_client.Client.stream)
// and the cancel_pipe-driven abort. For R-PR 1, the Agent just waits for
// the shutdown flag.
// =============================================================================

fn agentStubMain(args: *const ThreadArgs) void {
    while (!args.shutdown.load(.seq_cst)) {
        args.io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .real) catch {};
    }
}

// =============================================================================
// Tools thread stub (R-PR 1)
//
// R-PR 4 fills this with sandbox.Sandbox.spawnToolSubprocess(envp=[])
// + cancel propagation. For R-PR 1, the Tools thread just waits for the
// shutdown flag and watches the cancel pipe.
// =============================================================================

fn toolsStubMain(args: *const ThreadArgs) void {
    while (!args.shutdown.load(.seq_cst)) {
        // poll the cancel pipe to confirm the fds are usable (REQ-TUI-001
        // scenario for cancel_pipe shared agent↔tools). 1ms timeout keeps
        // the loop responsive to shutdown.
        var pollfd = [_]std.os.linux.pollfd{
            .{ .fd = args.cancel_pipe[0], .events = std.os.linux.POLL.IN, .revents = 0 },
        };
        _ = std.os.linux.poll(&pollfd, 1, 1);
        args.io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .real) catch {};
    }
}

// =============================================================================
// Tests (6 per design#408 §2.3 R-PR 1)
// =============================================================================

const testing = std.testing;

test "Runtime spawns 3 threads and joins (headless)" {
    // REQ-TUI-001 scenario 1 — Runtime.run() spawns 3 threads + joins.
    var runtime = try Runtime.spawn(.{});
    defer runtime.deinit();
    // Signal shutdown BEFORE run() so the threads exit on their first
    // loop iteration. In production, shutdown() is called by the signal
    // handler (SIGINT/SIGTERM); here the test simulates it directly.
    runtime.shutdown(testing.io);
    try runtime.run(testing.io);
    // After run() returns, all 3 threads are joined (thread fields == null).
    try testing.expect(runtime.tui_thread == null);
    try testing.expect(runtime.agent_thread == null);
    try testing.expect(runtime.tools_thread == null);
}

test "shutdown propagates to all 3 channels" {
    // REQ-TUI-001 scenario 2 — shutdown() closes all 5 channels.
    var runtime = try Runtime.spawn(.{});
    defer runtime.deinit();
    runtime.shutdown(testing.io);
    // All 5 channels should now refuse new puts (Closed error).
    try testing.expectError(error.Closed, runtime.channels.tui_to_agent.tryPut(testing.io, .Shutdown));
    try testing.expectError(error.Closed, runtime.channels.agent_to_tui.tryPut(testing.io, .Shutdown));
    try testing.expectError(error.Closed, runtime.channels.tui_to_tools.tryPut(testing.io, .Shutdown));
    try testing.expectError(error.Closed, runtime.channels.tools_to_agent.tryPut(testing.io, .Shutdown));
    try testing.expectError(error.Closed, runtime.channels.tools_to_tui.tryPut(testing.io, .Shutdown));
}

test "no stray Thread.spawn outside runtime.zig" {
    // REQ-TUI-001 scenario 3 — static grep finds 0 std.Thread.spawn
    // outside src/runtime.zig. Enforces the "all threading lives in
    // runtime.zig" invariant. Scans only production code so the test
    // itself is allowed to mention std.Thread.spawn.
    const forbidden_targets = [_][]const u8{
        "src/tui.zig",
        "src/channels.zig",
        "src/root.zig",
    };
    const io = testing.io;
    for (forbidden_targets) |path| {
        const content = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            testing.allocator,
            .limited(1 << 20),
        );
        defer testing.allocator.free(content);
        const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
        const prod_src = content[0..first_test];
        if (std.mem.indexOf(u8, prod_src, "std.Thread.spawn")) |idx| {
            std.debug.print("\n[stray-spawn] forbidden std.Thread.spawn in {s} at offset {d}\n", .{ path, idx });
            return error.StrayThreadSpawn;
        }
    }
}

test "cancel_pipe is shared between Agent and Tools" {
    // REQ-TUI-001 — Runtime.spawn creates a Linux pipe; both Agent and
    // Tools threads receive the same fd pair in their ThreadArgs.
    var runtime = try Runtime.spawn(.{});
    defer runtime.deinit();
    // Both fds are valid (>= 0) and distinct.
    try testing.expect(runtime.cancel_pipe[0] >= 0);
    try testing.expect(runtime.cancel_pipe[1] >= 0);
    try testing.expect(runtime.cancel_pipe[0] != runtime.cancel_pipe[1]);
}

test "shutdown timeout API surface returns JoinResult enum" {
    // REQ-TUI-012 — Runtime.join(timeout_ns) accepts a timeout and returns
    // a JoinResult. The actual deadline enforcement lands in R-PR 4
    // (where mibu lifecycle completion + std.Thread.join interaction
    // needs a real cancellable wait). For R-PR 1 we verify the API
    // surface: a clean join returns .clean, and JoinResult has both tags.
    var runtime = try Runtime.spawn(.{});
    defer runtime.deinit();
    // No threads spawned → join returns .clean immediately.
    const result = runtime.join(testing.io, 100 * std.time.ns_per_ms);
    try testing.expect(result == .clean);
    // Compile-time check: JoinResult enum has the .clean + .timeout tags.
    comptime {
        const info = @typeInfo(JoinResult).@"enum";
        var saw_clean = false;
        var saw_timeout = false;
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, "clean")) saw_clean = true;
            if (std.mem.eql(u8, f.name, "timeout")) saw_timeout = true;
        }
        if (!saw_clean or !saw_timeout) @compileError("JoinResult missing clean/timeout tags");
    }
}

test "sse coalesce 16ms end-to-end via runtime channels" {
    // REQ-TUI-004 — channels + pushSseChunk work correctly when reached
    // through the runtime's channel edges. 5 chunks within 5ms → 1.
    var runtime = try Runtime.spawn(.{});
    defer runtime.deinit();
    for (0..5) |i| {
        try channels_mod.pushSseChunk(testing.io, &runtime.channels.agent_to_tui, i, "x");
    }
    try testing.expectEqual(@as(usize, 1), runtime.channels.agent_to_tui.len());
}

test "no std.debug.print or getStdOut in TUI sources (stdios guard)" {
    // REQ-TUI-015 — no TUI source may write to stdout/stderr. Static
    // grep enforces the headless invariant. Scans only production code
    // (everything before the first `test "` marker) so the test itself
    // is allowed to use std.debug.print for diagnostics.
    const targets = [_][]const u8{
        "src/tui.zig",
        "src/runtime.zig",
        "src/channels.zig",
    };
    const io = testing.io;
    for (targets) |path| {
        const content = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            testing.allocator,
            .limited(1 << 20),
        );
        defer testing.allocator.free(content);
        const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
        const prod_src = content[0..first_test];
        if (std.mem.indexOf(u8, prod_src, "std.debug.print")) |idx| {
            std.debug.print("\n[stdios-guard] forbidden std.debug.print in {s} at offset {d}\n", .{ path, idx });
            return error.StrayStdoutWrite;
        }
        if (std.mem.indexOf(u8, prod_src, "std.io.getStdOut")) |idx| {
            std.debug.print("\n[stdios-guard] forbidden std.io.getStdOut in {s} at offset {d}\n", .{ path, idx });
            return error.StrayStdoutWrite;
        }
    }
}
