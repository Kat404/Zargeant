//! src/terminal/mod.zig — public API hub for the in-tree terminal control library.
//!
//! POSIX termios(3), ECMA-48, xterm ctlseqs, and the kitty keyboard protocol spec
//! are the sole reference sources; mibu and libvaxis source code are NOT consulted
//! (CONTRIBUTING.md:41 + ADR 0001 §Negative + ADR 0002 §"Negative").
//!
//! PR 1 (terminal-control-lib-from-scratch) lands only `term.zig`. PRs 2-5 add
//! cursor, style, dpm, kitty, event. The module hub re-exports them as they
//! land; PR 6 atomically re-points `src/tui.zig` callers from `mibu.*` to
//! `terminal.*` per the chain strategy in obs#1514.

pub const term = @import("term.zig");

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
