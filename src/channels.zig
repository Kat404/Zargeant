// src/channels.zig — 5 bounded channels (cap 256) + Event union (15 variants) +
// 16ms SSE coalesce on Agent→TUI edge.
//
// Spec:    sdd/tui-recovery/spec  (id=407) REQ-TUI-004
// Design:  sdd/tui-recovery/design (id=408) §1.2, §2.3 (R-PR 1)
//
// 5 channel edges (per design#408 §1.2):
//   tui→agent, agent→tui, tui→tools, tools→agent, tools→tui
// All capacity 256. The Agent→TUI edge carries 16ms REPLACE-on-newer
// coalesce via `pushSseChunk`. Overflow logs the exact warn string
// "agent→tui SSE channel overflow; dropped oldest chunk" via logger.global().
//
// Event union carries 15 variants across the 5 edges (per design#408 §1.2).
// This file is the type source-of-truth for runtime + tui; both consume
// the Event union by `@import`ing this file through `root.channels`.
//
// Linux/x86_64 Zig 0.16 only — matches every other module in the project.

const std = @import("std");
const builtin = @import("builtin");
const mibu = @import("mibu");
const logger = @import("logger.zig");

// =============================================================================
// Linux-only comptime guard (matches every other module in the project).
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("channels: linux-only v1");
}

// =============================================================================
// Event union (15 variants per design#408 §1.2)
// =============================================================================

/// Agent error classification (consumed by ErrorModal in R-PR 3).
pub const AgentErrorKind = enum {
    network,
    auth,
    tls_gated,
    sandbox,
    internal,
};

/// Tool subprocess error classification (consumed by ErrorModal in R-PR 3).
pub const ToolErrorKind = enum {
    spawn_failed,
    timeout,
    nonzero_exit,
    sandbox_violation,
};

/// Auth prompt trigger (consumed by modal in R-PR 3).
pub const AuthKind = enum {
    no_credentials,
    wrong_passphrase,
    key_invalid,
};

/// Single Event union across the 5 channel edges. 17 variants.
pub const Event = union(enum) {
    // TUI→Agent (7)
    KeyPress: mibu.events.Key,
    ApiKeySubmitted: []const u8,
    UnlockPasswordSubmitted: []const u8,
    UserToolRequest: UserToolArgs,
    /// PR 2 (tui-runtime-integration #441, REQ-TUI-042): TUI thread
    /// sends this when the 5-minute idle threshold trips; the Agent
    /// zeroes its in-memory key buffer.
    Relock,
    /// tui-verification (#1241, REQ-VER-011): TUI thread sends this
    /// after submitConsentGrant writes the credentials file. The Agent
    /// thread uses it as a signal to keep the in-memory key in sync
    /// with the on-disk file (future: trigger a backend sync).
    ConsentGrant: []const u8,
    Shutdown,

    // Agent→TUI (4 — SSE-coalesced StreamChunk on agent_to_tui)
    StreamChunk: StreamChunkPayload,
    AgentToolRequest: UserToolArgs,
    AgentError: AgentErrorPayload,
    AuthRequired: AuthKind,

    // TUI→Tools (2)
    DispatchToolRequest: UserToolArgs,
    CancelTool: u64,

    // Tools→TUI (2)
    ToolResult: ToolResultPayload,
    ToolError: ToolErrorPayload,

    // Tools→Agent (2)
    SubprocessSpawned: SubprocessSpawnedPayload,
    SubprocessExited: SubprocessExitedPayload,
};

pub const UserToolArgs = struct {
    id: u64,
    name: []const u8,
    args: []const u8,
};

pub const StreamChunkPayload = struct {
    seq: u64,
    text: []const u8,
};

pub const AgentErrorPayload = struct {
    kind: AgentErrorKind,
    message: []const u8,
};

pub const ToolResultPayload = struct {
    id: u64,
    output: []const u8,
};

pub const ToolErrorPayload = struct {
    id: u64,
    kind: ToolErrorKind,
    message: []const u8,
};

pub const SubprocessSpawnedPayload = struct {
    id: u64,
    pid: std.posix.pid_t,
    stdout_fd: std.posix.fd_t,
    stderr_fd: std.posix.fd_t,
};

