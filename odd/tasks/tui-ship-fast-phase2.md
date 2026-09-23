# TUI Ship-Fast Phase 2 — Architectural Tiger Style Retrofit

**Feature**: `tui-ship-fast-phase2`
**Branch**: `feat/tui-ship-fast-phase2` (NEW; off `feat/tui-ship-fast-phase0` after PR #40 merge)
**Base**: `feat/tui-ship-fast-phase0` @ `93fdb2a` (post Phase 0 + Phase 0.5 merge)
**Store**: engram topic `odd/tui-ship-fast-phase2/tasks`
**Created**: 2026-09-22
**Mode**: strict TDD (RED before GREEN), Conventional Commits, global git identity `Kat404 <71116973+Kat404@users.noreply.github.com>` ONLY
**PR strategy**: option D split — 6 PRs, all under 400 LoC review budget (per Ask me gate at tasks phase)

---

## Objective

Replace the heap-allocated `WindowMock` cell grid + per-frame `emitFrame` with a pure three-stage render pipeline: `renderToGrid(State, *ScreenGrid)` → `diffAndEmit(prev, active)` → `submitFrame(writer, bracketed)`. Add a `[2]ScreenGrid` double buffer on `Lifecycle` for bounded-memory frame composition. Add a dead-pty detector in `tuiThreadShutdown` for clean exit when /dev/tty is gone. Resolve R2 (kitty_active parser gate) and R5 (submitUnlockAsync cancel-pipe) that were deferred from Phase 0.5.

## Why now

Phase 0 (PR #40, merged 2026-09-21) fixed 7 surgical TUI bugs. Phase 0.5 closed 5 of 7 smoke residuals. Two residuals (R2 kitty_active, R5 cancel-pipe) plus the architectural debt that compounds them (UTF-8 truncation at `src/tui.zig:478`, per-frame heap `WindowMock` alloc, no DEC 2026 bracketing, no event-batching cap) cannot be addressed without the ScreenGrid + double-buffer refactor that this PR delivers.

## Scope

### In scope

- **WU 2.1** — `ScreenGrid` value type + `CursorIntent` enum (~290 LoC impl + ~330 LoC tests)
- **WU 2.2** — Pure `diffAndEmit` algorithm in `src/diff_emit.zig` (~180 LoC + ~50 LoC tests)
- **WU 2.3** — `renderToGrid` variants for the 5 modal draw fns (~90 LoC + ~120 LoC tests)
- **WU 2.4** — `WindowMock` adapter wrapping `ScreenGrid` (T-SG-8 contract preserved) (~50 LoC + ~80 LoC tests)
- **WU 2.5** — `Lifecycle` memory refactor: `[2]ScreenGrid` + `force_full_redraw: bool` (~50 LoC + ~60 LoC tests)
- **WU 2.6** — `tuiThreadLoop` integration: `submitFrame` replaces `emitFrame`; `MAX_DRAIN_PER_TICK = 128`; dead-pty detector (D1 option e) (~90 LoC + ~125 LoC tests)
- **R2** — `kitty_active` parser gate via `Parser.kitty_active: bool` field (~35 LoC + ~130 LoC tests)
- **R5** — `submitUnlockAsync` cancel-pipe wiring (~30 LoC + ~55 LoC tests)

**Total estimate**: ~815 LoC production + ~950 LoC tests = ~1,765 LoC (slightly above proposal's ~870 due to WindowMock adapter + new test targets).

### Out of scope (explicit deferrals)

- No new third-party dependencies (mibu, libvaxis, tcell, crossterm excluded — ADR 0001)
- No new `std.Thread.spawn` sites
- No `api_auth` signature changes
- No `channels.zig` protocol breaking changes
- No `WindowMock` removal (wrapped, not deleted — T-SG-8)
- No `tui.zig` `emitFrame` removal in this PR (deprecated behind new pipeline; follow-up PR)
- No `submitFrame` error categorization layer (D1 option d rejected; dead-pty detector covers the corner case)
- No retro-application of Tiger Style to other code (Phase 0 WU 0.0 commitment)
- No clean-room reimplementation of terminal primitives (in-tree `src/terminal/` from PR 6 preserved)

## Constraints (Tiger Style + project invariants)

1. Strict TDD: RED test before GREEN impl; tests in same commit as the impl they cover.
2. No allocator.alloc/calloc/create in hot paths (`diffAndEmit`, `renderToGrid`, `submitFrame`, `tuiThreadLoop`, `Parser.next`) — Tiger Style §3.
3. `std.debug.assert` on every new function precondition — Tiger Style §4.
4. `@intCast` / `@ptrCast` always range-guarded — Tiger Style §4.
5. Exhaustive switches on `State` union + `CursorIntent` enum — Tiger Style §5.
6. No recursion — all loops bounded (`MAX_DRAIN_PER_TICK = 128`, `cols*rows` for grid scans) — Tiger Style §5.
7. No AI co-author lines (CI guard rejects).
8. Git identity: `Kat404 <71116973+Kat404@users.noreply.github.com>` (global, no local override).
9. Conventional Commits format on every commit.
10. WindowMock T-SG-8 contract preserved (`pub fn drawKeyEntry`, `pub fn drawUnlock`, `pub fn drawConsentPrompt`, `pub fn drawErrorModal`, `pub fn drawAgentLoopView`, `pub fn init(allocator`, `pub fn diff(self` literals must remain in `src/modal.zig`).
11. WindowMock T-SG-9 contract preserved (no new third-party imports).
12. New T-SG-10: ScreenGrid type literal in `src/screen_grid.zig` (`pub const MAX_CELL_BUF`, `pub const ScreenGrid`, `pub fn init`, `pub fn writeCell`, etc.).
13. New T-SG-11: no allocator calls in `renderToGrid`/`diffAndEmit`/`submitFrame` hot paths.

## PR structure (option D — 6 PRs, all under 400 LoC)

| PR | Title | Tasks | LoC (impl+tests) | Branch from | Merge to |
|----|-------|-------|------------------:|-------------|----------|
| PR1a-i | Add ScreenGrid value type | T-2.1.1 | ~595 | origin/main | main |
| PR1a-ii | Add CursorIntent + cursorFromIntent | T-2.1.2 | ~80 | main | main |
| PR1b | Add diffAndEmit pure renderer | T-2.2.1 | ~325 | main | main |
| PR1c | Add renderToGrid variants + WindowMock adapter | T-2.3.1 + T-2.3.2 + T-2.3.3 + T-2.4.1 | ~210 | main | main |
| PR2 | Lifecycle refactor + submitFrame + dead-pty detector | T-2.5.1 + T-2.5.2 + T-2.6.1 + T-2.6.2 + T-2.6.3 | ~295 | main | main |
| PR3 | kitty_active gate + cancel_pipe wiring | T-R2.1 + T-R2.2 + T-R2.3 + T-R5.1 + T-R5.2 + T-R5.3 + T-R5.4 | ~370 | main | main |

## Work units (19 tasks)

| # | Task ID | Title | Files | LoC | PR |
|---|---------|-------|-------|----:|----|
| 1 | T-2.1.1 | ScreenGrid value type | NEW `src/screen_grid.zig`, MOD `src/root.zig`, MOD `build.zig`, NEW `tests/tui/screen_grid.zig` | +220 +280 | PR1a-i |
| 2 | T-2.1.2 | CursorIntent + cursorFromIntent | MOD `src/screen_grid.zig`, MOD `tests/tui/screen_grid.zig` | +30 +50 | PR1a-ii |
| 3 | T-2.2.1 | DiffEntry + diffAndEmit | NEW `src/diff_emit.zig`, MOD `src/root.zig`, MOD `build.zig`, MOD `tests/tui/screen_grid.zig` | +180 +50 | PR1b |
| 4 | T-2.3.1 | renderKeyEntryToGrid | MOD `src/modal.zig`, MOD `tests/tui/screen_grid.zig` | +20 +25 | PR1c |
| 5 | T-2.3.2 | render*ToGrid (4 more) | MOD `src/modal.zig`, MOD `tests/tui/screen_grid.zig` | +60 +80 | PR1c |
| 6 | T-2.3.3 | renderToGrid dispatcher | MOD `src/modal.zig`, MOD `tests/tui/screen_grid.zig` | +10 +15 | PR1c |
| 7 | T-2.4.1 | WindowMock adapter | MOD `src/modal.zig`, MOD `tests/tui/screen_grid.zig` | +50 +80 | PR1c |
| 8 | T-2.5.1 | Lifecycle fields | MOD `src/tui.zig`, MOD `tests/tui/runtime_thread.zig` | +40 +50 | PR2 |
| 9 | T-2.5.2 | tuiRealMain grids alloc | MOD `src/runtime.zig`, MOD `tests/tui/runtime_thread.zig` | +10 +10 | PR2 |
| 10 | T-2.6.1 | submitFrame orchestrator | MOD `src/tui.zig`, MOD `tests/tui/runtime_thread.zig` | +60 +80 | PR2 |
| 11 | T-2.6.2 | tuiThreadLoop calls submitFrame | MOD `src/tui.zig`, MOD `tests/tui/runtime_thread.zig` | +20 +30 | PR2 |
| 12 | T-2.6.3 | Dead-pty detector | MOD `src/tui.zig`, MOD `tests/tui/runtime_thread.zig` | +10 +15 | PR2 |
| 13 | T-R2.1 | Parser.kitty_active field | MOD `src/terminal/event.zig`, NEW `tests/terminal/kitty_active.zig`, MOD `build.zig` | +20 +30 | PR3 |
| 14 | T-R2.2 | parseKittyKb gate | MOD `src/terminal/event.zig`, MOD `tests/terminal/event_kitty.zig`, NEW `tests/terminal/kitty_active.zig` | +5 +90 | PR3 |
| 15 | T-R2.3 | tuiThreadInit wires setKittyActive | MOD `src/tui.zig`, MOD `tests/tui/runtime_thread.zig` | +10 +10 | PR3 |
| 16 | T-R5.1 | LoadCtx.cancel_pipe field | MOD `src/modal.zig`, MOD `tests/tui/runtime_thread.zig` | +5 +5 | PR3 |
| 17 | T-R5.2 | submitUnlockAsync takes cancel_pipe | MOD `src/modal.zig`, MOD `tests/tui/runtime_thread.zig` | +10 +15 | PR3 |
| 18 | T-R5.3 | runLoadWorker polls cancel_pipe | MOD `src/modal.zig`, MOD `tests/cancel_e2e.zig` | +10 +25 | PR3 |
| 19 | T-R5.4 | handleKeyInput threads cancel_pipe | MOD `src/tui.zig`, MOD `tests/tui/runtime_thread.zig` | +5 +10 | PR3 |

## Risks (declared)

1. **PR1a-i LoC ~595** (impl + tests combined). Production-only ~220 LoC is well under budget; tests ~280 LoC separately. If reviewer counts tests in LoC budget, consider splitting T-2.1.1 into T-2.1.1a (struct + accessors, ~150 impl + ~200 tests = 350) and T-2.1.1b (swap/snapshot, ~70 impl + ~80 tests = 150).
2. **T-2.4.1 (WindowMock adapter)** is the highest regression risk — must keep the 17 existing `modal.zig` tests green while forwarding 10 WindowMock methods to the new ScreenGrid. Mitigation: TDD order — adapter test first, then impl, then run full modal test battery per commit.
3. **T-2.6.2 (tuiThreadLoop calls submitFrame)** deletes the inline emitFrame at `src/tui.zig:639-677` AND the prev_snapshot dupe at `tui.zig:674-676`. If submitFrame's swap-on-zero-copy isn't proven in T-2.6.1 unit tests, Slice 2 ships with frame corruption. Mitigation: T-2.6.1 must include a RED test asserting `[2]ScreenGrid swap after diff produces identical current_grid`.
4. **T-R2.2 (parseKittyKb gate)** regresses the Phase 0.4 fix (functional codepoints 13→enter, 127→backspace, etc.) if the gate is placed before the codepoint mapping. Mitigation: gate must be placed AFTER `parseKittyKb` returns a valid Key (test the gate at `dispatchCsi:610` site, not inside `parseKittyKb`).
5. **Dead-pty detector (T-2.6.3)** is a 5-LoC addition but relies on `writer.flush()` correctly propagating `error.BrokenPipe` on PTY close. Mitigation: include a test that pipes to a closed fd and asserts shutdown returns without writing cleanup bytes.

## Acceptance criteria (per PR slice)

Each PR ships when:
- [ ] `just check` exit 0
- [ ] `just fmt-check` exit 0
- [ ] All relevant `just test-*` targets exit 0
- [ ] T-SG-8 / T-SG-9 / T-SG-10 / T-SG-11 static-grep guards still pass
- [ ] No AI co-author lines
- [ ] Git identity preserved (`Kat404 <71116973+Kat404@users.noreply.github.com>`)
- [ ] Conventional Commits format
- [ ] `just ci` 11/11 + new test targets green
- [ ] Manual `just run-mock` smoke test green (TUI launches + handles input)

## Verification recipes

```bash
# Always
just check                    # Tiger Style static guards
just fmt-check                 # formatting

# Per PR
just test-tui-screen-grid      # ScreenGrid + diff + render + adapter tests (PR1a-i onward)
just test-tui-runtime-thread   # TUI lifecycle tests (PR1c onward)
just test-tui                  # terminal smoke canary
just test-terminal             # terminal event tests
just test-cancel-path          # cancel pipe static guards (PR3)
just test-cancel-e2e           # cancel e2e (PR3, env-gated)

# End of each PR
just ci                        # full local CI (Podman + Alpine)
just run-mock                  # manual TUI smoke test
```

## References

- **Proposal**: `sdd/tui-ship-fast-phase2/proposal` (Engram)
- **Spec**: `sdd/tui-ship-fast-phase2/spec` (Engram) — 30 REQs, 50 Gherkin scenarios
- **Design**: `sdd/tui-ship-fast-phase2/design` (Engram) — file layout, function signatures
- **Tasks**: `sdd/tui-ship-fast-phase2/tasks` (Engram) — 19 tasks with RED anchors
- **Explore**: `sdd/tui-ship-fast-phase2/explore` (Engram) — 6 WUs + R2 + R5 with file:line anchors
- **Agy validation**: `zargeant/decision/agy-phase2-validation` (Engram) — 3 SS + 5 risks + 12 Q verdicts
- **PR split decision**: `tui-ship-fast-phase2/pr-split-decision` (Engram) — option D rationale
- **Phase 0 baseline**: `odd/tasks/tui-ship-fast-phase0.md` (merged in PR #40)
- **Phase 0.5 supplement**: `odd/tasks/tui-ship-fast-phase0.5.md` (merged in PR #40)
- **justfile recipes**: `AGENTS.md` §9
- **OpenCode question tool bug**: `anomalyco/opencode/issues/25873#issuecomment-5781016715`

## Verification evidence (as tasks complete)

| Task | Commit | `just` command | Expected | Status |
|------|--------|-----------------|----------|--------|
| T-2.1.1 | `4f5824a` | `just test-tui-screen-grid` | 10/10 PASS | ✅ DONE |
| T-2.1.2 | `a40f2ac` | `just test-tui-screen-grid` | 11/11 PASS | ✅ DONE |
| T-2.2.1 | `f0e69e2` (RED) + `<green>` (this WU) | `just test-tui-screen-grid` | 22/22 PASS | ✅ DONE |
| T-2.3.1 | `aecfe03` (RED) + `<green>` (this WU) | `just test-tui-screen-grid` | 23/23 PASS | ✅ DONE |
| T-2.3.2 | `93a85ec` (RED) + `bca7639` (GREEN) | `just test-tui-screen-grid` | 27/27 PASS | ✅ DONE |
| T-2.3.3 | `ac32567` (RED) + `<green>` (this WU) | `just test-tui-screen-grid` | 28/28 PASS | ✅ DONE |
| T-2.4.1 | `9db7f6d` (RED) + `<green>` (this WU) | `just test-tui-screen-grid` + `just test-runtime-thread` | 29/29 + 69/69 PASS | ✅ DONE |
| T-2.5.1 | `<this WU>` (combined RED+GREEN) | `just test-runtime-thread` | 78/78 PASS (69 prior + 9 new T-2.5.1 tests) | ✅ DONE |
| T-2.5.2 | `<this WU>` (T-2.5.1 carried the impl; this commit adds 2 RED tests) | `just test-runtime-thread` | 80/80 PASS (78 prior + 2 new T-2.5.2 tests) | ✅ DONE |

## Progress

- [x] T-2.1.1 ScreenGrid value type — **DONE** (`4f5824a`)
- [x] T-2.1.2 CursorIntent + cursorFromIntent — **DONE** (`a40f2ac`)
- [x] T-2.2.1 DiffEntry + diffAndEmit — **DONE** (`f0e69e2` RED + `<green>` GREEN)
- [x] T-2.3.1 renderKeyEntryToGrid — **DONE** (`aecfe03` RED + `<green>` GREEN)
- [x] T-2.3.2 render*ToGrid (4 more) — **DONE** (`93a85ec` RED + `bca7639` GREEN)
- [x] T-2.3.3 renderToGrid dispatcher — **DONE** (`ac32567` RED + `<green>` GREEN)
- [x] T-2.4.1 WindowMock adapter — **DONE** (`9db7f6d` RED + `<green>` GREEN)
- [x] T-2.5.1 Lifecycle fields — **DONE** (RED + GREEN combined; see test counts above)
- [x] T-2.5.2 tuiRealMain grids alloc — **DONE** (grid-init verification tests land here; the actual `tuiThreadInit` + stub-`Lifecycle` grid init was already in the T-2.5.1 commit because adding the `grids` field without initializing it would not compile)
- [ ] T-2.6.1 submitFrame orchestrator
- [ ] T-2.6.2 tuiThreadLoop calls submitFrame
- [ ] T-2.6.3 Dead-pty detector
- [ ] T-R2.1 Parser.kitty_active field
- [ ] T-R2.2 parseKittyKb gate
- [ ] T-R2.3 tuiThreadInit wires setKittyActive
- [ ] T-R5.1 LoadCtx.cancel_pipe field
- [ ] T-R5.2 submitUnlockAsync takes cancel_pipe
- [ ] T-R5.3 runLoadWorker polls cancel_pipe
- [ ] T-R5.4 handleKeyInput threads cancel_pipe
