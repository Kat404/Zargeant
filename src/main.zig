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
const api_auth = @import("api_auth.zig");

// =============================================================================
// Linux-only comptime guard (matches every other module in the project).
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("main: linux-only v1");
}

// =============================================================================
// Cold-start budget (REQ-TUI-014)
// =============================================================================

/// 50 ms cold-start budget per REQ-TUI-014. R-PR 4 adds a ReleaseFast
/// benchmark test asserting p99 < 50 ms over 1000 iterations; R-PR 2
/// ships the threshold check + warn logging.
pub const COLD_START_BUDGET_NS: u64 = 50 * std.time.ns_per_ms;

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
// Auth preflight (REQ-TUI-038, drift D-1)
//
// `preflightAuthState` resolves the auth state via `api_auth.initialState`
// (which is `fstatat`-only — never reads file content). Wrapped here so
// tests in `tests/tui/runtime_thread.zig` can assert the call site + the
// fstatat-only contract through a static-grep guard. The TUI thread uses
// the result to seed its initial modal state (key_entry vs unlock_prompt).
// =============================================================================

/// Resolve the auth state before `Runtime.run()`. Thin wrapper around
/// `api_auth.initialState` (which fstatats the XDG credentials path).
/// Returns `needs_first_entry` when no credentials file exists, or
/// `has_disk_file` when one does. The `has_memory_key` variant is a
/// post-unlock session state, NOT an `initialState()` return.
pub fn preflightAuthState() api_auth.AuthState {
    return api_auth.initialState();
}

// =============================================================================
// Cold-start timing (REQ-TUI-014)
// =============================================================================

/// Log `warn` if `elapsed_ns` exceeds `COLD_START_BUDGET_NS`. The budget
/// covers: kernel check (`sandbox.Sandbox.checkKernelSupport`),
/// `logger.initGlobal(io)`, and `Runtime.run()` entry. Caller passes the
/// elapsed time since the cold-start anchor placed at the top of `main`.
pub fn warnIfColdStartExceeded(io: std.Io, elapsed_ns: u64) !void {
    if (elapsed_ns > COLD_START_BUDGET_NS) {
        var buf: [128]u8 = undefined;
        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
        const budget_ms = COLD_START_BUDGET_NS / std.time.ns_per_ms;
        const msg = std.fmt.bufPrint(
            &buf,
            "cold-start took {d}ms (budget {d}ms)",
            .{ elapsed_ms, budget_ms },
        ) catch return;
        try logger.global().log(io, .warn, msg);
    }
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

    // Cold-start anchor — placed at the start of the [kernel check,
    // logger init, Runtime.run] boundary per REQ-TUI-014.
    const cold_start = std.Io.Timestamp.now(init.io, .real);

    // Kernel check. Logger not yet initialized, so we can't log — exit 1
    // on failure.
    sandbox.Sandbox.checkKernelSupport() catch {
        std.process.exit(1);
    };

    // Logger init (REQ-TUI-015 — headless /tmp/ai-harness-debug.log).
    logger.initGlobal(init.io) catch {};

    // Cold-start timing check (REQ-TUI-014). Warn if >50ms.
    const now = std.Io.Timestamp.now(init.io, .real);
    const elapsed_ns: u64 = @intCast(std.Io.Timestamp.durationTo(cold_start, now).nanoseconds);
    warnIfColdStartExceeded(init.io, elapsed_ns) catch {};

    // Auth preflight (REQ-TUI-038) — resolve the starting AuthState
    // (fstatat-only) before Runtime.run() and thread it through Config.
    // The TUI thread uses it to seed the modal state (.key_entry vs
    // .unlock_prompt).
    const auth_state = preflightAuthState();

    // --mock wiring (REQ-VER-005/008) — when --mock is set, start the
    // mock server and thread its handle into Config.mock_handle. The
    // Agent body uses the handle to pull the ephemeral port when
    // building the Request (target_host="127.0.0.1", target_port=port,
    // tls=false). Without --mock, mock_handle stays null and the
    // Agent body takes the real-mode branch (api.minimax.io:443).
    const mock_server_pkg = @import("mock_server.zig");
    var mock_handle: ?*mock_server_pkg.Handle = null;
    if (parsed.mock_mode) {
        mock_handle = mock_server_pkg.start(std.heap.page_allocator) catch {
            std.process.exit(1);
        };
        defer mock_handle.?.deinit();
    }

    // Runtime.run() delegation. R-PR 2 ships the R-PR 1 Runtime stub;
    // R-PR 4 replaces the TUI thread body with the real mibu lifecycle.
    var rt = runtime.Runtime.spawn(.{
        .mock_mode = parsed.mock_mode,
        .tls_gated = parsed.tls_gated,
        .initial_auth_state = auth_state,
        .mock_handle = mock_handle,
    }) catch {
        std.process.exit(1);
    };
    defer rt.deinit();
    rt.run(init.io) catch {};
}

