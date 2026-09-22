# TUI Ship-Fast Phase 0.5 — Opus-Validated Surgical Fixes

**Feature**: `tui-ship-fast-phase0.5`
**Branch**: `feat/tui-ship-fast-phase0` (continued from Phase 0)
**Base**: `feat/tui-ship-fast-phase0` @ `de9ce47` (Phase 0 complete)
**Store**: engram topic `odd/tui-ship-fast-phase0.5/tasks`
**Created**: 2026-09-21
**Mode**: strict TDD (RED before GREEN), Conventional Commits, global git identity `Kat404 <71116973+Kat404@users.noreply.github.com>` ONLY
**Validation**: Opus 4.6 (Thinking) — partial response before quota hit

## Objective

Fix 5 of 7 smoke-test residual failures with surgical, low-risk changes. Defer 2 failures (R2 kitty gate, R5 cancel-pipe) to Phase 2 architectural work.

## Opus-validated root causes

| # | Smoke-test failure | Real cause (Opus) | Fix complexity |
|---|---|---|---|
| **R1+R4** | Enter adds `*`; "t" delays; latency perception | `handleKeyInput` does NOT guard against `validating=true`. After submit, validating flag is set but new chars/Enter keep appending | ~3 LOC, surgical |
| **R3** | `\|` appears at 27 chars | Bounds check uses `cells.len` vs `cols` in spinner/progress render | ~1 LOC, surgical |
| **R6** | Esc no effect | By design (REQ-TIW-NEG-3 no-op). User expects clear-on-Esc | ~3 LOC, design decision |
| **R7** | Terminal corrupts on 2nd `zig build run` | `tuiThreadShutdown` missing `CSI ?25h` (show cursor) + `CSI 0m` (SGR reset) before `disableRawMode` | ~8 LOC, surgical |

## Out of scope (deferred to Phase 2)

- **R2** kitty_active parser gate (requires threading refactor)
- **R5** api_client cancel-pipe integration (requires bridge_sync_async refactor)

## Work units (4)

| WU | Title | Files | LOC | Tests |
|---|---|---|---|---|
| 1.5.1 | **RED+GREEN**: validating guard in handleKeyInput | `src/tui.zig:760-823` | +3/-0 | +25 (tests/tui/runtime_thread.zig) |
| 1.5.2 | **RED+GREEN**: spinner bounds check (cells.len → cols) | `src/modal.zig` (find spinner/progress render) | +1/-1 | +15 |
| 1.5.3 | **RED+GREEN**: Esc clears draft in key_entry | `src/tui.zig:788` | +3/-1 | +20 |
| 1.5.4 | **RED+GREEN**: shutdown sequence complete (CSI ?25h + CSI 0m) | `src/tui.zig:340-363` | +8/-0 | +20 |

**Total**: ~95 LOC + 80 LOC tests = ~175 LOC, 4 commits, 1 PR.

## Acceptance criteria

- [ ] All 418 existing tests pass under `zig build verify`
- [ ] 4 new RED tests written before GREEN impl (strict TDD)
- [ ] Each impl commit includes the corresponding test
- [ ] No allocator.alloc/calloc in hot paths (Tiger Style §3)
- [ ] `std.debug.assert` added for preconditions on every changed function
- [ ] Git author: `Kat404 <71116973+Kat404@users.noreply.github.com>` ONLY
- [ ] Commit messages follow Conventional Commits
- [ ] All commits land on `feat/tui-ship-fast-phase0` (no force pushes)
- [ ] `zig build verify` exit 0
- [ ] Manual `zig build run` smoke test: 5/7 reported symptoms no longer reproduce (R2 + R5 deferred)

## Risks (declared)

1. **R1+R4 validating guard**: may break existing tests that expect handleKeyInput to process chars during validating state. Mitigation: read existing tests first; only add guard for `.key_entry` (not `.unlock_prompt`).
2. **R3 spinner bounds check**: must locate exact spinner/progress render site. If drawKeyEntry doesn't render a spinner, fix is no-op. Mitigation: `rg "spinner" src/modal.zig` first.
3. **R6 Esc clear**: REQ-TIW-NEG-3 must be updated in `tests/tui/runtime_thread.zig` to reflect new behavior. Existing test may assert Esc returns false; update to assert draft cleared.
4. **R7 shutdown cleanup**: ordering matters — must show cursor BEFORE disableRawMode, reset SGR BEFORE exit alt-screen. Test must verify terminal state after shutdown (PTY smoke test env-gated).

## Verification evidence (to fill in)

| WU | Command | Expected |
|---|---|---|
| 1.5.1 | `zig build test --summary all` | 418+25/418+25 PASS |
| 1.5.2 | `zig build test --summary all` | 418+40/418+40 PASS |
| 1.5.3 | `zig build test --summary all` | 418+60/418+60 PASS |
| 1.5.4 | `zig build test --summary all` + PTY smoke | 418+80/418+80 PASS |

## Next step (after PR1.5 merged)

- Phase 2 (PR2): architectural Tiger Style retrofit targeting R2 + R5 holistically:
  - `ScreenGrid` static + double buffer
  - Pure `renderToGrid` + `diffAndEmit` + `submitFrame` pipeline
  - Event batching with `MAX_DRAIN_PER_TICK = 128`
  - DEC 2026 bracketing
  - UTF-8 emission via `std.unicode.utf8Encode`
  - Resize invalidation flag
  - Dead code deletion
  - `threadlocal var current_parser` elimination
  - `kitty_active` parser gate (resolves R2)
  - `api_client` cancel-pipe integration (resolves R5)
  - Total ~680 LOC, 4-5 days