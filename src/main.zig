// src/main.zig — tui-recovery R-PR 2 entry point scaffold.
//
// Spec:    sdd/tui-recovery/spec  (id=407) REQ-TUI-015, REQ-TUI-017
// Design:  sdd/tui-recovery/design (id=408) §2.3 R-PR 2
//
// R-PR 2 ships:
//   - CLI flag parsing (REQ-TUI-017: --mock, --tls-gated, --help, unknown → exit 2)
//   - Cold-start timing (REQ-TUI-014: warn if >50ms) — TASK 2.2 lands in
//     a follow-up commit on this branch
//   - Headless logging (REQ-TUI-015: via logger.global())
//
// Runtime.run() delegation lands in R-PR 4 (real mibu lifecycle integration).
// R-PR 2 ships the CLI + headless logging surface; main() spawns the
// R-PR 1 Runtime stub. Real mibu TUI thread body lands in R-PR 4.
//
// Linux/x86_64 Zig 0.16 only.

const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger.zig");
const sandbox = @import("sandbox.zig");
const runtime = @import("runtime.zig");

// =============================================================================
// Linux-only comptime guard (matches every other module in the project).
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("main: linux-only v1");
}

// =============================================================================
// CLI usage (REQ-TUI-017)
// =============================================================================

pub const usage: []const u8 =
    \\Usage: zargeant [--mock] [--tls-gated] [--help]
    \\
    \\Options:
    \\  --mock       Route Agent through mock_server.zig (no real HTTP)
    \\  --tls-gated  Set ZARGEANT_RUN_TLS_HANDSHAKE=1 in Agent env
    \\  --help       Show this help and exit 0
    \\
;

// =============================================================================
// CLI parsing (REQ-TUI-017)
// =============================================================================

pub const ParsedArgs = struct {
    mock_mode: bool = false,
    tls_gated: bool = false,
    help_requested: bool = false,
};

pub const ParseError = error{UnknownFlag};

/// Parse argv into a `ParsedArgs`. Returns `error.UnknownFlag` on the first
/// unrecognized flag. Caller decides what to do with the result — typically
/// print usage to stderr and exit 2 on `error.UnknownFlag`.
pub fn parseArgs(argv: []const []const u8) ParseError!ParsedArgs {
    var args: ParsedArgs = .{};
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--mock")) {
            args.mock_mode = true;
        } else if (std.mem.eql(u8, arg, "--tls-gated")) {
            args.tls_gated = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            args.help_requested = true;
        } else {
            return error.UnknownFlag;
        }
    }
    return args;
}

// =============================================================================
// Main entry point (REQ-TUI-015, REQ-TUI-017)
// =============================================================================

pub fn main(init: std.process.Init) !void {
    // Convert init.minimal.args.vector ([]const [*:0]const u8) to a
    // []const []const u8 slice for parseArgs. The vector is bounded by
    // argv's actual length; we cap at 16 which is far more than any
    // realistic invocation.
    const args_vec = init.minimal.args.vector;
    var argv_buf: [16][]const u8 = undefined;
    const argc = @min(args_vec.len, argv_buf.len);
    for (args_vec[0..argc], 0..) |arg, i| {
        argv_buf[i] = std.mem.sliceTo(arg, 0);
    }
    const argv = argv_buf[0..argc];

    // CLI parse (REQ-TUI-017). Unknown flag → exit 2 with usage on stderr.
    const parsed = parseArgs(argv) catch {
        var stderr = std.Io.File.stderr();
        stderr.writeStreamingAll(init.io, usage) catch {};
        std.process.exit(2);
    };

    // --help → exit 0 with usage on stdout.
    if (parsed.help_requested) {
        var stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(init.io, usage) catch {};
        std.process.exit(0);
    }

    // Kernel check. Logger not yet initialized, so we can't log — exit 1
    // on failure. Cold-start timing lands in T2.2 (separate commit).
    sandbox.Sandbox.checkKernelSupport() catch {
        std.process.exit(1);
    };

    // Logger init (REQ-TUI-015 — headless /tmp/ai-harness-debug.log).
    logger.initGlobal(init.io) catch {};

    // Runtime.run() delegation. R-PR 2 ships the R-PR 1 Runtime stub;
    // R-PR 4 replaces the TUI thread body with the real mibu lifecycle.
    var rt = runtime.Runtime.spawn(.{
        .mock_mode = parsed.mock_mode,
        .tls_gated = parsed.tls_gated,
    }) catch {
        std.process.exit(1);
    };
    defer rt.deinit();
    rt.run(init.io) catch {};
}

// =============================================================================
// Tests (REQ-TUI-017: 5 CLI tests)
// =============================================================================

const testing = std.testing;

test "parseArgs no flags returns defaults" {
    // REQ-TUI-017 — no flags = default behavior. Both flags off, no help.
    const argv = [_][]const u8{"zargeant"};
    const parsed = try parseArgs(&argv);
    try testing.expect(!parsed.mock_mode);
    try testing.expect(!parsed.tls_gated);
    try testing.expect(!parsed.help_requested);
}

test "parseArgs --help sets help_requested" {
    // REQ-TUI-017 --help exits 0 with usage on stdout. We test the
    // parsing piece (the exit() in main() is non-testable; manual
    // integration is `zig build run -- --help`).
    const argv = [_][]const u8{ "zargeant", "--help" };
    const parsed = try parseArgs(&argv);
    try testing.expect(parsed.help_requested);
    try testing.expect(!parsed.mock_mode);
    try testing.expect(!parsed.tls_gated);
}

test "parseArgs --mock sets mock_mode" {
    // REQ-TUI-017 --mock routes Agent through mock_server.zig.
    const argv = [_][]const u8{ "zargeant", "--mock" };
    const parsed = try parseArgs(&argv);
    try testing.expect(parsed.mock_mode);
    try testing.expect(!parsed.tls_gated);
    try testing.expect(!parsed.help_requested);
}

test "parseArgs --tls-gated sets tls_gated" {
    // REQ-TUI-017 --tls-gated sets ZARGEANT_RUN_TLS_HANDSHAKE=1 in
    // Agent env. R-PR 4 wires the env into the Agent thread body.
    const argv = [_][]const u8{ "zargeant", "--tls-gated" };
    const parsed = try parseArgs(&argv);
    try testing.expect(parsed.tls_gated);
    try testing.expect(!parsed.mock_mode);
    try testing.expect(!parsed.help_requested);
}

test "parseArgs --bogus returns error.UnknownFlag" {
    // REQ-TUI-017 unknown flag → exit 2 with usage on stderr.
    const argv = [_][]const u8{ "zargeant", "--bogus" };
    try testing.expectError(error.UnknownFlag, parseArgs(&argv));
}
