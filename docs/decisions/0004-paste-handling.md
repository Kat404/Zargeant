# ADR 0004 — Paste handling via DEC 2004 bracketed paste

## Status

Accepted (2026-09-10).

## Context

Pasting multi-byte content into the TUI collapsed to 1 char because the
Parser was recreated per `nextWithTimeout` call
(`src/terminal/event.zig:666` in pre-change code). The ring buffer was
destroyed with the stack-local parser when `nextWithTimeout` returned;
bytes past the first decoded event were lost. Two user-reported symptoms
trace to this root cause:

- **Symptom 4** (pasted API key shows only 1 `*`): the modal received 1
  per-char `.key` event per `nextWithTimeout` call. After the first
  event the parser (a fresh stack-local) had no bytes left; the
  remaining paste content evaporated.
- **Symptom 5** (valid keys rejected for length < 24): a 64-char paste
  delivered only the first 1-2 chars to `validateFormat`, which rejects
  any string shorter than 24 chars (`src/api_auth.zig:115-122`).

A separate parser-persistence test would have caught both symptoms; the
bug remained undetected until manual user testing on 2026-09-10
(explore obs#1555).

User-confirmed scope decision (proposal obs#1556 §Intent):
**ship-then-investigate** — fix the parser bug + add DEC 2004 bracketed
paste handling in this change. Symptoms 1-3 (no alt-screen, 4s delay,
stale `*`) are NOT in scope; if they persist post-merge, a separate
`tui-keyentry-env-investigation` change is dispatched.

## Decision

1. **Parser lifetime**: bound to `tui.Lifecycle` (TUI thread
   value-constructed struct, see design D1). Reachable via the
   module-level thread-local `current_parser: ?*Parser` in
   `src/terminal/event.zig`. Production wires it via
   `terminal.event.setCurrentParser(&lc.parser)` inside
   `tuiThreadInit` after `enableRawMode` succeeds; clears it inside
   `tuiThreadShutdown` after `disableRawMode`. The 4 KiB ring buffer
   becomes part of the stack-allocated Lifecycle (no new
   `allocator.create` call).
2. **Bracketed paste via DEC 2004** (`CSI ?2004h` enable,
   `CSI ?2004l` disable). The enable/disable pair is implemented as
   free functions in `src/terminal/dpm.zig` (matches the existing
   alt-screen + in-band-resize pattern), re-exported via
   `src/terminal/term.zig`, and called from
   `src/tui.zig:tuiThreadInit` (after `enterAltScreenAndResize`,
   before `pushKittyKb`) and `tuiThreadShutdown` (after `popKittyKb`,
   before `exitAltScreenAndResize`).
3. **Parser detects `CSI 200 ~` (start) and `CSI 201 ~` (end)** inside
   the existing `dispatchCsi` `final == '~'` branch. Start sets a new
   `paste_active: bool` field on `Parser`; between start and end,
   `decode()` short-circuits to emit one `.key: Key` event per UTF-8
   codepoint (or per ASCII byte). End emits `.paste_end` (void) and
   clears the flag. Embedded ESC bytes inside paste payload emit
   `.invalid` (0x1B is not a valid Unicode scalar per design D6).
4. **Spec deviation**: the test seam is named `setCurrentParser`
   (holds `?*Parser`), not `setCurrentLifecycle` (holds `?*Lifecycle`),
   to avoid circular dep between `terminal.event` and
   `tui.Lifecycle`. The semantic for tests is identical: inject
   parser, exercise `nextWithTimeout`, clear it. Documented here as a
   deviation from spec REQ-NEW-008.
5. **No new thread, no new channel, no new Event variant.** The
   existing `Event` union already carries `.paste_start: void` and
   `.paste_end: void` (terminal-control-lib PR 3 at
   `src/terminal/event.zig:140-141`); the existing 8-variant union is
   preserved. `src/tui.zig:613` already bare-matches these variants;
   zero consumer changes required.
6. **No regression on async `validateViaApi` offload** (bugfixes-2
   obs#1456). Paste events flow through the existing `handleKeyInput`
   per-char append path; the worker thread + `Event.ValidateApiReply`
   channel contract is untouched.

## Consequences

- **Pasting a 64-char valid key renders 64 `*` immediately** and the
  full string reaches `validateFormat` (≥ 24 chars → pass). Verified
  by `tests/api_auth.zig` regression test (WU-5).
- **`validateFormat` receives the full 64 chars** → valid key passes.
  Per-char events flow through the existing `handleKeyInput` path
  (`src/tui.zig:600-606`) which appends each `.char` to `ke.draft`.
- **DEC 2004 cleanly disabled on exit** (`CSI ?2004l` before
  alt-screen exit).
- **Terminals that don't support DEC 2004 fall back to per-key burst**:
  no `ESC[200~` / `ESC[201~` brackets are emitted by the terminal; the
  modal sees individual `.key` events as pre-change (no regression).
  Per-char redraw loop handles star rendering correctly.
- **One module-level mutable global added** (`current_parser`
  thread-local). Mitigated by the explicit `setCurrentParser` test
  seam + symmetric set/clear in `tuiThreadInit`/`tuiThreadShutdown`.
- **Lifecycle struct grows by ~4 KiB** (the `Parser` ring buffer).
  Lifecycle is value-constructed on the TUI thread stack (8 MiB
  default); 4 KiB is negligible.
- **Modal draft accumulator NOT introduced** (WU-4 was dropped per
  user decision). The existing per-char redraw loop in the modal
  renders one `*` per char, naturally handling paste payload
  delivered as per-char events.

## Alternatives considered

- **Parser as explicit 5th arg** (A2): rejected — bigger diff at every
  call site (`src/tui.zig:569` + every test that drives
  `nextWithTimeout`). One module-level mutable global with a test
  seam is the lazier path and the spec already accepts
  `setCurrentLifecycle` (REQ-NEW-008).
- **Custom paste protocol** (PASTE_BEGIN/PASTE_END sentinels):
  rejected — requires app-level cooperation from every terminal
  emulator, blocking paste from `xterm`, `kitty`, `alacritty`, and
  `wezterm` simultaneously. DEC 2004 is the standard.
- **DEC 2004 emit inside `enableRawMode`** (`term.zig:177`):
  rejected — `enableRawMode` has signature `(handle, backend)` with
  no writer parameter. Bundling DEC 2004 there would require either
  adding a writer parameter (signature break, REQ-NEW-009 violation)
  or performing a side-channel write that bypasses the buffered
  stdout writer. The dpm.zig + re-export pattern matches alt-screen
  + in-band-resize exactly.
- **Single `.paste` Event variant**: rejected — loses streaming info;
  modal would block on the full payload before redrawing, dropping
  the per-char rendering win. Per-char events between
  `.paste_start` / `.paste_end` markers give the modal the same UX
  as a fast typist.
- **Separate `paste_buffer: [4096]u8` field on Parser**: rejected as
  YAGNI — the existing `ring_buf` already holds the paste payload;
  adding a second buffer doubles the parser's memory footprint for
  zero semantic gain. Per design D5 + clean-room observation: reuse
  the existing buffer.
- **Modal accumulator (WU-4)**: dropped per user decision
  (proposal obs#1556 R-1 carry-in). The existing per-char redraw
  loop handles paste payload naturally; the `.paste_start` /
  `.paste_end` markers are bare-matched (void, no payload).

## References

- explore obs#1555 — root-cause analysis + 5 user-reported symptoms
- proposal obs#1556 — locked scope (ship-then-investigate + WU-4 dropped)
- spec obs#1557 — REQ-NEW-001..REQ-NEW-009 (9 requirements, 20 scenarios)
- design obs#1558 — D1..D6 decisions (locked before apply)
- tasks obs#1559 — 6 WU decomposition, WU-4 dropped
- bugfixes-2 obs#1454 + obs#1456 — async validateViaApi offload
  contract (preserved unchanged)
- terminal-control-lib cycle obs#1500-1522 — pre-existing
  `Event` union with `.paste_start` / `.paste_end` void variants
  (terminal-control-lib PR 3 at `src/terminal/event.zig:140-141`)

## Spec deviation log

| Deviation | Spec REQ | Design / Code | Rationale |
|-----------|----------|---------------|-----------|
| `setCurrentParser` holds `?*Parser` not `?*Lifecycle` | REQ-NEW-008 | Design D3 + `src/terminal/event.zig` thread-local | Avoid circular dep between `terminal.event` and `tui.Lifecycle`. Semantic for tests is identical. |
| DEC 2004 emits live in `dpm.zig` not `enableRawMode` | REQ-NEW-002 implicit | Design D4 + `src/terminal/dpm.zig` | `enableRawMode` has no writer param; bundling would break REQ-NEW-009 signature stability. |
| `current_parser` as the only module-level mutable | REQ-NEW-008 | Design D3 + `src/terminal/event.zig` thread-local | Symmetric set/clear in `tuiThreadInit`/`tuiThreadShutdown`; the test seam is the single mutation point. |