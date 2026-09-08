# ADR 0002 — Clean-room protocol citations for the in-tree terminal control library

## Status

Accepted (2026-09-08). Implements the follow-up recorded in [ADR 0001 §Follow-ups](0001-libvaxis-to-mibu.md) line 62.

## Context

[ADR 0001](0001-libvaxis-to-mibu.md) pinned `mibu@636a36a` as the TUI surface and recorded a follow-up (line 62) to write a "future `0002-clean-room.md` ADR" documenting the clean-room protocol for adding TUI primitives not in mibu. The `tui-input-flow-bugfixes-2` chain (closed 2026-09-07, HEAD `3156ff7`) revealed the project's TUI surface is approaching mibu's full API surface, and mibu is single-author (`xyaman`). ADR 0001 §"Alternatives Considered" #2 (line 71-73) flagged a clean-room reimplementation as a viable long-term fallback.

This ADR establishes the protocol citations and review discipline for replacing mibu with an in-tree `src/terminal/` module. Every primitive in that module derives from one of the four cited specs. No mibu or libvaxis source is consulted. POSIX `termios(3)`, ECMA-48, the kitty keyboard protocol, and xterm ctlseqs are the sole reference sources, as required by `CONTRIBUTING.md:41` and ADR 0001 §"Negative".

The clean-room protocol is binding for the entire six-PR replacement chain (`terminal-control-lib-from-scratch`). Each subsequent PR cites the spec section it implements and includes at least one RED test before its GREEN implementation.

## Decision

### 1. Protocol citation table

| Primitive | File | Spec citation |
|-----------|------|---------------|
| `terminal.term.enableRawMode` | `src/terminal/term.zig` | POSIX `termios(3)` §Canonical mode, §Non-canonical mode, §Raw mode (`c_lflag &= ~(ICANON \| ECHO \| ISIG \| IEXTEN)`) |
| `terminal.term.disableRawMode` | `src/terminal/term.zig` | POSIX `termios(3)` §TCSANOW (`std.posix.TCSA.NOW`) — restore saved termios |
| `terminal.term.getSize` | `src/terminal/term.zig` | POSIX `ioctl(2)` + Linux `T.IOCGWINSZ` (`std.posix.linux.T.IOCGWINSZ`); `std.posix.winsize` is the carrier struct (`row`/`col`) |
| `terminal.cursor.goTo` | `src/terminal/cursor.zig` | ECMA-48 §CSI CUP `CSI <row>;<col> H` (1-indexed coords) |
| `terminal.style.{reset,bold,underline,reverse}` | `src/terminal/style.zig` | ECMA-48 §SGR `CSI <n> m` (reset=0, bold=1, underline=4, reverse=7) |
| `terminal.dpm.{enterAlternateScreen,exitAlternateScreen}` | `src/terminal/dpm.zig` | xterm ctlseqs §Private Modes 1049 (`CSI ? 1049 h/l`) |
| `terminal.dpm.{enableInBandResize,disableInBandResize}` | `src/terminal/dpm.zig` | xterm ctlseqs §Private Modes 2048 (`CSI ? 2048 h/l`) |
| `terminal.dpm.{beginSynchronizedUpdate,endSynchronizedUpdate}` | `src/terminal/dpm.zig` | xterm ctlseqs §Synchronized Update 2026 (`CSI ? 2026 h/l`) |
| `terminal.dpm.queryModeWithTimeout` (DECRQM emit) | `src/terminal/dpm.zig` | xterm ctlseqs §DECRQM `CSI ? <mode> $ p` request |
| `terminal.dpm.parseDecRqmReply` | `src/terminal/dpm.zig` | xterm ctlseqs §DECRPM `CSI ? <mode> ; <state> $ y` reply |
| `terminal.kitty.pushKittyKeyboard` | `src/terminal/kitty.zig` | kitty keyboard protocol §push `CSI > <flags> u` (bit 1 disambiguate, bit 2 report_events, bit 4 alternate_keys) |
| `terminal.kitty.popKittyKeyboard` | `src/terminal/kitty.zig` | kitty keyboard protocol §pop `CSI < u` |
| `terminal.kitty.supportsKittyKeyboardWithTimeout` | `src/terminal/kitty.zig` | kitty keyboard protocol §query `CSI ? u` + ack |
| `terminal.event.nextWithTimeout` | `src/terminal/event.zig` | POSIX `poll(2)` + `read(2)` + xterm ctlseqs §Keyboard input + kitty keyboard protocol §Events `CSI <code>[:<mods>][:event] u` |
| `terminal.event.pollReadable` | `src/terminal/event.zig` | POSIX `poll(2)` thin wrapper |
| In-band resize parsing (`CSI 8 ; <rows> ; <cols> t` → `.resize`) | `src/terminal/event.zig` | xterm ctlseqs §In-band resize reply (UNCONDITIONAL parsing per spec REQ-TCL-004 C11 — emitted by tmux and other multiplexers regardless of DEC 2048 negotiation) |
| `terminal.event.Mods.ctrl` default | `src/terminal/event.zig` | Anonymous-struct-literal coercion (tests/tui/runtime_thread.zig:2117, :2167) |

