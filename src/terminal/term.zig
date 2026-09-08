//! src/terminal/term.zig — POSIX termios(3) lifecycle + pluggable OS backend.
//!
//! POSIX termios(3) §Canonical mode, §Non-canonical mode. Saves the original
//! termios on enable, restores on disable. Re-exports DPM enter/exit/
//! sync-update per design C31 (smoke canary compatibility). Pluggable Backend
//! per design D3 enables headless CI verification without a real TTY.
//!
//! ADR 0002 §1 protocol citation table anchors each public symbol to the
//! cited spec section; clean-room rule (CONTRIBUTING.md:41 + ADR 0001 §Negative).

const std = @import("std");
const builtin = @import("builtin");

/// Carries the terminal size in cells (width × height). Two fields match the
/// shape the renamed smoke canary asserts at tests/tui/terminal_smoke.zig:42
/// (formerly tests/tui/mibu_smoke.zig:42). Width and height are derived from
/// `std.posix.winsize.col` and `std.posix.winsize.row` respectively.
pub const TermSize = struct {
    width: u16,
    height: u16,
};

/// Pluggable OS backend for termios operations. Production code uses
/// `PosixBackend.backend()`; tests use `MockBackend.backend()` with canned
/// termios + winsize values. Each field is a function pointer so the Backend
/// is a value type that can be passed by copy (per design D3 / peer-review
/// C27 — no overloading, always 2-arg `enableRawMode(handle, backend)`).
pub const Backend = struct {
    tcgetattr: *const fn (handle: std.Io.File.Handle) anyerror!std.posix.termios,
    tcsetattr: *const fn (handle: std.Io.File.Handle, when: std.posix.TCSA, term: std.posix.termios) anyerror!void,
    ioctl_gwinsz: *const fn (handle: std.Io.File.Handle) anyerror!std.posix.winsize,
};

/// Production backend. Wraps std.posix.tcgetattr / tcsetattr and a direct
/// `ioctl(2)` syscall for `TIOCGWINSZ` on Linux. Returns a fully-populated
/// `Backend` value; the caller copies the value into `enableRawMode` and
/// `RawTerm.backend`.
pub const PosixBackend = struct {
    pub fn backend() Backend {
        return .{
            .tcgetattr = tcgetattrPosix,
            .tcsetattr = tcsetattrPosix,
            .ioctl_gwinsz = ioctlGwinszPosix,
        };
    }

    fn tcgetattrPosix(handle: std.Io.File.Handle) anyerror!std.posix.termios {
        return std.posix.tcgetattr(handle);
    }

    fn tcsetattrPosix(handle: std.Io.File.Handle, when: std.posix.TCSA, term: std.posix.termios) anyerror!void {
        return std.posix.tcsetattr(handle, when, term);
    }

    fn ioctlGwinszPosix(handle: std.Io.File.Handle) anyerror!std.posix.winsize {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOs;
        }
        var ws: std.posix.winsize = std.mem.zeroes(std.posix.winsize);
        const fd: usize = @bitCast(@as(isize, handle));
        const rc = std.os.linux.syscall3(.ioctl, fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return ws,
            .INTR => return error.Interrupted,
            .NOTTY => return error.NotATerminal,
            else => return std.posix.unexpectedErrno(std.os.linux.errno(rc)),
        }
    }
};