// =============================================================================
// Tests (REQ-TUI-017: 5 CLI tests; REQ-TUI-014: 2 cold-start tests)
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

test "warnIfColdStartExceeded logs warn when >50ms" {
    // REQ-TUI-014 scenario 1 — warn fires when cold-start >50ms.
    // We pass an explicit elapsed_ns (the "mock clock" injects delay).
    try logger.initGlobal(testing.io);
    defer logger.deinitGlobal(testing.io);

    const elapsed_ns = 51 * std.time.ns_per_ms;
    try warnIfColdStartExceeded(testing.io, elapsed_ns);

    // Read log file and verify the warn message.
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        logger.defaultPath,
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(contents);
    try testing.expect(std.mem.indexOf(u8, contents, "[WARN]") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "cold-start took 51ms") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "(budget 50ms)") != null);
}

test "warnIfColdStartExceeded does not log when <=50ms" {
    // REQ-TUI-014 — triangulation: when the budget is met, no warn is
    // emitted. The log file is truncated at initGlobal() so the only
    // bytes after the call should be empty.
    try logger.initGlobal(testing.io);
    defer logger.deinitGlobal(testing.io);

    const elapsed_ns = 10 * std.time.ns_per_ms;
    try warnIfColdStartExceeded(testing.io, elapsed_ns);

    // Read the log file — should be empty (no entries written).
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        logger.defaultPath,
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(contents);
    try testing.expectEqual(@as(usize, 0), contents.len);
}

// =============================================================================
// R-PR 4 tests — REQ-TUI-017 scenario 2/3 (--mock → mock_server, --tls-gated
// → env var injection). The CLI parser produces ParsedArgs; we verify
// the threading to runtime.Config shape.
// =============================================================================

const runtime_cfg = @import("runtime.zig").Config;

test "Runtime.Config mock_mode threaded from --mock" {
    // REQ-TUI-017 scenario 2 — --mock routes the Agent through
    // mock_server.zig via the runtime.Config.mock_mode flag.
    const argv = [_][]const u8{ "zargeant", "--mock" };
    const parsed = try parseArgs(&argv);
    const cfg: runtime_cfg = .{
        .mock_mode = parsed.mock_mode,
        .tls_gated = parsed.tls_gated,
    };
    try testing.expect(cfg.mock_mode);
    try testing.expect(!cfg.tls_gated);
}

test "Runtime.Config tls_gated threaded from --tls-gated" {
    // REQ-TUI-017 scenario 3 — --tls-gated sets ZARGEANT_RUN_TLS_HANDSHAKE=1
    // via the runtime.Config.tls_gated flag (the Agent thread sets the env
    // var at startup, see runtime.zig).
    const argv = [_][]const u8{ "zargeant", "--tls-gated" };
    const parsed = try parseArgs(&argv);
    const cfg: runtime_cfg = .{
        .mock_mode = parsed.mock_mode,
        .tls_gated = parsed.tls_gated,
    };
    try testing.expect(cfg.tls_gated);
    try testing.expect(!cfg.mock_mode);
}

test "Runtime.Config defaults when neither flag is set" {
    const argv = [_][]const u8{"zargeant"};
    const parsed = try parseArgs(&argv);
    const cfg: runtime_cfg = .{
        .mock_mode = parsed.mock_mode,
        .tls_gated = parsed.tls_gated,
    };
    try testing.expect(!cfg.mock_mode);
    try testing.expect(!cfg.tls_gated);
}