### 2. Per-primitive test coverage

Each primitive MUST have at least one RED test before GREEN implementation (spec REQ-TCL-012 / REQ-TCL-013). Per-PR test matrix in [`sdd/terminal-control-lib-from-scratch/tasks`](../../engram-topics) obs#1514 §6.

| Primitive | RED test |
|-----------|----------|
| `enableRawMode` | termios round-trip via `MockBackend`; saves original, restores on disable |
| `getSize` | `MockBackend.ioctl_gwinsz` returns canned `winsize{row=40, col=120}` → `TermSize{width=120, height=40}` |
| `enterAlternateScreen` | fixed-writer byte assertion `ESC[?1049h` |
| `queryModeWithTimeout` | EINTR, poll timeout, malformed reply, wrong-mode-number all return `.supported() == false` |
| `nextWithTimeout` | C11 unconditional `CSI 8;40;120 t` → `.resize` (void); C9 EINTR + pending → `.resize`; C9 EINTR + no-pending → `.none` |

### 3. Public API discipline

- `terminal.term` re-exports `enterAlternateScreen`, `exitAlternateScreen`, `enableInBandResize`, `disableInBandResize`, `beginSynchronizedUpdate`, `endSynchronizedUpdate` from `dpm.zig` (peer-review C31). The renamed smoke canary at `tests/tui/terminal_smoke.zig:64-91` (formerly `tests/tui/mibu_smoke.zig`) iterates the `terminal.term` namespace and asserts those six names plus `enableRawMode` and `getSize`.
- `RawTerm.disableRawMode` is a METHOD on `RawTerm` (peer-review C29). `src/tui.zig:300` calls it via method syntax `rt.disableRawMode()`.
- `KittyFlags` exposes at least one declaration (`pub fn bits(self) u8`) so the renamed smoke canary's `decls.len > 0` assertion passes (peer-review C32).
- `enableRawMode(handle, backend: Backend) !RawTerm` is the ONLY signature (peer-review C27). Zig has no function overloading. PR 6 updates `src/tui.zig:245` from `mibu.term.enableRawMode(handle)` to `terminal.term.enableRawMode(handle, .posix)`.
- `nextWithTimeout(...) anyerror!Event` returns an error union (peer-review C28). `src/tui.zig:540` uses `catch continue`, which requires `Event` to be wrapped in `anyerror!Event`.

### 4. Review discipline

Every PR in the chain MUST:

1. Cite the spec section it implements in a comment header above each new public function or struct.
2. Land a RED test BEFORE its GREEN implementation (TDD cycle evidence in apply-progress).
3. Append each new `src/terminal/*.zig` file to the three static-guard target arrays (`src/runtime.zig:716-748`, `src/runtime.zig:784-814`, `src/api_auth.zig:696-734`) in the SAME commit that creates the file (proposal C17, C20). File MUST exist on disk when the array is appended.
4. NOT modify `src/tui.zig` mibu imports, `src/channels.zig:69`, `build.zig.zon`, or `build.zig` mibu wiring (proposal N11-N13). Those land atomically in PR 6.
5. NOT use `getenv`, `readFile`, `libsecret`, `Secret Service`, or any terminfo lookup in `src/terminal/*.zig` (proposal N14 / C18). The `src/api_auth.zig:696-734` grep-fail guard rejects such patterns.