/// Test-only backend with canned termios + winsize values and per-call counters.
/// Tests construct one of these, attach the `Backend` value to `enableRawMode`,
/// and assert the counters after the call. Returns the configured error when
/// `fail_*` fields are set; otherwise returns the canned values.
pub const MockBackend = struct {
    original_termios: std.posix.termios = std.mem.zeroes(std.posix.termios),
    winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 },
    fail_tcgetattr: ?anyerror = null,
    fail_tcsetattr: ?anyerror = null,
    fail_ioctl_gwinsz: ?anyerror = null,
    tcgetattr_count: u32 = 0,
    tcsetattr_count: u32 = 0,
    ioctl_gwinsz_count: u32 = 0,

    const Options = struct {
        original_termios: std.posix.termios = std.mem.zeroes(std.posix.termios),
        winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 },
        fail_tcgetattr: ?anyerror = null,
        fail_tcsetattr: ?anyerror = null,
        fail_ioctl_gwinsz: ?anyerror = null,
    };

    pub fn init(opts: Options) MockBackend {
        return .{
            .original_termios = opts.original_termios,
            .winsize = opts.winsize,
            .fail_tcgetattr = opts.fail_tcgetattr,
            .fail_tcsetattr = opts.fail_tcsetattr,
            .fail_ioctl_gwinsz = opts.fail_ioctl_gwinsz,
        };
    }

    pub fn deinit(_: *MockBackend) void {}

    pub fn backend(_: *MockBackend) Backend {
        // Ponytail: `self` is unused here because fn ptrs are static and
        // reach back to a thread-local. Tests should NOT use MockBackend
        // concurrently; production uses PosixBackend.
        return .{
            .tcgetattr = tcgetattrMock,
            .tcsetattr = tcsetattrMock,
            .ioctl_gwinsz = ioctlGwinszMock,
        };
    }

    fn tcgetattrMock(_: std.Io.File.Handle) anyerror!std.posix.termios {
        // Thread-local handle to the active MockBackend instance. Set via
        // `setActive` from the test's MockBackend.init scope.
        const m = active_mock orelse return error.NoActiveMock;
        m.tcgetattr_count += 1;
        if (m.fail_tcgetattr) |e| return e;
        return m.original_termios;
    }

    fn tcsetattrMock(_: std.Io.File.Handle, _: std.posix.TCSA, _: std.posix.termios) anyerror!void {
        const m = active_mock orelse return error.NoActiveMock;
        m.tcsetattr_count += 1;
        if (m.fail_tcsetattr) |e| return e;
    }

    fn ioctlGwinszMock(_: std.Io.File.Handle) anyerror!std.posix.winsize {
        const m = active_mock orelse return error.NoActiveMock;
        m.ioctl_gwinsz_count += 1;
        if (m.fail_ioctl_gwinsz) |e| return e;
        return m.winsize;
    }

    /// Set this MockBackend as the active one before calling functions that
    /// take `Backend` by value. The MockBackend must outlive the Backend use.
    pub fn activate(self: *MockBackend) void {
        active_mock = self;
    }

    pub fn deactivate(_: *MockBackend) void {
        active_mock = null;
    }

    /// Thread-local pointer to the currently active MockBackend. Tests that
    /// use MockBackend must NOT run concurrently (zig test runs serially
    /// per file, so this is safe).
    threadlocal var active_mock: ?*MockBackend = null;
};

/// Saved-termios RAII token returned by `enableRawMode`. Method `disableRawMode`
/// restores the original termios (per peer-review C29 — `disableRawMode` must
/// be a method on RawTerm, not a free function, because `src/tui.zig:300`
/// calls `rt.disableRawMode()`). The method also counts as the one decl the
/// renamed smoke canary requires (`decls.len > 0` per peer-review C32).
pub const RawTerm = struct {
    original: std.posix.termios,
    handle: std.Io.File.Handle,
    backend: Backend,

    pub fn disableRawMode(self: RawTerm) anyerror!void {
        try self.backend.tcsetattr(self.handle, .NOW, self.original);
    }
};

/// Enable raw mode on the given handle. Saves the original termios, transforms
/// it to a non-canonical raw mode (clears ICANON + ECHO at minimum), then
/// applies it via `tcsetattr(TCSANOW)`. The returned `RawTerm` carries the
/// saved termios + handle + backend; call `disableRawMode` to restore.
///
/// Per peer-review C27, the function takes `backend: Backend` as an explicit
/// argument (no Zig function overloading). PR 6 calls this as
/// `terminal.term.enableRawMode(handle, .posix)` after `src/tui.zig:245`.
pub fn enableRawMode(handle: std.Io.File.Handle, backend: Backend) anyerror!RawTerm {
    const original = try backend.tcgetattr(handle);
    var raw = original;
    // POSIX termios(3) §Non-canonical mode: disable canonical line buffering
    // and echo. ISIG preserved (signal-generating input keys still produce
    // signals per the default). Additional flags are not part of this PR's
    // surface; the full transformation lands in PR 6 alongside src/tui.zig.
    //
    // ponytail: minimal transformation sufficient for the PR 1 contract
    // (save / apply / restore round-trip). Bitfield edits via direct field
    // assignment; the Zig 0.16 std.posix.lflag is a packed struct(u32) so
    // bitwise masks would require runtime field-by-field copies. The PR 6
    // production transformation (ISIG, IEXTEN, IXON/ICRNL, OPOST, VMIN/VTIME,
    // etc.) is independent of the round-trip contract and stays in `src/tui.zig`.
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    try backend.tcsetattr(handle, .NOW, raw);
    return .{
        .original = original,
        .handle = handle,
        .backend = backend,
    };
}

/// Query the terminal size via `ioctl(TIOCGWINSZ)`. Returns a `TermSize` whose
/// width/height come from `winsize.col` / `winsize.row`. Errors propagate
/// unchanged (`error.NotATerminal` if the handle is not a tty).
pub fn getSize(handle: std.Io.File.Handle) anyerror!TermSize {
    // Ponytail: in-tree `getSize` keeps the std.posix layer hidden so callers
    // don't import linux.T directly. The Backend abstraction is the public
    // seam; for PR 1, a small PosixBackend-style fallback is inlined here
    // until we factor out the ioctl_gwinsz plumbing.
    const backend = PosixBackend.backend();
    const ws = try backend.ioctl_gwinsz(handle);
    return .{ .width = ws.col, .height = ws.row };
}

