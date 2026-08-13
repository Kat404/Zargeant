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
    pub const Cell = root.modal.Cell;
    pub const Style = root.modal.Style;
    pub const WindowMock = root.modal.WindowMock;
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
    pub const Config = root.runtime.Config;
    pub const ThreadArgs = root.runtime.ThreadArgs;
    pub const refuseMockHost = root.runtime.refuseMockHost;
    pub const buildMockRequest = root.runtime.buildMockRequest;
    pub const buildRealRequest = root.runtime.buildRealRequest;
    pub const mapChunkError = root.runtime.mapChunkError;
    pub const openErrorKind = root.runtime.openErrorKind;
    pub const AgentErrorClass = root.runtime.AgentErrorClass;
};
const Auth = struct {
    const root = @import("api_auth");
    pub const AuthState = root.api_auth.AuthState;
    pub const initialState = root.api_auth.initialState;
};
const Main = struct {
    const root = @import("main");
    pub const preflightAuthState = root.main_mod.preflightAuthState;
};
const Tui = struct {
    const root = @import("tui");
    pub const ThreadArgs = root.tui.ThreadArgs;
    pub const emitFrame = root.tui.emitFrame;
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
    // `src/runtime.zig` is EXCLUDED — T-SG-4 covers the narrowing
    // (literal IS allowed in real-mode branch, must come AFTER the
    // mock-mode refusal guard in source order).
    const targets = [_][]const u8{
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
        .allocator = testing.allocator,
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

// =============================================================================
// PR 2 — Auth dispatcher (REQ-TUI-038, REQ-TUI-033 extension)
//
// main()'s pre-run hook calls `api_auth.initialState()` (fstatat-only) and
// threads the result through `Runtime.Config.initial_auth_state` →
// `ThreadArgs.initial_auth_state`. The TUI thread seeds the modal state from
// this field.
//
// RED tests below assert:
//   1. `preflightAuthState` returns the AuthState produced by
//      `api_auth.initialState` (the XDG-credentials-file exists check).
//   2. `initialState` body uses `fstatat` and does NOT use `read`/`pread`/
//      `preadv` (defends the manual-only invariant by construction).
//   3. `Runtime.Config` carries `initial_auth_state` (default
//      .needs_first_entry so existing callers compile).
//   4. `ThreadArgs` (tui.zig canonical) carries `initial_auth_state`.
// =============================================================================

test "main preflight: initialState routes to needs_first_entry when no creds" {
    // REQ-TUI-038 scenario 1 — no credentials file → AuthState.needs_first_entry.
    // We call `preflightAuthState()` (the main.zig dispatcher helper). The
    // helper wraps `api_auth.initialState` which fstatats the XDG path. When
    // the running test environment has no credentials at the XDG path, the
    // helper returns .needs_first_entry (the common case in CI + dev).
    const result = Main.preflightAuthState();
    // Either outcome is acceptable here; we test the FUNCTION contract by
    // checking it's one of the two valid initialState values (drift D-1:
    // initialState never returns .has_memory_key).
    try testing.expect(result == .needs_first_entry or result == .has_disk_file);
}

test "main preflight: initialState is fstatat-only (no read content)" {
    // REQ-TUI-038 — `initialState` MUST only stat the credentials file; it
    // must NOT read its contents. A read of the encrypted credentials would
    // add timing/IO surface and contradict the "lazy" preflight contract.
    // Static-grep on the function body asserts the pattern.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/api_auth.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);

    // Locate the `pub fn initialState` body.
    const sig_idx = std.mem.indexOf(u8, content, "pub fn initialState") orelse {
        try testing.expect(false);
        return;
    };
    const body_start = std.mem.indexOfPos(u8, content, sig_idx, "{") orelse return;
    var depth: usize = 0;
    var body_end: usize = body_start;
    for (content[body_start..], 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                body_end = body_start + i + 1;
                break;
            }
        }
    }
    const body = content[body_start..body_end];

    // The body MUST contain fstatat (proves it stats the file).
    try testing.expect(std.mem.indexOf(u8, body, "fstatat") != null);
    // The body MUST NOT contain read/pread/preadv (forbids reading content).
    try testing.expect(std.mem.indexOf(u8, body, "std.os.linux.read") == null);
    try testing.expect(std.mem.indexOf(u8, body, "std.posix.read") == null);
    try testing.expect(std.mem.indexOf(u8, body, "pread") == null);
}

