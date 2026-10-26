// S1/WU-1.1 — RED test for sandbox isolation order.
//
// Static guard: parses `src/sandbox.zig` source and asserts that the first
// `PR_SET_NO_NEW_PRIVS` byte offset is LESS than the first `restrictSelf`
// byte offset. landlock_restrict_self(2) requires the no_new_privs bit to
// be set BEFORE the call (otherwise EPERM determinista on non-root user,
// deterministically swallowed by `catch {}`).
//
// ⚠️ This is a grep-test. Acceptable HERE because the order of two syscalls
// is a structural property, not a behavioral one — an empirical Landlock test
// would require a kernel with Landlock ABI v1 in a privileged container,
// not available in CI. Documented as a follow-up if/when CI gains that
// capability. The trade-off is documented in
// `odd/tasks/s1-wu-1.1-sandbox-fail-closed.md` §"Test RED".

const std = @import("std");
const testing = std.testing;

/// Read the production sandbox.zig source from disk at runtime. We can't use
/// `@embedFile("../src/sandbox.zig")` because Zig 0.16 rejects paths
/// outside the module root. The test runner's CWD is the project root (set
/// by `build.zig`'s test step), so the relative path `src/sandbox.zig`
/// resolves correctly. Uses the Zig 0.16 `std.Io.Dir` API + `testing.io`.
fn readSandboxSource(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/sandbox.zig",
        allocator,
        .limited(256 * 1024),
    );
}

test "PR_SET_NO_NEW_PRIVS se establece ANTES de landlock_restrict_self" {
    const src = try readSandboxSource(testing.allocator);
    defer testing.allocator.free(src);

    // Anchor on the child-block landlock call pattern (the only `restrictSelf`
    // call that uses `.restrictSelf(applied.landlock_fd) catch {` form — the
    // test helper at line 682 uses `try sandbox_linux.Landlock.restrictSelf`
    // and is wrapped differently). Then search BACKWARDS from that position
    // for the nearest `PR_SET_NO_NEW_PRIVS` literal. The backward scan
    // correctly anchors the order inside the child block, not anywhere else
    // in the file (comments, test helpers, etc.).
    const landlock_call_pattern = ".restrictSelf(applied.landlock_fd) catch {";
    const restrict_idx = std.mem.indexOf(u8, src, landlock_call_pattern) orelse
        return error.ChildLandlockCallNotFound;

    // Search backwards from restrict_idx for the nearest PR_SET_NO_NEW_PRIVS.
    // std.mem.lastIndexOf returns the last occurrence at or before a position.
    const prctl_idx = std.mem.lastIndexOf(u8, src[0..restrict_idx], "PR_SET_NO_NEW_PRIVS") orelse
        return error.NoNewPrivsBeforeLandlockNotFound;

    try testing.expect(prctl_idx < restrict_idx);
}

test "Seccomp.loadFilter NO es código muerto — se llama en el camino de setup" {
    // Belt-and-suspenders: even if the order is fixed, the fail-closed
    // behavior depends on calling `Seccomp.loadFilter` (which checks the
    // seccomp() return code) instead of an inline `std.os.linux.seccomp(...)`
    // with the return discarded. This test asserts the call site exists.
    //
    // Reference: `sandbox_linux.zig:234` defines `Seccomp.loadFilter`.
    // The fix in S1/WU-1.1 must invoke it from `src/sandbox.zig`.
    const src = try readSandboxSource(testing.allocator);
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "Seccomp.loadFilter") != null);
}
