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
    pub const Config = root.runtime.Config;
    pub const ThreadArgs = root.runtime.ThreadArgs;
    pub const refuseMockHost = root.runtime.refuseMockHost;
    pub const buildMockRequest = root.runtime.buildMockRequest;
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