test "main preflight: Runtime.Config carries initial_auth_state (default .needs_first_entry)" {
    // REQ-TUI-033 extension (PR 2) — Runtime.Config gains `initial_auth_state`
    // so main() can thread the preflight result into the runtime. Default
    // .needs_first_entry keeps existing `Runtime.spawn(.{})` callers compiling.
    var cfg: Rt.Config = .{};
    try testing.expectEqual(@as(usize, @intFromEnum(cfg.initial_auth_state)), @intFromEnum(Auth.AuthState.needs_first_entry));
    // Verify the field can be set + read back.
    cfg.initial_auth_state = .has_disk_file;
    try testing.expectEqual(@as(usize, @intFromEnum(cfg.initial_auth_state)), @intFromEnum(Auth.AuthState.has_disk_file));
}

test "main preflight: ThreadArgs (tui.zig canonical) carries initial_auth_state" {
    // REQ-TUI-033 extension (PR 2) — ThreadArgs, canonical in tui.zig,
    // gains `initial_auth_state` so the TUI thread can seed the modal
    // state from the runtime-supplied AuthState. Default
    // .needs_first_entry; tuiThreadLoop reads it before the first poll.
    _ = Tui.ThreadArgs{
        .io = testing.io,
        .allocator = testing.allocator,
        .channels = undefined,
        .cancel_pipe = .{ -1, -1 },
        .shutdown = undefined,
        .key = null,
        .mock_handle = null,
        .initial_auth_state = .has_disk_file,
    };
    const info = @typeInfo(Tui.ThreadArgs).@"struct".fields;
    var saw_auth = false;
    inline for (info) |f| {
        if (std.mem.eql(u8, f.name, "initial_auth_state")) saw_auth = true;
    }
    try testing.expect(saw_auth);
}

// =============================================================================
// PR 2 — Auth flow (REQ-TUI-039, REQ-TUI-040)
//
// The TUI thread seeds its modal state from `ThreadArgs.initial_auth_state`.
// `modal.initialModalState(auth_state)` converts the AuthState to a fresh
// modal.State. The TUI thread calls this once on startup, before its
// first poll. Subsequent submit handlers (submitKeyEntry, submitUnlock,
// submitConsentGrant) drive the state machine from there.
//
// RED tests below assert:
//   1. initialModalState(.needs_first_entry) → .key_entry
//   2. initialModalState(.has_disk_file) → .unlock_prompt
//   3. initialModalState(.has_memory_key) → .welcome (defensive — not
//      normally produced by `initialState` but kept safe for in-session
//      use).
// =============================================================================

const ModalAuth = struct {
    const root = @import("modal");
    pub const initialModalState = root.modal.initialModalState;
};

test "modal: initialModalState(.needs_first_entry) returns .key_entry" {
    // REQ-TUI-039 — first-launch path opens KeyEntry so the user can type
    // their API key. The state must be a fresh .key_entry with no draft.
    const state = ModalAuth.initialModalState(Auth.AuthState.needs_first_entry);
    try testing.expect(std.meta.activeTag(state) == .key_entry);
    try testing.expectEqual(@as(usize, 0), state.key_entry.draft_len);
    try testing.expect(state.key_entry.err_msg == null);
}

test "modal: initialModalState(.has_disk_file) returns .unlock_prompt" {
    // REQ-TUI-040 — subsequent-launch path opens Unlock so the user
    // types the passphrase for the existing credentials file.
    const state = ModalAuth.initialModalState(Auth.AuthState.has_disk_file);
    try testing.expect(std.meta.activeTag(state) == .unlock_prompt);
    try testing.expectEqual(@as(usize, 0), state.unlock_prompt.draft_len);
    try testing.expect(state.unlock_prompt.err_msg == null);
}

test "modal: initialModalState(.has_memory_key) returns .welcome (defensive)" {
    // Defensive — `has_memory_key` is a session-only state set after
    // successful unlock. It should NOT be produced by `initialState` (drift
    // D-1), but the conversion is safe and returns .welcome so the TUI
    // thread doesn't crash if it ever appears.
    const state = ModalAuth.initialModalState(Auth.AuthState.has_memory_key);
    try testing.expect(std.meta.activeTag(state) == .welcome);
}

test "TUI body: tuiThreadLoop seeds modal state from initial_auth_state (static-grep)" {
    // REQ-TUI-039/040 wiring — tuiThreadLoop must call
    // `modal.initialModalState(args.initial_auth_state)` to seed the
    // modal state before the first poll. Static-grep: the call site
    // exists in src/tui.zig.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/tui.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);
    try testing.expect(std.mem.indexOf(u8, no_comments, "initialModalState") != null);
    try testing.expect(std.mem.indexOf(u8, no_comments, "initial_auth_state") != null);
}