### 5. ADR 0001 follow-ups closure

ADR 0001 §"Follow-ups" line 62 records:

> A future `0002-clean-room.md` ADR will document the clean-room protocol for adding TUI primitives not in mibu (POSIX termios(3), ECMA-48, kitty keyboard spec, xterm ctlseqs only — never read libvaxis source). See `CONTRIBUTING.md` for the standing rule.

This ADR fulfills that commitment. The standing rule in `CONTRIBUTING.md:41` is unchanged (no libvaxis source). The new rule added here is **no mibu source either**, applied across all six PRs of the `terminal-control-lib-from-scratch` change.

The mibu pin at `636a36a353614da2a537b060c33f17d608915eab` (ADR 0001 line 32) remains in force until PR 6 atomically removes the `.mibu` dep block. `tests/tui/mibu_pin.zig` (REQ-TUI-020) and `tests/tui/mibu_smoke.zig` continue to enforce the pin until PR 6 deletes the former and renames the latter.

### 6. Negative

No source code from `mibu` (github.com/xyaman/mibu, MIT) or `libvaxis` is consulted during implementation. The author has not opened, read, grepped, vendored, or referenced either repository during the authoring of this ADR or the subsequent six PRs. All primitive implementations derive from POSIX `termios(3)`, ECMA-48, the kitty keyboard protocol spec, and xterm ctlseqs as cited above. Reference test vectors from any source are public-spec test cases; they are not derived from mibu or libvaxis source code.

## Consequences

Positive:

- **Reviewable provenance.** Every `src/terminal/*.zig` public symbol points to a spec section, so reviewers can verify correctness without reading project code.
- **Single-author indirection eliminated.** mibu's single-author risk (ADR 0001 §"Negative") is retired at PR 6.
- **Capability lockdown.** The six-PR additive/atomic-swap topology (proposal §6.1) keeps `src/tui.zig` mibu imports, `src/channels.zig:69`, `build.zig.zon`, and `build.zig` mibu wiring untouched through PRs 1-5. The atomic swap in PR 6 is reversible as a single transaction.
- **Test discipline.** Each primitive's RED test is recorded in the apply-progress artifact. CI runs `zig build test-terminal --summary all && zig build test --summary all` at every PR (proposal §14 C19).

Negative / risks:

- **Clean-room latency.** Working only from cited specs is slower than reading reference implementations. This is the price of license cleanliness and is explicitly accepted per ADR 0001 §"Negative".
- **Stale citations.** The four cited specs are stable but occasionally updated (xterm ctlseqs has revisions). Citation comments should reference the latest stable version as of 2026-09-08.

## Alternatives Considered

### 1. Vendor mibu at `vendor/mibu/`

Rejected. ADR 0001 §"Negative" lists vendoring as a fallback only if upstream dies. Vendoring now would defeat the clean-room protocol and would not retire the single-author risk.

### 2. Read mibu source for spec-level shape only

Rejected. The clean-room rule is binary at the project level. Even spec-level shape from a MIT-licensed dep creates ambiguity about the implementation's origin. Reading POSIX / ECMA-48 / kitty / xterm is sufficient.

### 3. Skip the ADR

Rejected. ADR 0001 line 62 commits to writing this ADR. Skipping it would leave the follow-up dangling and would propagate ambiguity into PRs 2-6.

## References

- [ADR 0001 — Replace libvaxis with mibu](0001-libvaxis-to-mibu.md)
- `CONTRIBUTING.md:37-51` (clean-room rule), `:81-94` (grep-fail target list)
- POSIX `termios(3)`, `ioctl(2)` (per Linux man-pages 5.x)
- ECMA-48 (5th edition, 1991) §CSI parameters, §SGR
- xterm ctlseqs (current as of 2026-09-08) §Private Modes (1049, 2026, 2048), §DECRQM/DECRPM, §In-band resize
- kitty keyboard protocol (current as of 2026-09-08) §push/pop, §query, §Events
- Zig 0.16 `std.posix.termios`, `std.posix.TCSA`, `std.posix.winsize`, `std.os.linux.T.IOCGWINSZ`
- Engram topic `sdd/terminal-control-lib-from-scratch` for proposal/spec/design/tasks
