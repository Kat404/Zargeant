const std = @import("std");

pub const VERSION: [*:0]const u8 = "0.0.0";

test "version module is wired" {
    // VERSION is a compile-time constant. No runtime behavior to test,
    // but the strict-tdd CI check (ci.yml) requires every src/*.zig
    // to have at least one test block. Existence assertion is enough.
    try std.testing.expect(std.mem.len(VERSION) > 0);
}
