pub const harness = @import("harness.zig");
pub const version = @import("version.zig");
pub const logger = @import("logger.zig");
pub const sandbox = @import("sandbox.zig");
pub const api_client = @import("api_client.zig");
pub const api_sse = @import("api_sse.zig");
pub const api_auth = @import("api_auth.zig");
pub const mock_server = @import("mock_server.zig");
pub const fixtures_test = @import("fixtures_test.zig");

// ponytail: stub main for the build-toolchain slice. exe.entry = .disabled
// skips the entry-point link, but std.start.zig still needs root.main to exist
// at semantic-analysis time. The TUI slice replaces this with the real entry.
pub fn main() void {}

// Touch logger/sandbox/api-client/api-sse/api-auth/mock-server types so the
// test runner pulls in src/{logger,sandbox,api_client,api_sse,api_auth}.zig
// AND src/mock_server.zig (which holds the in-file test blocks) under
// `zig build test`. Without these references, Zig's lazy compilation skips
// the modules and their tests never run.
comptime {
    _ = logger.Level;
    _ = logger.Logger;
    _ = logger.defaultPath;
    _ = harness.harness_placeholder;
    _ = sandbox.Sandbox;
    _ = sandbox.ToolSubprocess;
    _ = api_client.Client;
    _ = api_client.Request;
    _ = api_client.ChunkEvent;
    _ = api_sse.Parser;
    _ = api_sse.Event;
    _ = api_auth.validateFormat;
    _ = mock_server.Handle;
    _ = fixtures_test;
}