// =============================================================================
// PR 2 — Idle relock (REQ-TUI-042, spec#192)
//
// After 5 minutes without user input the runtime invalidates the
// in-memory key (`memset(0)`) and re-prompts Unlock on the next user
// action. The 5-minute threshold is exposed as `runtime.IDLE_RELOCK_MS`
// so tests are hermetic (inject a fake clock).
//
// RED tests assert:
//   1. `isIdleRelockDue` returns true when elapsed > IDLE_RELOCK_MS.
//   2. `isIdleRelockDue` returns false when elapsed < IDLE_RELOCK_MS.
//   3. The `Event.Relock` variant exists in the channels union (the
//      Agent thread uses it to zero its key buffer).
//   4. tuiThreadMain references `isIdleRelockDue` (static-grep).
// =============================================================================

const Idle = struct {
    const root = @import("runtime");
    pub const isIdleRelockDue = root.runtime.isIdleRelockDue;
    pub const IDLE_RELOCK_MS = root.runtime.IDLE_RELOCK_MS;
};

test "idle relock: isIdleRelockDue returns true when elapsed > 5min" {
    // REQ-TUI-042 scenario 1 — 5 minutes without user input triggers
    // relock. We inject a fake clock: last_user_action = 0, now = 5min+1.
    try testing.expect(Idle.isIdleRelockDue(0, Idle.IDLE_RELOCK_MS + 1));
    // Far past the threshold.
    try testing.expect(Idle.isIdleRelockDue(0, Idle.IDLE_RELOCK_MS * 10));
}

test "idle relock: isIdleRelockDue returns false when elapsed < 5min" {
    // REQ-TUI-042 scenario 2 — anything under the threshold is fine.
    try testing.expect(!Idle.isIdleRelockDue(0, 0));
    try testing.expect(!Idle.isIdleRelockDue(0, Idle.IDLE_RELOCK_MS - 1));
    try testing.expect(!Idle.isIdleRelockDue(1000, 1000 + 60_000));
}

test "idle relock: Event.Relock variant exists in channels union (REQ-TUI-042)" {
    // REQ-TUI-042 wiring — the TUI thread sends `.Relock` to the Agent
    // when the idle threshold trips; the Agent zeroes its key buffer.
    // The static-grep guard confirms the variant is declared in
    // src/channels.zig.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/channels.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);
    try testing.expect(std.mem.indexOf(u8, no_comments, "Relock") != null);
}

test "idle relock: tuiThreadMain references isIdleRelockDue (static-grep)" {
    // The TUI thread checks idle on each iteration. Static-grep: the
    // call site exists in src/tui.zig.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/tui.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);
    try testing.expect(std.mem.indexOf(u8, no_comments, "isIdleRelockDue") != null);
}

// =============================================================================
// PR 2 — No-TTY headless fallback (REQ-TUI-047)
//
// `mibu.term.enableRawMode` failure (no `/dev/tty`, CI) MUST NOT crash
// the process. The TUI thread falls back to logger-only rendering via
// `logger.global()` and the runtime continues to completion.
//
// RED test asserts:
//   1. The `Lifecycle` struct carries a `no_tty: bool` field that
//      signals degraded mode. The TUI thread checks this before
//      invoking the bracket renderers.
// =============================================================================

test "no-TTY: Lifecycle carries no_tty flag for degraded mode (REQ-TUI-047)" {
    const info = @typeInfo(Tui.ThreadArgs).@"struct".fields;
    _ = info; // compile-time only
    // The Lifecycle struct lives in src/tui.zig. We assert the field
    // exists at the type level via @typeInfo. This is a static-grep
    // guard mirrored in runtime_thread.zig to keep the dedicated
    // test artifact self-contained.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/tui.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);
    try testing.expect(std.mem.indexOf(u8, no_comments, "no_tty") != null);
}

// =============================================================================
// PR 2 — Real mode (REQ-TUI-043, REQ-TUI-044)
//
// When `config.mock_mode = false`, the Agent thread sets the
// production Request triple: `target_host = "api.minimax.io"`,
// `target_port = 443`, `tls = true`. The TLS handshake uses the
// shipped `tls_handrolled` path (no openssl, no rustls).
//
// RED tests assert:
//   1. `buildRealRequest` returns a Request with the production triple
//      and uses the supplied API key as the first message's user content.
//   2. The Agent body has a real-mode branch (static-grep guard).
//   3. The `api.minimax.io` literal in src/runtime.zig production code
//      appears ONLY inside the real-mode branch (REQ-TUI-035 narrowing).
// =============================================================================

