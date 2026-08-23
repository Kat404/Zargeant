// tests/api_client.zig — integration guards for the Opción B stdlib rewrite.
//
// Spec:   sdd/opción-b/spec (obs#1360)  REQ-NEW-003 + REQ-NEW-004
// Design: sdd/opción-b/design (obs#1369)
//
// Wired as a separate test artifact so the static-grep guards below run in
// CI under `zig build test`. Mirrors the tests/tui/runtime_thread.zig
// pattern (separate module per cross-cutting guard). ~30 LoC.
//
// Headless invariant: no writes to stdout/stderr.
// Linux/x86_64 Zig 0.16 only.

const std = @import("std");
const testing = std.testing;

// =============================================================================
// Linux-only comptime guard.
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("api_client tests: linux-only v1");
}

const builtin = @import("builtin");

// =============================================================================
// Module aliases — tests/api_client.zig uses lib_mod (src/root.zig) for the
// shared modules, exactly like tests/tui/runtime_thread.zig.
// =============================================================================
const ApiClient = struct {
    const root = @import("api_client");
    pub const tls_conn = root.api_client.tls_conn;
    pub const Request = root.api_client.Request;
    pub const Message = root.api_client.Message;
};
const Auth = struct {
    const root = @import("api_auth");
    pub const validateViaApiWithTarget = root.api_auth.validateViaApiWithTarget;
};

// =============================================================================
// T-AC-1: tryOneAttempt's TLS branch uses stdlib (no raw socket/connect).
//
// The runtime production path (TLS branch of tryOneAttempt) MUST NOT call
// std.os.linux.{socket,connect} directly — stdlib's std.http.Client owns
// the socket (REQ-NEW-003). The plain HTTP branch (mock-server 127.0.0.1
// compat) keeps raw syscalls and is checked separately.
// =============================================================================
test "T-AC-1: tryOneAttempt TLS branch uses stdlib" {
    const io = testing.io;
    const content = std.Io.Dir.cwd().readFileAlloc(io, "src/api_client.zig", testing.allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer testing.allocator.free(content);

    // Locate the tryOneAttempt body — naive brace counter, scoped to 16 KB.
    const sig_idx = std.mem.indexOf(u8, content, "fn tryOneAttempt") orelse return;
    const body_start = std.mem.indexOfPos(u8, content, sig_idx, "{") orelse return;
    const body_end = @min(body_start + 16384, content.len);
    const body = content[body_start..body_end];

    // The TLS branch (bounded by `if (req.tls) {`) MUST contain stdlib hooks
    // and MUST NOT contain raw socket/connect outside mock-server paths.
    const tls_branch_start = std.mem.indexOf(u8, body, "if (req.tls)") orelse return;
    const tls_branch_end = std.mem.indexOfPos(u8, body, tls_branch_start, "} else {") orelse return;
    const tls_branch = body[tls_branch_start..tls_branch_end];
    try testing.expect(std.mem.indexOf(u8, tls_branch, "tls_conn.connect") != null);
    try testing.expect(std.mem.indexOf(u8, tls_branch, "std.os.linux.socket") == null);
}

// =============================================================================
// T-AC-2: validateViaApiWithTarget routes TLS through bridge_sync_async.
// Per obs#1369 (D5 REWORKED) + REQ-NEW-006, the TLS path MUST run via the
// sync→async bridge so the side-thread watcher can call Future.cancel(io)
// on cancel-pipe readability (which SIGIO-interrupts the stdlib worker).
// =============================================================================
test "T-AC-2: validateViaApiWithTarget TLS uses bridge_sync_async" {
    const io = testing.io;
    const content = std.Io.Dir.cwd().readFileAlloc(io, "src/api_auth.zig", testing.allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer testing.allocator.free(content);

    const sig_idx = std.mem.indexOf(u8, content, "pub fn validateViaApiWithTarget") orelse return;
    const body_start = std.mem.indexOfPos(u8, content, sig_idx, "{") orelse return;
    const body_end = @min(body_start + 12288, content.len);
    const body = content[body_start..body_end];

    try testing.expect(std.mem.indexOf(u8, body, "bridge_sync_async") != null);
    try testing.expect(std.mem.indexOf(u8, body, "runBlocking") != null);
    try testing.expect(std.mem.indexOf(u8, body, "TlsConnectFn") != null);
}

// =============================================================================
// T-AC-3: tls_conn.connect signature matches the bridge's expected async fn
// shape — takes `io`, `alloc`, `host`, `port`; returns an error union
// wrapping tls_conn. Exact error set is inferred (NOT anyerror), so we
// check the error-union shape rather than the literal return type.
// =============================================================================
test "T-AC-3: tls_conn.connect signature matches bridge fn shape" {
    const FnTy = @TypeOf(ApiClient.tls_conn.connect);
    const info = @typeInfo(FnTy).@"fn";
    try testing.expectEqual(@as(usize, 4), info.params.len);
    try testing.expectEqual(std.Io, info.params[0].type.?);
    try testing.expectEqual(std.mem.Allocator, info.params[1].type.?);
    try testing.expectEqual([]const u8, info.params[2].type.?);
    try testing.expectEqual(u16, info.params[3].type.?);
    // Return type must be an error union wrapping tls_conn.
    try testing.expect(@typeInfo(info.return_type.?) == .error_union);
    const payload = @typeInfo(info.return_type.?).error_union.payload;
    try testing.expectEqual(ApiClient.tls_conn, payload);
}
