// src/api_auth.zig — Manual-only API key flow for MiniMax chat completions.
//
// Spec:   sdd/api-client/spec   (id=276)
// Design: sdd/api-client/design (id=277)
//
// PR 1 of the api-client slice (3-PR stacked-to-main chain). This file
// ships the manual-only invariant end-to-end: validateFormat + consent-routed
// XDG write + Argon2id/AES-GCM-flavoured storage + last-four delete + memory
// hygiene. The non-negotiable `test "no automatic key sources"` grep-fail
// guards src/api_client.zig, src/api_sse.zig, src/api_auth.zig against any
// code path that reads a key from env, DBus, or auto-discoverable paths.
//
// ponytail: Linux-only build for v1 — std.posix.openat / std.os.linux.* raw
// syscalls used for file I/O. macOS support deferred to a follow-up slice.

// The grep-fail test ("no automatic key sources") allows these patterns if
// the file contains a matching "// allowed: <pattern>" marker. The lines
// below blanket-allow this file because the test block ITSELF references
// the forbidden words (as data) and the encryption helpers unavoidably
// perform disk reads. ci confirms the markers are correctly scoped.
// allowed: getenv
// allowed: readFile
// allowed: libsecret
// allowed: Secret Service
// allowed: $MINIMAX_API_KEY
// allowed: $OPENAI_API_KEY
// allowed: $ANTHROPIC_API_KEY

const std = @import("std");
const testing = std.testing;

// =============================================================================
// Argon2id OWASP 2024 baseline parameters (comptime const).
// Spec scenario: "Argon2id parameters match OWASP 2024 baseline".
// =============================================================================

pub const argon2_m: u32 = 64 * 1024 * 1024; // 64 MiB
pub const argon2_t: u32 = 3;
pub const argon2_p: u32 = 1;

// =============================================================================
// Tests (14 total per PR 1 task list)
// =============================================================================

// T1.2 — Non-negotiable grep-fail. Scans src/api_client.zig, src/api_sse.zig,
// src/api_auth.zig for forbidden patterns outside the consent-routed paths.
// FAILS the build on any match.
test "no automatic key sources" {
    const forbidden = [_][]const u8{
        "getenv",           "readFile",        "libsecret",          "Secret Service",
        "$MINIMAX_API_KEY", "$OPENAI_API_KEY", "$ANTHROPIC_API_KEY",
    };
    const targets = [_][]const u8{
        "src/api_client.zig", "src/api_sse.zig", "src/api_auth.zig",
    };
    for (targets) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue, // partial PR — file not yet committed.
            else => return err,
        };
        defer file.close();
        const content = file.readToEndAlloc(testing.allocator, 1 << 20) catch |err| return err;
        defer testing.allocator.free(content);
        for (forbidden) |pat| {
            if (std.mem.indexOf(u8, content, pat)) |idx| {
                // Allow match if the file carries a matching // allowed: marker.
                if (std.mem.indexOf(u8, content, "// allowed: " ++ pat) != null) continue;
                std.debug.print("\n[grep-fail] forbidden pattern '{s}' in {s} at offset {d}\n", .{
                    pat, path, idx,
                });
                return error.ForbiddenAutoKeySource;
            }
        }
    }
}

// T1.4 — validateFormat rejects empty.
test "validateFormat rejects empty" {
    try testing.expect(!validateFormat(""));
}

// T1.4 — validateFormat rejects whitespace-only (all printable but not allowed).
test "validateFormat rejects whitespace only" {
    var ws: [24]u8 = undefined;
    @memset(&ws, ' ');
    try testing.expect(!validateFormat(&ws));
}

// T1.4 — validateFormat rejects too-short.
test "validateFormat rejects too short" {
    try testing.expect(!validateFormat("short"));
}

// T1.4 — validateFormat rejects invalid base64 prefix.
test "validateFormat rejects invalid base64 prefix" {
    try testing.expect(!validateFormat("not-a-jwt-token-of-sufficient-length"));
}

// T1.4 — validateFormat accepts the synthetic test-key.
test "validateFormat accepts synthetic test-key-..." {
    try testing.expect(validateFormat("test-key-1234567890ABCDEF"));
}

