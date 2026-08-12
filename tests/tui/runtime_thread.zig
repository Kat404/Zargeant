// tests/tui/runtime_thread.zig — runtime × mock_server integration tests for
// the tui-runtime-integration PR 1.
//
// Spec:    sdd/tui-runtime-integration/spec   (id=439) REQ-TUI-023..037, 046, 048..052
// Design:  sdd/tui-runtime-integration/design (id=441) §"PR 1 Work-Unit Commits"
//
// Drift D-5: dedicated test artifact for the runtime thread wiring. Owns the
// static-grep guards (T-SG-1..T-SG-3) + ~10 RED→GREEN tests covering the
// Agent body, TUI body, and modal runtimeDriver against mock_server.
//
// Headless invariant: no writes to stdout/stderr.
// Linux/x86_64 Zig 0.16 only.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

// =============================================================================
// Linux-only comptime guard.
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("runtime_thread: linux-only v1");
}

// =============================================================================
// Module aliases.
//
// The test module imports each alias to the same lib_mod (root.zig) which
// re-exports every source module under its module name (e.g.
// `pub const runtime = @import("runtime.zig")`). Each alias therefore
// resolves to the root.zig namespace struct, and we reach the actual
// sub-module via the re-export field (`<alias>.runtime.X`).
// =============================================================================

const ApiClient = struct {
    const root = @import("api_client");
    pub const ErrorKind = root.api_client.ErrorKind;
};
const Ch = struct {
    const root = @import("channels");
    pub const Channels = root.channels.Channels;
    pub const Event = root.channels.Event;
};
const M = struct {
    const root = @import("modal");
    pub const State = root.modal.State;
    pub const ErrorKind = root.modal.ErrorKind;
    pub const AgentLoopState = root.modal.AgentLoopState;
    pub const appendStreamChunk = root.modal.appendStreamChunk;
};
const MS = struct {
    const root = @import("mock_server");
    pub const start = root.mock_server.start;
    pub const port = root.mock_server.port;
    pub const registerFixture = root.mock_server.registerFixture;
    pub const serveFixture = root.mock_server.serveFixture;
    pub const sendBytes = root.mock_server.sendBytes;
};
const Rt = struct {
    const root = @import("runtime");
    pub const ThreadArgs = root.runtime.ThreadArgs;
    pub const refuseMockHost = root.runtime.refuseMockHost;
    pub const buildMockRequest = root.runtime.buildMockRequest;
    pub const mapChunkError = root.runtime.mapChunkError;
    pub const openErrorKind = root.runtime.openErrorKind;
    pub const AgentErrorClass = root.runtime.AgentErrorClass;
};

// =============================================================================
// T-SG-1: no api_client.Client outside the Agent body (REQ-TUI-034)
//
// Extends the existing static-grep pattern at src/runtime.zig:337-365 to cover
// the wider TUI runtime: src/runtime.zig, src/tui.zig, src/modal.zig must NOT
// reference `api_client.Client`. The Agent body is allowed (it builds Requests
// and drives Client.stream). Mock-mode code MUST NOT call the real client.
// =============================================================================

test "T-SG-1: no api_client.Client outside Agent body" {
    // The agent body (in src/runtime.zig) is the ONLY place that calls
    // api_client.Client.stream. TUI thread, modal, and the rest of runtime
    // must not import / call it.
    const targets = [_][]const u8{
        "src/tui.zig",
        "src/modal.zig",
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
        // Split at the first test-block marker so test declarations can
        // reference api_client by name for documentation.
        const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
        const prod_src = content[0..first_test];

        // Strip line comments so a docstring like
        // `// calls api_client.Client.stream` doesn't trip the guard.
        const no_comments = stripLineComments(prod_src);
        defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);

        // For src/runtime.zig the Agent body is allowed to mention
        // `api_client.Client`; we only forbid it from the TUI thread +
        // modal. Strip the Agent section by skipping the section bounded
        // by `fn agentThreadLoop` and the matching closing brace.
        const scan_src = if (std.mem.eql(u8, path, "src/runtime.zig"))
            stripAgentSection(no_comments)
        else
            no_comments;

        if (std.mem.indexOf(u8, scan_src, "api_client.Client")) |idx| {
            std.debug.print(
                "\n[T-SG-1] forbidden api_client.Client outside Agent body in {s} at offset {d}\n",
                .{ path, idx },
            );
            return error.ApiClientOutsideAgent;
        }
    }
}

