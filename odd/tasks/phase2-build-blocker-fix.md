# Phase 2 Build Blocker Fix — Wiring `screen_grid` + `diff_emit` in `exe_mod`

**Feature**: `phase2-build-blocker-fix`
**Type**: Hotfix (1-line wiring in `build.zig`)
**Priority**: P0 — blocks merge of all 4 Phase 2 PRs
**Discovery**: User-requested pre-merge QA gauntlet on 2026-09-30; caught by `just build` failing before merge.
**Mode**: direct (1-line wiring, no new tests needed beyond existing 297+)

---

## Problem

Phase 2 slice 1 (PR #44) added two new modules to `build.zig`:

```zig
const screen_grid_mod = b.createModule(.{ ... });
const diff_emit_mod   = b.createModule(.{ ... });
```

and wired them into `lib_mod` only:

```zig
lib_mod.addImport("screen_grid", screen_grid_mod);   // line 509
lib_mod.addImport("diff_emit", diff_emit_mod);       // line 529
```

But `src/tui.zig` (compiled in both `lib_mod` and `exe_mod`) uses `@import("screen_grid")` and `@import("diff_emit")` for its `grids: [2]ScreenGrid` field. When the executable (`exe_mod`, root = `src/root.zig`) compiles `src/tui.zig`, the `@import("screen_grid")` call fails because `exe_mod` doesn't register `screen_grid` as an import.

### Why the bug wasn't caught by per-PR CI

Each PR's local CI ran `just ci-fast` (12 steps, all green). `just ci-fast` invokes the **7 individual `test-*` targets** which compile their own modules with explicit `addImport` wiring for the test step. They do **not** compile the full `just build` target that exercises `exe_mod`'s module graph. So the gap between `lib_mod` (wiring) and `exe_mod` (missing wiring) was invisible to per-PR CI.

The bug only surfaced when the user explicitly asked for `just build` as a pre-merge gate. This is exactly the failure mode that AGENTS.md §10 (Pre-Merge QA Gate Ordering) was written to prevent in the future.

### Error verbatim

```
src/tui.zig:152:23: error: no module named 'screen_grid' available within module 'root'
    grids: [2]@import("screen_grid").ScreenGrid = undefined,
                      ^~~~~~~~~~~~~

src/modal.zig:33:20: error: const screen_grid_mod = @import("screen_grid");
                                ^~~~~~~~~~~~~
```

Reproduces on all three build modes: Debug, ReleaseSafe, ReleaseFast.

---

## Fix

**File**: `build.zig`
**Lines**: after line 150 (`exe_mod.addImport("terminal", terminal_mod);`)
**Change**: 2 lines, mirroring the existing `lib_mod.addImport` calls at lines 509 and 529:

```zig
// Phase 2 fix: PR #44 (slice 1) added screen_grid_mod + diff_emit_mod and
// registered them in lib_mod (lines 509, 529) for test-* targets. They
// were missing in exe_mod, so the production binary couldn't compile
// because src/tui.zig uses @import("screen_grid") for its `grids`
// field. Mirror the wiring for the executable's root module.
exe_mod.addImport("screen_grid", screen_grid_mod);
exe_mod.addImport("diff_emit", diff_emit_mod);
```

**Risk**: minimal — symmetric mirror of `lib_mod` wiring. No new module introduced; no behavior change; no test updates needed (existing 297+ tests already pass per slice-level CI).

---

## Tasks

- [ ] T-1: Apply the 2-line fix in `build.zig` (mirror of lines 509/529 to after line 150).
- [ ] T-2: Run `just build` — confirm exit 0.
- [ ] T-3: Run `just build-safe` — confirm exit 0.
- [ ] T-4: Run `just build-fast` — confirm exit 0.
- [ ] T-5: Run `just check` — confirm exit 0 (static guards still clean).
- [ ] T-6: Run `just test-all` — confirm exit 0 (regression check on 297+ tests).
- [ ] T-7: Run `just verify` — confirm exit 0 (3-mode compile + checks).
- [ ] T-8: Run `just ci` — confirm exit 0 (Podman independent verification).
- [ ] T-9: Open PR "chore(build): wire screen_grid + diff_emit in exe_mod" with the fix.
- [ ] T-10: Update each of the 4 stacked PRs (PRs #44..#47) to include the fix commit
       (or document that PR #46's Path C hybrid commit already lives on the same branch and
       a new hotfix branch re-based on main + cherry-pick of the fix is cleaner).
- [ ] T-11: After merge sequence #44 → #45 → #46 → #47 → fix, the Phase 2 stack lands on main
       with the build gate green.

---

## Out of scope (NOT addressed by this fix)

1. **`@ptrCast` byte-identity assumption** (Slice 2/3 manual review concern): ScreenGrid.Cell ↔ modal.Cell via `@ptrCast` assumes byte-identical struct layout. No `comptime` assertion enforces it. Track as a follow-up PR.
2. **`first_frame` legacy field** (Slice 3 Path C hybrid): unused by `submitFrame`, kept for T-TIRFIX-003a test compat. Cleanup when T-TIRFIX-003a is updated to use `force_full_redraw`.
3. **`Style` struct incompleteness** (Slice 1): only bold is emitted; underline/reverse deferred.
4. **`Parser.kitty_active` concurrency**: plain `bool`, not atomic; currently safe because TUI-thread-only access.
5. **Stale `hotfix/tui-input-rendering-last-x-tracking` branch**: 10 commits with 2 no-op duplicates. User can delete with `git branch -D` when convenient.

---

## Acceptance criteria

- [ ] `just build` exit 0 (Debug)
- [ ] `just build-safe` exit 0 (ReleaseSafe)
- [ ] `just build-fast` exit 0 (ReleaseFast)
- [ ] `just check` exit 0
- [ ] `just test-all` exit 0
- [ ] `just verify` exit 0
- [ ] `just ci` exit 0
- [ ] No new tests required (existing 297+ tests already cover the affected code)
- [ ] `git diff build.zig` shows exactly 2 lines added (no other changes)

---

## References

- AGENTS.md §10 (Pre-Merge QA Gate Ordering) — the rule that caught this bug
- Phase 2 feature doc: `odd/tasks/tui-ship-fast-phase2.md` §"PR structure"
- `build.zig` lines 499–529 (the original `lib_mod` wiring)
- Session closure obs#1788 (Phase 2 PR stack shipped without this fix)
- Session closure obs#1789 (Phase 2 stack complete summary)