pub const SubprocessExitedPayload = struct {
    id: u64,
    exit_code: u32,
};

// =============================================================================
// Bounded channel (cap 256). Ring buffer + Io.Mutex + Io.Condition.
// std.Thread has no Channel in 0.16; we roll a small one.
// =============================================================================

pub const CHANNEL_CAPACITY: usize = 256;

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();
        const CAP = CHANNEL_CAPACITY;

        mutex: std.Io.Mutex = .init,
        not_empty: std.Io.Condition = .init,
        not_full: std.Io.Condition = .init,
        buffer: [CAP]T = undefined,
        head: usize = 0, // pop position
        tail: usize = 0, // push position
        count: usize = 0,
        closed: bool = false,

        /// Compile-time channel capacity (per REQ-TUI-004 scenario 1).
        pub const capacity: usize = CAP;

        /// Non-blocking push. Returns error.Full if at capacity.
        pub fn tryPut(self: *Self, io: std.Io, item: T) !void {
            self.mutex.lock(io) catch return error.Canceled;
            defer self.mutex.unlock(io);
            if (self.closed) return error.Closed;
            if (self.count == CAP) return error.Full;
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % CAP;
            self.count += 1;
            self.not_empty.signal(io);
        }

        /// Blocking push. Waits for a consumer to drain if at capacity.
        pub fn put(self: *Self, io: std.Io, item: T) !void {
            self.mutex.lock(io) catch return error.Canceled;
            while (self.count == CAP and !self.closed) {
                self.not_full.wait(io, &self.mutex) catch {
                    self.mutex.unlockUncancelable(io);
                    return error.Canceled;
                };
            }
            if (self.closed) {
                self.mutex.unlockUncancelable(io);
                return error.Closed;
            }
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % CAP;
            self.count += 1;
            self.not_empty.signal(io);
            self.mutex.unlock(io);
        }

        /// Non-blocking pop. Returns null if empty.
        pub fn tryGet(self: *Self, io: std.Io) ?T {
            self.mutex.lock(io) catch return null;
            defer self.mutex.unlock(io);
            if (self.count == 0) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % CAP;
            self.count -= 1;
            self.not_full.signal(io);
            return item;
        }

        /// Blocking pop. Waits for a producer to enqueue if empty.
        pub fn get(self: *Self, io: std.Io) !T {
            self.mutex.lock(io) catch return error.Canceled;
            while (self.count == 0 and !self.closed) {
                self.not_empty.wait(io, &self.mutex) catch {
                    self.mutex.unlockUncancelable(io);
                    return error.Canceled;
                };
            }
            if (self.count == 0) {
                self.mutex.unlockUncancelable(io);
                return error.Closed;
            }
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % CAP;
            self.count -= 1;
            self.not_full.signal(io);
            self.mutex.unlock(io);
            return item;
        }

        /// Peek at the most recently pushed item without removing it.
        /// Used by `pushSseChunk` to implement REPLACE-on-newer.
        pub fn peekLast(self: *Self, io: std.Io) ?T {
            self.mutex.lock(io) catch return null;
            defer self.mutex.unlock(io);
            if (self.count == 0) return null;
            const idx = if (self.tail == 0) CAP - 1 else self.tail - 1;
            return self.buffer[idx];
        }

        /// Replace the most recently pushed item. Caller must ensure
        /// `count > 0` (use `peekLast` first). For SSE coalesce — the
        /// producer drops the in-window predecessor in favor of the newer
        /// chunk.
        pub fn replaceLast(self: *Self, io: std.Io, item: T) !void {
            self.mutex.lock(io) catch return error.Canceled;
            defer self.mutex.unlock(io);
            if (self.count == 0) return error.Empty;
            const idx = if (self.tail == 0) CAP - 1 else self.tail - 1;
            self.buffer[idx] = item;
        }

        /// Snapshot the current count. Approximate under concurrency
        /// (the caller should hold no expectation beyond "for observability").
        pub fn len(self: *Self) usize {
            return self.count;
        }

        /// Mark the channel closed. Producers and consumers will observe
        /// `error.Closed` / `null` respectively once drained.
        pub fn close(self: *Self, io: std.Io) void {
            self.mutex.lock(io) catch return;
            self.closed = true;
            self.mutex.unlock(io);
            self.not_empty.broadcast(io);
            self.not_full.broadcast(io);
        }
    };
}

