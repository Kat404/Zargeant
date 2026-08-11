# Contributing to zargeant

Thanks for your interest in zargeant. This document covers the contribution workflow, the rules around our single third-party dependency (mibu), and the clean-room policy for TUI primitives.

## Ground rules

- **Strict TDD.** Tests are written **before** implementation. Each work unit ships a focused test (or self-test) plus its implementation in the same commit. The full `zig build test` gate must exit 0 on **Debug**, **ReleaseSafe**, and **ReleaseFast** before any PR opens.
- **No AI co-attribution.** Commits are authored by the human; AI assistance is not co-attributed.
- **English for technical artifacts.** Code, comments, commit messages, specs, and PR bodies are in English. Use a neutral register; this project does not adopt a regional voice in technical work.
- **Conventional Commits.** Subject line ≤ 50 chars, prefixed with `feat(scope):`, `fix(scope):`, `chore:`, `docs:`, `test(scope):`, `refactor(scope):`. The body explains *why*, not *what*.
- **Work-unit commits.** One commit = one deliverable unit. Tests travel with the code they verify. Docs travel with the change they explain. See `~/.config/opencode/skills/work-unit-commits/SKILL.md` (or the in-repo equivalent).
- **Review budget.** Each PR targets ≤ 400 changed lines. Use chained PRs above 400; the `chained-pr` skill walks the topology.

## TUI dependency (mibu)

zargeant's TUI render surface is **mibu**, pinned at the exact commit

```
636a36a353614da2a537b060c33f17d608915eab
```

- Source: <https://github.com/xyaman/mibu>
- License: MIT
- Zero transitive deps. Zero heap allocations in the hot path. ~950 LoC total.

The pin is enforced by `tests/tui/mibu_pin.zig` (REQ-TUI-020). The test reads `.dependencies.mibu.hash` from `build.zig.zon` and asserts equality. CI fails if the hash drifts.

**Do not upgrade mibu opportunistically.** Any mibu bump requires:

1. A new ADR entry in `docs/decisions/` (e.g. `0003-mibu-pin-update.md`) documenting the upstream change, the API diff, and the verification done against zargeant's TUI code paths.
2. An update to `tests/tui/mibu_pin.zig` with the new expected hash.
3. A review of every mibu call site (`src/tui.zig` + `tests/tui/mibu_smoke.zig`) against the upstream API at the new commit.
4. All three `zig build test` modes green (Debug + ReleaseSafe + ReleaseFast).

If upstream mibu dies, the fallback plan is documented in `docs/decisions/0001-libvaxis-to-mibu.md` (vendor mibu to `vendor/mibu/`, or fall back to a clean-room reimplementation). Do not chase a new third-party TUI dep without an ADR.

## Clean-room policy (TUI primitives)

zargeant uses only a small slice of mibu's surface. If you need a TUI primitive mibu does not expose (e.g. a new terminal capability, a custom escape sequence, a kitty keyboard progress report), follow the clean-room protocol:

1. **Do not read libvaxis source.** Ever. The libvaxis → mibu swap in `docs/decisions/0001-libvaxis-to-mibu.md` documents why we left that codebase.
2. **Consult the relevant public specs:**
   - POSIX `termios(3)` for raw mode, termios save/restore, and signal handling.
   - ECMA-48 for CSI / DCS / OSC escape sequences and parameterized control functions.
   - The kitty keyboard protocol (<https://sw.kovidgoyal.net/kitty/keyboard-protocol/>) for the kitty kb extensions.
   - xterm ctlseqs (<https://invisible-island.net/xterm/ctlseqs/ctlseqs.html>) for the long tail of DEC private modes (e.g. 2048, 1049, 2026) and terminal capability queries.
3. **Cite each spec in the code comment** above the new code. A one-line citation (`// POSIX termios(3) §canonical mode`) is enough.
4. **Add a RED test** in `src/tui.zig` (or `tests/tui/` if the test requires a separate file) that exercises the new primitive headlessly (no TTY — use `os.tty = false`).
5. **Document the new ADR entry** in `docs/decisions/0002-clean-room.md` (create when the first such primitive lands). The ADR records the spec citations, the code path, and the test coverage.

Rationale: independent re-implementations of well-specified terminal protocols are settled practice (curl, libssh2, kitty, alacritty, wezterm all have such code). Reading libvaxis would contaminate the implementation with its design choices and re-introduce the maintenance tail we explicitly left behind.

## No new third-party deps without an ADR

Adding a new dep to `build.zig.zon` requires:

1. A new ADR under `docs/decisions/` with: why the dep is needed, the alternatives considered (including stdlib + clean-room), the license, the dep's transitive deps, and the upgrade policy.
2. The dep pinned at an exact commit (no caret ranges).
3. An update to the project's anti-slop guardrails (no abstract factories over the dep; reuse over reimplementation).
4. PR review approval.

This applies to any TUI dep, HTTP dep, crypto dep, or sandbox dep. The only currently-approved dep is mibu.

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

If you add a new TUI source file, append it to the targets list in `src/api_auth.zig` and add the new file to the test assertion.

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

By contributing, you agree to release your contributions under [The Unlicense](https://unlicense.org/) (the project's license). If you are contributing code derived from MIT-licensed works (e.g. mibu), keep the original copyright notice and license header in the affected files.
