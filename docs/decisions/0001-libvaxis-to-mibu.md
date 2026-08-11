# ADR 0001 — Replace libvaxis with mibu

## Status

Accepted (2026-08-10).

## Context

The original `tui` spec (`sdd/tui/spec#379` REQ-TUI-018) and design (`sdd/tui/design#380 §4`) pinned **libvaxis v0.5.1** as the TUI render surface. v0.5.1 was selected because it is the last release whose transitive dependencies (`zg 0.13.2`, `zigimg 3a667bdb`, `libxev f6a672a`) compile cleanly on a contemporary Zig toolchain.

Reality on Zig 0.16.0:

- v0.5.1's transitive deps target Zig 0.12 / 0.13 era `std.posix.*` and `std.atomic.*` APIs.
- `zig build` on Zig 0.16.0 fails to resolve `std.posix.sigaction`'s `mask` field type and `std.atomic.Value` ordering syntax across the dep tree.
- The transitive deps also pull in `libxev` whose v0.5.x API was reworked in v0.7+ and does not match the version vendored under v0.5.1.

First attempted mitigation: vendor libvaxis `v0.6.0-dev` (commit `7655966a`). This works on Zig 0.16.0 but:

- Vendors ~150K lines (libvaxis core + `uucode` 3K + `zigimg` 25K + `zg` ~120K). Bloat factor ~300x versus what zargeant actually uses.
- Breaks the "exact-tag pin" guarantee from REQ-TUI-018 — vendoring a pre-release is high risk; the next upstream tag may break API or transitive deps again.
- Forces the next reviewer to read the vended source before any TUI change.

Research memo `obs#399` (2026-08-10) investigated four alternatives to break out of this corner. Key data points from that memo:

- Zargeant uses **~0.5% of the vendored tree** (5 type-name comptime canaries in `src/tui.zig`; no method calls in PR 1, ~10-15 symbols planned for R-PR 3/4).
- Zig 0.16 stdlib exposes `std.posix.termios`, `tcgetattr`/`tcsetattr`, `winsize`, `sigaction`, and `T.IOCGWINSZ`. No `link_libc` is required.
- **mibu** (`github.com/xyaman/mibu`, MIT, commit `636a36a353614da2a537b060c33f17d608915eab`) is a near-perfect drop-in: zero deps, zero heap allocations, ~950 LoC total, Zig 0.16 tested, and its API surface covers all of zargeant's needs (raw mode, alt screen, kitty keyboard, in-band resize, synchronized update).
- A clean-room reimplementation would be ~1,160 LoC (term 80 + event 500 + render 300 + tests 200). Viable at 5-10 days effort.

## Decision

**Replace libvaxis v0.5.1 with mibu at exact commit `636a36a353614da2a537b060c33f17d608915eab`.**

The mibu pin is enforced at every R-PR start by `tests/tui/mibu_pin.zig` (REQ-TUI-020), which reads `.dependencies.mibu.hash` from `build.zig.zon` and asserts equality. CI fails loud if the hash drifts.

What this commits us to:

- **One new dep** (mibu, MIT, single-author but actively maintained as of 2026-08-10).
- **One commit** on `feat/tui-pr1` swaps the build dep (`dc647af build: drop libvaxis/uucode/zigimg; add mibu@636a36a dep`) and the second swaps the call sites (`d0ee10b feat(tui): swap libvaxis comptime canaries for mibu API`).
- **No new dependency on any mibu-fork or vendored tree**. The vendored libvaxis tree is deleted; it does not reappear.
- **TUI render lifecycle is mibu-driven** (REQ-TUI-002): `term.enableRawMode` → `RawTerm` token → `enterAlternateScreen` → `enableInBandResize` → `queryKittyKeyboard` → `pushKittyKeyboard(flags)` → per-frame `begin/endSynchronizedUpdate` → `popKittyKeyboard` → `exitAlternateScreen` → `raw_term.disableRawMode`. The verified mibu API surface (at commit `636a36a`) is documented in `sdd/tui-recovery/design#408 §2.2`.
- **SIGWINCH dual-path** (REQ-TUI-019): mibu's `events.queryModeWithTimeout(io, file, writer, 2048, ...)` for DEC 2048 in-band resize PLUS a `std.posix.sigaction(SIG.WINCH, ...)` fallback for legacy terminals. Both paths converge on a `std.atomic.Value(bool)` `redraw_pending` flag with `.seq_cst` ordering.

## Consequences

Positive:

