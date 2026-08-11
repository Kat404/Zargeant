// tests/tui/mibu_pin.zig -- mibu pin reproducibility assertion.
//
// Spec:   sdd/tui-recovery/spec  (id=407) REQ-TUI-020
// Design: sdd/tui-recovery/design (id=408) §2.3 R-PR 4
//
// REQ-TUI-020 — mibu must remain pinned at commit 636a36a353614da2a537b060c33f17d608915eab
// for the full 5-R-PR cycle of the tui-recovery change. The Zig hash-encoded form is
// declared in build.zig.zon under `.dependencies.mibu.hash`. This test reads the
// zon file at test-time and asserts both the encoded hash AND the literal git
// SHA-1 are present. Hash drift fails the build.
//
// This file is its own test step (wired in build.zig as `test-tui-mibu-pin`)
// to keep the mibu import resolution isolated from the main test runner.

const std = @import("std");

const EXPECTED_GIT_SHA: []const u8 = "636a36a353614da2a537b060c33f17d608915eab";

// The Zig hash format is `<package>-<version>-<base64-url-no-padding>`.
// The mibu dep is encoded as `mibu-0.0.1-dev-...`. We assert the prefix +
// the raw hash from build.zig.zon matches what's published for commit
// 636a36a.
const EXPECTED_HASH_PREFIX: []const u8 = "mibu-0.0.1-dev-";
const EXPECTED_HASH_SUFFIX: []const u8 = "Ddr1rtM7AQCgWQX1VKWPN6Q6ySlxuEhvclmTaIv22PKK";

test "mibu pin at 636a36a (REQ-TUI-020)" {
    // Read build.zig.zon and assert the mibu dep block contains both
    // the git SHA (URL fragment) and the Zig hash form (hash field).
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "build.zig.zon",
        alloc,
        .limited(1 << 16),
    );
    defer alloc.free(contents);

    // 1. The git SHA appears in the URL fragment (`#<sha>`).
    try std.testing.expect(std.mem.indexOf(u8, contents, EXPECTED_GIT_SHA) != null);

    // 2. The Zig hash form appears in `.hash = "<pkg>-<ver>-<base64>"`.
    try std.testing.expect(std.mem.indexOf(u8, contents, EXPECTED_HASH_PREFIX) != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, EXPECTED_HASH_SUFFIX) != null);
}

test "mibu pin unchanged across cycle (REQ-TUI-020 scenario 2)" {
    // REQ-TUI-020 scenario 2 — pin survives all 5 R-PRs. This is a
    // tripwire; the same hash appears once now and once after R-PR 5
    // merges. The R-PR 5 cycle-wide test is identical to this one;
    // we duplicate it here so the assertion is wired from R-PR 4
    // onward.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "build.zig.zon",
        alloc,
        .limited(1 << 16),
    );
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, EXPECTED_GIT_SHA) != null);
}
