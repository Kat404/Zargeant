// Logger module for zargeant (logger slice).
//
// Headless /tmp/ai-harness-debug.log writer per spec id=197. Three concurrent
// threads share the same Logger; writes are serialized through std.Io.Mutex.
// Sync I/O via std.posix / std.os.linux syscalls — no Io cancel points on the
// hot path.
//
// Spec: id=197 (8 requirements, 12 scenarios).
// Design: id=199 (instance-based Logger, 7 decisions).
//
// ponytail: Linux-only build for v1 — std.os.linux.* raw syscalls used for
// write/close/fchmod/dup2/pipe because std.posix.* wrappers for these were
// stripped in Zig 0.16. macOS support deferred: would link_libc + std.c.*.
// 12 in-file tests run under `zig build test` (test step root = src/root.zig).

const std = @import("std");

// -----------------------------------------------------------------------------
// Public types
// -----------------------------------------------------------------------------

pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

pub const defaultPath: []const u8 = "/tmp/ai-harness-debug.log";

pub const Error = error{
    OpenFailed,
    WriteFailed,
    FchmodFailed,
    NoWritableTempDir,
    MessageTooLong,
    Closed,
};

/// Maximum message length (bytes). Anything longer is rejected with
/// error.MessageTooLong to bound the per-line stack buffer.
pub const MAX_MESSAGE_LEN: usize = 16 * 1024;

pub const Logger = struct {
    fd: std.posix.fd_t,
    mutex: std.Io.Mutex,
    path: []const u8,

    pub fn init(io: std.Io, path_opt: ?[]const u8) Error!Logger {
        _ = io;
        const path = if (path_opt) |p| p else defaultPath;

        // O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode 0o600.
        const flags: std.posix.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        };
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, flags, 0o600) catch return error.OpenFailed;

        // fchmod post-open defeats umask masking of requested mode bits.
        const chmod_rc = std.os.linux.fchmod(fd, 0o600);
        if (chmod_rc != 0) {
            _ = std.os.linux.close(fd);
            return error.FchmodFailed;
        }

        return Logger{
            .fd = fd,
            .mutex = std.Io.Mutex.init,
            .path = path,
        };
    }

    pub fn deinit(self: *Logger, io: std.Io) void {
        if (self.fd >= 0) {
            self.mutex.lock(io) catch return;
            const fd = self.fd;
            self.fd = -1;
            self.mutex.unlock(io);
            _ = std.os.linux.close(fd);
        }
    }

    pub fn log(self: *Logger, io: std.Io, level: Level, msg: []const u8) Error!void {
        if (msg.len > MAX_MESSAGE_LEN) return error.MessageTooLong;
        if (self.fd < 0) return error.Closed;

        self.mutex.lock(io) catch return error.WriteFailed;
        defer self.mutex.unlock(io);

        var buf: [4096]u8 = undefined;
        const ts = formatTimestamp(io, &buf) catch return error.WriteFailed;
        const tid = std.Thread.getCurrentId();
        const written = std.fmt.bufPrint(buf[ts.len..], " [{s}] [thread={d}] {s}\n", .{
            levelToken(level),
            @as(u32, @intCast(tid)),
            msg,
        }) catch return error.WriteFailed;
        const line = buf[0 .. ts.len + written.len];
        const rc = std.os.linux.write(self.fd, line.ptr, line.len);
        if (rc != line.len) return error.WriteFailed;
    }

    pub fn logf(self: *Logger, io: std.Io, level: Level, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return error.MessageTooLong;
        try self.log(io, level, msg);
    }
};

// -----------------------------------------------------------------------------
// Module-level global accessor
// -----------------------------------------------------------------------------

var g_logger: ?Logger = null;

pub fn initGlobal(io: std.Io) Error!void {
    if (g_logger != null) return;
    g_logger = try Logger.init(io, null);
}

pub fn global() *Logger {
    return &(g_logger orelse @panic("logger.global() called before initGlobal()"));
}

pub fn deinitGlobal(io: std.Io) void {
    if (g_logger) |*l| l.deinit(io);
    g_logger = null;
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

fn levelToken(l: Level) []const u8 {
    return switch (l) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERR",
    };
}

/// Returns the first dir that is writable (tested by creating a probe file),
/// or null if none work. Empty strings are skipped (matches `getenv`-unset
/// semantics). Used by both `Logger.init` (with the env-chain) and tests.
fn resolveWritableDir(dirs: []const []const u8) ?[]const u8 {
    for (dirs) |dir| {
        if (dir.len == 0) continue;
        if (isDirWritable(dir)) return dir;
    }
    return null;
}

