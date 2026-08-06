pub const harness = @import("harness.zig");
pub const version = @import("version.zig");
pub const logger = @import("logger.zig");

// ponytail: stub main for the build-toolchain slice. exe.entry = .disabled
// skips the entry-point link, but std.start.zig still needs root.main to exist
// at semantic-analysis time. The TUI slice replaces this with the real entry.
pub fn main() void {}

// Touch logger types so the test runner pulls in src/logger.zig (which holds
// the in-file test blocks) under `zig build test`. Without this reference,
// Zig's lazy compilation skips logger.zig entirely and its tests never run.
comptime {
    _ = logger.Level;
    _ = logger.Logger;
    _ = logger.defaultPath;
    _ = harness.harness_placeholder;
}