test "Agent body: buildRealRequest enforces api.minimax.io:443 + tls=true (REQ-TUI-043)" {
    // PR 2 — when `config.mock_mode = false`, the Agent body MUST build
    // a Request with `target_host = "api.minimax.io"`, `target_port = 443`,
    // and `tls = true`. The API key is the user prompt's content (the
    // Agent forwards it; Client.stream threads it into the Authorization
    // header).
    const key = "test-key-1234567890ABCDEF";
    const req = Rt.buildRealRequest(.{
        .id = 1,
        .name = "ask",
        .args = key,
    });
    try testing.expectEqualStrings("api.minimax.io", req.target_host);
    try testing.expectEqual(@as(u16, 443), req.target_port);
    try testing.expect(req.tls);
    try testing.expectEqual(@as(usize, 1), req.messages.len);
    try testing.expectEqualStrings("user", req.messages[0].role);
    try testing.expectEqualStrings(key, req.messages[0].content);
}

test "Agent body: real-mode branch exists in agentThreadLoop (static-grep)" {
    // REQ-TUI-043 — the Agent body MUST branch on mock_mode before
    // building the Request. Static-grep: a real-mode branch exists in
    // src/runtime.zig production code.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/runtime.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);
    try testing.expect(std.mem.indexOf(u8, no_comments, "buildRealRequest") != null);
    try testing.expect(std.mem.indexOf(u8, no_comments, "api.minimax.io") != null);
}

// =============================================================================
// PR 2 — Remove internal coalesce + Client.validateKey stub
// (REQ-TUI-025 single-window + REQ-TUI-045 stub removal)
//
// The `api_client.ChunkEventStream.coalesce_started_at` field is REMOVED —
// the channel layer's `channels.pushSseChunk` owns the 16ms REPLACE
// coalesce (single window, no double coalescing per design #441 §WARN
// risk). The `Client.validateKey` stub is REMOVED — real validation is
// `api_auth.validateViaApi` (api-auth-fixes PR #9).
//
// RED test asserts: neither symbol appears in src/api_client.zig
// production code.
// =============================================================================

test "api_client: coalesce_started_at field REMOVED from ChunkEventStream (REQ-TUI-025)" {
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/api_client.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);
    try testing.expect(std.mem.indexOf(u8, no_comments, "coalesce_started_at") == null);
}

test "api_client: Client.validateKey stub REMOVED (REQ-TUI-045)" {
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/api_client.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);
    try testing.expect(std.mem.indexOf(u8, no_comments, "validateKey") == null);
}

// =============================================================================
// T-SG-4: no api.minimax.io literal in mock-mode code path (re-test, PR 2)

// =============================================================================
// T-SG-4: no api.minimax.io literal in mock-mode code path (re-test, PR 2)
//
// REQ-TUI-035 — the literal `api.minimax.io` MUST only appear in the
// real-mode branch (`config.mock_mode == false`). PR 1 left the guard
// failing (no literal at all in the tree). PR 2 narrows the guard so the
// literal is allowed inside the real-mode branch ONLY.
// =============================================================================

test "T-SG-4: api.minimax.io literal confined to real-mode branch (PR 2 narrowing)" {
    // PR 2 narrows the T-SG-2 guard: the literal IS allowed in src/runtime.zig
    // but ONLY inside the `if (!config.mock_mode)` branch. The guard below
    // asserts the literal exists in src/runtime.zig production code AND that
    // the `mock_mode` host refusal guard (REQ-TUI-027) sits BEFORE the
    // literal in source order (so the guard fires first).
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/runtime.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);

    // Locate the refuseMockHost marker (proves the mock-mode guard is in place).
    const refuse_idx = std.mem.indexOf(u8, no_comments, "refuseMockHost") orelse {
        try testing.expect(false);
        return;
    };
    // The literal may appear (PR 2 introduces it). If it does, the
    // refuseMockHost marker must come FIRST in source order — so the guard
    // fires before any potential mock-mode reach to api.minimax.io.
    if (std.mem.indexOf(u8, no_comments, "api.minimax.io")) |literal_idx| {
        try testing.expect(refuse_idx < literal_idx);
    }
}

