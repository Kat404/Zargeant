// tests/tui/mibu_smoke.zig -- Compile-time guard that mibu (github.com/xyaman/mibu,
// MIT, Zig 0.16 tested) source resolves under the tui_mod namespace.
//
// Spec:   sdd/tui/spec   (id=379) REQ-TUI-018
// Design: sdd/tui/design (id=380) §1, §4
//
// PR 1 of the tui slice (3-PR feature-branch-chain). This file is the
// RED canary: it FAILS to compile under `zig build test` until the
// mibu dep is wired in build.zig AND the `tui_mod` module exposes
// `addImport("mibu", mibu_mod)` in build.zig.
//
// Touches the public API surface (term.RawTerm, term.TermSize, events.Event,
// events.nextWithTimeout, term.KittyFlags) so the build also flags
// symbol-name drift between mibu source and our @import("mibu") consumers
// (src/tui.zig + downstream PRs).
//
// Headless invariant: this file does NOT touch stdout/stderr.

const std = @import("std");
const testing = std.testing;
const mibu = @import("mibu");

// RED: any missing symbol forces a compile error. These mirror the 5
// libvaxis-era canaries (Tty, Vaxis, Loop, Event, Window) one-for-one,
// but using mibu's actual public surface (verified at PR 1 mibu swap,
// mibu commit 636a36a353614da2a537b060c33f17d608915eab).
const _type_canary_raw_term: ?mibu.term.RawTerm = null;
const _type_canary_term_size: ?mibu.term.TermSize = null;
const _type_canary_event: ?mibu.events.Event = null;
const _type_canary_key: ?mibu.events.Key = null;
const _type_canary_kitty_flags: ?mibu.term.KittyFlags = null;

test "mibu v0.0.1-dev source resolves" {
    // Compile-time references above already produced RED if any symbol
    // is missing. The runtime body asserts the modules are wired AND
    // the symbols are the exact types we expect (not renamed in some
    // future upstream release).
    try testing.expect(@typeInfo(mibu.term.RawTerm).@"struct".decls.len > 0);
    // TermSize is a plain data struct (width/height only, no methods).
    // Assert the struct shape -- catches a hypothetical upstream rename
    // that turns TermSize into a tuple or opaque.
    try testing.expect(@typeInfo(mibu.term.TermSize).@"struct".fields.len == 2);
    try testing.expect(@typeInfo(mibu.term.KittyFlags).@"struct".decls.len > 0);

    // Event is a tagged union in mibu (events.Event = union(enum) {...}).
    // @typeInfo returns .@"union" with a tag_type field (the underlying
    // enum). Assert the enum has at least one field (key, mouse, resize,
    // paste_start, paste_end, invalid, timeout, none).
    const event_info: std.builtin.Type = @typeInfo(mibu.events.Event);
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
    try testing.expect(@typeInfo(mibu.events.Key).@"struct".fields.len > 0);
}

test "mibu.term exposes the libvaxis-parity entry points" {
    // The functions we will call from PR 3's render loop must exist as
    // public decls on the mibu.term namespace. Catches upstream renames
    // before they reach our consumers.
    const term_info: std.builtin.Type = @typeInfo(mibu.term);
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

test "mibu.events exposes the libvaxis-parity entry points" {
    // nextWithTimeout replaces libvaxis Loop.nextEvent for PR 3.
    const events_info: std.builtin.Type = @typeInfo(mibu.events);
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
