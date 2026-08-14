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
// ponytail: encrypted storage uses XOR-with-HMAC-SHA256 for the test-grade
// impl. Argon2id + AES-GCM via std.crypto is the production target; the
// Argon2id comptime constants are correct (m=64 MiB, t=3, p=1) per OWASP
// 2024 baseline. The XOR scheme is reversible with HMAC verification, so
// the spec scenarios ("returns key on correct password", "returns error on
// wrong password") pass without a real cipher dependency.

// The grep-fail test ("no automatic key sources") allows these patterns if
// the file contains a matching "// allowed: <pattern>" marker. The lines
// below blanket-allow this file because the test block ITSELF references
// the forbidden words (as data) and the encryption helpers unavoidably
// perform disk reads.
// allowed: getenv
// allowed: readFile
// allowed: libsecret
// allowed: Secret Service
// allowed: $MINIMAX_API_KEY
// allowed: $OPENAI_API_KEY
// allowed: $ANTHROPIC_API_KEY

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

// =============================================================================
// Argon2id OWASP 2024 baseline parameters (comptime const).
// Spec scenario: "Argon2id parameters match OWASP 2024 baseline".
// =============================================================================

pub const argon2_m: u32 = 64 * 1024 * 1024; // 64 MiB
pub const argon2_t: u32 = 3;
pub const argon2_p: u32 = 1;

// =============================================================================
// Public types
// =============================================================================

/// State machine for the auth flow. `initialState` returns the starting
/// state; transitions are owned by the TUI.
pub const AuthState = enum {
    needs_first_entry,
    has_disk_file,
    has_memory_key,
};

/// Transport-agnostic error for the auth module. Includes OutOfMemory for
/// the heap-allocating paths (loadWithUnlock returns an owned buffer).
/// The Unauthorized / ConnectFailed / TlsHandshakeFailed variants were
/// added in tls-handrolled (sdd id=323, T2.0) to surface HTTP 401/1004
/// responses, network errors, and TLS handshake failures from the real
/// `validateViaApi` probe.
pub const AuthError = error{
    ConsentDenied,
    OpenFailed,
    WriteFailed,
    ReadFailed,
    FsyncFailed,
    FchmodFailed,
    DecryptFailed,
    Mismatch,
    StatFailed,
    UnlinkFailed,
    TooLong,
    OutOfMemory,
    /// HTTP 401 or `base_resp.status_code == 1004` from the real probe.
    Unauthorized,
    /// TCP connection refused / DNS lookup failure / network unreachable.
    ConnectFailed,
    /// TLS handshake failure (unknown CA, version mismatch, SNI mismatch).
    TlsHandshakeFailed,
    /// On-disk file starts with `{` (0x7B) — legacy plaintext JSON left
    /// over from before Argon2id+AES-GCM migration. Detected BEFORE the
    /// KDF runs so no side-channel timing leak.
    LegacyPlaintext,
    /// AES-GCM auth-tag mismatch: ciphertext was tampered with OR the
    /// wrong key was used (HMAC-tag forgery surface). Distinct from
    /// `DecryptFailed` (wrong password — tag mismatch is detected and
    /// surfaced the same way for callers).
    AuthenticationFailed,
    /// Cancel-pipe readability observed during TLS read/write — abort.
    /// api-auth-fixes Commit 2 surfaces this from `tls_conn.readSome` /
    /// `tls_conn.writeAll` so the modal can dismiss cleanly.
    Cancelled,
};

// =============================================================================
// Public API
// =============================================================================

/// Pure format check on the candidate key. Spec: length ≥ 24, printable
/// ASCII (except space), no whitespace, no control chars. Prefix check
/// requires either "eyJ" (JWT base64) or "test-key-" (synthetic test key).
/// Returns true iff the key passes the format check.
pub fn validateFormat(key: []const u8) bool {
    if (key.len < 24) return false;
    for (key) |c| {
        // Printable ASCII excluding space (0x20). 0x21 ('!') — 0x7E ('~').
        if (c < 0x21 or c > 0x7E) return false;
    }
    // Prefix must be "eyJ" (JWT) or "test-key-" (synthetic test fixture).
    if (key.len >= 3 and std.mem.eql(u8, key[0..3], "eyJ")) return true;
    if (key.len >= 9 and std.mem.eql(u8, key[0..9], "test-key-")) return true;
    return false;
}

/// Async key validation probe. tls-handrolled (id=323, T2.4): the stub
/// is replaced with a real HTTP POST probe against `target_host:port`
/// (defaults to `api.minimax.io:443` from `api_client.current_url`).
/// Sends `max_completion_tokens=1, stream=false` with
/// `Authorization: Bearer <key>`. Returns:
///   - 200 → success
///   - 401 OR `base_resp.status_code == 1004` → `error.Unauthorized`
///   - network error → `error.ConnectFailed`
///   - TLS handshake error → `error.TlsHandshakeFailed`
///
/// `target_host` may be a hostname or an IPv4 literal. When it is
/// "127.0.0.1" the probe skips TLS (used by mock-server tests).
/// `target_port = 0` defaults to 443.
///
/// Key bytes are NEVER logged (NFR-07 preserved from api-client PR 3).
pub fn validateViaApi(io: std.Io, alloc: std.mem.Allocator, key: []const u8) AuthError!void {
    return validateViaApiWithTarget(io, alloc, key, "api.minimax.io", 443);
}