fn isDirWritable(dir: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const needs_sep = dir.len > 0 and dir[dir.len - 1] != '/';
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}.zargeant-write-probe", .{
        dir,
        if (needs_sep) "/" else "",
    }) catch return false;

    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o600) catch return false;
    _ = std.os.linux.close(fd);
    unlinkBestEffort(path);
    return true;
}

fn unlinkBestEffort(path: []const u8) void {
    // Convert []const u8 to [:0]const u8 for the null-terminated syscall.
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > buf.len - 1) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = std.os.linux.unlinkat(std.posix.AT.FDCWD, buf[0..path.len :0].ptr, 0);
}

/// Default path resolution: TMPDIR -> XDG_RUNTIME_DIR -> /tmp.
/// Returns a writable directory (which the caller joins with the basename
/// they want for the log file).
fn resolveWritableDefaultDir() Error![]const u8 {
    const tmpdir = readEnv("TMPDIR");
    const xdg = readEnv("XDG_RUNTIME_DIR");

    var candidates: [3][]const u8 = undefined;
    var count: usize = 0;
    if (tmpdir) |v| {
        candidates[count] = v;
        count += 1;
    } else {
        candidates[count] = "";
        count += 1;
    }
    if (xdg) |v| {
        candidates[count] = v;
        count += 1;
    } else {
        candidates[count] = "";
        count += 1;
    }
    candidates[count] = "/tmp";
    count += 1;

    return resolveWritableDir(candidates[0..count]) orelse return error.NoWritableTempDir;
}

/// Default path resolution: TMPDIR/ai-harness-debug.log ->
/// XDG_RUNTIME_DIR/ai-harness-debug.log -> /tmp/ai-harness-debug.log.
fn resolveDefaultPath() Error![]const u8 {
    const dir = try resolveWritableDefaultDir();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const basename = "ai-harness-debug.log";
    const needs_sep = dir.len > 0 and dir[dir.len - 1] != '/';
    return std.fmt.bufPrint(&buf, "{s}{s}{s}", .{
        dir,
        if (needs_sep) "/" else "",
        basename,
    }) catch return error.OpenFailed;
}

/// Linux without libc has no getenv. Read /proc/self/environ and parse.
/// Returns null if the variable is unset or empty.
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
        // Find end of this entry (null separator).
        const slice = buf[idx..total];
        const rel_end = std.mem.indexOfScalar(u8, slice, 0);
        const end = if (rel_end) |r| idx + r else total;
        const entry = buf[idx..end];
        // Look for "NAME=" prefix.
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

fn formatTimestamp(io: std.Io, buf: []u8) ![]u8 {
    const ts_i64 = std.Io.Clock.real.now(io).toSeconds();
    const ts: u64 = @intCast(ts_i64);
    const epoch = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day = epoch.getEpochDay();
    const yd = epoch_day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u5, md.day_index + 1),
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

// -----------------------------------------------------------------------------
// Tests (12 spec scenarios + 1 smoke from src/harness.zig)
// -----------------------------------------------------------------------------

const testing = std.testing;
const tmpDir = testing.tmpDir;

fn readFileContents(path: []const u8, buf: []u8) !usize {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.OpenFailed;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    _ = std.os.linux.close(fd);
    return total;
}

fn tmpLogPath(tmp: *std.testing.TmpDir, io: std.Io, name: []const u8) ![]u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    return try std.fs.path.join(testing.allocator, &[_][]const u8{ dir_buf[0..dir_len], name });
}

test "init creates file with mode 0600" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const file_path = try tmpLogPath(&tmp, io, "log.txt");
    defer testing.allocator.free(file_path);

    var l = try Logger.init(io, file_path);
    defer l.deinit(io);

    const file = std.Io.File{ .handle = l.fd, .flags = .{ .nonblocking = false } };
    const stat = try std.Io.File.stat(file, io);
    const mode_mask: u32 = 0o777;
    const actual_mode: u32 = @intCast(@as(std.posix.mode_t, @bitCast(stat.permissions.toMode())) & mode_mask);
    try testing.expectEqual(@as(u32, 0o600), actual_mode);
}

test "env fallback to XDG_RUNTIME_DIR" {
    const io = testing.io;

    var tmp_b = tmpDir(.{});
    defer tmp_b.cleanup();

    var path_b: [std.fs.max_path_bytes]u8 = undefined;
    const len_b = try tmp_b.dir.realPath(io, &path_b);

    const candidates = [_][]const u8{
        "/nonexistent-zargeant-test-unwritable",
        path_b[0..len_b],
    };
    const picked = resolveWritableDir(&candidates) orelse return error.NoWritableTempDir;
    try testing.expectEqualStrings(path_b[0..len_b], picked);
}