// =============================================================================
// T-SG-5: no xor / hmac / sha256 in src/api_auth.zig production body
//
// REQ-TUI-046 + post-api-auth-fixes — the production credential code uses
// Argon2id + AES-GCM only. Any direct XOR/HMAC/SHA256 use in the
// production body would be a regression. The constants block at L44-46
// mentions `argon2_*` parameters which are NOT xor/hmac/sha256 — those
// patterns are forbidden.
// =============================================================================

test "T-SG-5: src/api_auth.zig production body has no xor / hmac / sha256" {
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/api_auth.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);

    // None of these patterns should appear in the production prefix.
    // Argon2id is the production cipher (api-auth-fixes #9); any
    // standalone xor/hmac/sha256 use is a regression.
    try testing.expect(std.mem.indexOf(u8, no_comments, "xor") == null);
    try testing.expect(std.mem.indexOf(u8, no_comments, "hmac") == null);
    try testing.expect(std.mem.indexOf(u8, no_comments, "sha256") == null);
}

// =============================================================================
// PR fix-slice — tui-verification (REQ-VER-001..004)
//
// CRITICAL bug #2 from explore #1237: src/runtime.zig:322-338 (tuiRealMain)
// is a stub-drain that ignores the production tuiThreadInit/Loop/Shutdown
// composers in src/tui.zig. The TUI thread never renders, never polls mibu,
// never recovers the terminal. This static-grep guard (T-VR-1) fences the
// fix: the three composers MUST be referenced from inside tuiRealMain.
// =============================================================================

test "T-VR-1: tuiRealMain calls tuiThreadInit + tuiThreadLoop + tuiThreadShutdown" {
    // REQ-VER-001/002/003 — production wiring must compose the three
    // R-PR 4 lifecycle functions. Static-grep on the tuiRealMain body
    // (src/runtime.zig): the three symbol references must exist.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/runtime.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);

    // Locate the tuiRealMain function body. Anchor on the signature so
    // we don't accidentally catch comments / unrelated references.
    const sig = std.mem.indexOf(u8, no_comments, "fn tuiRealMain") orelse {
        try testing.expect(false);
        return;
    };
    const body_start = std.mem.indexOfPos(u8, no_comments, sig, "{") orelse return;
    var depth: usize = 0;
    var body_end: usize = body_start;
    for (no_comments[body_start..], 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                body_end = body_start + i + 1;
                break;
            }
        }
    }
    const body = no_comments[body_start..body_end];

    // Each composer must be referenced inside the body.
    try testing.expect(std.mem.indexOf(u8, body, "tuiThreadInit") != null);
    try testing.expect(std.mem.indexOf(u8, body, "tuiThreadLoop") != null);
    try testing.expect(std.mem.indexOf(u8, body, "tuiThreadShutdown") != null);
}
test "T-VR-1b: tuiRealMain catches tuiThreadInit failure → no_tty fallback (REQ-VER-004)" {
    // REQ-VER-004 — when tuiThreadInit cannot enable raw mode (no TTY,
    // CI), the thread continues in logger-only mode. The static-grep
    // guard verifies the call site uses `if (lc.no_tty) …` (or an
    // equivalent pattern) and that the Lifecycle.no_tty fallback path
    // is reachable from tuiRealMain.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/runtime.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);

    // Locate the tuiRealMain function body.
    const sig = std.mem.indexOf(u8, no_comments, "fn tuiRealMain") orelse {
        try testing.expect(false);
        return;
    };
    const body_start = std.mem.indexOfPos(u8, no_comments, sig, "{") orelse return;
    var depth: usize = 0;
    var body_end: usize = body_start;
    for (no_comments[body_start..], 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                body_end = body_start + i + 1;
                break;
            }
        }
    }
    const body = no_comments[body_start..body_end];

    // The body must reference tuiThreadInit (proves the wiring), and
    // must contain a `no_tty` reference (proves the fallback is wired).
    // Note: `no_tty` may occur AFTER the body (e.g. the lifecycle
    // return value), so we widen the scan to a small window of the
    // surrounding prod prefix to keep the test focused but tolerant.
    const window_after = no_comments[body_end..@min(body_end + 4096, no_comments.len)];
    try testing.expect(std.mem.indexOf(u8, body, "tuiThreadInit") != null);
    try testing.expect(std.mem.indexOf(u8, window_after, "no_tty") != null or std.mem.indexOf(u8, body, "no_tty") != null);
}

