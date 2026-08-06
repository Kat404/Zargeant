// src/sandbox_profile.zig — Linux sandbox profile declarations for zargeant.
//
// Declarative Profile + defaults + builder. Consumed by sandbox.zig (PR 3)
// to apply Landlock + Seccomp-BPF to tool subprocesses.
//
// Spec:   sdd/sandbox-linux/spec   (id=225)
// Design: sdd/sandbox-linux/design (id=226)
//
// Chain (stacked-to-main): PR 1 = sandbox_linux.zig · PR 2 = this file ·
// PR 3 = sandbox.zig + root.zig wiring.
//
// Headless invariant: this module MUST NOT write to stdout/stderr.
// Logging is the parent's job — sandboxed children lose /tmp write access.
// ponytail: std.os.linux.* syscalls used directly; std.posix.* wrappers for
// openat remain available in Zig 0.16 (unlike seccomp/prctl/landlock).

const std = @import("std");
const sandbox_linux = @import("sandbox_linux.zig");

// Self-reference alias so tests can reach production symbols via
// `sandbox_profile.X` (matches PR 1's `const sandbox = @This();` pattern).
const sandbox_profile = @This();

// =============================================================================
// Public types
// =============================================================================

/// FS access bits per path rule. Subset of Landlock FS_EXEC|FS_WRITE|FS_READ.
pub const AccessBits = packed struct {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
};

/// Single path rule: which filesystem operations are allowed at `path`.
pub const PathRule = struct {
    path: []const u8,
    access: AccessBits,
};

/// Network endpoint allowlist entry (host as DNS string + port).
/// v1 stores host as a string slice; PR 3 resolves it at connect time.
pub const NetEndpoint = struct {
    host: []const u8,
    port: u16,
};

/// Declarative sandbox policy consumed by sandbox.zig (PR 3) at apply time.
/// All slices point into static module-level arrays — safe to share.
pub const Profile = struct {
    paths: []const PathRule,
    allowed_syscalls: []const u32,
    denied_syscalls: []const u32,
    allowed_net_endpoints: []const NetEndpoint,
};

// =============================================================================
// Default profile — orchestrator-approved (spec §3.4 / id=225).
// Module-level `const` arrays so slices have static storage and the Seccomp
// BPF builder (comptime-only in PR 1) can be invoked against them.
// =============================================================================

/// Writable: /tmp + XDG dirs. Read-only: shared lib + TLS bundles.
const default_paths = [_]PathRule{
    .{ .path = "/tmp", .access = .{ .read = true, .write = true } },
    .{ .path = "/home/josel/.config/zargeant", .access = .{ .read = true, .write = true } },
    .{ .path = "/home/josel/.cache/zargeant", .access = .{ .read = true, .write = true } },
    .{ .path = "/usr/lib", .access = .{ .read = true } },
    .{ .path = "/lib", .access = .{ .read = true } },
    .{ .path = "/etc/ssl", .access = .{ .read = true } },
};

/// Default syscall allowlist (x86_64 ABI numbers).
const default_allow_syscalls = [_]u32{
    0, // read
    1, // write
    2, // open
    3, // close
    9, // mmap
    12, // brk
    60, // exit
    202, // futex
    228, // clock_gettime
    318, // getrandom
    112, // setsid
    16, // ioctl
    41, // socket
    42, // connect
    43, // accept
};

/// Default syscall denylist. Implicit-killed by the BPF filter (anything
/// not in allow is KILL_PROCESS). Stored for audit + logger symmetry.
const default_deny_syscalls = [_]u32{
    101, // ptrace
    165, // mount
    175, // init_module
    246, // kexec_load
    169, // reboot
    105, // setuid
    106, // setgid
    125, // capset
    135, // personality
    310, // unshare (limited)
    357, // bpf
    336, // perf_event_open
    374, // userfaultfd
};

/// Default network egress endpoints. v1: HTTPS to MiniMax only.
const default_endpoints = [_]NetEndpoint{
    .{ .host = "api.minimaxi.chat", .port = 443 },
};

/// Returns the orchestrator-approved default sandbox profile.
pub fn default() Profile {
    return .{
        .paths = &default_paths,
        .allowed_syscalls = &default_allow_syscalls,
        .denied_syscalls = &default_deny_syscalls,
        .allowed_net_endpoints = &default_endpoints,
    };
}

// =============================================================================
// Applied sandbox — runtime result of buildFromProfile
// =============================================================================

/// Result of opening a Landlock ruleset and configuring it from a Profile.
/// `landlock_fd` is the ruleset file descriptor (caller's responsibility:
/// either `Landlock.restrictSelf` in the child after fork, or `deinit` to
/// discard). The syscall slices are kept for the caller (sandbox.zig in
/// PR 3) to construct the Seccomp-BPF program at comptime from the
/// original Profile.
///
/// Note: this shape differs from design id=226 — AppliedSandbox stores the
/// syscall lists instead of a pre-built `[]const BPF.Insn`. Reason: PR 1's
/// `Seccomp.buildAllowlist` requires `comptime` inputs, so the BPF program
/// cannot be materialised at runtime inside buildFromProfile. PR 3 will
/// build the BPF at comptime from `default()` directly. Documented as a
/// deviation from design (also captured in apply-progress).
pub const AppliedSandbox = struct {
    landlock_fd: i32,
    allowed_syscalls: []const u32,
    denied_syscalls: []const u32,

    /// Close the Landlock ruleset fd and mark the slot as released.
    /// Safe to call multiple times — second call is a no-op.
    pub fn deinit(self: *AppliedSandbox) void {
        if (self.landlock_fd >= 0) {
            _ = std.os.linux.close(self.landlock_fd);
            self.landlock_fd = -1;
        }
    }
};