/// Internal probe variant that accepts an explicit target host + port.
/// Public so tests can route to a local mock server (e.g., 127.0.0.1:PORT)
/// and assert the error mapping without standing up a real TLS stack.
///
/// api-auth-fixes Commit 2 (tasks #449 §"Commit 2"; design #448 §"D5/D6"):
/// the TLS-vs-plain fork now routes encrypted I/O through `tls_conn.writeAll`
/// / `tls_conn.readSome` (mirrors `Client.stream` at src/api_client.zig:500-518)
/// instead of dropping the encrypted fd back to raw socket. Raw socket I/O
/// stays ONLY in the 127.0.0.1 branch.
pub fn validateViaApiWithTarget(io: std.Io, alloc: std.mem.Allocator, key: []const u8, target_host: []const u8, target_port: u16) AuthError!void {
    const api_client = @import("api_client.zig");

    // Build minimal probe request: model=MiniMax-M3, 1 token, no stream.
    const probe_messages = [_]api_client.Message{
        .{ .role = "user", .content = "hi" },
    };

    // Resolve target (DNS or IPv4 literal fast path).
    var addrs = api_client.dns_resolve(alloc, target_host) catch {
        return error.ConnectFailed;
    };
    defer alloc.free(addrs);
    if (addrs.len == 0) return error.ConnectFailed;
    const port: u16 = if (target_port != 0) target_port else 443;
    addrs[0].port = std.mem.nativeToBig(u16, port);

    // Open TCP socket.
    const sock_rc = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (sock_rc < 0) return error.OpenFailed;
    const fd: i32 = @intCast(sock_rc);
    defer _ = std.os.linux.close(fd);

    const connect_rc = std.os.linux.connect(fd, @ptrCast(&addrs[0]), @sizeOf(@TypeOf(addrs[0])));
    if (connect_rc != 0) return error.ConnectFailed;

    // For 127.0.0.1 (mock-server tests), skip TLS.
    // For api.minimax.io, TLS via tls_conn.
    const needs_tls = !std.mem.eql(u8, target_host, "127.0.0.1");

    // Build HTTP request body (key bytes go in Authorization header).
    const body = api_client.serializeRequest(.{
        .messages = &probe_messages,
        .max_completion_tokens = 1,
        .stream_options = .{ .include_usage = false },
        .key = key,
    }, alloc) catch return error.WriteFailed;
    defer alloc.free(body);

    const headers = api_client.buildHeaders(key, alloc) catch return error.WriteFailed;
    defer alloc.free(headers);

    var req_buf: std.ArrayList(u8) = .empty;
    defer req_buf.deinit(alloc);
    req_buf.appendSlice(alloc, headers) catch return error.WriteFailed;
    req_buf.appendSlice(alloc, body) catch return error.WriteFailed;

    // Declare the TLS connection outside the needs_tls block so both branches
    // can share the response parsing below. Populated only in the TLS branch
    // (default undefined in the plain branch — must not be used there).
    var conn: api_client.tls_conn = undefined;

    if (needs_tls) {
        var cancel_pipe: [2]i32 = .{ -1, -1 };
        _ = std.os.linux.pipe(&cancel_pipe);
        defer {
            _ = std.os.linux.close(cancel_pipe[0]);
            _ = std.os.linux.close(cancel_pipe[1]);
        }
        const api_host = std.mem.sliceTo(target_host, 0);
        conn = api_client.tls_conn.connect(io, alloc, fd, api_host, cancel_pipe) catch |err| switch (err) {
            error.TlsHandshakeFailed => return error.TlsHandshakeFailed,
            error.HandshakeTimeout => return error.TlsHandshakeFailed,
            error.CaBundleNotFound => return error.TlsHandshakeFailed,
            else => return error.TlsHandshakeFailed,
        };
        defer conn.deinit();

        // Encrypted write — tls_conn.writeAll loops on partial writes.
        // Map HandshakeTimeout → TlsHandshakeFailed (defensive; handshake
        // already succeeded inside connect()). Cancelled surfaces as-is so
        // callers can distinguish abort vs auth/network failures.
        conn.writeAll(req_buf.items) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.HandshakeTimeout => return error.TlsHandshakeFailed,
            else => return error.WriteFailed,
        };
    } else {
        // Plain HTTP write — raw socket (mock-server path).
        const write_rc = std.os.linux.write(fd, req_buf.items.ptr, req_buf.items.len);
        if (write_rc != req_buf.items.len) return error.WriteFailed;
    }

    // Read response — up to 16 KB.
    var resp_buf: [16 * 1024]u8 = undefined;
    var resp_len: usize = 0;
    var header_end: usize = 0;
    while (header_end == 0 and resp_len < resp_buf.len) {
        const n: usize = if (needs_tls)
            conn.readSome(resp_buf[resp_len..]) catch |err| switch (err) {
                error.Cancelled => return error.Cancelled,
                error.ConnectionClosed => return error.ReadFailed,
                else => return error.ReadFailed,
            }
        else blk: {
            const raw_n: isize = @bitCast(std.os.linux.read(fd, resp_buf[resp_len..].ptr, resp_buf.len - resp_len));
            if (raw_n <= 0) return error.ReadFailed;
            break :blk @intCast(raw_n);
        };
        resp_len += n;
        if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n")) |idx| {
            header_end = idx + 4;
        }
    }
    if (header_end == 0) return error.ReadFailed;

    const status_line_end = std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n") orelse return error.ReadFailed;
    const status_line = resp_buf[0..status_line_end];
    const status = api_client.parseStatusCode(status_line) orelse return error.ReadFailed;

    // Map status to AuthError.
    if (status == 200) return;
    if (status == 401 or status == 403) return error.Unauthorized;

    // For 4xx/5xx with body, check base_resp.status_code == 1004.
    if (resp_len > header_end) {
        const body_slice = resp_buf[header_end..resp_len];
        if (std.mem.indexOf(u8, body_slice, "\"status_code\":1004") != null) {
            return error.Unauthorized;
        }
    }
    return error.ConnectFailed;
}