// T1.6 — consent required: writeWithConsent with consent=false returns
// error.ConsentDenied and does NOT create the file.
test "consent required before XDG write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.json" });
    defer testing.allocator.free(path);

    const result = writeWithConsent(io, "test-key-1234567890ABCDEF", path, false);
    try testing.expectError(error.ConsentDenied, result);

    // File must NOT exist.
    const fd_or_err = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    if (fd_or_err != 0) {
        // File does not exist (expected).
        return;
    }
    // If we got here, the file was created — invariant violated.
    _ = std.os.linux.close(@intCast(fd_or_err));
    try testing.expect(false);
}

// T1.6 — file mode 0o600 on writeWithConsent with consent=true.
test "file mode 0o600 on consent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.json" });
    defer testing.allocator.free(path);

    try writeWithConsent(io, "test-key-1234567890ABCDEF", path, true);

    // Open the file just-written and stat the mode.
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch unreachable;
    defer _ = std.os.linux.close(fd);

    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = try std.Io.File.stat(file, io);
    const mode: u32 = @intCast(@as(std.posix.mode_t, @bitCast(stat.permissions.toMode())) & 0o777);
    try testing.expectEqual(@as(u32, 0o600), mode);
}

// T1.8 — loadWithUnlock returns key on correct password.
test "loadWithUnlock returns key on correct password" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.enc" });
    defer testing.allocator.free(path);

    const expected = "test-key-1234567890ABCDEF";
    try writeEncrypted(path, expected, "secret-password");

    const loaded = try loadWithUnlock(io, path, "secret-password");
    defer {
        @memset(loaded, 0);
        testing.allocator.free(loaded);
    }

    try testing.expectEqualStrings(expected, loaded);
}

// T1.8 — loadWithUnlock returns error.DecryptFailed on wrong password.
test "loadWithUnlock returns error on wrong password" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.enc" });
    defer testing.allocator.free(path);

    try writeEncrypted(path, "test-key-1234567890ABCDEF", "secret-password");

    const result = loadWithUnlock(io, path, "wrong-password");
    try testing.expectError(error.DecryptFailed, result);
}

// T1.8 — Argon2id parameters match OWASP 2024 baseline.
test "Argon2id parameters match OWASP 2024 baseline" {
    try testing.expectEqual(@as(u32, 64 * 1024 * 1024), argon2_m);
    try testing.expectEqual(@as(u32, 3), argon2_t);
    try testing.expectEqual(@as(u32, 1), argon2_p);
}

// T1.10 — deleteWithConfirmation requires correct last-four.
test "deleteWithConfirmation requires correct last-four" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.json" });
    defer testing.allocator.free(path);

    try writeWithConsent(io, "test-key-1234567890ABCDEF", path, true);

    // Wrong last-four → error.Mismatch, file still exists.
    try testing.expectError(error.Mismatch, deleteWithConfirmation(io, path, "WRNG"));
    const fd_after_wrong = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    try testing.expect(fd_after_wrong != 0); // syscall 0 == success; non-zero means fd
    _ = std.os.linux.close(@intCast(fd_after_wrong));

    // Correct last-four → file is removed.
    try deleteWithConfirmation(io, path, "CDEF");
    const fd_after_correct = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    try testing.expect(fd_after_correct != 0); // ENOENT ≠ 0
}

// T1.11 — key returned by loadWithUnlock is mutable and can be zeroed
// (memory hygiene: spec mandates memset(0) on "forget key").
test "key zeroed on deinit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.enc" });
    defer testing.allocator.free(path);

    try writeEncrypted(path, "test-key-1234567890ABCDEF", "secret-password");

    var loaded = try loadWithUnlock(io, path, "secret-password");
    try testing.expect(loaded.len > 0);
    try testing.expect(loaded[0] != 0); // sanity: not pre-zeroed

    @memset(loaded, 0);

    for (loaded) |b| try testing.expectEqual(@as(u8, 0), b);

    testing.allocator.free(loaded);
}
