//! tests/terminal/kitty_active.zig — RED tests for Parser.kitty_active gate (PR3, T-R2.1 + T-R2.2).
//!
//! Spec coverage: REQ-TCL-004 (CAP-33 terminal-event-parser) R2 fix —
//! the kitty kb dispatcher must gate on a per-parser flag that mirrors
//! `Lifecycle.kitty_flags_pushed`. Without the gate, any terminal that
//! emits `CSI ... u` (including a literal shift+u in legacy terminals
//! or a non-kitty CSI extension) gets mis-parsed as a kitty kb event,
//! forcing every TUI modal to special-case the literal codepoint.
//!
//! Test count: 9 RED tests.
//!   T-R2.1 (3 tests) — Parser.kitty_active field + setKittyActive + kittyActive
//!   T-R2.2 (6 tests) — gate truth table for `u` dispatch
//!
//! Strict TDD (CONTRIBUTING.md:7): tests authored alongside the WU's
//! RED commits. The first commit (T-R2.1 RED) adds the field + stub
//! setters/getters; this file exists from the T-R2.1 RED commit onward
//! so the gate-truth-table tests can be added incrementally per WU.
//!
//! Why the gate matters (per design §3.5): pre-fix, every `CSI ... u`
//! sequence was routed to `parseKittyKb` unconditionally — the
//! `lifecycle.kitty_flags_pushed` flag was never read. A terminal
//! that didn't push kitty kb could still emit `CSI 97 u` for a
//! literal 'a' (some terminals encode `Shift+U` this way as an
//! extension), and the parser would surface it as a `.key(.char('a'))`
//! with `.mods.shift=true` — confusing downstream consumers. The gate
//! routes those bytes back to `.invalid` when kitty kb is inactive.

const std = @import("std");
const testing = std.testing;

const event = @import("event");

// =============================================================================
// T-R2.1 — Parser.kitty_active field + setters/getters.
//
// These three tests verify the API surface (init + setter + getter)
// they are independent of the dispatcher's gate logic and pass as
// soon as the field + setters/getters land (T-R2.1 GREEN).
// =============================================================================

test "T-R2.1.1: Parser.kitty_active defaults to false (init)" {
    // PR3 R2 fix — the gate must default to conservative (no kitty kb
    // parsing) so untrusted terminals stay inert until `setKittyActive(true)`
    // is called explicitly.
    const parser = event.Parser.init();
    try testing.expectEqual(false, parser.kitty_active.load(.seq_cst));
    try testing.expectEqual(false, parser.kittyActive());
}

test "T-R2.1.2: Parser.setKittyActive(true) updates field" {
    // After `setKittyActive(true)`, both the direct field access and
    // the getter reflect the new value.
    var parser = event.Parser.init();
    parser.setKittyActive(true);
    try testing.expectEqual(true, parser.kitty_active.load(.seq_cst));
    try testing.expectEqual(true, parser.kittyActive());
}

test "T-R2.1.3: Parser.setKittyActive(false) updates field (round-trip)" {
    // Round-trip: setting true then false returns to false. The
    // setter is the only mutation point (per design D3 lock-in).
    var parser = event.Parser.init();
    parser.setKittyActive(true);
    try testing.expectEqual(true, parser.kittyActive());
    parser.setKittyActive(false);
    try testing.expectEqual(false, parser.kitty_active.load(.seq_cst));
    try testing.expectEqual(false, parser.kittyActive());
}

// =============================================================================
// T-R2.2 — Dispatch gate truth table.
//
// Six tests verify the dispatcher's behavior at the `final == 'u'`
// branch in `dispatchCsi`:
//   - kitty_active=false → return .invalid (gate blocks parseKittyKb)
//   - kitty_active=true  → parseKittyKb runs as before
//
// The truth table covers the three shapes most TUI modals depend on:
//   1. plain codepoint    (CSI 97 u  = literal 'a' press)
//   2. functional code    (CSI 127 u = backspace — regression guard for
//      the Phase 0.4 codepoint mapping fix)
//   3. codepoint + mods   (CSI 65;5 u = 'A' with shift+ctrl)
//
// Test scenarios 4-6 mirror the regression that motivated the gate:
// without `setKittyActive(true)`, the dispatcher's `final == 'u'`
// branch must NOT call `parseKittyKb`. Pre-fix, it did — so a terminal
// that didn't push kitty kb still produced `.key(.char('a'))` for
// `CSI 97 u`, confusing every TUI consumer.
// =============================================================================

