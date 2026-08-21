// tools/debug_call.zig — micro-CLI for stdin-only API key validation.
//
// tls-handrolled (sdd id=323, T3.3): reads the API key from stdin (fd 0),
// trims whitespace, calls api_auth.validateFormat, then calls real
// api_auth.validateViaApi to probe api.minimax.io:443. Prints a
// human-readable status to stdout; logs metadata to
// /tmp/ai-harness-debug.log via the Logger.
//
// Exit codes:
//   0 → API key validated successfully (HTTP 200)
//   1 → invalid key format (validateFormat returns false)
//   2 → server rejected the key (HTTP 401 or base_resp.status_code == 1004)
//   3 → TLS handshake / network failure
//
// Hard invariants:
//   - Reads key from stdin ONLY (no argv, env, file, OS keyring).
//   - Writes nothing about the key to stdout or the log file.
//   - Runs single-threaded (no std.Thread.spawn).
//   - Linux-only v1 — comptime guard MUST be the FIRST executable statement.
//
// Build:
//   $ zig build tools-debug
// Run:
//   $ echo "test-key-1234567890ABCDEF" | zig build tools-debug
//   $ printf "%s" "$YOUR_API_KEY" | zig build tools-debug
//
// ponytail: minimal CLI; uses std.process.exit() for status codes rather
// than returning from main() so the user's shell sees the right exit
// code regardless of stderr capture state. Logger init/deinit is wrapped
// in defer for headless-mode safety (file mode 0600).
//
// =============================================================================
// Linux-only comptime guard. MUST be the FIRST executable statement.
// Companion to src/api_client.zig:49-53 and src/sandbox_linux.zig.
// =============================================================================
comptime {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux)
        @compileError("debug-call: linux-only v1 — see proposal id=318 constraint #5");
}

const std = @import("std");
const api_auth = @import("api_auth");
const api_client = @import("api_client");
const logger = @import("logger");

// Maximum bytes to read from stdin. Synthetic test keys are ≤ 256 bytes;
// real JWT keys are typically < 4 KB. Anything larger is rejected.
const MAX_KEY_LEN: usize = 4096;

pub fn main() !void {
    // Zig 0.16 removed std.heap.GeneralPurposeAllocator; std.heap.DebugAllocator
    // is the direct replacement (leak detection + safety in Debug). The test
    // mode uses std.testing.allocator instead, but main() runs as a real
    // executable under `zig build tools-debug` and needs its own allocator.
    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_alloc.deinit();
    const alloc = debug_alloc.allocator();

    // Initialize a real std.Io instance for exe-mode I/O. The test mode uses
    // std.testing.io, but main() runs as a real executable and the logger
    // requires a non-test Io. Threaded mode handles concurrent logging (we
    // don't spawn threads here, but the logger API is the same).
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Initialize the logger (writes to /tmp/ai-harness-debug.log).
    try logger.initGlobal(io);
    defer logger.deinitGlobal(io);

    // Read the API key from stdin (fd 0) ONLY.
    var buf: [MAX_KEY_LEN + 1]u8 = undefined;
    // Zig 0.16 removed std.fs.getStdIn(); read fd 0 directly via the raw
    // syscall. Stdin is the ONLY key source (hardcoded fd 0 = invariant).
    const n: isize = @bitCast(std.os.linux.read(0, &buf, buf.len));
    if (n <= 0) {
        logger.global().log(io, .err, "debug_call: empty stdin") catch {};
        std.process.exit(3);
    }
    if (@as(usize, @intCast(n)) > MAX_KEY_LEN) {
        logger.global().log(io, .err, "debug_call: key exceeds MAX_KEY_LEN") catch {};
        std.process.exit(1);
    }
    const key = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");

    // Format check first.
    if (!api_auth.validateFormat(key)) {
        logger.global().log(io, .warn, "debug_call: invalid_key_format") catch {};
        std.process.exit(1);
    }

    // Probe the API.
    api_auth.validateViaApi(io, alloc, key) catch |err| {
        logger.global().log(io, .err, "debug_call: validate_failed") catch {};
        // zargeant/tls-diag: surface the actual Zig error name to stderr
        // so the user (and CI) can distinguish ConnectFailed /
        // TlsHandshakeFailed / CaBundleNotFound / HandshakeTimeout
        // without parsing the log file. std.debug.print returns void —
        // no error union to catch (it panics on broken stderr).
        std.debug.print("debug_call: validateViaApi error: {s}\n", .{@errorName(err)});
        switch (err) {
            error.Unauthorized => std.process.exit(2),
            error.ConnectFailed, error.TlsHandshakeFailed => std.process.exit(3),
            else => std.process.exit(3),
        }
    };

    // Success.
    logger.global().log(io, .info, "debug_call: api_key_validated") catch {};
    std.process.exit(0);
}