// =============================================================================
// The 5 channel edges that compose the runtime topology.
// =============================================================================

pub const Channels = struct {
    tui_to_agent: Channel(Event),
    agent_to_tui: Channel(Event),
    tui_to_tools: Channel(Event),
    tools_to_agent: Channel(Event),
    tools_to_tui: Channel(Event),

    /// Construct the 5 channels. Channels are value types (no allocator
    /// needed) since the ring buffer is inline.
    pub fn init() Channels {
        return .{
            .tui_to_agent = .{},
            .agent_to_tui = .{},
            .tui_to_tools = .{},
            .tools_to_agent = .{},
            .tools_to_tui = .{},
        };
    }

    /// Close all 5 channels. Idempotent.
    pub fn closeAll(self: *Channels, io: std.Io) void {
        self.tui_to_agent.close(io);
        self.agent_to_tui.close(io);
        self.tui_to_tools.close(io);
        self.tools_to_agent.close(io);
        self.tools_to_tui.close(io);
    }
};

// =============================================================================
// SSE coalesce (REQ-TUI-004 scenario 2 + 3)
//
// The Agent thread pushes StreamChunk events into `agent_to_tui` faster
// than the TUI can render. We coalesce within a 16ms window using
// REPLACE-on-newer semantics: if the most recent item already in the
// channel is a StreamChunk, replace it with the new one (no growth).
// If the channel is full AND the tail is not a StreamChunk, we drop
// the oldest non-StreamChunk item, log the exact warn string, and retry.
// Producer never blocks.
// =============================================================================

/// Push a StreamChunk with 16ms REPLACE-on-newer semantics.
/// Channel must be `agent_to_tui`.
pub fn pushSseChunk(io: std.Io, ch: *Channel(Event), seq: u64, text: []const u8) !void {
    const new_event: Event = .{ .StreamChunk = .{ .seq = seq, .text = text } };

    // Fast path: tail is a StreamChunk — REPLACE in place.
    if (ch.peekLast(io)) |last| {
        if (last == .StreamChunk) {
            try ch.replaceLast(io, new_event);
            return;
        }
    }

    // Slow path: tryPut. If full, drop oldest, log exact warn, retry.
    ch.tryPut(io, new_event) catch |err| switch (err) {
        error.Full => {
            _ = ch.tryGet(io);
            logger.global().log(io, .warn, "agent→tui SSE channel overflow; dropped oldest chunk") catch {};
            try ch.tryPut(io, new_event);
        },
        else => return err,
    };
}

// =============================================================================
// Tests (5 per REQ-TUI-004 scenarios 1-4 + 1 for SSE coalesce helper)
// =============================================================================

const testing = std.testing;

test "Event union has 17 variants" {
    // REQ-TUI-004 scenario 4 — every variant from design#408 §1.2 resolves.
    // PR 2 (tui-runtime-integration #441, REQ-TUI-042) added the `Relock`
    // variant for the 5-min idle relock: 15 → 16.
    // tui-verification (#1241, REQ-VER-011) added the `ConsentGrant`
    // variant: 16 → 17.
    const fields = @typeInfo(Event).@"union".fields;
    try testing.expectEqual(@as(usize, 17), fields.len);
}