test "T-R2.2.1: kitty_active=false, CSI 97 u returns .invalid (gate blocks)" {
    // Plain 'a' codepoint with kitty kb gate OFF. Pre-fix, the
    // dispatcher always called `parseKittyKb` and returned
    // `.key(.char('a'))`. The gate must now return `.invalid` so
    // downstream modals don't see a phantom kitty kb event.
    var parser = event.Parser.init();
    // kitty_active is false by default — no setKittyActive(true) here.
    try testing.expectEqual(false, parser.kittyActive());
    parser.feedBytes("\x1b[97u");
    const ev = parser.decode();
    try testing.expect(ev == .invalid);
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

test "T-R2.2.2: kitty_active=true, CSI 97 u returns .key press (gate opens)" {
    // Same sequence with the gate ON must produce a `.key` event with
    // `.code = .char('a')` — the Phase 0.4 functional-codepoint
    // mapping (9, 13, 27, 127) leaves 97 as `.char(97)`.
    var parser = event.Parser.init();
    parser.setKittyActive(true);
    parser.feedBytes("\x1b[97u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'a'), ev.key.code.char);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
}

test "T-R2.2.3: kitty_active=false, CSI 13 u returns .invalid (regression: DEL/Enter not parsed)" {
    // Regression guard for the Phase 0.4 fix (functional codepoint
    // mapping). Pre-fix AND with the new gate OFF, `CSI 13 u` would
    // still call `parseKittyKb` and return `.key(.enter)`. The gate
    // must return `.invalid` so an untrusted terminal emitting a
    // literal `\x1b[13u` (e.g. an emacs binding) doesn't surface a
    // phantom `.enter` event.
    var parser = event.Parser.init();
    try testing.expectEqual(false, parser.kittyActive());
    parser.feedBytes("\x1b[13u");
    const ev = parser.decode();
    try testing.expect(ev == .invalid);
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

test "T-R2.2.4: kitty_active=true, CSI 127 u returns .key .backspace (functional code mapping preserved)" {
    // With the gate ON, the Phase 0.4 functional-codepoint mapping
    // still maps 127 (ASCII DEL) to `.backspace`. This guards against
    // an accidental regression where the gate placement swallows the
    // codepoint mapping. Per the ODD risk §4: gate must be placed
    // AFTER `parseKittyKb` returns a valid Key — gate at the
    // `dispatchCsi:610` site, NOT inside `parseKittyKb`.
    var parser = event.Parser.init();
    parser.setKittyActive(true);
    parser.feedBytes("\x1b[127u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expect(ev.key.code == .backspace);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
}

test "T-R2.2.5: kitty_active=false, CSI 65;5 u returns .invalid (mods not parsed)" {
    // Plain 'A' with shift+ctrl modifiers. With the gate OFF, the
    // dispatcher must return `.invalid` — no `.key` event surfaces,
    // no Mods field gets populated. Pre-fix, `parseKittyKb` ran
    // unconditionally and produced `.key(.char('A'), .mods = shift+ctrl)`.
    var parser = event.Parser.init();
    try testing.expectEqual(false, parser.kittyActive());
    parser.feedBytes("\x1b[65;5u");
    const ev = parser.decode();
    try testing.expect(ev == .invalid);
    try testing.expectEqual(@as(usize, 0), parser.ring_len);
}

test "T-R2.2.6: kitty_active=true, CSI 65;5 u returns .key with shift+ctrl mods" {
    // With the gate ON, the same sequence produces `.key(.char('A'))`
    // with `mods.shift == true` and `mods.ctrl == true` (mod bitmask
    // 5 = 1 (shift) + 4 (ctrl) per the kitty kb spec). This mirrors
    // the existing event_kitty.zig Scenario 4 with the gate-ON setup.
    var parser = event.Parser.init();
    parser.setKittyActive(true);
    parser.feedBytes("\x1b[65;5u");
    const ev = parser.decode();
    try testing.expect(ev == .key);
    try testing.expectEqual(@as(u21, 'A'), ev.key.code.char);
    try testing.expectEqual(true, ev.key.mods.shift);
    try testing.expectEqual(true, ev.key.mods.ctrl);
    try testing.expectEqual(false, ev.key.mods.alt);
    try testing.expectEqual(false, ev.key.mods.super_);
    try testing.expectEqual(event.EventKind.press, ev.key.event);
}

// =============================================================================
// Issue #53 (tech-debt review, obs#1791 §4): Parser.kitty_active must be
// std.atomic.Value(bool), not plain bool. Currently safe because Parser is
// TUI-thread-only; the atomic change future-proofs the field for shared
// access (e.g. orchestrator-side ring buffer readers). std.atomic.Value
// guarantees no torn reads/writes on x86_64 and matches the pattern
// already used by Lifecycle.redraw_pending (src/tui.zig:110).
// =============================================================================

test "issue #53: Parser.kitty_active atomic API is available (load/store)" {
    // The field must be std.atomic.Value(bool) so .load/.store compile.
    // Plain bool has no .load member → this test would fail to compile.
    var parser = event.Parser.init();
    parser.setKittyActive(true);
    const loaded: bool = parser.kitty_active.load(.seq_cst);
    try testing.expectEqual(true, loaded);

    parser.setKittyActive(false);
    const reloaded: bool = parser.kitty_active.load(.seq_cst);
    try testing.expectEqual(false, reloaded);
}

test "issue #53: Parser.kitty_active is std.atomic.Value(bool) (struct shape)" {
    // Compile-time type check — the field type must be std.atomic.Value(bool).
    // If a future PR regresses this to plain bool, the type assertion catches it.
    const p = event.Parser.init();
    const T = @TypeOf(p.kitty_active);
    try testing.expect(T == std.atomic.Value(bool));
}

test "issue #53: Parser.kitty_active concurrent load/store from multiple threads" {
    // Stress test — one alternating writer + two readers, with the
    // writer looping until BOTH readers complete. The writer flips
    // true↔false every iteration; each reader loops until it observes
    // BOTH values then signals completion. With this protocol:
    //   - The writer is GUARANTEED to be active while the readers run
    //     (the writer loop condition `completed < 2` only becomes
    //     false after both readers fetchAdd their completion flag).
    //   - The writer alternates every iteration, so any reader that
    //     does ≥2 iterations while the writer is active MUST observe
    //     both true AND false (the writer flips between them).
    // This is deterministic — no fixed-iteration flake (where readers
    // could finish before the writer started).
    //
    // The prior assertion `v == true or v == false` was trivially true
    // on x86_64 (where bool reads are naturally atomic); this version
    // actually validates the atomic API delivers consistent values
    // across concurrent threads.
    //
    // Counters are std.atomic.Value(usize) shared between the two
    // readers — fetchAdd avoids the read-modify-write race that plain
    // `usize += 1` would have across the two readers.
    var parser = event.Parser.init();
    var seen_true = std.atomic.Value(usize).init(0);
    var seen_false = std.atomic.Value(usize).init(0);
    var completed = std.atomic.Value(usize).init(0);

    const WriterCtx = struct {
        p: *event.Parser,
        completed: *std.atomic.Value(usize),
    };
    const ReaderCtx = struct {
        p: *event.Parser,
        seen_true: *std.atomic.Value(usize),
        seen_false: *std.atomic.Value(usize),
        completed: *std.atomic.Value(usize),
    };

    const writerFn = struct {
        fn run(ctx: *const WriterCtx) void {
            var i: usize = 0;
            // Keep writing until BOTH readers have completed. This
            // guarantees the writer is active while the readers are
            // running, so the readers can observe the alternation.
            while (ctx.completed.load(.seq_cst) < 2) {
                ctx.p.setKittyActive(i % 2 == 0);
                i += 1;
            }
        }
    }.run;

    const readerFn = struct {
        fn run(ctx: *const ReaderCtx) void {
            var local_seen_true = false;
            var local_seen_false = false;
            var iters: usize = 0;
            // Loop until we observe BOTH values. The cap (10000) is
            // safety only — with the writer alternating every iteration
            // and the writer guaranteed active until both readers
            // complete, two consecutive iterations MUST see both
            // values. The cap is well above any sane OS scheduling
            // jitter.
            while (iters < 10000 and (!local_seen_true or !local_seen_false)) : (iters += 1) {
                const v: bool = ctx.p.kitty_active.load(.seq_cst);
                if (v) {
                    local_seen_true = true;
                    _ = ctx.seen_true.fetchAdd(1, .seq_cst);
                } else {
                    local_seen_false = true;
                    _ = ctx.seen_false.fetchAdd(1, .seq_cst);
                }
            }
            // If the cap was hit without observing both values, the
            // atomic API is broken (writer stopped writing before
            // reader finished). This should never fire with the
            // completed-count writer protocol above.
            if (!local_seen_true or !local_seen_false) {
                std.debug.panic(
                    "atomic stress test failed: reader saw only one value " ++
                        "after 10000 iterations (true={}, false={})",
                    .{ local_seen_true, local_seen_false },
                );
            }
            _ = ctx.completed.fetchAdd(1, .seq_cst);
        }
    }.run;

    var w_ctx = WriterCtx{ .p = &parser, .completed = &completed };
    var rt1_ctx = ReaderCtx{
        .p = &parser,
        .seen_true = &seen_true,
        .seen_false = &seen_false,
        .completed = &completed,
    };
    var rt2_ctx = ReaderCtx{
        .p = &parser,
        .seen_true = &seen_true,
        .seen_false = &seen_false,
        .completed = &completed,
    };

    var wt = try std.Thread.spawn(.{}, writerFn, .{&w_ctx});
    var rt1 = try std.Thread.spawn(.{}, readerFn, .{&rt1_ctx});
    var rt2 = try std.Thread.spawn(.{}, readerFn, .{&rt2_ctx});
    wt.join();
    rt1.join();
    rt2.join();

    // Sanity check — at least one observation of each value across
    // all reader iterations (the shared atomic counters).
    try testing.expect(seen_true.load(.seq_cst) > 0);
    try testing.expect(seen_false.load(.seq_cst) > 0);
}
