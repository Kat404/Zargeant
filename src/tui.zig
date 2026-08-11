// src/tui.zig -- TUI thread body + mibu 0.0.1-dev lifecycle scaffold.
//
// Spec:   sdd/tui/spec   (id=379) REQ-TUI-002, REQ-TUI-003, REQ-TUI-015
// Design: sdd/tui/design (id=380) §4, §6
//
// PR 1 of the tui slice (3-PR feature-branch-chain) ships the mibu
// lifecycle scaffold only -- actual render + modal composition land in
// PR 3 (sdd id=381 tasks 3.1-3.6). This file exists in PR 1 because
// the `tui_mod` in build.zig references src/tui.zig as its root source
// and the mibu import needs at least one file to bind to.
//
// libvaxis was originally planned for PR 1 (design §4) but its v0.5.1
// transitive deps (zg, zigimg, libxev) do not compile on Zig 0.16. The
// squashed-away 5 libvaxis commits on feat/tui-pr1 vendored v0.6.0-dev
// at vendor/libvaxis/, vendor/zigimg/, vendor/uucode/ -- ~150K lines.
//
// mibu (github.com/xyaman/mibu, MIT, commit 636a36a353614da2a537b060c33f17d608915eab,
// Zig 0.16 tested) replaces libvaxis cleanly: zero transitive deps,
// zero heap allocations, ~950 LoC. PR 1 force-pushed with squash to
// wipe the libvaxis vendoring and replace it with this mibu scaffold.
// See obs#399 for the full replacement research.
//
// Linux/x86_64 Zig 0.16 only -- same guard as every other module in the
// project (logger, api_client, sandbox, etc.).
//
// Headless invariant: no writes to stdout/stderr. Defense-in-depth via
// the grep-fail target list in src/api_auth.zig.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Linux-only comptime guard (matches every other module in the project).
// MUST be the FIRST executable statement so non-Linux targets abort at
// compile time before any std.os.linux.* symbol is referenced.
// =============================================================================
comptime {
    if (builtin.os.tag != .linux)
        @compileError("tui: linux-only v1 -- see sdd/tui/proposal id=373 constraint #5");
}

const mibu = @import("mibu");

// Touch the mibu public API surface at compile time so the dep is
// verified to resolve when tui_mod compiles. PR 3 replaces these
// references with the real TUI render loop (`term.enterAlternateScreen`,
// `term.enableRawMode`, `term.beginSynchronizedUpdate`, `events.nextWithTimeout`,
// `term.getSize`, `term.exitAlternateScreen`).
//
// These mirror the 5 libvaxis-era canaries one-for-one but using mibu's
// actual public names (verified in /tmp/mibu-readonly at commit 636a36a).
comptime {
    _ = mibu.term.RawTerm;
    _ = mibu.term.TermSize;
    _ = mibu.term.KittyFlags;
    _ = mibu.events.Event;
    _ = mibu.events.nextWithTimeout;
}

// =============================================================================
// Tests (PR 1 -- compile-time only; PR 3 adds headless render tests)
// =============================================================================

test "tui_mod references mibu symbols" {
    // Compile-time references above already enforced the import.
    // The runtime body just confirms the symbols are reachable and the
    // module exposes the libvaxis-parity entry points we'll need in PR 3.
    const T = @TypeOf(mibu.term.RawTerm);
    try std.testing.expect(@typeInfo(T).@"struct".decls.len > 0);

    const term_info: std.builtin.Type = @typeInfo(mibu.term);
    var saw_enable_raw = false;
    for (term_info.@"struct".decls) |d| {
        if (std.mem.eql(u8, d.name, "enableRawMode")) saw_enable_raw = true;
    }
    try std.testing.expect(saw_enable_raw);
}

// PR 1 placeholder entry point. PR 3 (sdd id=381 task 3.2) wires the
// real TUI thread body that consumes runtime channels and drives the
// mibu render loop. PR 4+ replaces this with the production entry
// sourced from src/main.zig.
pub fn main() void {}
