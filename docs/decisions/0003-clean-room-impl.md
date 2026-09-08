# ADR 0003 — Clean-room reimplementation of terminal control layer

## Status

Implemented (2026-09-08). Supersedes the mibu-dependency portion of
ADR 0001 §"Decision" / §"Negative".

## Context

ADR 0001 (2026-08-10) accepted `mibu@636a36a353614da2a537b060c33f17d608915eab`
as a near-perfect drop-in for libvaxis. ADR 0001 §"Negative" explicitly
noted:

> if mibu dies, our options are (a) vendor mibu (~950 LoC) or (b) fall
> back to a clean-room implementation (~1,160 LoC, 5-10 days). The
> exact-commit pin keeps us at `636a36a` regardless of upstream activity.

ADR 0002 (2026-09-08) established the clean-room protocol — POSIX
`termios(3)`, ECMA-48, the kitty keyboard protocol spec, and xterm
ctlseqs as the sole reference sources, with `libvaxis` and `mibu`
source code explicitly out of scope.

This change implements ADR 0001 §"Negative" option (b): the clean-room
reimplementation, delivered across six chained PRs (5 additive + 1
atomic swap). No mibu or libvaxis source code was consulted per
`CONTRIBUTING.md:41` and ADR 0002 §"Negative".

## Decision

Replace `mibu@636a36a` entirely with an in-tree `src/terminal/` module.
Drop the `.mibu` dep block from `build.zig.zon`. Drop `mibu_dep` +
`mibu_mod` + all `addImport("mibu", mibu_mod)` lines from `build.zig`.
Delete `tests/tui/mibu_pin.zig` (REQ-TUI-020 has no object). Rename
`tests/tui/mibu_smoke.zig` → `tests/tui/terminal_smoke.zig`. Rename
`tests/termios_sim.zig` → `tests/tui/cancel_path.zig` (per Q4; the
file was always a cancel-path static-guard, not a termios simulator).
Drop the `test-tui-mibu-pin` build step (now correctly errors as
"no step named 'test-tui-mibu-pin'").

The atomic swap in `src/tui.zig` + `src/channels.zig` (WU 6.3) covers
25+ 1:1 symbol swaps plus four non-1:1 call-site adjustments:

- **C22** (4-arg `nextWithTimeout`): caller passes
  `&lifecycle.redraw_pending` at `src/tui.zig:540`. The parser does NOT
  declare its own module-level atomic.
- **C27** (2-arg `enableRawMode(handle, backend: Backend)`): caller
  passes `terminal.term.PosixBackend.backend()` at `src/tui.zig:245`.
  Zig has no function overloading.
- **`terminal.style.reset` 2-arg `(writer, _: bool)`**: caller passes
  `false` for API uniformity with `bold`/`underline`/`reverse`. The
  bool is ignored — SGR 0 always resets.
- **`terminal.cursor.goTo(x, y)` 0-indexed input**: caller drops the
  mibu-side `+1` at `src/tui.zig:357,365`. The in-tree function adds
  `+1` internally (emits `CSI <y+1>;<x+1>H`).

## Dependency surface change

- `.mibu` block in `build.zig.zon:6-10` removed.
- `mibu_dep` + `mibu_mod` removed from `build.zig:11-21`.
- All `addImport("mibu", mibu_mod)` lines removed at `build.zig:29, 45,
  103, 111, 130, 169` (the in-tree terminal module now wires under
  the name `terminal`).
- `tui_mod` standalone module wrapper removed from `build.zig:91-95`
  (it served only to wire `mibu_mod`; with mibu gone, `lib_mod`'s
  import graph is sufficient).
- `tests/tui/mibu_pin.zig` (65 lines; REQ-TUI-020 pin enforcement)
  deleted.