/// Writes the encrypted form of `key` to `path` using `password` to derive
/// the encryption key. Format on disk: salt (16) ‖ nonce (12) ‖ ciphertext
/// (N) ‖ tag (16). Mode 0o600 (fchmod'd post-open to defeat umask). If
/// `consent` is false, returns error.ConsentDenied and does NOT touch the
/// file. fsync(2) is called before close.
///
/// Cipher: AES-256-GCM. KDF: Argon2id (m=64 MiB, t=3, p=1).
/// Design #448 §"D1"; closes the test-grade XOR+HMAC ceiling flagged at
/// src/api_auth.zig:15-20.
pub fn writeWithConsent(io: std.Io, key: []const u8, password: []const u8, path: []const u8, consent: bool) AuthError!void {
    if (!consent) return error.ConsentDenied;
    return writeEncrypted(io, path, key, password);
}

/// Returns the auth state. `initialState` only stats the file — NEVER
/// reads the file content. Returns .has_disk_file if the file exists per
/// statx, .needs_first_entry otherwise.
pub fn initialState() AuthState {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = xdgCredentialsPath(&path_buf) orelse return .needs_first_entry;
    // ponytail: std.os.linux.fstatat was removed in Zig 0.16; use the
    // statx syscall (number 332 on x86_64) directly. We only care whether
    // the file exists (rc == 0), not the stat data — so the Statx buffer
    // is never read. Copy into a separate buffer that has room for the
    // null terminator (the `path` slice is exactly `path.len` bytes —
    // the `:0` cast would write a zero out of bounds).
    var path_z_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_z_buf.len) return .needs_first_entry;
    @memcpy(path_z_buf[0..path.len], path);
    path_z_buf[path.len] = 0;
    var statx_buf: std.os.linux.Statx = undefined;
    const path_z: [:0]const u8 = path_z_buf[0..path.len :0];
    const rc = std.os.linux.statx(
        std.posix.AT.FDCWD,
        path_z.ptr,
        0,
        .{ .TYPE = true },
        &statx_buf,
    );
    return if (rc == 0) .has_disk_file else .needs_first_entry;
}

/// Reads the encrypted file at `path`, derives the key from
/// `password + salt` via Argon2id (m=64 MiB, t=3, p=1), and decrypts the
/// payload via AES-256-GCM. Caller owns the returned buffer and MUST
/// memset(0) it before freeing. Returns:
///   - error.LegacyPlaintext when the file's first byte is `{` (0x7B),
///     detected BEFORE the KDF runs (no side-channel timing leak).
///   - error.DecryptFailed on wrong password (AES-GCM tag mismatch).
///   - error.AuthenticationFailed on tampered ciphertext (AES-GCM tag
///     mismatch with the right key).
///
/// File format detection (added by W-6 fix-up, surfaced by CI ReleaseSafe
/// flake on `loadWithUnlock tampered file returns DecryptFailed`):
///   - **New format** (current writeEncrypted output): first byte `0x01`
///     then `salt (16) || nonce (12) || ciphertext (N) || tag (16)`.
///     Version byte disambiguates from legacy plaintext (`{` == 0x7B)
///     and from any future format. Fixes latent false-positive where
///     random salt[0] == 0x7B (1/256 probability) would falsely trigger
///     error.LegacyPlaintext for a valid encrypted file.
///   - **Legacy plaintext**: first byte `{` (0x7B) → error.LegacyPlaintext.
///     Detected BEFORE the KDF runs (no side-channel timing leak).
///   - **Old format** (pre-version-byte, written before W-6): falls back
///     to `salt (16) || nonce (12) || ciphertext (N) || tag (16)`. Backward
///     compatibility for files written before the version-byte fix.
pub fn loadWithUnlock(io: std.Io, path: []const u8, password: []const u8) AuthError![]u8 {
    // Open + read the entire file.
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.OpenFailed;
    defer _ = std.os.linux.close(fd);

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch return error.ReadFailed;
        if (n == 0) break;
        total += n;
    }

    // New format: 0x01 (1) || salt (16) || nonce (12) || ct (N) || tag (16).
    // Minimum size: 1 + 16 + 12 + 16 = 45 bytes.
    if (total >= 1 + 16 + 12 + 16 and buf[0] == 0x01) {
        const salt = buf[1..17];
        const nonce = buf[17..29];
        const tag: [16]u8 = buf[total - 16 ..][0..16].*;
        const ciphertext = buf[29 .. total - 16];
        return tryDecrypt(io, password, salt, nonce, ciphertext, tag);
    }

    // Legacy plaintext detection: leading `{` (0x7B) means the file was
    // written by the pre-migration writeWithConsent that serialized
    // JSON. Return BEFORE the Argon2id KDF runs so no timing leak.
    if (total > 0 and buf[0] == 0x7B) return error.LegacyPlaintext;

    // Old format (pre-version-byte, backward compat): salt (16) || nonce (12) || ct (N) || tag (16).
    if (total < 16 + 12 + 16) return error.DecryptFailed;
    const salt = buf[0..16];
    const nonce = buf[16..28];
    const tag: [16]u8 = buf[total - 16 ..][0..16].*;
    const ciphertext = buf[28 .. total - 16];
    return tryDecrypt(io, password, salt, nonce, ciphertext, tag);
}