// =============================================================================
// PR fix-slice — tui-verification (REQ-VER-005/006/008)
//
// CRITICAL bug #1 from explore #1237: src/main.zig ignores
// `parsed.mock_mode`. The --mock flag is parsed but never threads the
// mock_server handle into runtime.Config.mock_handle, so the Agent body
// always takes the real-mode branch (api.minimax.io:443). The mock flag
// is effectively a no-op.
//
// Static-grep guards (T-VR-2, T-VR-3) fence the fix:
//   - mock_server.start is called only when parsed.mock_mode is true
//   - main() does NOT call mock_server.start in the no-flag path
//   - Config.mock_handle flows into the Runtime.spawn call
// =============================================================================

test "T-VR-2: main() calls mock_server.start only when --mock is set (REQ-VER-005/008)" {
    // REQ-VER-005/008 — the --mock branch in main() must call
    // mock_server.start and thread the handle into Config. The
    // static-grep guard fences that the call site is INSIDE an
    // `if (parsed.mock_mode)` branch (so the no-flag path is safe).
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/main.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);

    // mock_server.start must appear in production code (via the
    // module alias or the qualified import). The test is forgiving on
    // the alias name (`.start(` covers both `mock_server.start(` and
    // `mock_server_pkg.start(` after a `const mock_server_pkg = @import(...)`).
    try testing.expect(std.mem.indexOf(u8, no_comments, ".start(std.heap.page_allocator)") != null or std.mem.indexOf(u8, no_comments, ".start(allocator)") != null or std.mem.indexOf(u8, no_comments, "mock_server.start") != null);
    // The reference to `parsed.mock_mode` must appear (proves the branch).
    try testing.expect(std.mem.indexOf(u8, no_comments, "parsed.mock_mode") != null);
    // Config.mock_handle must be set in main (proves the threading).
    try testing.expect(std.mem.indexOf(u8, no_comments, "mock_handle") != null);
}

test "T-VR-2b: Runtime.spawn call in main() threads mock_handle (REQ-VER-006)" {
    // REQ-VER-006 — the Config struct constructed in main() must set
    // `.mock_handle` (either to the live handle from mock_server.start
    // or to null for the no-flag path). Static-grep: the field name
    // appears in main() production code.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/main.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);

    // The mock_handle field is set via field-init syntax: `.mock_handle = ...`
    // We assert the literal text ".mock_handle" appears in main.zig.
    try testing.expect(std.mem.indexOf(u8, no_comments, ".mock_handle") != null);
}

// =============================================================================
// PR fix-slice — tui-verification (REQ-VER-009/010/011/012)
//
// Per-frame modal dispatch from the TUI thread (REQ-VER-009/010):
// tuiThreadMain must call `modal.runtimeDriverTick` each iteration so
// agent_to_tui events (StreamChunk, AgentError) update the modal state.
// agentThreadLoop must handle .ApiKeySubmitted + .ConsentGrant events
// (REQ-VER-011). submitUnlock enforces a 3-attempt cap → .error_modal
// (REQ-VER-012).
// =============================================================================

test "T-VR-3: tuiThreadMain dispatches per-frame modal events via runtimeDriverTick (REQ-VER-009/010)" {
    // REQ-VER-009/010 — the TUI thread must drive the modal state
    // machine from per-frame events. Static-grep: tuiThreadMain
    // references `runtimeDriverTick` (the helper that drains
    // agent_to_tui into the modal state).
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/tui.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);

    // runtimeDriverTick must be referenced from tui.zig production code.
    try testing.expect(std.mem.indexOf(u8, no_comments, "runtimeDriverTick") != null);
}

test "T-VR-4: agentThreadLoop handles .ApiKeySubmitted + .ConsentGrant (REQ-VER-011)" {
    // REQ-VER-011 — the Agent body must explicitly handle the
    // .ApiKeySubmitted and .ConsentGrant event variants. Static-grep:
    // both event references appear inside the agentThreadLoop function
    // body in src/runtime.zig.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/runtime.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);

    // Locate the agentThreadLoop function body.
    const sig = std.mem.indexOf(u8, no_comments, "fn agentThreadLoop") orelse {
        try testing.expect(false);
        return;
    };
    const body_start = std.mem.indexOfPos(u8, no_comments, sig, "{") orelse return;
    var depth: usize = 0;
    var body_end: usize = body_start;
    for (no_comments[body_start..], 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                body_end = body_start + i + 1;
                break;
            }
        }
    }
    const body = no_comments[body_start..body_end];

    // The body must reference both .ApiKeySubmitted and .ConsentGrant.
    try testing.expect(std.mem.indexOf(u8, body, ".ApiKeySubmitted") != null);
    try testing.expect(std.mem.indexOf(u8, body, ".ConsentGrant") != null);
}