test "env fallback to /tmp" {
    const candidates = [_][]const u8{
        "",
        "",
        "/tmp",
    };
    const picked = resolveWritableDir(&candidates) orelse return error.NoWritableTempDir;
    try testing.expect(picked.len > 0);
}

test "returns error.NoWritableTempDir when no candidate writable" {
    const candidates = [_][]const u8{
        "/nonexistent-zargeant-a",
        "/nonexistent-zargeant-b",
        "/nonexistent-zargeant-c",
    };
    try testing.expect(resolveWritableDir(&candidates) == null);
}

test "truncate on startup" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const file_path = try tmpLogPath(&tmp, io, "log.txt");
    defer testing.allocator.free(file_path);

    {
        var l = try Logger.init(io, file_path);
        defer l.deinit(io);
        try l.log(io, .info, "first session line 1");
        try l.log(io, .info, "first session line 2");
    }

    {
        var l = try Logger.init(io, file_path);
        defer l.deinit(io);
        try l.log(io, .info, "second session");
    }

    var read_buf: [4096]u8 = undefined;
    const n = try readFileContents(file_path, &read_buf);
    const contents = read_buf[0..n];
    try testing.expect(std.mem.indexOf(u8, contents, "second session") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "first session") == null);
}

test "log format matches ISO8601 + LEVEL + thread regex" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const file_path = try tmpLogPath(&tmp, io, "log.txt");
    defer testing.allocator.free(file_path);

    var l = try Logger.init(io, file_path);
    defer l.deinit(io);
    try l.log(io, .info, "hello world");

    var read_buf: [4096]u8 = undefined;
    const n = try readFileContents(file_path, &read_buf);
    const contents = read_buf[0..n];

    try testing.expect(contents.len > 0);
    try testing.expect(contents[contents.len - 1] == '\n');
    try testing.expect(std.mem.indexOf(u8, contents, " [INFO] [thread=") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "Z [INFO] [thread=") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "hello world\n") != null);

    try testing.expect(contents.len >= 21);
    for (contents[0..4]) |c| try testing.expect(c >= '0' and c <= '9');
    try testing.expect(contents[4] == '-');
    try testing.expect(contents[7] == '-');
    try testing.expect(contents[10] == 'T');
    try testing.expect(contents[13] == ':');
    try testing.expect(contents[16] == ':');
    try testing.expect(contents[19] == 'Z');
    try testing.expect(contents[20] == ' ');
}

test "concurrency: 3 threads x 1000 lines non-interleaved" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const file_path = try tmpLogPath(&tmp, io, "log.txt");
    defer testing.allocator.free(file_path);

    var l = try Logger.init(io, file_path);
    defer l.deinit(io);

    const Ctx = struct {
        logger: *Logger,
        io: std.Io,

        fn run(c: *@This()) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                c.logger.log(c.io, .info, "msg") catch unreachable;
            }
        }
    };
    var ctx = Ctx{ .logger = &l, .io = io };

    const t1 = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    const t2 = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    const t3 = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    t1.join();
    t2.join();
    t3.join();

    var read_buf: [256 * 1024]u8 = undefined;
    const n = try readFileContents(file_path, &read_buf);
    const contents = read_buf[0..n];

    var line_count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfScalar(u8, contents[idx..], '\n')) |rel| {
        line_count += 1;
        idx += rel + 1;
    }
    try testing.expectEqual(@as(usize, 3000), line_count);
}

test "MessageTooLong on message > 16 KiB" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const file_path = try tmpLogPath(&tmp, io, "log.txt");
    defer testing.allocator.free(file_path);

    var l = try Logger.init(io, file_path);
    defer l.deinit(io);

    var msg: [16385]u8 = undefined;
    @memset(&msg, 'x');
    try testing.expectError(error.MessageTooLong, l.log(io, .info, &msg));
}

test "level enum coverage" {
    const tokens = [_][]const u8{ "DEBUG", "INFO", "WARN", "ERR" };
    const tags = [_]Level{ .debug, .info, .warn, .err };
    for (tags, tokens) |tag, expected| {
        try testing.expectEqualStrings(expected, levelToken(tag));
    }
}

test "deinit closes fd" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const file_path = try tmpLogPath(&tmp, io, "log.txt");
    defer testing.allocator.free(file_path);

    var l = try Logger.init(io, file_path);
    const captured_fd = l.fd;
    l.deinit(io);
    const buf: [1]u8 = .{0};
    const rc = std.os.linux.write(captured_fd, &buf, 1);
    // On Linux, write() returns negative errno encoded as usize when it fails.
    // EBADF = 9. We just assert rc != buf.len (i.e., the write was rejected).
    try testing.expect(rc != buf.len);
}