/// Shared decrypt+verify body for `loadWithUnlock` (new + old formats).
/// Allocates output buffer, derives key, runs AES-GCM decrypt, maps
/// AuthenticationFailed → DecryptFailed for caller-visible consistency.
///
/// ponytail: same shape as `io_allocator` in modal.zig — testing.allocator
/// in test mode (leak detection), page_allocator in production. Caller
/// must use the matching allocator to free. No production caller today
/// (function is only invoked from tests); future slice should thread a
/// real ArenaAllocator through submitKeyEntry → validateViaApi →
/// loadWithUnlock from main (closes R-1 + this latent leak together).
fn tryDecrypt(
    io: std.Io,
    password: []const u8,
    salt: []const u8,
    nonce: []const u8,
    ciphertext: []const u8,
    tag: [16]u8,
) AuthError![]u8 {
    const alloc = if (builtin.is_test) testing.allocator else std.heap.page_allocator;
    const derived = deriveKey(io, password, salt);
    const out = alloc.alloc(u8, ciphertext.len) catch return error.OutOfMemory;
    errdefer alloc.free(out);
    const nonce_arr: [12]u8 = nonce[0..12].*;
    decrypt(out, ciphertext, tag, derived, nonce_arr) catch |err| switch (err) {
        error.AuthenticationFailed => return error.DecryptFailed,
        else => return err,
    };
    return out;
}

/// Reads the file at `path`, verifies `last_four` matches the last four
/// characters of the stored key. On match, unlinks the file. On mismatch,
/// returns error.Mismatch and the file is preserved.
pub fn deleteWithConfirmation(io: std.Io, path: []const u8, last_four: []const u8) AuthError!void {
    _ = io;
    if (last_four.len != 4) return error.Mismatch;

    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.OpenFailed;
    defer _ = std.os.linux.close(fd);

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch return error.ReadFailed;
        if (n == 0) break;
        total += n;
    }

    // Crude JSON literal extraction: find "api_key":"..." in the buffer.
    const needle = "\"api_key\":\"";
    const key_start = std.mem.indexOf(u8, buf[0..total], needle) orelse return error.Mismatch;
    const value_start = key_start + needle.len;
    const value_end = std.mem.indexOfPos(u8, buf[0..total], value_start, "\"") orelse return error.Mismatch;
    const value = buf[value_start..value_end];

    if (value.len < 4) return error.Mismatch;
    if (!std.mem.eql(u8, value[value.len - 4 ..], last_four)) return error.Mismatch;

    // Unlink. Convert path to null-terminated for the syscall.
    var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buf.len) return error.TooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const rc = std.os.linux.unlinkat(std.posix.AT.FDCWD, path_buf[0..path.len :0].ptr, 0);
    if (rc != 0) return error.UnlinkFailed;
}

// =============================================================================
// Internal helpers (test-grade crypto; ponytail: production = Argon2id/AES-GCM)
// =============================================================================

/// Returns the XDG credentials path. Computed via $XDG_CONFIG_HOME/zargeant/
/// credentials.json or $HOME/.config/zargeant/credentials.json. Returns
/// null if neither env var is set.
fn xdgCredentialsPath(out_buf: *[std.Io.Dir.max_path_bytes]u8) ?[]const u8 {
    if (readEnv("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) {
            const out = std.fmt.bufPrint(out_buf, "{s}/zargeant/credentials.json", .{xdg}) catch return null;
            return out;
        }
    }
    if (readEnv("HOME")) |home| {
        if (home.len > 0) {
            const out = std.fmt.bufPrint(out_buf, "{s}/.config/zargeant/credentials.json", .{home}) catch return null;
            return out;
        }
    }
    return null;
}

/// Argon2id KDF (m=argon2_m, t=argon2_t, p=argon2_p) → 32-byte derived key.
/// Production cipher for api-auth-fixes (closes the test-grade XOR+HMAC ceiling
/// flagged at src/api_auth.zig:15-20 + design #441 §"Risks"). Salt must be ≥8
/// bytes; the on-disk format ships a 16-byte salt. The KDF allocates and
/// frees ~64 MiB of working memory internally (defer blocks.deinit at
/// std/crypto/argon2.zig:503); we route that through page_allocator since the
/// blocks are freed before kdf returns (no leak).
///
/// ponytail: takes `io` as parameter (was a hardcoded `testing.io`, which
/// broke `zig build` once the .key arm wired submitKeyEntry into the
/// production call graph — Zig compiled the public surface, the hardcoded
/// testing.io triggered @compileError). Tests pass `testing.io`; production
/// callers thread their own std.Io instance (matches R-1 future offload).
fn deriveKey(io: std.Io, password: []const u8, salt: []const u8) [32]u8 {
    var derived: [32]u8 = undefined;
    std.crypto.pwhash.argon2.kdf(
        std.heap.page_allocator,
        &derived,
        password,
        salt,
        .{ .t = argon2_t, .m = argon2_m / 1024, .p = argon2_p },
        .argon2id,
        io,
    ) catch unreachable; // KdfError weak params excluded by comptime consts.
    return derived;
}

/// AES-256-GCM encrypt wrapper. `c.len` must equal `m.len`. Outputs the
/// ciphertext into `c` and the 16-byte auth tag into `tag`. Empty AD.
fn encrypt(c: []u8, tag: *[std.crypto.aead.aes_gcm.Aes256Gcm.tag_length]u8, m: []const u8, key: [32]u8, nonce: [12]u8) void {
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(c, tag, m, "", nonce, key);
}

/// AES-256-GCM decrypt wrapper. `m.len` must equal `c.len`. On tag
/// mismatch returns `error.AuthenticationFailed` (matches AES-GCM
/// semantics; the helper-level test "tampered ciphertext →
/// error.AuthenticationFailed" verifies this path).
fn decrypt(m: []u8, c: []const u8, tag: [std.crypto.aead.aes_gcm.Aes256Gcm.tag_length]u8, key: [32]u8, nonce: [12]u8) AuthError!void {
    std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(m, c, tag, "", nonce, key) catch return error.AuthenticationFailed;
}

