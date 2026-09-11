# Contributing to zargeant

Thanks for your interest in zargeant. This document covers the contribution workflow, the rules around our TUI dependency (in-tree `src/terminal/`), and the clean-room policy for TUI primitives.

## Ground rules

- **Strict TDD.** Tests are written **before** implementation. Each work unit ships a focused test (or self-test) plus its implementation in the same commit. The full `zig build test` gate must exit 0 on **Debug**, **ReleaseSafe**, and **ReleaseFast** before any PR opens.
- **No AI co-attribution.** Commits are authored by the human; AI assistance is not co-attributed.
- **English for technical artifacts.** Code, comments, commit messages, specs, and PR bodies are in English. Use a neutral register; this project does not adopt a regional voice in technical work.
- **Conventional Commits.** Subject line ≤ 50 chars, prefixed with `feat(scope):`, `fix(scope):`, `chore:`, `docs:`, `test(scope):`, `refactor(scope):`. The body explains *why*, not *what*.
- **Work-unit commits.** One commit = one deliverable unit. Tests travel with the code they verify. Docs travel with the change they explain. See `~/.config/opencode/skills/work-unit-commits/SKILL.md` (or the in-repo equivalent).
- **Review budget.** Each PR targets ≤ 400 changed lines. Use chained PRs above 400; the `chained-pr` skill walks the topology.

## TUI dependency (in-tree `src/terminal/`)

zargeant's TUI render surface is **the in-tree `src/terminal/` module**, replaced from the previous `mibu@636a36a` dependency in PR 6 of the `terminal-control-lib-from-scratch` change. See `docs/decisions/0003-clean-room-impl.md` for the full rationale and `docs/decisions/0002-clean-room.md` for the per-primitive protocol citations.

- Source: `src/terminal/` (mod.zig, term.zig, cursor.zig, style.zig, dpm.zig, kitty.zig, event.zig)
- License: The Unlicense (project license)
- Zero transitive deps. Zero external dependencies. In-tree only.

The smoke canary at `tests/tui/terminal_smoke.zig` (renamed from `tests/tui/mibu_smoke.zig` per Q4) asserts the public surface (`terminal.term.RawTerm`, `terminal.term.TermSize`, `terminal.kitty.KittyFlags`, `terminal.event.Event`, `terminal.event.Key`, `terminal.event.nextWithTimeout`, `terminal.event.pollReadable`, plus the 6 DPM re-exports on `terminal.term` per design C31). CI fails if any symbol drifts.

**Do not add a third-party TUI dep.** Adding any external TUI library requires:

1. A new ADR entry in `docs/decisions/` documenting why the dep is needed, the alternatives considered (including in-tree + clean-room), the license, and the upgrade policy.
2. The dep pinned at an exact commit (no caret ranges).
3. PR review approval.

The previous `mibu` fallback plan (ADR 0001 §"Negative": vendor to `vendor/mibu/`, or fall back to a clean-room reimplementation) is now fulfilled by the in-tree module. ADR 0001's libvaxis → mibu history is preserved for context.

## Clean-room policy (TUI primitives)

If you need a TUI primitive the in-tree `src/terminal/` module does not expose (e.g. a new terminal capability, a custom escape sequence, a kitty keyboard progress report), follow the clean-room protocol:

1. **Do not read libvaxis or mibu source.** Ever. The libvaxis → mibu → in-tree trajectory is documented in `docs/decisions/0001-libvaxis-to-mibu.md` and `docs/decisions/0003-clean-room-impl.md`.
2. **Consult the relevant public specs:**
   - POSIX `termios(3)` for raw mode, termios save/restore, and signal handling.
   - ECMA-48 for CSI / DCS / OSC escape sequences and parameterized control functions.
   - The kitty keyboard protocol (<https://sw.kovidgoyal.net/kitty/keyboard-protocol/>) for the kitty kb extensions.
   - xterm ctlseqs (<https://invisible-island.net/xterm/ctlseqs/ctlseqs.html>) for the long tail of DEC private modes (e.g. 2048, 1049, 2026) and terminal capability queries.
3. **Cite each spec in the code comment** above the new code. A one-line citation (`// POSIX termios(3) §canonical mode`) is enough.
4. **Add a RED test** in `tests/terminal/` (the test-terminal step at `build.zig`) that exercises the new primitive headlessly (no TTY — use a `MockBackend` or byte-fixture).
5. **Document the spec citation** in `docs/decisions/0002-clean-room.md` (the ADR records per-primitive references). The ADR is the source of truth for which spec governs which primitive.

Rationale: independent re-implementations of well-specified terminal protocols are settled practice (curl, libssh2, kitty, alacritty, wezterm all have such code). Reading libvaxis or mibu would contaminate the implementation with their design choices and re-introduce the maintenance tail we explicitly left behind. The in-tree `src/terminal/` module is the authoritative surface; every primitive derives from the four cited specs.

## No new third-party deps without an ADR

Adding a new dep to `build.zig.zon` requires:

1. A new ADR under `docs/decisions/` with: why the dep is needed, the alternatives considered (including stdlib + clean-room), the license, the dep's transitive deps, and the upgrade policy.
2. The dep pinned at an exact commit (no caret ranges).
3. An update to the project's anti-slop guardrails (no abstract factories over the dep; reuse over reimplementation).
4. PR review approval.

This applies to any TUI dep, HTTP dep, crypto dep, or sandbox dep. After PR 6 of `terminal-control-lib-from-scratch`, the project has zero third-party TUI deps; the in-tree `src/terminal/` module replaces the previous `mibu@636a36a`.

## Project modules (reuse over reimplementation)

zargeant ships the following in-tree modules. Reuse them; do not reimplement:

| Module               | Role                                                            |
| -------------------- | --------------------------------------------------------------- |
| `src/logger.zig`     | Headless logging to `/tmp/ai-harness-debug.log` (mode `0600`).  |
| `src/sandbox.zig`    | `spawnToolSubprocess(...)` with Landlock + Seccomp-BPF.         |
| `src/api_client.zig` | MiniMax HTTP-SSE client.                                        |
| `src/api_auth.zig`   | API-key validation + 0o600 consent write.                       |
| `src/tls_conn.zig`   | Handrolled TLS state machine.                                   |
| `src/mock_server.zig`| Mock HTTP server for tests.                                     |
| `src/terminal/`      | TUI control layer (termios + CSI/SGR + DEC private modes + kitty kb + event parser). In-tree; replaces the previous `mibu@636a36a` dep per ADR 0003. |

The TUI code (`src/tui.zig`, `src/runtime.zig`, `src/modal.zig`, `src/password_input.zig`) routes through these — no parallel implementations.

## Grep-fail guardrails

`src/api_auth.zig` runs a static grep (`getenv | readFile | libsecret | Secret Service`) over 10 source files. The grep MUST return 0 matches. The 10 targets are:

- `src/api_client.zig`
- `src/api_sse.zig`
- `src/api_auth.zig`
- `tools/debug_call.zig`
- `src/tui.zig`
- `src/runtime.zig`
- `src/channels.zig`
- `src/main.zig`
- `src/password_input.zig`
- `src/modal.zig`

If you add a new TUI source file (in `src/terminal/` or elsewhere), append it to the targets list in `src/api_auth.zig` and add the new file to the test assertion. Per ADR 0002 / peer-review C18, no `src/terminal/*.zig` file may contain `getenv`, `readFile`, `libsecret`, or `Secret Service` patterns.

## Submitting a PR

1. Branch from the appropriate base (see `sdd-flow` skill for chained PR topology).
2. Run the verification gate:

   ```bash
   zig build test --summary all
   zig build test --summary all -Doptimize=ReleaseSafe
   zig build test --summary all -Doptimize=ReleaseFast
   ```

   All three must exit 0.
3. Push the branch and open a PR. The PR body must include the chain context (position, base, follow-up, review budget) per the `chained-pr` skill.
4. Address review comments with fixup commits; squash on merge.

## License

By contributing, you agree to release your contributions under [The Unlicense](https://unlicense.org/) (the project's license). The in-tree `src/terminal/` module (replacing the previous `mibu` dependency per ADR 0003) is also released under The Unlicense; the original `mibu` source was MIT-licensed at commit `636a36a353614da2a537b060c33f17d608915eab`, but the in-tree reimplementation is independent clean-room work authored against POSIX `termios(3)`, ECMA-48, the kitty keyboard protocol, and xterm ctlseqs only — no mibu or libvaxis source was consulted per `CONTRIBUTING.md:41` and ADR 0002 §"Negative".