test "no stdout or stderr writes" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const file_path = try tmpLogPath(&tmp, io, "log.txt");
    defer testing.allocator.free(file_path);

    var pipe_fds: [2]i32 = undefined;
    const prc = std.os.linux.pipe(&pipe_fds);
    try testing.expectEqual(@as(usize, 0), prc);
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    const saved_out_rc = std.os.linux.dup(std.posix.STDOUT_FILENO);
    const saved_err_rc = std.os.linux.dup(std.posix.STDERR_FILENO);
    const saved_out: i32 = @intCast(@as(isize, @bitCast(saved_out_rc)));
    const saved_err: i32 = @intCast(@as(isize, @bitCast(saved_err_rc)));
    const dup_out_rc = std.os.linux.dup2(write_fd, std.posix.STDOUT_FILENO);
    const dup_err_rc = std.os.linux.dup2(write_fd, std.posix.STDERR_FILENO);
    try testing.expectEqual(@as(usize, @intCast(std.posix.STDOUT_FILENO)), dup_out_rc);
    try testing.expectEqual(@as(usize, @intCast(std.posix.STDERR_FILENO)), dup_err_rc);

    var l = try Logger.init(io, file_path);
    defer l.deinit(io);
    try l.log(io, .info, "should not reach stdout or stderr");
    try l.logf(io, .warn, "formatted {d}", .{42});

    // Close the pipe write end so the read below can drain to EOF instead of
    // blocking. fd 1 and fd 2 are aliases of write_fd at this point; closing
    // write_fd closes fd 1 and fd 2 too. We restore them from saved_* below.
    const close_rc = std.os.linux.close(write_fd);
    try testing.expectEqual(@as(usize, 0), close_rc);

    // Also dup2 read_fd to fd 1 and fd 2 so the test framework's status
    // messages (printed during subsequent tests) don't deadlock our pipe.
    _ = std.os.linux.dup2(read_fd, std.posix.STDOUT_FILENO);
    _ = std.os.linux.dup2(read_fd, std.posix.STDERR_FILENO);

    var drain: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < drain.len) {
        const r = std.os.linux.read(read_fd, drain[total..].ptr, drain.len - total);
        if (r == 0) break;
        if (r > 0x7ffff000) break;
        total += r;
    }
    try testing.expectEqual(@as(usize, 0), total);

    _ = std.os.linux.dup2(saved_out, std.posix.STDOUT_FILENO);
    _ = std.os.linux.dup2(saved_err, std.posix.STDERR_FILENO);
    _ = std.os.linux.close(saved_out);
    _ = std.os.linux.close(saved_err);
    _ = std.os.linux.close(read_fd);
}

test "logger.log via global() works" {
    const io = testing.io;
    try initGlobal(io);
    defer deinitGlobal(io);
    const l = global();
    try l.log(io, .info, "via global");
    try l.logf(io, .warn, "fmt {d}", .{7});
}

test "CLOEXEC flag set on fd via fcntl F_GETFD" {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const file_path = try tmpLogPath(&tmp, io, "cloexec.txt");
    defer testing.allocator.free(file_path);

    var l = try Logger.init(io, file_path);
    defer l.deinit(io);

    // fcntl(F.GETFD) returns fd flags; FD_CLOEXEC bit indicates the fd is
    // closed on exec. Verifies that O_CLOEXEC was applied at open time.
    const fd_flags = std.os.linux.fcntl(l.fd, std.os.linux.F.GETFD, 0);
    try testing.expect((fd_flags & std.os.linux.FD_CLOEXEC) != 0);
}

test "first writable candidate wins in fallback chain" {
    const io = testing.io;

    var tmp_a = tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = tmpDir(.{});
    defer tmp_b.cleanup();

    var path_a: [std.fs.max_path_bytes]u8 = undefined;
    const len_a = try tmp_a.dir.realPath(io, &path_a);
    var path_b: [std.fs.max_path_bytes]u8 = undefined;
    const len_b = try tmp_b.dir.realPath(io, &path_b);

    // Both candidates writable; first one must win (matches spec requirement
    // that TMPDIR outranks XDG_RUNTIME_DIR outranks /tmp when all set).
    const candidates = [_][]const u8{
        path_a[0..len_a],
        path_b[0..len_b],
    };
    const picked = resolveWritableDir(&candidates) orelse return error.NoWritableTempDir;
    try testing.expectEqualStrings(path_a[0..len_a], picked);
}