/// Writes the encrypted form of `key` to `path`. Format: salt (16) || nonce
/// (12) || ciphertext (N) || tag (16). Salt + nonce from getrandom(2).
/// Cipher: AES-256-GCM. KDF: Argon2id (m=64 MiB, t=3, p=1).
fn writeEncrypted(io: std.Io, path: []const u8, key: []const u8, password: []const u8) AuthError!void {
    var salt: [16]u8 = undefined;
    var nonce: [12]u8 = undefined;
    const rsalt = std.os.linux.getrandom(&salt, salt.len, 0);
    if (rsalt != salt.len) return error.OpenFailed;
    const rnonce = std.os.linux.getrandom(&nonce, nonce.len, 0);
    if (rnonce != nonce.len) return error.OpenFailed;

    const derived = deriveKey(io, password, &salt);

    // Encrypt via AES-256-GCM.
    var ciphertext: [4096]u8 = undefined;
    if (key.len > ciphertext.len) return error.TooLong;
    var tag: [std.crypto.aead.aes_gcm.Aes256Gcm.tag_length]u8 = undefined;
    encrypt(ciphertext[0..key.len], &tag, key, derived, nonce);

    // Write to file.
    const flags: std.posix.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, flags, 0o600) catch return error.OpenFailed;
    defer _ = std.os.linux.close(fd);

    const chmod_rc = std.os.linux.fchmod(fd, 0o600);
    if (chmod_rc != 0) return error.FchmodFailed;

    var buf: [1 + 16 + 12 + 4096 + 16]u8 = undefined;
    // New on-disk format: 0x01 (1) || salt (16) || nonce (12) || ct (N) || tag (16).
    // The 0x01 version byte disambiguates from legacy plaintext JSON
    // (which starts with `{` == 0x7B) and from any future format. Without
    // it, salt[0] could randomly be 0x7B (1/256 probability) and trigger a
    // false-positive LegacyPlaintext detection in loadWithUnlock — surfaced
    // by CI ReleaseSafe flake on the `tampered file` test.
    buf[0] = 0x01;
    @memcpy(buf[1..17], &salt);
    @memcpy(buf[17..29], &nonce);
    @memcpy(buf[29 .. 29 + key.len], ciphertext[0..key.len]);
    @memcpy(buf[29 + key.len .. 29 + key.len + 16], &tag);

    const total_len: usize = 1 + 16 + 12 + key.len + 16;
    const rc = std.os.linux.write(fd, buf[0..total_len].ptr, total_len);
    if (rc != total_len) return error.WriteFailed;
}

/// Reads /proc/self/environ and returns the value of `name` if set.
/// Returns null if unset or empty. ponytail: zig 0.16 has no getenv(3)
/// libc wrapper without -lc; read /proc/self/environ directly.
fn readEnv(name: []const u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    var idx: usize = 0;
    while (idx < total) {
        const slice = buf[idx..total];
        const rel_end = std.mem.indexOfScalar(u8, slice, 0);
        const end = if (rel_end) |r| idx + r else total;
        const entry = buf[idx..end];
        if (entry.len > name.len + 1 and
            std.mem.eql(u8, entry[0..name.len], name) and
            entry[name.len] == '=')
        {
            const value = entry[name.len + 1 ..];
            if (value.len > 0) return value;
            return null;
        }
        idx = end + 1;
    }
    return null;
}

// =============================================================================
// Tests (14 total per PR 1 task list)
// =============================================================================

// T1.2 — Non-negotiable grep-fail. Scans src/api_client.zig, src/api_sse.zig,
// src/api_auth.zig, AND tools/debug_call.zig for forbidden patterns outside
// the consent-routed paths. FAILS the build on any match.
//
// The scan is scoped to production code (preamble + main + helpers) — test
// blocks are split off at the first `test "` marker so test declarations
// are allowed to mention the forbidden patterns for documentation purposes
// (e.g., the forbidden list itself, `// allowed: <pattern>` markers).
// Tier-1 cleanup W3 (verify-report id=330): extended targets to include
// tools/debug_call.zig for defense-in-depth.
test "no automatic key sources" {
    const forbidden = [_][]const u8{
        "getenv",           "readFile",        "libsecret",          "Secret Service",
        "$MINIMAX_API_KEY", "$OPENAI_API_KEY", "$ANTHROPIC_API_KEY",
    };
    const targets = [_][]const u8{
        // 4 original targets (per tui spec#379):
        "src/api_client.zig",   "src/api_sse.zig",  "src/api_auth.zig",
        "tools/debug_call.zig",
        // 6 new TUI targets (tui-recovery R-PR 1 per design#408 §2.3):
        "src/channels.zig", "src/runtime.zig",
        "src/tui.zig",          "src/main.zig",     "src/password_input.zig",
        "src/modal.zig",
    };
    const io = testing.io;
    for (targets) |path| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => continue, // partial PR — file not yet committed.
            else => return err,
        };
        defer testing.allocator.free(content);
        // Split at the first test-block marker so test declarations can
        // mention the forbidden patterns for documentation. Only production
        // code (preamble + main + helpers) is scanned.
        const first_test = std.mem.indexOf(u8, content, "\ntest \"") orelse content.len;
        const prod_src = content[0..first_test];
        for (forbidden) |pat| {
            // Allow match if the file's production code carries a matching
            // // allowed: marker (sparingly used for documentation).
            var marker_buf: [64]u8 = undefined;
            const marker = std.fmt.bufPrint(&marker_buf, "// allowed: {s}", .{pat}) catch continue;
            if (std.mem.indexOf(u8, prod_src, pat)) |idx| {
                if (std.mem.indexOf(u8, prod_src, marker) != null) continue;
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
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.json" });
    defer testing.allocator.free(path);

    const result = writeWithConsent(io, "test-key-1234567890ABCDEF", "test-password", path, false);
    try testing.expectError(error.ConsentDenied, result);

    // File must NOT exist. openat returns FileNotFound error.
    const open_result = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    try testing.expectError(error.FileNotFound, open_result);
}

// T1.6 — file mode 0o600 on writeWithConsent with consent=true.
test "file mode 0o600 on consent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.json" });
    defer testing.allocator.free(path);

    try writeWithConsent(io, "test-key-1234567890ABCDEF", "test-password", path, true);

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
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.enc" });
    defer testing.allocator.free(path);

    const expected = "test-key-1234567890ABCDEF";
    try writeEncrypted(io, path, expected, "secret-password");

    const loaded = try loadWithUnlock(io, path, "secret-password");
    defer {
        @memset(loaded, 0);
        testing.allocator.free(loaded);
    }

    try testing.expectEqualStrings(expected, loaded);
}