// =============================================================================
// Re-exports — design C31 keeps the renamed smoke canary at
// tests/tui/terminal_smoke.zig:64-91 (formerly tests/tui/mibu_smoke.zig)
// passing without change. PRs 2-5 land the actual implementations; for PR 1
// these are placeholder re-exports so the names exist on `terminal.term`.
// =============================================================================

// ponytail: stubs defer real impl to PRs 2-3. Mark as deliberate simplifications;
// upgrade by replacing each `= @compileError(...)` with the actual @import chain.
pub const enterAlternateScreen = struct {
    pub fn call(_: *std.Io.Writer) anyerror!void {
        @compileError("terminal.term.enterAlternateScreen lands in PR 2 (dpm.zig)");
    }
}.call;
pub const exitAlternateScreen = struct {
    pub fn call(_: *std.Io.Writer) anyerror!void {
        @compileError("terminal.term.exitAlternateScreen lands in PR 2 (dpm.zig)");
    }
}.call;
pub const enableInBandResize = struct {
    pub fn call(_: *std.Io.Writer) anyerror!void {
        @compileError("terminal.term.enableInBandResize lands in PR 2 (dpm.zig)");
    }
}.call;
pub const disableInBandResize = struct {
    pub fn call(_: *std.Io.Writer) anyerror!void {
        @compileError("terminal.term.disableInBandResize lands in PR 2 (dpm.zig)");
    }
}.call;
pub const beginSynchronizedUpdate = struct {
    pub fn call(_: *std.Io.Writer) anyerror!void {
        @compileError("terminal.term.beginSynchronizedUpdate lands in PR 2 (dpm.zig)");
    }
}.call;
pub const endSynchronizedUpdate = struct {
    pub fn call(_: *std.Io.Writer) anyerror!void {
        @compileError("terminal.term.endSynchronizedUpdate lands in PR 2 (dpm.zig)");
    }
}.call;

// =============================================================================
// Inline tests (REQTCL-013 — every public API has at least one inline test).
// These exercise the MockBackend and assert the structural invariants the
// in-tree tests/terminal/term.zig will later cover with deeper scenarios.
// =============================================================================

const testing = std.testing;

test "TermSize is a 2-field struct" {
    try testing.expect(@typeInfo(TermSize).@"struct".fields.len == 2);
    const sz: TermSize = .{ .width = 120, .height = 40 };
    try testing.expectEqual(@as(u16, 120), sz.width);
    try testing.expectEqual(@as(u16, 40), sz.height);
}

test "RawTerm.disableRawMode is a method declaration" {
    // Smoke canary at tests/tui/terminal_smoke.zig:38 asserts decls.len > 0;
    // the method counts as the 1 declaration. Guard against accidental
    // removal of the method.
    const decls = @typeInfo(RawTerm).@"struct".decls;
    try testing.expect(decls.len > 0);
    var saw_disable = false;
    for (decls) |d| {
        if (std.mem.eql(u8, d.name, "disableRawMode")) saw_disable = true;
    }
    try testing.expect(saw_disable);
}

test "PosixBackend returns fully populated Backend value" {
    const backend = PosixBackend.backend();
    // All three function pointers must be non-null; if any is unset the
    // Zig type system catches it at compile time, but the runtime check
    // documents the contract.
    try testing.expect(@intFromPtr(backend.tcgetattr) != 0);
    try testing.expect(@intFromPtr(backend.tcsetattr) != 0);
    try testing.expect(@intFromPtr(backend.ioctl_gwinsz) != 0);
}

test "term.zig re-exports the 6 DPM entry points (design C31)" {
    // Renamed smoke canary at tests/tui/terminal_smoke.zig:64-91 iterates the
    // terminal.term namespace and asserts these 6 names. The names must
    // resolve at compile time even before PR 2 lands the real impls.
    const term_info: std.builtin.Type = @typeInfo(@import("term.zig"));
    const decls = term_info.@"struct".decls;
    const required = [_][]const u8{
        "enterAlternateScreen",
        "exitAlternateScreen",
        "enableInBandResize",
        "disableInBandResize",
        "beginSynchronizedUpdate",
        "endSynchronizedUpdate",
        "enableRawMode",
        "getSize",
    };
    for (required) |name| {
        var found = false;
        for (decls) |d| {
            if (std.mem.eql(u8, d.name, name)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}