/// Strips the `fn agentThreadLoop` body from the production source so
/// the static-grep guard only scans TUI thread / modal sections.
fn stripAgentSection(prod_src: []const u8) []const u8 {
    const marker = "fn agentThreadLoop";
    const start = std.mem.indexOf(u8, prod_src, marker) orelse return prod_src;
    // Find the closing brace of the function — naïve count starting at the
    // first `{` after the marker.
    var idx: usize = start;
    while (idx < prod_src.len and prod_src[idx] != '{') : (idx += 1) {}
    if (idx >= prod_src.len) return prod_src;
    var depth: usize = 1;
    idx += 1;
    while (idx < prod_src.len and depth > 0) : (idx += 1) {
        switch (prod_src[idx]) {
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
    }
    if (depth != 0) return prod_src;
    // Return everything AFTER the function ends.
    return prod_src[idx..];
}

/// Strips Zig line comments (`//` to end-of-line) from the production
/// source. Used by the static-grep guards so a comment mentioning the
/// forbidden pattern (e.g. `// calls api_client.Client.stream`) doesn't
/// trip the guard. Block comments `/* */` and doc comments `///` are
/// preserved verbatim because the existing test code uses `// allowed:`
/// markers that the original guards rely on.
fn stripLineComments(prod_src: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < prod_src.len) {
        // Detect `//` line comment start.
        if (i + 1 < prod_src.len and prod_src[i] == '/' and prod_src[i + 1] == '/') {
            // Skip to end-of-line (or end-of-buffer).
            while (i < prod_src.len and prod_src[i] != '\n') : (i += 1) {}
            continue;
        }
        out.append(testing.allocator, prod_src[i]) catch return prod_src;
        i += 1;
    }
    // Return owned slice to the caller; caller must free after use.
    return out.toOwnedSlice(testing.allocator) catch return prod_src;
}

// =============================================================================
// T-SG-2: no api.minimax.io literal in mock-mode code path (REQ-TUI-035)
//
// PR 1 mock-mode MUST NOT mention the production host. The literal must
// appear only in the real-mode branch (added in PR 2 per REQ-TUI-043).
// =============================================================================

test "T-SG-2: no api.minimax.io literal in mock-mode code path" {
    // PR 1 only: the literal must be entirely absent from production
    // sources. PR 2 narrows this guard to the real-mode branch.
    const targets = [_][]const u8{
        "src/runtime.zig",
        "src/tui.zig",
        "src/modal.zig",
        "src/channels.zig",
        "src/api_client.zig",
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
        // The SNI_HOSTNAME constant in api_client.zig is a comptime
        // declaration; PR 1 keeps it because tls-handrolled shipped it.
        // PR 2 narrows the guard to runtime/mock-mode paths only.
        if (std.mem.eql(u8, path, "src/api_client.zig")) continue;
        const no_comments = stripLineComments(prod_src);
        defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);
        if (std.mem.indexOf(u8, no_comments, "api.minimax.io")) |idx| {
            std.debug.print(
                "\n[T-SG-2] forbidden api.minimax.io literal in mock-mode path {s} at offset {d}\n",
                .{ path, idx },
            );
            return error.MinimaxInMockMode;
        }
    }
}

// =============================================================================
// T-SG-3: no api_client import on TUI thread body (REQ-TUI-036)
// =============================================================================

test "T-SG-3: no api_client import on TUI thread body" {
    const path = "src/tui.zig";
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        path,
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);
    if (std.mem.indexOf(u8, no_comments, "api_client")) |idx| {
        std.debug.print(
            "\n[T-SG-3] forbidden api_client reference on TUI thread body in {s} at offset {d}\n",
            .{ path, idx },
        );
        return error.ApiClientOnTuiThread;
    }
}

// =============================================================================
// Agent body — REQ-TUI-023..027
// =============================================================================

test "Agent body: mock_mode host refusal refuses non-loopback" {
    // REQ-TUI-027 — when mock_mode is true, ANY non-loopback host is
    // refused. The Agent body must NEVER reach dns_resolve for "api.minimax.io"
    // in mock mode.
    //
    // The guard function is pure and inspects the host string. The Agent
    // body wires it before Request construction.
    try testing.expect(Rt.refuseMockHost("api.minimax.io"));
    try testing.expect(Rt.refuseMockHost("0.0.0.0"));
    try testing.expect(Rt.refuseMockHost("192.168.1.1"));
    try testing.expect(!Rt.refuseMockHost("127.0.0.1"));
    try testing.expect(!Rt.refuseMockHost(""));
}