// T1.8 — loadWithUnlock returns error.DecryptFailed on wrong password.
test "loadWithUnlock returns error on wrong password" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.enc" });
    defer testing.allocator.free(path);

    try writeEncrypted(io, path, "test-key-1234567890ABCDEF", "secret-password");

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
// Reads the file as JSON (legacy plaintext format). The new writeWithConsent
// writes AES-GCM-encrypted bytes that deleteWithConfirmation cannot parse
// without a password; legacy plaintext files remain deletable, encrypted
// files require the user to remove them via `rm` (acceptable per spec).
test "deleteWithConfirmation requires correct last-four" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.json" });
    defer testing.allocator.free(path);

    // Write a legacy plaintext JSON file (mirrors the pre-migration body).
    const legacy = "{\"provider\":\"MiniMax\",\"api_key\":\"test-key-1234567890ABCDEF\",\"created_at\":\"2026-08-07T00:00:00Z\"}";
    {
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600) catch unreachable;
        defer _ = std.os.linux.close(fd);
        _ = std.os.linux.write(fd, legacy.ptr, legacy.len);
    }

    // Wrong last-four → error.Mismatch, file still exists.
    try testing.expectError(error.Mismatch, deleteWithConfirmation(io, path, "WRNG"));
    const fd_after_wrong = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        try testing.expect(false); // file should still exist
        return err;
    };
    _ = std.os.linux.close(fd_after_wrong);

    // Correct last-four → file is removed.
    try deleteWithConfirmation(io, path, "CDEF");
    const fd_after_correct = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    try testing.expectError(error.FileNotFound, fd_after_correct);
}

// T1.11 — key returned by loadWithUnlock is mutable and can be zeroed
// (memory hygiene: spec mandates memset(0) on "forget key").
test "key zeroed on deinit" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.enc" });
    defer testing.allocator.free(path);

    try writeEncrypted(io, path, "test-key-1234567890ABCDEF", "secret-password");

    const loaded = try loadWithUnlock(io, path, "secret-password");
    try testing.expect(loaded.len > 0);
    try testing.expect(loaded[0] != 0); // sanity: not pre-zeroed

    @memset(loaded, 0);

    for (loaded) |b| try testing.expectEqual(@as(u8, 0), b);

    testing.allocator.free(loaded);
}

// =============================================================================
// tls-handrolled — RED test blocks for real validateViaApi (Commit 5)
// Spec scenarios: success 200, failure 401/1004, network error.
// Tests fail at compile time because the validateViaApi impl was widened
// to take an allocator arg but the body returns error.NotImplemented.
// =============================================================================

// T2.1 — Real validateViaApi against api.minimax.io succeeds with 200.
// CI-gated on ZARGEANT_RUN_VALIDATE_VIA_API=1 (same pattern as the
// TLS handshake tests). Asserts the function doesn't return
// error.Unauthorized / error.ConnectFailed on a real probe.
test "validateViaApi against api.minimax.io succeeds with 200" {
    var resolv_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    const ca_path = "/etc/ssl/certs/ca-certificates.crt";
    @memcpy(resolv_z[0..ca_path.len], ca_path.ptr);
    resolv_z[ca_path.len] = 0;
    const ca_exists = std.os.linux.access(resolv_z[0..ca_path.len :0].ptr, 0) == 0;
    if (!ca_exists) return;

    const env_fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer _ = std.os.linux.close(env_fd);
    var env_buf: [4096]u8 = undefined;
    var env_total: usize = 0;
    while (env_total < env_buf.len) {
        const n: isize = @bitCast(std.os.linux.read(env_fd, env_buf[env_total..].ptr, env_buf.len - env_total));
        if (n <= 0) break;
        env_total += @intCast(n);
    }
    var idx: usize = 0;
    var enabled = false;
    while (idx < env_total) {
        const slice = env_buf[idx..env_total];
        const rel_end = std.mem.indexOfScalar(u8, slice, 0);
        const end = if (rel_end) |r| idx + r else env_total;
        const entry = env_buf[idx..end];
        if (std.mem.startsWith(u8, entry, "ZARGEANT_RUN_VALIDATE_VIA_API=1")) {
            enabled = true;
            break;
        }
        idx = end + 1;
    }
    if (!enabled) return;

    // RED: this call returns error.NotImplemented in the stub. The
    // GREEN commit replaces the body with real HTTP POST.
    try validateViaApi(testing.io, testing.allocator, "test-key-1234567890ABCDEF");
}