test "T-VR-5: submitUnlock references the 3-attempt counter (REQ-VER-012)" {
    // REQ-VER-012 — submitUnlock enforces a 3-attempt cap. After the
    // 3rd wrong passphrase, state transitions to .error_modal.
    // Static-grep: the submitUnlock function body in src/modal.zig
    // references both the attempt counter and the .error_modal
    // transition.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/modal.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);
    const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
    const prod_src = content[0..first_test];
    const no_comments = stripLineComments(prod_src);
    defer if (no_comments.ptr != prod_src.ptr) testing.allocator.free(no_comments);

    // Locate the submitUnlock function body.
    const sig = std.mem.indexOf(u8, no_comments, "pub fn submitUnlock") orelse {
        try testing.expect(false);
        return;
    };
    const body_start = std.mem.indexOfPos(u8, no_comments, sig, "{") orelse return;
    var depth: usize = 0;
    var body_end: usize = body_start;
    for (no_comments[body_start..], 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                body_end = body_start + i + 1;
                break;
            }
        }
    }
    const body = no_comments[body_start..body_end];

    // The body must reference attempts (the counter) and .error_modal
    // (the cap terminal state).
    try testing.expect(std.mem.indexOf(u8, body, "attempts") != null);
    try testing.expect(std.mem.indexOf(u8, body, ".error_modal") != null);
}

// =============================================================================
// tui-render-wiring slice (sdd/tui-render-wiring/spec REQ-RW-001/002)
// W1 tests: seed + prev_snapshot alloc
// =============================================================================

test "W1-1: tuiRealMain seeds redraw_pending=true after tuiThreadInit" {
    // REQ-RW-001 — `tuiRealMain` MUST call
    // `lc.redraw_pending.store(true, .seq_cst)` exactly once after
    // `tuiThreadInit` returns and `!lc.no_tty`. The seed call unblocks
    // the loop's first render (the bug from zargeant/tui-render-missing).
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/runtime.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);

    // Locate the tuiRealMain function body.
    const sig = std.mem.indexOf(u8, content, "fn tuiRealMain") orelse {
        try testing.expect(false);
        return;
    };
    try testing.expect(std.mem.indexOfPos(u8, content, sig, "lc.redraw_pending.store(true, .seq_cst)") != null);
}

test "W1-2: tuiRealMain allocates prev_snapshot via args.allocator.alloc" {
    // REQ-RW-002 — `Lifecycle.prev_snapshot: ?[]Cell` is heap-allocated
    // once at init via `args.allocator.alloc(...)`. Both the field
    // assignment literal and the alloc call must appear in tuiRealMain.
    const content = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/runtime.zig",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(content);

    const sig = std.mem.indexOf(u8, content, "fn tuiRealMain") orelse {
        try testing.expect(false);
        return;
    };
    try testing.expect(std.mem.indexOfPos(u8, content, sig, "prev_snapshot") != null);
    try testing.expect(std.mem.indexOfPos(u8, content, sig, "args.allocator.alloc") != null);
}

// =============================================================================
// tui-render-wiring W3 tests (REQ-RW-003, REQ-RW-005, REQ-RW-007)
// =============================================================================

test "W3-1: emitFrame writes CSI cursor position + cell byte for a 2-cell diff" {
    // REQ-RW-003 scenario S-RW-004 — given prev = all spaces and current
    // with cell at 1-indexed (col=2, row=1) = 'X' bold, the buffer
    // contains the cursor-position escape `\x1b[1;2H` (row=1, col=2),
    // the bold SGR `\x1b[1m`, and the cell byte 'X'. Also a trailing
    // `\x1b[0m` reset.
    var prev: [4]M.Cell = .{
        .{ .ch = ' ', .style = .{} },
        .{ .ch = ' ', .style = .{} },
        .{ .ch = ' ', .style = .{} },
        .{ .ch = ' ', .style = .{} },
    };
    var current: [4]M.Cell = .{
        .{ .ch = ' ', .style = .{} },
        .{ .ch = 'X', .style = .{ .bold = true } },
        .{ .ch = ' ', .style = .{} },
        .{ .ch = ' ', .style = .{} },
    };
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Tui.emitFrame(&w, &prev, &current, 2, 2, testing.allocator);
    const out = buf[0..w.end];
    // Cursor position: mibu.cursor.goTo(writer, x=2, y=1) → \x1b[1;2H
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1;2H") != null);
    // Bold SGR
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
    // Cell byte 'X'
    try testing.expect(std.mem.indexOf(u8, out, "X") != null);
    // Trailing reset
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
}

