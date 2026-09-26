//! tests/terminal/root.zig — single entrypoint for the test-terminal build step.
//!
//! Spec: REQ-TCL-012 (test-terminal step MUST prove non-zero test count),
//! REQ-TCL-013 (per-PR append discipline keeps new slices discoverable).
//!
//! Forces inline test discovery via std.testing.refAllDecls on the imported
//! submodules. PRs 2-5 append additional `_ = @import("<slice>.zig");` lines
//! here in the same commit that creates src/terminal/<slice>.zig (proposal
//! C19 / obs#1510 REQ-TCL-012).
//!
//! Imports:
//!   - `terminal` → src/terminal/mod.zig (the public API hub)
//!   - `term`     → src/terminal/term.zig (PR 1 slice; tests/terminal/term.zig imports it)
//!   - `@import("term.zig")` (sibling) → tests/terminal/term.zig (RED tests)
//!
//! `terminal_mod` is wired in build.zig as the `terminal` dep for the test
//! root module; `term_mod` is wired as the `term` dep for tests/terminal/term.zig.

const std = @import("std");
pub const terminal = @import("terminal");

test {
    _ = @import("term.zig"); // PR 1
    _ = @import("cursor.zig"); // PR 2 — WU 2.1
    _ = @import("style.zig"); // PR 2 — WU 2.1
    _ = @import("dpm.zig"); // PR 2 — WU 2.2
    _ = @import("kitty.zig"); // PR 2 — WU 2.3
    _ = @import("event_types.zig"); // PR 3 — WU 3.1 (basic type-coercion tests)
    _ = @import("event_parser.zig"); // PR 3 — WU 3.2 (streaming UTF-8 + base parser)
    _ = @import("event_critical.zig"); // PR 3 — WU 3.3 (C9/C11/C22/C28 lock-ins)
    _ = @import("event_kitty.zig"); // PR 4 — WU 4.1 (kitty kb CSI ... u parser)
    _ = @import("kitty_active.zig"); // PR 3 — T-R2.1+T-R2.2 (kitty_active gate)
    _ = @import("probe_lexer.zig"); // PR 5 — WU 5.1 (DECRPM reply lexer + 4 C14 failure modes)
    _ = @import("key_entry_paste.zig"); // tui-keyentry-rebuild WU-6 (pty integration for bracketed paste)
    std.testing.refAllDecls(terminal);
}
