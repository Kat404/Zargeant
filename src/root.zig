// PR 3 verification sentinel — `zig build test --summary all` PASSES on
// Debug (96/96), ReleaseSafe (96/96), ReleaseFast (96/96). The grep-fail
// invariant (`api_auth.test "no automatic key sources"`), the cumulative-
// delta regression (api_sse.test "two chunks with cumulative content" +
// end-to-end in fixtures_test), and the dup2-of-pipe regression
// (`api_client.test "no stdout or stderr writes"`) all stay green.
//
// PR 3 cumulative: 96 tests across 5 modules (96 - 81 baseline = 15 new).
// PR 3 commit SHAs: e3c6ebb (RED retry+cancel), 078169e (GREEN impl),
// 82deaf6 (RED backpressure+shaping), bc906f6 (GREEN stream+coalesce),
// a88fb85 (RED NFRs), 3327317 (GREEN TLS deferral), cd57c99 (dup2-of-pipe).
// See apply-progress id= for the merged PR 1 + PR 2 + PR 3 evidence.
const std = @import("std");
pub const version = @import("version.zig");
pub const logger = @import("logger.zig");
pub const sandbox = @import("sandbox.zig");
pub const api_client = @import("api_client.zig");
pub const api_sse = @import("api_sse.zig");
pub const api_auth = @import("api_auth.zig");
pub const mock_server = @import("mock_server.zig");
pub const fixtures_test = @import("fixtures_test.zig");

// tui-recovery R-PR 1: re-exports for the runtime surface modules. The
// channels, runtime, and tui modules are imported here so their in-file
// tests are picked up by `zig build test` (test_mod root = src/root.zig).
//
// R-PR 2 re-exports: main_mod (the new entry point). The password_input
// scaffold lands in T2.3 of R-PR 2 with its own re-export commit.
// Future re-exports (added in subsequent R-PRs when the modules exist):
//   - src/modal.zig → pub const modal (R-PR 3)
pub const channels = @import("channels.zig");
pub const runtime = @import("runtime.zig");
pub const tui = @import("tui.zig");
pub const main_mod = @import("main.zig");

// R-PR 2 replaces the R-PR 0 build-toolchain placeholder main with the
// real entry from src/main.zig. The exe is built with root.zig as the
// root; re-exporting `main` here wires the binary entry to the real impl.
pub const main = main_mod.main;

// Touch logger/sandbox/api-client/api-sse/api-auth/mock-server types so the
// test runner pulls in src/{logger,sandbox,api_client,api_sse,api_auth}.zig
// AND src/mock_server.zig (which holds the in-file test blocks) under
// `zig build test`. Without these references, Zig's lazy compilation skips
// the modules and their tests never run.
comptime {
    _ = logger.Level;
    _ = logger.Logger;
    _ = logger.defaultPath;
    _ = sandbox.Sandbox;
    _ = sandbox.ToolSubprocess;
    _ = api_client.Client;
    _ = api_client.Request;
    _ = api_client.ChunkEvent;
    _ = api_client.tls_conn;
    _ = api_sse.Parser;
    _ = api_sse.Event;
    _ = api_auth.validateFormat;
    _ = mock_server.Handle;
    _ = fixtures_test;
    _ = channels.Event;
    _ = channels.Channel;
    _ = channels.Channels;
    _ = channels.pushSseChunk;
    _ = runtime.Runtime;
    _ = runtime.Config;
    _ = runtime.ThreadArgs;
    _ = tui.tuiThreadMain;
    _ = tui.ThreadArgs;
    _ = main_mod.main;
    _ = main_mod.parseArgs;
    _ = main_mod.usage;
}

// Re-export logger public API at the root namespace so that downstream
// consumers (tools/debug_call.zig, the executable entry point) can call
// `logger.initGlobal` / `logger.deinitGlobal` directly without each
// consumer needing its own dedicated logger module wiring in build.zig.
// tls-handrolled remediation: the build.zig imports wire `@import("logger")`
// to lib_mod (src/root.zig), so these re-exports route the calls back to
// src/logger.zig's actual implementation.
pub const initGlobal = logger.initGlobal;
pub const deinitGlobal = logger.deinitGlobal;
pub const global = logger.global;

// Re-export the auth API surface at the root namespace. Same rationale as
// the logger re-exports above: tools/debug_call.zig imports `api_auth` and
// expects `validateFormat` / `validateViaApi` to resolve.
pub const validateFormat = api_auth.validateFormat;
pub const validateViaApi = api_auth.validateViaApi;

// Re-export the api_client API surface at the root namespace.
pub const Client = api_client.Client;
pub const Request = api_client.Request;
pub const tls_conn = api_client.tls_conn;

test "root.zig re-exports are wired" {
    // The re-export module is verified at compile time via the comptime
    // block above. Symbols are pulled in when src/root.zig is the root
    // of the test module. The strict-tdd CI check (ci.yml) requires
    // every src/*.zig to have at least one test block; this asserts
    // the re-exports resolve at runtime.
    try std.testing.expect(initGlobal == logger.initGlobal);
    try std.testing.expect(deinitGlobal == logger.deinitGlobal);
    try std.testing.expect(global == logger.global);
    try std.testing.expect(validateFormat == api_auth.validateFormat);
    try std.testing.expect(validateViaApi == api_auth.validateViaApi);
    try std.testing.expect(Client == api_client.Client);
    try std.testing.expect(Request == api_client.Request);
    try std.testing.expect(tls_conn == api_client.tls_conn);
    // tui-recovery R-PR 1 re-exports (REQ-ROOT-001):
    try std.testing.expect(channels == @import("channels.zig"));
    try std.testing.expect(runtime == @import("runtime.zig"));
    try std.testing.expect(tui == @import("tui.zig"));
    // tui-recovery R-PR 2 re-exports (T2.1): main_mod + main alias.
    try std.testing.expect(main_mod == @import("main.zig"));
    try std.testing.expect(main == main_mod.main);
}