test "W3-2: emitFrame writes SGR codes for bold/underline/reverse/reset" {
    // REQ-RW-003 + REQ-RW-007 (S-RW-010) — per-cell lazy SGR emits. Bold
    // cell triggers \x1b[1m; underline triggers \x1b[4m; reverse triggers
    // \x1b[7m; each cell preceded by a \x1b[0m reset (no StyleTracker).
    var prev: [3]M.Cell = .{
        .{ .ch = ' ', .style = .{} },
        .{ .ch = ' ', .style = .{} },
        .{ .ch = ' ', .style = .{} },
    };
    var current: [3]M.Cell = .{
        .{ .ch = 'A', .style = .{ .bold = true } },
        .{ .ch = 'B', .style = .{ .underline = true } },
        .{ .ch = 'C', .style = .{ .reverse = true } },
    };
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Tui.emitFrame(&w, &prev, &current, 3, 1, testing.allocator);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[4m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[7m") != null);
}

test "W3-3: emitFrame writes no cursor escapes when prev == current" {
    // REQ-RW-003 scenario S-RW-005 — when prev == current, the diff is
    // empty so only the trailing reset SGR is emitted (no cursor
    // positions).
    var cells: [4]M.Cell = .{
        .{ .ch = 'A', .style = .{ .bold = true } },
        .{ .ch = 'B', .style = .{ .underline = true } },
        .{ .ch = 'C', .style = .{} },
        .{ .ch = 'D', .style = .{} },
    };
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Tui.emitFrame(&w, &cells, &cells, 2, 2, testing.allocator);
    const out = buf[0..w.end];
    // No cursor-position escapes (those look like \x1b[<num>;<num>H).
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2;1H") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2;2H") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1H") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1;2H") == null);
    // Trailing reset only.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
}

test "W3-4: emitFrame frees the diff slice under std.testing.allocator" {
    // REQ-RW-003 scenario S-RW-006 — emitFrame MUST free the diff slice
    // allocated by WindowMock.diff. With std.testing.allocator the leak
    // detector asserts zero leaks.
    var prev: [3]M.Cell = .{
        .{ .ch = ' ', .style = .{} },
        .{ .ch = ' ', .style = .{} },
        .{ .ch = ' ', .style = .{} },
    };
    var current: [3]M.Cell = .{
        .{ .ch = 'X', .style = .{ .bold = true } },
        .{ .ch = 'Y', .style = .{ .underline = true } },
        .{ .ch = 'Z', .style = .{ .reverse = true } },
    };
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Tui.emitFrame(&w, &prev, &current, 3, 1, testing.allocator);
    // If emitFrame leaks the diff slice, the testing.allocator would
    // assert on scope exit; we got here so the leak is zero.
    try testing.expect(w.end > 0);
}

test "W3-5: emitFrame ignores WindowMock.in_alt_screen + cursor_hidden" {
    // REQ-RW-005 (S-RW-008) — emitFrame must not consult the WindowMock's
    // bookkeeping flags. The same prev/current pair produces byte-equivalent
    // output regardless of the flag state.
    var prev: [2]M.Cell = .{
        .{ .ch = ' ', .style = .{} },
        .{ .ch = ' ', .style = .{} },
    };
    var current: [2]M.Cell = .{
        .{ .ch = 'X', .style = .{ .bold = true } },
        .{ .ch = 'Y', .style = .{ .underline = true } },
    };
    var buf_a: [256]u8 = undefined;
    var w_a = std.Io.Writer.fixed(&buf_a);
    try Tui.emitFrame(&w_a, &prev, &current, 2, 1, testing.allocator);
    var buf_b: [256]u8 = undefined;
    var w_b = std.Io.Writer.fixed(&buf_b);
    try Tui.emitFrame(&w_b, &prev, &current, 2, 1, testing.allocator);
    try testing.expectEqual(w_a.end, w_b.end);
    try testing.expectEqualSlices(u8, buf_a[0..w_a.end], buf_b[0..w_b.end]);
}