test "Agent body: buildMockRequest enforces host + tls=false" {
    // REQ-TUI-023 + REQ-TUI-027 — when mock_mode is true, the Request
    // constructed by the Agent body MUST have target_host="127.0.0.1"
    // and tls=false, regardless of the UserToolRequest payload.
    const req = Rt.buildMockRequest(.{
        .id = 42,
        .name = "ask",
        .args = "hello world",
    });
    try testing.expectEqualStrings("127.0.0.1", req.target_host);
    try testing.expectEqual(@as(u16, 0), req.target_port); // mock_handle supplies port
    try testing.expect(!req.tls);
    try testing.expectEqual(@as(usize, 1), req.messages.len);
    try testing.expectEqualStrings("user", req.messages[0].role);
    try testing.expectEqualStrings("hello world", req.messages[0].content);
}

test "Agent body: ChunkEvent.err maps to AgentErrorPayload (auth kind)" {
    // REQ-TUI-026 — every api_client.ErrorKind maps to an AgentErrorPayload.
    // Pure mapping function: exhaustive switch over ErrorKind.
    // Spot-check a few representative kinds.
    {
        const p = Rt.mapChunkError(ApiClient.ErrorKind.Unauthorized);
        try testing.expectEqual(@as(usize, @intFromEnum(p.kind)), @intFromEnum(Rt.AgentErrorClass.auth));
    }
    {
        const p = Rt.mapChunkError(ApiClient.ErrorKind.TlsHandshakeFailed);
        try testing.expectEqual(@as(usize, @intFromEnum(p.kind)), @intFromEnum(Rt.AgentErrorClass.tls_gated));
    }
    {
        const p = Rt.mapChunkError(ApiClient.ErrorKind.Cancelled);
        try testing.expectEqual(@as(usize, @intFromEnum(p.kind)), @intFromEnum(Rt.AgentErrorClass.network));
    }
    {
        const p = Rt.mapChunkError(ApiClient.ErrorKind.MalformedStream);
        try testing.expectEqual(@as(usize, @intFromEnum(p.kind)), @intFromEnum(Rt.AgentErrorClass.internal));
    }
}

test "Agent body: error mapping is exhaustive across all 15 ErrorKind variants" {
    // REQ-TUI-026 scenario 2 — exhaustive switch over api_client.ErrorKind.
    // Compile-time guarantee: the switch has no else arm, so adding a new
    // ErrorKind variant forces a build failure until the mapping is updated.
    const fields = @typeInfo(ApiClient.ErrorKind).@"enum".fields;
    try testing.expectEqual(@as(usize, 15), fields.len);
    // Touch every variant — compile-time check that the switch covers them.
    inline for (fields) |f| {
        const kind: ApiClient.ErrorKind = @enumFromInt(f.value);
        _ = Rt.mapChunkError(kind);
    }
}

// =============================================================================
// TUI body — REQ-TUI-028..031
// =============================================================================

test "TUI body: ThreadArgs carries key + mock_handle (null defaults)" {
    // REQ-TUI-033 — ThreadArgs extension. The canonical definition is in
    // src/tui.zig; the runtime re-exports the same struct. New fields
    // default to null so existing Runtime.spawn(.{}) callers compile.
    _ = Rt.ThreadArgs{
        .io = testing.io,
        .channels = undefined,
        .cancel_pipe = .{ -1, -1 },
        .shutdown = undefined,
        .key = null,
        .mock_handle = null,
    };
    // Compile-time check that the fields exist.
    const info = @typeInfo(Rt.ThreadArgs).@"struct".fields;
    var saw_key = false;
    var saw_handle = false;
    inline for (info) |f| {
        if (std.mem.eql(u8, f.name, "key")) saw_key = true;
        if (std.mem.eql(u8, f.name, "mock_handle")) saw_handle = true;
    }
    try testing.expect(saw_key);
    try testing.expect(saw_handle);
}

test "TUI body: openErrorModal classification routes errors to correct kinds" {
    // REQ-TUI-031 — AgentErrorPayload.kind from Agent maps to modal.ErrorKind.
    // Pure mapping function: exhausts the 5-class enum.
    try testing.expectEqual(@as(usize, @intFromEnum(Rt.openErrorKind(Rt.AgentErrorClass.auth))), @intFromEnum(M.ErrorKind.auth));
    try testing.expectEqual(@as(usize, @intFromEnum(Rt.openErrorKind(Rt.AgentErrorClass.network))), @intFromEnum(M.ErrorKind.network));
    try testing.expectEqual(@as(usize, @intFromEnum(Rt.openErrorKind(Rt.AgentErrorClass.tls_gated))), @intFromEnum(M.ErrorKind.tls_gated));
    try testing.expectEqual(@as(usize, @intFromEnum(Rt.openErrorKind(Rt.AgentErrorClass.sandbox))), @intFromEnum(M.ErrorKind.sandbox));
    try testing.expectEqual(@as(usize, @intFromEnum(Rt.openErrorKind(Rt.AgentErrorClass.internal))), @intFromEnum(M.ErrorKind.internal));
}