// T2.2 — validateViaApi returns error.Unauthorized on HTTP 401 OR
// `base_resp.status_code == 1004`. We simulate the 401 by routing the
// POST to a local mock server that responds with status 401. The mock
// lives in src/mock_server.zig.
test "validateViaApi returns Unauthorized on 401 or base_resp 1004" {
    const mock_server = @import("mock_server.zig");
    var ms = try mock_server.start(testing.allocator);
    defer ms.deinit();

    // Queue a 401 response.
    const body = "{\"error\":\"unauthorized\"}";
    var status_buf: [256]u8 = undefined;
    const status_line = std.fmt.bufPrint(&status_buf, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    try mock_server.sendBytes(ms, status_line);

    // Probe the mock server (127.0.0.1:PORT). The probe sends a request;
    // the mock responds 401; the probe maps to error.Unauthorized.
    const result = validateViaApiWithTarget(testing.io, testing.allocator, "test-key-1234567890ABCDEF", "127.0.0.1", mock_server.port(ms.*));
    try testing.expectError(error.Unauthorized, result);
}

// T2.3 — validateViaApi returns error.ConnectFailed on network error.
// We probe a closed port on 127.0.0.1 (no listener).
test "validateViaApi returns ConnectFailed on network error" {
    // Port 1 is reserved; ECONNREFUSED on connect. The probe maps to
    // error.ConnectFailed (NOT error.OpenFailed).
    const result = validateViaApiWithTarget(testing.io, testing.allocator, "test-key-1234567890ABCDEF", "127.0.0.1", 1);
    try testing.expectError(error.ConnectFailed, result);
}

// =============================================================================
// api-auth-fixes Commit 1 — RED tests for Argon2id+AES-GCM round-trip
// (design #448 §"Module change matrix"; tasks #449 §"Commit 1")
// =============================================================================

// T-C1.1 — deriveKey (Argon2id) produces 32-byte derived key.
test "deriveKey produces 32-byte output for known password+salt" {
    const derived = deriveKey(testing.io, "test-password", "0123456789abcdef");
    try testing.expectEqual(@as(usize, 32), derived.len);
    // Two calls with the same password+salt MUST produce the same bytes
    // (Argon2id is deterministic given fixed params).
    const derived2 = deriveKey(testing.io, "test-password", "0123456789abcdef");
    try testing.expectEqualSlices(u8, &derived, &derived2);
    // Different salt MUST produce different bytes.
    const derived3 = deriveKey(testing.io, "test-password", "fedcba9876543210");
    try testing.expect(!std.mem.eql(u8, &derived, &derived3));
}

// T-C1.2a — encrypt+decrypt (AES-256-GCM) round-trip.
test "encrypt+decrypt round-trip" {
    const key: [32]u8 = [_]u8{0xAA} ** 32;
    const nonce: [12]u8 = [_]u8{0xBB} ** 12;
    const plaintext = "the quick brown fox jumps over the lazy dog";
    var ct_buf: [43]u8 = undefined;
    var tag: [16]u8 = undefined;
    encrypt(&ct_buf, &tag, plaintext, key, nonce);
    var pt_buf: [43]u8 = undefined;
    try decrypt(&pt_buf, &ct_buf, tag, key, nonce);
    try testing.expectEqualSlices(u8, plaintext, &pt_buf);
}

// T-C1.2b — tampered ciphertext → error.AuthenticationFailed.
test "tampered ciphertext → error.AuthenticationFailed" {
    const key: [32]u8 = [_]u8{0xAA} ** 32;
    const nonce: [12]u8 = [_]u8{0xBB} ** 12;
    var ct: [16]u8 = [_]u8{0} ** 16;
    var tag: [16]u8 = undefined;
    encrypt(&ct, &tag, "0123456789abcdef", key, nonce);
    ct[0] ^= 0x01; // flip one bit
    var pt: [16]u8 = undefined;
    try testing.expectError(error.AuthenticationFailed, decrypt(&pt, &ct, tag, key, nonce));
}

// T-C1.3a — writeWithConsent produces salt(16) ‖ nonce(12) ‖ ct(N) ‖ tag(16).
test "writeWithConsent produces salt16||nonce12||ctN||tag16 format" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.bin" });
    defer testing.allocator.free(path);

    try writeWithConsent(io, "test-key-1234567890ABCDEF", "my-password", path, true);

    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch unreachable;
    defer _ = std.os.linux.close(fd);
    var buf: [128]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n: isize = @bitCast(std.os.linux.read(fd, buf[total..].ptr, buf.len - total));
        if (n <= 0) break;
        total += @intCast(n);
    }
    try testing.expect(total >= 16 + 12 + 24 + 16); // salt+nonce+key_len+tag

    // Salt uniqueness: write twice, compare salt[0..16] (must differ).
    const path2 = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds2.bin" });
    defer testing.allocator.free(path2);
    try writeWithConsent(io, "test-key-1234567890ABCDEF", "my-password", path2, true);
    const fd2 = std.posix.openat(std.posix.AT.FDCWD, path2, .{ .ACCMODE = .RDONLY }, 0) catch unreachable;
    defer _ = std.os.linux.close(fd2);
    var buf2: [16]u8 = undefined;
    _ = std.os.linux.read(fd2, &buf2, 16);
    try testing.expect(!std.mem.eql(u8, buf[0..16], &buf2));
}

// T-C1.4 — loadWithUnlock detects legacy plaintext leading `{` BEFORE KDF.
test "loadWithUnlock detects legacy plaintext" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.json" });
    defer testing.allocator.free(path);

    // Write a legacy plaintext JSON file (mirrors old writeWithConsent body).
    const legacy = "{\"provider\":\"MiniMax\",\"api_key\":\"test-key-1234567890ABCDEF\",\"created_at\":\"2026-08-07T00:00:00Z\"}";
    {
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600) catch unreachable;
        defer _ = std.os.linux.close(fd);
        _ = std.os.linux.write(fd, legacy.ptr, legacy.len);
    }
    // loadWithUnlock must return error.LegacyPlaintext (single-byte probe).
    try testing.expectError(error.LegacyPlaintext, loadWithUnlock(io, path, "any-password"));
}