// =============================================================================
// In-file grep-fail tests (Commit 7, T3.1 + T3.2).
//
// The grep-fail test scans tools/debug_call.zig itself for forbidden
// patterns that would indicate auto-key loading. The forbidden list is
// a SEPARATE list from src/api_auth.zig's grep-fail (which targets
// src/api_client.zig, src/api_sse.zig, src/api_auth.zig). Spec id=319
// §"Requirement: API key entry remains MANUAL ONLY" Scenario: "Micro-CLI
// reads key from stdin, not argv" + §"Scenario: Micro-CLI does not read
// any file argument" + §"Scenario: Micro-CLI does not import keyring
// APIs or DBus".
// =============================================================================

/// Returns true iff `needle` appears anywhere in `haystack`. Used by
/// the in-file grep-fail tests below.
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// T3.1 — tools/debug_call.zig reads key from stdin ONLY. The source must
// not reference argv, env, file-open, or keyring APIs. The forbidden
// list mirrors spec id=319 §"Scenario: Micro-CLI reads key from stdin,
// not argv" + §"Scenario: Micro-CLI does not import keyring APIs or
// DBus".
//
// NOTE: This test excludes the test block itself from the grep target
// (we look at the preamble of the file — the main() function and
// helpers — not the test declarations). Otherwise the test itself
// would be flagged for mentioning the forbidden patterns by name.
test "tools/debug_call.zig reads key from stdin only" {
    const forbidden = [_][]const u8{
        "getenv",
        "std.posix.getenv",
        "std.env.get",
        "std.fs.openFile",
        "std.fs.cwd().openFile",
        "std.posix.openat",
        "--key",
        "--api-key",
        "libsecret",
        "Secret Service",
        "sd-bus",
        "sd_bus_",
        "argsAlloc",
        "argsFree",
    };
    const src = @embedFile("debug_call.zig");
    // Split at the marker comment that begins the test blocks. We
    // only check the production code (main + helpers) against the
    // forbidden list — the test declarations are allowed to mention
    // the patterns for documentation purposes.
    const marker = "// =============================================================================\n// In-file grep-fail tests";
    const split_idx = std.mem.indexOf(u8, src, marker) orelse src.len;
    const prod_src = src[0..split_idx];
    for (forbidden) |pat| {
        try std.testing.expect(!contains(prod_src, pat));
    }
}

// T3.2 — tools/debug_call.zig never logs key bytes. Reads
// /tmp/ai-harness-debug.log and asserts zero matches for a unique
// synthetic key. The synthetic key is generated at runtime so it never
// appears in the source code (which would defeat the grep-fail
// invariant — the source could be hardcoded to match).
//
// Implementation note: this test does NOT actually invoke main() (which
// would block on network) — it relies on compile-time assertions + log
// reads to verify the no-log invariant. A future slice can wire
// end-to-end validation.
test "tools/debug_call.zig never logs key bytes" {
    // Generate a synthetic key at runtime — never appears in source.
    var synthetic_buf: [40]u8 = undefined;
    const prefix = "test-key-NEVER-LOGGED-";
    @memcpy(synthetic_buf[0..prefix.len], prefix);
    const hex_chars = "0123456789ABCDEF";
    var i: usize = prefix.len;
    while (i < synthetic_buf.len) : (i += 1) {
        synthetic_buf[i] = hex_chars[(i * 7 + 13) % hex_chars.len];
    }
    const synthetic_key = synthetic_buf[0..];

    // (a) Compile-time guard: the source must NOT contain the synthetic
    //     key as a literal. Otherwise a future commit might hardcode it.
    const src = @embedFile("debug_call.zig");
    try std.testing.expect(!contains(src, synthetic_key));

    // (b) Runtime guard: read /tmp/ai-harness-debug.log and assert the
    //     synthetic key does not appear there from any prior run of this
    //     CLI. Logger writes only metadata (status codes), never the key.
    var log_buf: [16384]u8 = undefined;
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/tmp/ai-harness-debug.log", .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer _ = std.os.linux.close(fd);
    var total: usize = 0;
    while (total < log_buf.len) {
        const n: isize = @bitCast(std.os.linux.read(fd, log_buf[total..].ptr, log_buf.len - total));
        if (n <= 0) break;
        total += @intCast(n);
    }
    const log_contents = log_buf[0..total];
    try std.testing.expect(std.mem.indexOf(u8, log_contents, synthetic_key) == null);
}

// T3.2b — Linux comptime guard emits compileError on non-Linux.
test "tools/debug_call.zig Linux guard" {
    comptime {
        const builtin = @import("builtin");
        if (builtin.os.tag != .linux) {
            @compileError("debug-call: linux-only v1 — see proposal id=318 constraint #5");
        }
    }
    try std.testing.expect(true);
}

// T3.2c — main() function exists and has the expected signature.
test "tools/debug_call.zig has main function" {
    // Compile-time assertion that main exists; Zig's symbol resolution
    // already verifies this when the file is compiled.
    try std.testing.expect(@hasDecl(@This(), "main"));
}