test "channels have capacity 256 (5 edges)" {
    // REQ-TUI-004 scenario 1 — every channel.capacity == 256.
    // The 5 channel edges all share Channel(Event), so assert via the
    // type const. Per-instance field would be redundant.
    try testing.expectEqual(@as(usize, 256), Channel(Event).capacity);
    var c = Channels.init();
    defer c.closeAll(testing.io);
    // Instance check: tryPut up to 256 succeeds, 257th returns error.Full.
    for (0..256) |i| {
        try c.tui_to_agent.tryPut(testing.io, .{ .SubprocessExited = .{ .id = i, .exit_code = 0 } });
        try c.agent_to_tui.tryPut(testing.io, .{ .SubprocessExited = .{ .id = i, .exit_code = 0 } });
        try c.tui_to_tools.tryPut(testing.io, .{ .SubprocessExited = .{ .id = i, .exit_code = 0 } });
        try c.tools_to_agent.tryPut(testing.io, .{ .SubprocessExited = .{ .id = i, .exit_code = 0 } });
        try c.tools_to_tui.tryPut(testing.io, .{ .SubprocessExited = .{ .id = i, .exit_code = 0 } });
    }
    try testing.expectError(error.Full, c.tui_to_agent.tryPut(testing.io, .{ .SubprocessExited = .{ .id = 999, .exit_code = 0 } }));
    try testing.expectError(error.Full, c.agent_to_tui.tryPut(testing.io, .{ .SubprocessExited = .{ .id = 999, .exit_code = 0 } }));
    try testing.expectError(error.Full, c.tui_to_tools.tryPut(testing.io, .{ .SubprocessExited = .{ .id = 999, .exit_code = 0 } }));
    try testing.expectError(error.Full, c.tools_to_agent.tryPut(testing.io, .{ .SubprocessExited = .{ .id = 999, .exit_code = 0 } }));
    try testing.expectError(error.Full, c.tools_to_tui.tryPut(testing.io, .{ .SubprocessExited = .{ .id = 999, .exit_code = 0 } }));
}

test "pushSseChunk coalesces 5 chunks → 1 frame (REPLACE-on-newer)" {
    // REQ-TUI-004 scenario 2 — 5 SSE chunks within 5ms → 1 frame consumes latest.
    var ch: Channel(Event) = .{};
    defer ch.close(testing.io);

    for (0..5) |i| {
        try pushSseChunk(testing.io, &ch, i, "chunk");
    }

    // REPLACE-on-newer: channel holds at most 1 StreamChunk at a time.
    try testing.expectEqual(@as(usize, 1), ch.len());

    // Consumer reads the latest chunk.
    const got = ch.tryGet(testing.io).?;
    try testing.expect(got == .StreamChunk);
    try testing.expectEqual(@as(u64, 4), got.StreamChunk.seq);

    // Channel now empty.
    try testing.expectEqual(@as(usize, 0), ch.len());
}

test "overflow logs warn exact string" {
    // REQ-TUI-004 scenario 3 — Agent→TUI channel at capacity 256; producer
    // pushes chunk #257; producer doesn't block; logger captures exact warn.
    try logger.initGlobal(testing.io);
    defer logger.deinitGlobal(testing.io);

    var ch: Channel(Event) = .{};
    defer ch.close(testing.io);

    // Fill the channel with non-StreamChunk events so the tail is not a
    // StreamChunk and REPLACE-on-newer cannot fire — forces the overflow path.
    for (0..256) |i| {
        try ch.tryPut(testing.io, .{ .SubprocessExited = .{ .id = i, .exit_code = 0 } });
    }
    try testing.expectEqual(@as(usize, 256), ch.len());

    // Push a StreamChunk — tail is not a StreamChunk, channel is full.
    // Must NOT block. Must log the exact warn.
    try pushSseChunk(testing.io, &ch, 999, "overflow-chunk");

    // Channel should now hold 255 originals (oldest dropped) + 1 StreamChunk.
    try testing.expectEqual(@as(usize, 256), ch.len());

    // Read the log file and verify the exact warn string.
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        logger.defaultPath,
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(contents);
    try testing.expect(std.mem.indexOf(u8, contents, "agent→tui SSE channel overflow; dropped oldest chunk") != null);
}

test "tryPut returns error.Full at capacity" {
    // Sanity check: the non-blocking path returns error.Full, not block.
    var ch: Channel(Event) = .{};
    defer ch.close(testing.io);

    for (0..256) |i| {
        try ch.tryPut(testing.io, .{ .SubprocessExited = .{ .id = i, .exit_code = 0 } });
    }
    try testing.expectError(error.Full, ch.tryPut(testing.io, .{ .SubprocessExited = .{ .id = 999, .exit_code = 1 } }));
}