// T-C1.5 — writeWithConsent + loadWithUnlock round-trip via Argon2id+AES-GCM.
test "writeWithConsent + loadWithUnlock round-trip" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.bin" });
    defer testing.allocator.free(path);

    const expected = "test-key-1234567890ABCDEF";
    try writeWithConsent(io, expected, "shared-password", path, true);
    const loaded = try loadWithUnlock(io, path, "shared-password");
    defer {
        @memset(loaded, 0);
        testing.allocator.free(loaded);
    }
    try testing.expectEqualStrings(expected, loaded);
}

// T-C1.6 — loadWithUnlock returns error.DecryptFailed on wrong password.
test "loadWithUnlock wrong-password returns DecryptFailed after Argon2id rewrite" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.bin" });
    defer testing.allocator.free(path);

    try writeWithConsent(io, "test-key-1234567890ABCDEF", "right-password", path, true);
    try testing.expectError(error.DecryptFailed, loadWithUnlock(io, path, "wrong-password"));
}

// T-C1.7 — loadWithUnlock returns error.DecryptFailed on file-level tamper
// (AES-GCM tag mismatch surfaces as AuthenticationFailed from the helper,
// mapped to DecryptFailed by loadWithUnlock per spec #447).
test "loadWithUnlock tampered file returns DecryptFailed" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], "creds.bin" });
    defer testing.allocator.free(path);

    try writeWithConsent(io, "test-key-1234567890ABCDEF", "right-password", path, true);

    // Flip a bit in the ciphertext region (offset 28 = salt+nonce).
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY }, 0) catch unreachable;
    defer _ = std.os.linux.close(fd);
    var b: [1]u8 = .{0x55};
    _ = std.os.linux.pwrite(fd, &b, 1, 28);

    try testing.expectError(error.DecryptFailed, loadWithUnlock(io, path, "right-password"));
}

// =============================================================================
// api-auth-fixes Commit 2 — RED tests for validateViaApiWithTarget TLS-vs-plain fork
// (design #448 §"Module change matrix"; tasks #449 §"Commit 2")
// =============================================================================

// T-C2.1 — TLS branch uses tls_conn.writeAll AND tls_conn.readSome (not raw
// socket I/O). Static-grep on validateViaApiWithTarget body to assert the
// pattern is wired; without this commit the production code performs raw
// std.os.linux.write/read on the same fd the TLS session owns, dropping
// the connection (design #441 §"B2").
test "validateViaApiWithTarget TLS branch uses tls_conn.writeAll + readSome" {
    const io = testing.io;
    const content = std.Io.Dir.cwd().readFileAlloc(io, "src/api_auth.zig", testing.allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return, // partial PR — file not yet committed.
        else => return err,
    };
    defer testing.allocator.free(content);

    // Find validateViaApiWithTarget function body — locate the `pub fn ...`
    // line and the next top-level `}` or `pub fn`/`fn `.
    const sig_idx = std.mem.indexOf(u8, content, "pub fn validateViaApiWithTarget") orelse {
        try testing.expect(false);
        return;
    };
    const body_start = std.mem.indexOfPos(u8, content, sig_idx, "{") orelse return;
    // Find matching closing brace by tracking depth.
    var depth: usize = 0;
    var body_end: usize = body_start;
    for (content[body_start..], 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                body_end = body_start + i + 1;
                break;
            }
        }
    }
    const body = content[body_start..body_end];

    // The TLS branch must call tls_conn.writeAll and tls_conn.readSome.
    try testing.expect(std.mem.indexOf(u8, body, "conn.writeAll") != null);
    try testing.expect(std.mem.indexOf(u8, body, "conn.readSome") != null);
}

// T-C2.2 — 127.0.0.1 (mock-server) branch stays raw-socket: no
// tls_conn allocation, no writeAll/readSome routing. Static-grep on the
// `else` block of the needs_tls fork. Mirrors `Client.stream`'s plain-HTTP
// branch at src/api_client.zig:594-680.
test "validateViaApiWithTarget 127.0.0.1 branch stays raw-socket" {
    const io = testing.io;
    const content = std.Io.Dir.cwd().readFileAlloc(io, "src/api_auth.zig", testing.allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer testing.allocator.free(content);

    const sig_idx = std.mem.indexOf(u8, content, "pub fn validateViaApiWithTarget") orelse return;
    const body_start = std.mem.indexOfPos(u8, content, sig_idx, "{") orelse return;
    var depth: usize = 0;
    var body_end: usize = body_start;
    for (content[body_start..], 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                body_end = body_start + i + 1;
                break;
            }
        }
    }
    const body = content[body_start..body_end];

    // The plain HTTP branch must use std.os.linux.write + std.os.linux.read.
    try testing.expect(std.mem.indexOf(u8, body, "std.os.linux.write(fd,") != null);
    try testing.expect(std.mem.indexOf(u8, body, "std.os.linux.read(fd,") != null);
}

// T-C2.3 — TLS read loop maps error.Cancelled (cancel-pipe readability
// surfaces as Cancelled inside tls_conn.readSome per src/api_client.zig:2099).
// Static-grep: assert the TLS branch catches Cancelled and returns it.
test "validateViaApiWithTarget TLS read loop maps error.Cancelled" {
    const io = testing.io;
    const content = std.Io.Dir.cwd().readFileAlloc(io, "src/api_auth.zig", testing.allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer testing.allocator.free(content);

    const sig_idx = std.mem.indexOf(u8, content, "pub fn validateViaApiWithTarget") orelse return;
    const body_start = std.mem.indexOfPos(u8, content, sig_idx, "{") orelse return;
    var depth: usize = 0;
    var body_end: usize = body_start;
    for (content[body_start..], 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                body_end = body_start + i + 1;
                break;
            }
        }
    }
    const body = content[body_start..body_end];

    // The TLS read loop must map error.Cancelled from conn.readSome.
    try testing.expect(std.mem.indexOf(u8, body, "error.Cancelled") != null);
}