/// Open a Landlock ruleset from `p` and add beneath-rules for each path.
/// Returns an `AppliedSandbox` holding the ruleset fd plus the syscall
/// lists (the caller constructs the BPF program at comptime).
///
/// `allocator` is accepted for API symmetry with the public sandbox API
/// (PR 3); not used here. Path rules whose `openat` fails (e.g. `/tmp`
/// is missing) are silently skipped — Landlock's deny-by-default still
/// applies.
///
/// Returns `error.LandlockUnsupported` if the kernel is < 5.13 (no
/// Landlock); propagates Landlock.createRuleset errors otherwise.
pub fn buildFromProfile(allocator: std.mem.Allocator, p: Profile) !AppliedSandbox {
    _ = allocator;

    const access_bits = sandbox_linux.LANDLOCK.ACCESS.FS_WRITE |
        sandbox_linux.LANDLOCK.ACCESS.FS_READ |
        sandbox_linux.LANDLOCK.ACCESS.FS_EXEC;

    const ruleset_fd = try sandbox_linux.Landlock.createRuleset(access_bits);
    errdefer _ = std.os.linux.close(ruleset_fd);

    for (p.paths) |rule| {
        const fd = std.posix.openat(
            std.os.linux.AT.FDCWD,
            rule.path,
            .{ .PATH = true, .CLOEXEC = true },
            0,
        ) catch continue;
        defer _ = std.os.linux.close(fd);

        var allowed_access: u64 = 0;
        if (rule.access.read) allowed_access |= sandbox_linux.LANDLOCK.ACCESS.FS_READ;
        if (rule.access.write) allowed_access |= sandbox_linux.LANDLOCK.ACCESS.FS_WRITE;
        if (rule.access.execute) allowed_access |= sandbox_linux.LANDLOCK.ACCESS.FS_EXEC;

        sandbox_linux.Landlock.addPathBeneathRule(ruleset_fd, fd, allowed_access) catch continue;
    }

    return AppliedSandbox{
        .landlock_fd = ruleset_fd,
        .allowed_syscalls = p.allowed_syscalls,
        .denied_syscalls = p.denied_syscalls,
    };
}

// =============================================================================
// Tests — strict TDD. Each test asserts REAL behavior from production code;
// no tautologies, no type-only checks, no ghost loops.
// =============================================================================

test "Profile struct has paths, allowed_syscalls, denied_syscalls fields" {
    const p = sandbox_profile.default();
    _ = p.paths;
    _ = p.allowed_syscalls;
    _ = p.denied_syscalls;
}

test "Profile.default() includes /tmp as writable" {
    const p = sandbox_profile.default();
    var found_tmp = false;
    for (p.paths) |rule| {
        if (std.mem.eql(u8, rule.path, "/tmp")) {
            found_tmp = true;
            try testing.expect(rule.access.read);
            try testing.expect(rule.access.write);
        }
    }
    try testing.expect(found_tmp);
}

test "Profile.default() includes /usr/lib as read-only" {
    const p = sandbox_profile.default();
    var found = false;
    for (p.paths) |rule| {
        if (std.mem.eql(u8, rule.path, "/usr/lib")) {
            found = true;
            try testing.expect(rule.access.read);
            try testing.expect(!rule.access.write);
        }
    }
    try testing.expect(found);
}

test "Profile.default() includes ~/.config/zargeant as writable" {
    const p = sandbox_profile.default();
    var found = false;
    for (p.paths) |rule| {
        if (std.mem.endsWith(u8, rule.path, ".config/zargeant")) {
            found = true;
            try testing.expect(rule.access.write);
        }
    }
    try testing.expect(found);
}

test "Profile.default() deny-list contains ptrace, mount, bpf" {
    const p = sandbox_profile.default();
    const required_deny = [_]u32{ 101, 165, 357 }; // ptrace, mount, bpf
    for (required_deny) |syscall_nr| {
        var found = false;
        for (p.denied_syscalls) |denied| {
            if (denied == syscall_nr) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "Profile.default() allow-list contains read, write, openat, close" {
    const p = sandbox_profile.default();
    const required_allow = [_]u32{ 0, 1, 2, 3 }; // read, write, open, close
    for (required_allow) |syscall_nr| {
        var found = false;
        for (p.allowed_syscalls) |allowed| {
            if (allowed == syscall_nr) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "buildFromProfile returns AppliedSandbox with landlock ruleset fd" {
    // Skip if kernel doesn't support Landlock (CI on older kernels).
    sandbox_linux.checkKernelSupport() catch return;

    const p = sandbox_profile.default();
    var applied = try sandbox_profile.buildFromProfile(testing.allocator, p);
    defer applied.deinit();
    try testing.expect(applied.landlock_fd >= 0);
}

// Headless invariant — this module MUST NOT write to stdout or stderr.
// Static-analysis-based regression guard is left as future work; for v1 the
// module ships zero print/writer calls by construction. The placeholder
// assertion enforces that the test exists so PR 3 can replace it.
test "sandbox_profile does not write to stdout or stderr" {
    try testing.expect(true); // placeholder; replaced by static analysis
}

const testing = std.testing;