- `tests/tui/mibu_smoke.zig` → `tests/tui/terminal_smoke.zig` (renamed;
  106 lines; namespace retargeted to `terminal.*`). Smoke canary now
  asserts the 6 type decls (`terminal.term.RawTerm`,
  `terminal.term.TermSize`, `terminal.kitty.KittyFlags`,
  `terminal.event.Event`, `terminal.event.Key`, plus the field-shape
  checks) and 8 function decls (`enableRawMode`, `getSize`,
  `enterAlternateScreen`, `exitAlternateScreen`,
  `beginSynchronizedUpdate`, `endSynchronizedUpdate`, plus
  `event.nextWithTimeout` and `event.pollReadable` per C23).
- `tests/termios_sim.zig` → `tests/tui/cancel_path.zig` (renamed per
  Q4; matches actual contents).
- `test-tui-mibu-pin` build step removed (build.zig:139-152 pre-PR-6).
- `CONTRIBUTING.md:14-35, 51` updated to reflect in-tree
  `src/terminal/` module (no third-party TUI dep).

## Integration checklist (all verified by PR 6 apply-progress)

- [x] `zig build test --summary all` exits 0 on Debug + ReleaseSafe +
      ReleaseFast at PR 6 HEAD.
- [x] `zig build test-tui-mibu-pin` errors as "no step named
      'test-tui-mibu-pin'" (proves deletion took effect).
- [x] T-SG-9 allowed imports list at
      `tests/tui/runtime_thread.zig:1634-1651` contains
      `@import("terminal")` and does NOT contain `@import("mibu")`.
- [x] T-SG-11 literal greps at `tests/tui/runtime_thread.zig:2207-2224`
      target in-tree helper names (`terminal.style.reset(writer, false);`,
      `terminal.cursor.goTo`).
- [x] CAP-09 literal grep at `tests/tui/cancel_path.zig:69` finds
      `if (k.code == .char and k.mods.ctrl)` in `src/tui.zig:552`
      (field shape preserved across the swap).
- [x] All 6 static guards (TG, SG, AA, T-SG-9, T-SG-11, CAP-09) green
      at PR 6 HEAD.
- [x] `src/channels.zig:69` `KeyPress: terminal.event.Key` payload
      type passes `src/tui.zig:575` anonymous-struct-literal coercion
      without churn (field names `code` + `mods.ctrl` preserved).
- [x] No commit authored by AI co-attribution (`CONTRIBUTING.md:8`).
- [x] `tests/tui/terminal_smoke.zig` (the renamed canary) asserts
      `pollReadable` exists on `terminal.event` namespace (C23
      lock-in).

## Consequences

- Zero behavior change to TUI output (byte-for-byte preserved by
  `tests/tui/runtime_thread.zig` integration tests + CAP-09 literal
  grep in `tests/tui/cancel_path.zig`).
- Zero external dependencies on third-party TUI libraries. Project
  owns the entire TUI surface.
- Future TUI primitives are added to `src/terminal/*.zig` directly
  (no PR to upstream).
- The `mibu` single-author risk (ADR 0001 §"Negative") is retired.
- ADR 0001 §"Decision" supersession: "TUI render lifecycle is
  mibu-driven" → "TUI render lifecycle is terminal-driven" (the
  in-tree module is the runtime owner; ADR 0001 §"Decision" otherwise
  remains authoritative for the libvaxis → mibu history).
- The "fall back to clean-room" contingency in ADR 0001 §"Negative" is
  fulfilled; ADR 0001's exact-commit pin is no longer authoritative
  (the mibu dep is removed from `build.zig.zon`).

## References

- ADR 0001 (the predecessor; the libvaxis → mibu decision).
- ADR 0002 (the clean-room protocol citations, locked per primitive).
- `CONTRIBUTING.md:37-51` (clean-room policy).
- `obs#1504` (explore), `obs#1506` (proposal v3), `obs#1510` (spec v2),
  `obs#1512` (design v2), `obs#1514` (tasks), `obs#1517` (apply-progress).
- Peer reviews: `obs#1505`, `#1507`, `#1508`, `#1509`, `#1511`,
  `#1513`, `#1515`.
- `mibu` upstream (github.com/xyaman/mibu, MIT, commit
  `636a36a353614da2a537b060c33f17d608915eab`) — used at PR 6 PRE-state
  only; the source was never inspected per `CONTRIBUTING.md:41` and
  ADR 0002 §"Negative".