- **~150K vendored lines removed** (`vendor/libvaxis/` 20,585 + `vendor/uucode/` ~3K + `vendor/zigimg/` ~25K + `vendor/zg/` ~120K). Build cache slimmer; reviewer cognitive load on TUI changes drops to ~50 LoC instead of 150K.
- **+50 lines of mibu wiring** across `src/tui.zig` + `build.zig`. The mibu surface is small and named (RawTerm, TermSize, Io.Writer, etc.), so reviewers can read it end-to-end.
- **Zig 0.16 stays the only toolchain**. No downgrade to 0.14/0.15; the other 4 slices (logger, sandbox, api-client, tls-handrolled) keep their 0.16-clean bases.
- **mibu's API matches the spec's intent**: per-frame synchronized update, in-band resize, kitty keyboard protocol — all primitives the spec called for in libvaxis, available in mibu's smaller surface.
- **Cycle completion is unblocked**: R-PR 1 through R-PR 5 of `tui-recovery` can ship without libvaxis blocking the chain.

Negative / risks:

- **mibu is single-author** (`xyaman`, last commit 22 days before this ADR per `obs#399`). If mibu dies, our options are: (a) vendor mibu (single `git mv` to `vendor/mibu/`, ~950 LoC), or (b) fall back to a clean-room implementation (~1,160 LoC, 5-10 days). The exact-commit pin keeps us at `636a36a` regardless of upstream activity.
- **API surface mismatch with the original prompt's examples**: the orchestrator prompt for tui-PR 1 contained 3 mibu call signatures that drift from the verified API at `636a36a` (e.g. `term.saveTermios` does not exist; `pushKittyKeyboard` takes `*std.Io.Writer`, not `Io.File.Handle`). The corrections are locked in `sdd/tui-recovery/design#408 §2.1` and propagated through `src/tui.zig` at R-PR 4.
- **PR #1 → PR #2 migration is awkward**: the original `tui` PR #1 (https://github.com/Kat404/Zargeant/pull/2) was force-pushed to swap libvaxis vendoring for mibu. Reviewers reading PR #1 will see 1 task instead of the originally planned 5. The remaining 4 tasks ship in the tui-recovery chain (R-PR 1..R-PR 4).

Follow-ups:

- A future `0002-clean-room.md` ADR will document the clean-room protocol for adding TUI primitives not in mibu (POSIX termios(3), ECMA-48, kitty keyboard spec, xterm ctlseqs only — never read libvaxis source). See `CONTRIBUTING.md` for the standing rule.
- The mibu pin is preserved at `636a36a353614da2a537b060c33f17d608915eab` for the full 5-PR `tui-recovery` cycle. Any pin update requires a new ADR.

## Alternatives Considered

### 1. Status quo — keep libvaxis `v0.6.0-dev` vendored

**Rejected.** Vendoring a pre-release is high risk: the next upstream tag may break the API or pull in a new transitive dep. Reviewers face ~150K lines of third-party code at every TUI change. The "exact-tag pin" guarantee from REQ-TUI-018 is broken — the vendored commit `7655966a` is not a tag.

### 2. Clean-room reimplementation (~1,160 LoC)

**Deferred.** Viable per `obs#399` at 5-10 days effort (term 80 + event 500 + render 300 + tests 200 LoC). MIT explicitly permits this; the implementation is against POSIX termios(3), ECMA-48, kitty keyboard spec, and xterm ctlseqs — settled practice with many independent implementations (HTTP, DNS, TLS, etc.). Worth considering for the long term if mibu maintenance stalls, but mibu's surface already covers our needs at 1-2 days integration cost. Documented as a future ADR if mibu dies.

### 3. Vendor a Zig 0.13 fork of libvaxis v0.5.x

**Rejected.** Depends on a third-party fork that may itself be abandoned. We would inherit the fork's maintenance burden (rebase on upstream, fix Zig 0.13 → 0.16 drift) without solving the underlying problem.

### 4. Downgrade Zig to 0.14 / 0.15

**Rejected.** Breaks the base of 4 other slices (`logger`, `sandbox`, `api-client`, `tls-handrolled`) which all use Zig 0.16-only `std.posix.*` and `std.atomic.*` APIs. A downgrade would force a coordinated rewrite of ~3,500 LoC across those slices for no benefit beyond the TUI dep pin.

## References

- `sdd/tui/spec#379` — original libvaxis v0.5.1 pin (REQ-TUI-018)
- `sdd/tui/design#380 §4` — original TUI design with libvaxis surface
- `sdd/tui/archive-report#402` — partial-cycle archive of the original tui PR; deviation 1 documents the libvaxis → mibu swap
- `sdd/tui/libvaxis-replacement-research#399` — research memo (options, legal review, LoC estimates)
- `sdd/tui-recovery/spec#407` — 22 REQs adapted for mibu (REQ-TUI-002, REQ-TUI-018 substitutions; REQ-TUI-019..022 added)
- `sdd/tui-recovery/design#408 §2.1–2.4` — verified mibu API surface + per-R-PR lifecycle detail
- `sdd/tui-recovery/tasks#410` — 32-task implementation plan across 5 R-PRs
- https://github.com/Kat404/Zargeant/pull/2 — original tui PR #1 (now mibu-backed)
- https://github.com/xyaman/mibu — mibu source repository