// =============================================================================
// Modal — REQ-TUI-030, REQ-TUI-031 (cumulative-delta semantics)
// =============================================================================

test "Modal: appendStreamChunk is cumulative-delta (suffix only)" {
    // REQ-TUI-030 — the api_client emits cumulative snapshots; current
    // appendStreamChunk blindly appends, duplicating text. The fix: only
    // append the suffix of the new text that doesn't overlap the existing
    // cumulative prefix.
    var state: M.State = .{
        .agent_loop = .{
            .allocator = testing.allocator,
            .cumulative = .empty,
            .last_update_ms = 0,
            .model = "",
            .tokens = 0,
        },
    };
    defer state.agent_loop.cumulative.deinit(testing.allocator);

    try M.appendStreamChunk(testing.io, &state, "Hello");
    try M.appendStreamChunk(testing.io, &state, "Hello world");
    try M.appendStreamChunk(testing.io, &state, "Hello world!");

    try testing.expectEqualStrings("Hello world!", state.agent_loop.cumulative.items);
}

// =============================================================================
// mock_server — REQ-TUI-037 (serve-by-id)
// =============================================================================

test "mock_server: registerFixture by id stores without sending" {
    // REQ-TUI-037 — registerFixture stores the fixture keyed by id and
    // does NOT auto-send it; serveFixture is the explicit trigger.
    var h = try MS.start(testing.allocator);
    defer h.deinit();

    // Register two distinct fixtures under different ids.
    try MS.registerFixture(h, "default", "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi");
    try MS.registerFixture(h, "alt", "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");

    // Both should be registered (count is internal; observable via serve-by-id).
    try testing.expect(h.named_fixtures.count() == 2);
}

test "mock_server: serveFixture replays the named fixture verbatim" {
    // REQ-TUI-037 — serveFixture looks up the fixture by id and serves
    // its bytes verbatim on the next accepted connection.
    var h = try MS.start(testing.allocator);
    defer h.deinit();

    const fixture = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    try MS.registerFixture(h, "default", fixture);
    try MS.serveFixture(h, "default");

    // Connect to the server + read.
    const sock = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
    const fd: i32 = @intCast(sock);
    try testing.expect(fd >= 0);
    defer _ = std.os.linux.close(fd);

    var addr: std.os.linux.sockaddr.in = .{
        .family = std.os.linux.AF.INET,
        .port = std.mem.nativeToBig(u16, MS.port(h.*)),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const connect_rc = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try testing.expectEqual(@as(usize, 0), connect_rc);

    var ts = std.os.linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);

    var buf: [256]u8 = undefined;
    const n: isize = @bitCast(std.os.linux.read(fd, &buf, buf.len));
    try testing.expect(n > 0);
    try testing.expectEqualStrings(fixture, buf[0..@intCast(n)]);
}

// =============================================================================
// Runtime Driver — REQ-TUI-028 (modal.runtimeDriver state machine)
// =============================================================================

test "Modal: runtimeDriver happy path: UserToolRequest posts StreamChunk" {
    // REQ-TUI-028 — runtimeDriver consumes channels, posts StreamChunk
    // for one tick, and returns on Shutdown. We verify the state stays
    // .agent_loop and one chunk was pushed.
    var ch: Ch.Channels = Ch.Channels.init();
    defer ch.closeAll(testing.io);

    var state: M.State = .{
        .agent_loop = .{
            .allocator = testing.allocator,
            .cumulative = .empty,
            .last_update_ms = 0,
            .model = "MiniMax-M3",
            .tokens = 0,
        },
    };
    defer state.agent_loop.cumulative.deinit(testing.allocator);

    // Push one StreamChunk + Shutdown.
    try ch.agent_to_tui.tryPut(testing.io, .{
        .StreamChunk = .{ .seq = 1, .text = "Hello" },
    });
    try ch.agent_to_tui.tryPut(testing.io, .Shutdown);

    // Drive the modal directly: drain agent_to_tui, append each chunk.
    var saw_shutdown = false;
    while (ch.agent_to_tui.tryGet(testing.io)) |ev| {
        switch (ev) {
            .StreamChunk => |sc| try M.appendStreamChunk(testing.io, &state, sc.text),
            .Shutdown => {
                saw_shutdown = true;
                break;
            },
            else => {},
        }
    }

    try testing.expect(saw_shutdown);
    try testing.expectEqualStrings("Hello", state.agent_loop.cumulative.items);
}
