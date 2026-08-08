// test/fixtures_test.zig — Invariant test for the recorded fixture.
//
// Spec:   sdd/api-client/spec   (id=276) §"Recorded fixture has redacted key"
// Design: sdd/api-client/design (id=277) §"test/fixtures/minimax_stream.jsonl"
//
// PR 2 ships the recorded fixture (key REDACTED to `eyJ…[REDACTED]…`) plus a
// compile-time + runtime invariant that scans every fixture file under
// `test/fixtures/` for any real-shape API key (the `eyJ` JWT prefix followed
// by 32+ base64-ish characters). FAILS the build on any match.

const std = @import("std");
const testing = std.testing;

// T2.7 — Enforce the redaction invariant on every recorded fixture.
test "no real keys in fixtures" {
    const allocator = testing.allocator;
    const io = testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "test/fixtures", .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(allocator, &[_][]const u8{ "test/fixtures", entry.name });
        defer allocator.free(path);

        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
        defer allocator.free(content);

        // Forbidden: any `eyJ[A-Za-z0-9._-]{32,}` pattern (real JWT-shaped keys).
        // Allowed: the literal redaction marker `eyJ…[REDACTED]…`.
        var idx: usize = 0;
        while (idx < content.len) {
            const remaining = content[idx..];
            const eyJ_idx = std.mem.indexOf(u8, remaining, "eyJ") orelse break;
            const absolute_eyJ = idx + eyJ_idx;

            // Allow `eyJ…[REDACTED]…` literal.
            if (std.mem.startsWith(u8, remaining[eyJ_idx..], "eyJ…[REDACTED]…")) {
                idx = absolute_eyJ + "eyJ…[REDACTED]…".len;
                continue;
            }

            // After `eyJ`, scan the next 64 chars for the suspicious base64 run.
            const after_prefix = remaining[eyJ_idx + 3 ..];
            var run_len: usize = 0;
            for (after_prefix) |c| {
                const is_base64ish = switch (c) {
                    'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => true,
                    else => false,
                };
                if (!is_base64ish) break;
                run_len += 1;
                if (run_len >= 64) break;
            }

            if (run_len >= 32) {
                std.debug.print("\n[grep-fail-fixtures] forbidden key-shape in {s} at offset {d}\n", .{ path, absolute_eyJ });
                return error.ForbiddenRealKeyInFixture;
            }

            idx = absolute_eyJ + 3 + run_len;
        }
    }
}
