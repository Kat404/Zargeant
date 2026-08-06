const std = @import("std");

// ponytail: stub for the build-toolchain slice. Downstream slices (logger, sandbox,
// HTTP client, TUI) attach real modules here without touching build.zig.
pub const harness_placeholder: u8 = 0;

test "smoke" {
    try std.testing.expect(true);
}
