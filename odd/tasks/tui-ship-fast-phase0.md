# TUI Ship-Fast Phase 0 — Root-Cause Fixes

**Feature**: `tui-ship-fast-phase0`
**Branch**: `feat/tui-ship-fast-phase0`
**Base**: `origin/main` @ `e9de8fcc` (clean, no PR #39 merged)
**Store**: engram topic `odd/tui-ship-fast-phase0/tasks`
**Created**: 2026-09-21
**Mode**: strict TDD (RED before GREEN), Conventional Commits, global git identity `Kat404 <71116973+Kat404@users.noreply.github.com>` ONLY (never local/placeholder)

## Objective

Fix the 5 user-reported TUI input bugs at root cause, surgically, in one atomic PR. PR1 of 2 in the architectural Tiger Style retrofit (Phase 2 follows in PR2 once this PR is merged + user-validated).

## Problem

User reports 5 persistent TUI input symptoms at HEAD `e9de8fc` despite PR #39 (`tui-input-rendering-fixes`) claiming fixes landed:
1. Paste of long API key → no asterisks rendered
2. Enter after typing → taken as char, not submit
3. Typing latency: A,S,D → only 1 char after D before next appears
4. `Enter API key:` prompt has no leading space
5. Holding backspace first ADDS asterisks, then settles to removal

## Root causes (agy-validated, 2026-09-21)

| Defect | File:line | Resolves |
|---|---|---|
| `Parser.next` polls unconditionally without checking `ring_len > 0`; timeout aborts paste prematurely | `src/terminal/event.zig:240-294` | Bugs 1, 3 |
| `parseKittyKb` hardcodes `Key.code = .{ .char = key_code }`; functional codepoints (13=enter, 127=backspace, 27=esc, 9=tab) never reach `KeyCode.enter/.backspace/.esc/.tab` | `src/terminal/event.zig:525-526` | Bugs 2, 5 |
| Cursor position coupled to diff array in `emitFrame`; no CUP emitted when `diffs.len == 0` | `src/tui.zig:405-444` | Bug 4 |
| `enableRawMode` only clears ICANON+ECHO; leaves ICRNL/IXON/OPOST at defaults | `src/terminal/term.zig:177-199` | hardening |

## Scope

**In-scope**:
- 5 surgical code changes to fix the 3 root defects
- 3 new regression test batteries (one per defect family)
- 1 commit per work-unit (8 total commits)
- AGENTS.md (Tiger Style mandate) commit at branch tip
- `zig build verify` must remain green (408 existing tests + ~10 new tests)

**Out-of-scope** (Phase 2 in separate PR):
- Eliminating `threadlocal var current_parser` (use explicit `*Parser` param)
- Replacing heap `WindowMock` with static `ScreenGrid`
- Pure renderer pipeline (`renderToGrid` + `diffAndEmit`)
- Double buffering with `[2]ScreenGrid` + `active_idx` XOR swap
- `MAX_CELLS_CEILING = 32768` heap allocation in `tuiThreadInit`
- DEC 2026 bracketing in `submitFrame`
- UTF-8 emission via `std.unicode.utf8Encode`
- Resize invalidation flag (`force_full_redraw`)
- Dead code deletion (`src/password_input.zig`, `runtime.zig:476-484`, `event.zig:790-792`)

## Work units (8)

| WU | Title | Files | LOC | Tests |
|---|---|---|---|---|
| 0.0 | Commit `AGENTS.md` (Tiger Style mandate) | `AGENTS.md` (new) | 163 | n/a |
| 0.1 | RED: tests for Parser.next draining `ring_buf` before poll | `tests/terminal/event_parser.zig` (add) | +35 | new RED tests for paste + multi-key sequences |
| 0.2 | GREEN: drain `ring_buf` in `Parser.next` before poll | `src/terminal/event.zig:240-294` | +5/-3 | 0.1 tests pass |
| 0.3 | RED: tests for kitty kb codepoint mapping (13→enter, 127→backspace, 27→esc, 9→tab) | `tests/terminal/event_kitty.zig` (add) | +30 | new RED tests for `\x1b[13u`, `\x1b[127;2:2u`, `\x1b[13;1u` |
| 0.4 | GREEN: map functional codepoints in `parseKittyKb` | `src/terminal/event.zig:476-534` | +10/-3 | 0.3 tests pass |
| 0.5 | RED: tests for cursor position from explicit layout state | `tests/tui/runtime_thread.zig` (add) | +25 | new RED tests for `draft_len = 0` cursor placement |
| 0.6 | GREEN: cursor from `drawKeyEntry` output + use in `emitFrame` | `src/modal.zig:355-432` + `src/tui.zig:388-444` | +18/-22 | 0.5 tests pass |
| 0.7 | GREEN: complete `enableRawMode` cfmakeraw (clear ICRNL/IXON/OPOST, set VMIN=1 VTIME=0) | `src/terminal/term.zig:177-199` | +6/-2 | new unit test verifying tcsetattr post-state |
| 0.8 | Full verification: `zig build verify`, `zig build run` smoke | n/a | n/a | all 408 + new tests pass |

## Acceptance criteria

- [ ] All 408 existing tests pass under `zig build verify`
- [ ] All new RED tests written before GREEN impl (strict TDD)
- [ ] Each impl commit (0.2, 0.4, 0.6, 0.7) includes the corresponding test
- [ ] No allocator.alloc/calloc in hot paths (Parser.next, parseKittyKb, drawKeyEntry, emitFrame) — Tiger Style §3
- [ ] `std.debug.assert` added for preconditions on every changed function
- [ ] `@intCast` sites guarded with range asserts
- [ ] No `else =>` lazy switches added
- [ ] Git author: `Kat404 <71116973+Kat404@users.noreply.github.com>` ONLY
- [ ] Commit messages follow Conventional Commits format
- [ ] All commits land on `feat/tui-ship-fast-phase0` (no force pushes)
- [ ] `zig build verify` exit 0
- [ ] Manual `zig build run` confirms 5 reported bugs no longer reproduce

## Verification evidence (to fill in after each WU)

| WU | Command | Pre-Module State | Expected Outcome | Actual |
|---|---|---|---|---|
| 0.0 | `git log -1` | n/a | AGENTS.md committed | TBD |
| 0.1 | `zig build test --summary all` | 408/408 PASS | 408/408 PASS (RED tests) | TBD |
| 0.2 | `zig build test --summary all` | 408/408 + 0.1 RED | 408+5/408+5 PASS | TBD |
| 0.3 | `zig build test --summary all` | 408+5/408+5 | 408+5/408+5 PASS (new RED) | TBD |
| 0.4 | `zig build test --summary all` | 408+5/408+5 | 408+8/408+8 PASS | TBD |
| 0.5 | `zig build test --summary all` | 408+8/408+8 | 408+8/408+8 PASS (new RED) | TBD |
| 0.6 | `zig build test --summary all` | 408+8/408+8 | 408+10/408+10 PASS | TBD |
| 0.7 | `zig build test --summary all` | 408+10/408+10 | 408+11/408+11 PASS | TBD |
| 0.8 | `zig build verify` | 408+11/408+11 | 0 exit, 408+11 PASS | TBD |

## Risks (declared)

1. **Test flakiness on CI**: parser tests using `feedBytes(slice)` are deterministic; tests using `next()` with real fd need careful state setup. Mitigation: prefer `parser.feedBytes(...) + parser.decode()` direct (agy recommendation).
2. **`tuiThreadLoop` not modified in this PR**: keep `threadlocal var current_parser` and `WindowMock` heap intact. Phase 2 PR will address.
3. **`AGENTS.md` commit scope**: only the file itself; do not retroactively apply Tiger Style to other code.
4. **PR1 merge conflicts with PR #39 (`feat/tui-input-rendering-fixes`)**: PR #39 may or may not be merged first. This branch is FROM `origin/main` so no conflict possible on this PR. PR #39 merge to main will require user decision.
5. **Manual smoke test may show latent bugs**: Phase 0 fixes root causes; some surface symptoms (e.g. paste in WezTerm) may reveal additional issues. These go to Phase 2.

## Files to modify (summary)

| File | Phase 0 changes | Notes |
|---|---|---|
| `AGENTS.md` | +163 (new) | Tiger Style mandate, repo root |
| `src/terminal/event.zig` | ~+15/-6 | WU 0.2 (drain) + 0.4 (kitty map) |
| `src/terminal/term.zig` | ~+6/-2 | WU 0.7 (cfmakeraw) |
| `src/modal.zig` | ~+10/-8 | WU 0.6 (cursor in drawKeyEntry output) |
| `src/tui.zig` | ~+8/-14 | WU 0.6 (emitFrame uses cursor from layout) |
| `tests/terminal/event_parser.zig` | +35 | WU 0.1 (RED) |
| `tests/terminal/event_kitty.zig` | +30 | WU 0.3 (RED) |
| `tests/tui/runtime_thread.zig` | +25 | WU 0.5 (RED) |
| `tests/terminal/term.zig` | +12 | WU 0.7 (RED for enableRawMode) |

**Total**: 9 files, ~+303/-30 LOC, 8 commits, 1 PR.

## Next step (after PR1 merged)

PR2 — Phase 2 architectural Tiger Style retrofit:
- `ScreenGrid` static replacement for `WindowMock`
- `[2]ScreenGrid` in Lifecycle + heap-allocated buffers
- Pure `renderToGrid` + `diffAndEmit` + `submitFrame` pipeline
- Event batching with `MAX_DRAIN_PER_TICK = 128`
- DEC 2026 bracketing
- UTF-8 emission
- Resize invalidation
- Dead code deletion
- `threadlocal var current_parser` elimination

Estimated: ~680 LOC, 4-5 days, 6 WUs, separate PR.