pub const harness = @import("harness.zig");
pub const version = @import("version.zig");

// ponytail: stub main for the build-toolchain slice. exe.entry = .disabled
// skips the entry-point link, but std.start.zig still needs root.main to exist
// at semantic-analysis time. The TUI slice replaces this with the real entry.
pub fn main() void {}
