// tests/tui/terminal_smoke.zig -- Compile-time guard that the in-tree
// `src/terminal/` module exposes the public surface src/tui.zig (and
// downstream consumers) depend on.
//
// Spec:    REQ-TCL-012 (test-terminal step), REQ-TUI-018 (predecessor)
// Design:  sdd/tui/design id=380 §1, §4 (predecessor); ADR 0003
//
// PR 6 (terminal-control-lib-from-scratch, WU 6.4): renamed from
// tests/tui/mibu_smoke.zig. The canary now exercises `src/terminal/`
// instead of the mibu dep. After PR 6 the `mibu` package is removed
// (WU 6.5); this file is the single authoritative smoke check that
// the in-tree module keeps the public surface stable.
//
// Touches the public API surface (term.RawTerm, term.TermSize,
// event.Event, event.Key, kitty.KittyFlags, event.nextWithTimeout,
// event.pollReadable, plus the term.{enterAlternateScreen,getSize,
// beginSynchronizedUpdate,...} re-exports from dpm per design C31)
// so the build also flags symbol-name drift between the in-tree
// module and consumers (src/tui.zig + downstream PRs).
//
// Headless invariant: this file does NOT touch stdout/stderr.

const std = @import("std");
const testing = std.testing;
const terminal = @import("terminal");

// RED: any missing symbol forces a compile error. These mirror the 5
// libvaxis-era canaries (Tty, Vaxis, Loop, Event, Window) one-for-one,
// but using the in-tree terminal module's actual public surface
// (per ADR 0003 + design v2 §4).
const _type_canary_raw_term: ?terminal.term.RawTerm = null;
const _type_canary_term_size: ?terminal.term.TermSize = null;
const _type_canary_event: ?terminal.event.Event = null;
const _type_canary_key: ?terminal.event.Key = null;
const _type_canary_kitty_flags: ?terminal.kitty.KittyFlags = null;

test "terminal in-tree source resolves" {
    // Compile-time references above already produced RED if any symbol
    // is missing. The runtime body asserts the modules are wired AND
    // the symbols are the exact types we expect (not renamed in some
    // future refactor).
    try testing.expect(@typeInfo(terminal.term.RawTerm).@"struct".decls.len > 0);
    // TermSize is a plain data struct (width/height only, no methods).
    // Assert the struct shape -- catches a hypothetical refactor
    // that turns TermSize into a tuple or opaque.
    try testing.expect(@typeInfo(terminal.term.TermSize).@"struct".fields.len == 2);
    try testing.expect(@typeInfo(terminal.kitty.KittyFlags).@"struct".decls.len > 0);

    // Event is a tagged union (terminal.event.Event = union(enum) {...}).
    // @typeInfo returns .@"union" with a tag_type field (the underlying
    // enum). Assert the enum has at least one field (key, mouse, resize,
    // paste_start, paste_end, invalid, timeout, none).
    const event_info: std.builtin.Type = @typeInfo(terminal.event.Event);
    switch (event_info) {
        .@"union" => |u| {
            try testing.expect(u.fields.len > 0);
            if (u.tag_type) |Tag| {
                try testing.expect(@typeInfo(Tag).@"enum".fields.len > 0);
            }
        },
        else => return error.ExpectedUnionEvent,
    }

    // Key is a struct with a KeyCode union field.
    try testing.expect(@typeInfo(terminal.event.Key).@"struct".fields.len > 0);
}

test "terminal.term exposes the public entry points" {
    // The functions we call from src/tui.zig must exist as public
    // decls on the terminal.term namespace. Catches refactor renames
    // before they reach our consumers.
    //
    // Per design C31 the dpm enter/exit/sync-update helpers are
    // re-exported on terminal.term so src/tui.zig can use the
    // `terminal.term.{enterAlternateScreen,...}` form byte-for-byte.
    const term_info: std.builtin.Type = @typeInfo(terminal.term);
    try testing.expect(term_info == .@"struct");
    const decls = term_info.@"struct".decls;
    var saw_enable_raw = false;
    var saw_get_size = false;
    var saw_enter_alt = false;
    var saw_exit_alt = false;
    var saw_begin_sync = false;
    var saw_end_sync = false;
    for (decls) |d| {
        if (std.mem.eql(u8, d.name, "enableRawMode")) saw_enable_raw = true;
        if (std.mem.eql(u8, d.name, "getSize")) saw_get_size = true;
        if (std.mem.eql(u8, d.name, "enterAlternateScreen")) saw_enter_alt = true;
        if (std.mem.eql(u8, d.name, "exitAlternateScreen")) saw_exit_alt = true;
        if (std.mem.eql(u8, d.name, "beginSynchronizedUpdate")) saw_begin_sync = true;
        if (std.mem.eql(u8, d.name, "endSynchronizedUpdate")) saw_end_sync = true;
    }
    try testing.expect(saw_enable_raw);
    try testing.expect(saw_get_size);
    try testing.expect(saw_enter_alt);
    try testing.expect(saw_exit_alt);
    try testing.expect(saw_begin_sync);
    try testing.expect(saw_end_sync);
}

test "terminal.event exposes nextWithTimeout + pollReadable" {
    // nextWithTimeout replaces libvaxis Loop.nextEvent for PR 3.
    // pollReadable is the C23 lock-in sub-capability for the renamed
    // smoke canary to assert (obs#1511 C23).
    const events_info: std.builtin.Type = @typeInfo(terminal.event);
    try testing.expect(events_info == .@"struct");
    const decls = events_info.@"struct".decls;
    var saw_next = false;
    var saw_poll = false;
    for (decls) |d| {
        if (std.mem.eql(u8, d.name, "nextWithTimeout")) saw_next = true;
        if (std.mem.eql(u8, d.name, "pollReadable")) saw_poll = true;
    }
    try testing.expect(saw_next);
    try testing.expect(saw_poll);
}
