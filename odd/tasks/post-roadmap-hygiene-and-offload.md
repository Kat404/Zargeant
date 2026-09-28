# Post-roadmap hygiene + Agent-thread offload

**Feature**: `post-roadmap-hygiene-and-offload`
**Type**: Tech debt cleanup + HIGH-priority architectural offload
**Priority**: HIGH (FU-1) + P3 hygiene (FU-2, audit, tool_calls follow-up)
**Mode**: ODD + TDD + RDD (per project convention since 2026-09-26, engram obs#1794)
**Branch**: `chore/post-roadmap-hygiene-and-offload` (feature branch from `main @ d859909`)
**Test runners** (per file):
- `just test-runtime-thread` — covers `src/modal.zig`, `src/runtime.zig`, `src/channels.zig`, `src/api_auth.zig` via `tests/tui/runtime_thread.zig`
- `just test-tui` — covers `src/modal.zig::WindowMock` via `tests/tui/screen_grid.zig`
- `just test-api-client` — covers `src/api_client.zig` via `tests/api_client.zig` (REQ-NEW-003 socket guard)
- `just test-cancel-path` — covers cancel_pipe plumbing (CAP-09 invariant, unchanged)
- `just test-cancel-e2e` — env-gated e2e (CAP-09, may hang per AGENTS.md §9.2)

**Pre-conditions**:
- `main @ d859909` (verified 0 ahead/behind origin/main)
- 0 open issues, 0 open PRs
- Local CI green: `just build` + `just build-safe` + `just build-fast` + `just check` + `just ci-fast`
- Working tree clean (only `.gga` untracked)

---

## Goal

Close out the post-roadmap backlog that accumulated during the 2026-09-26 housekeeping inventory:

1. **FU-1 [HIGH]** — Move `validateViaApi` off the per-submit TUI/spawn path and onto the existing Agent thread. The current path spawns a one-shot worker per submit (`runValidateWorker` at `src/modal.zig:953`, called from `submitKeyEntryAsync`/`submitUnlockAsync`) that duplicates the threading + cancel-pipe plumbing the runtime already owns. Offload follows the same pattern `agentDispatchTool` (`src/runtime.zig:663-671`) uses for `DispatchToolRequest`.

2. **FU-2 [P3]** — Fix the `WindowMock.print` overwriting bug at `src/modal.zig:230`. `print` always starts at `(col=0, row=0)`, so `drawConsentPrompt` (5 calls) and `drawErrorModal` (with em-dash fragmentation at `:1646-1647`) overwrite each other's fragments. The `render*ToGrid` mirrors already use advancing `writeCell(col, row, …)` coords — the WindowMock path was never fixed.

3. **api-client-testability-audit [P3]** — Confirm via `rg` that no `testing.allocator` / `testing.io` leaks to production in `src/api_client.zig`. Inventory (per mapper): **44 hits in api_client.zig, 21 in api_auth.zig, 50+ in modal.zig — all inside `test "…" { … }` blocks except the 2 helpers (`tryDecrypt`, `io_allocator`) which are already gated with `builtin.is_test`. Audit is already clean.** Action: regression test that catches future leaks + an audit-log commit message.

4. **tool-subprocess-pool follow-up [P3]** — Parse LLM `tool_calls` JSON from SSE stream. The current `agentDispatchTool` (`src/runtime.zig:663-671`) forwards `UserToolRequest` verbatim as `DispatchToolRequest` — the conservative v1 path from slice 7. The SSE parser at `src/api_sse.zig:285-295` only walks `choices[0].delta.content` / `.reasoning_content` and never inspects `delta.tool_calls[i]`. Anthropic API streaming returns `tool_calls` inside `delta.tool_calls` (each with `id`, `type="function"`, `function.{name, arguments=JSON-encoded string}`); single-shot returns them inside `choices[0].message.tool_calls`.

## Scope

| File | Action | WU |
| --- | --- | --- |
| `src/channels.zig` | +1 variant `Event.ValidateApiRequest { kind: enum{ key_entry, unlock }, key_or_pass: [BUF_LEN]u8, key_len: usize }` | WU-3 |
| `src/runtime.zig` | New arm in `agentThreadLoop` for `ValidateApiRequest` → `agentRunValidate` helper → `Event.ValidateApiReply` on `submit_reply` (16→17 variants) | WU-3 |
| `src/modal.zig` | **Drop** `runValidateWorker` + `ValidateCtx` + `LoadCtx` + `std.Thread.spawn` at `:807, :853, :1137`. Replace call sites with `Event.ValidateApiRequest` post on `tui_to_agent` | WU-3 |
| `src/modal.zig` | Add `WindowMock.printAt(self, col, row, text, style)`. Keep `WindowMock.print` as `printAt(0,0,…)` for back-compat. Update `drawConsentPrompt`/`:drawErrorModal`/`drawKeyEntry`/`drawUnlock`/`drawAgentLoopView` to use `printAt` with advancing cursor. T-SG-8 signatures verbatim | WU-2 |
| `src/api_client.zig` | Add regression test `test "testing.allocator never reaches production"` that fails if any non-test-block line references `testing.allocator` / `testing.io` | WU-1 |
| `src/api_sse.zig` | Extend SSE parser to extract `delta.tool_calls[i]` and `message.tool_calls[i]`. Serialize `function.arguments` (JSON-encoded string) into the existing `UserToolArgs.args` field | WU-4 |
| `src/runtime.zig` | Extend `agentThreadLoop` drain to consume parsed `tool_calls` events and synthesize one `Event.DispatchToolRequest` per call, post via `agentDispatchTool` | WU-4 |
| `src/channels.zig` | Optional: +1 variant `Event.ToolCallsDetected { count: u8 }` for TUI status indicator (defers if budget tight) | WU-4 |
| `tests/tui/screen_grid.zig` | Update T-2.4.1 cases 3+4 to assert `printAt` semantics (corrected layout, UTF-8 atomicity preserved) | WU-2 |
| `tests/tui/runtime_thread.zig` | New RED→GREEN fixtures for FU-1 (validate path via Agent arm) + WU-4 (tool_calls SSE) | WU-3, WU-4 |
| `tests/api_client.zig` | New test "audit: testing.allocator never reaches production" | WU-1 |

**Out of scope (intentional non-goals):**

- `Modal` renderer cleanup beyond `WindowMock.printAt` — keep signature contracts intact (T-SG-8).
- `ArenaAllocator` propagation to runtime (R-1 carry-forward, deferred to a future slice if `validateViaApi` becomes async-only).
- `Event.ToolCallsDetected` variant — defer if WU-4 budget tight.
- New `odd/archive/` folder — completed feature docs stay in `odd/tasks/` (precedent: housekeeping + phase0/0.5/2/build-blocker-fix).
- Push to origin / PR creation — user's decision per ODD §6. This slice lands commits on the feature branch.

## Acceptance criteria

### WU-1 (audit)
- [ ] `rg -n 'testing\.(allocator|io)' src/api_client.zig` returns 0 results outside `test "…" { … }` blocks (verification grep, automated into the regression test)
- [ ] New test `test "audit: testing.allocator never reaches production"` in `src/api_client.zig` parses the source file and fails if any `testing.allocator` / `testing.io` literal appears outside a `test` block
- [ ] `just build-safe` + `just build-fast` pass (would fail loudly if any leak)
- [ ] `just test-api-client` passes

### WU-2 (WindowMock.printAt)
- [ ] `WindowMock.printAt(self, col, row, text, style)` added to `src/modal.zig`
- [ ] `WindowMock.print(text, style)` preserved as `printAt(0, 0, text, style)` for back-compat
- [ ] `drawConsentPrompt`, `drawErrorModal`, `drawKeyEntry`, `drawUnlock`, `drawAgentLoopView` updated to use `printAt` with advancing cursor (no signature changes — T-SG-8 preserved)
- [ ] `tests/tui/screen_grid.zig` T-2.4.1 cases 3+4 updated to assert corrected layout (no overwrite)
- [ ] `tests/tui/runtime_thread.zig` T-SG-8 + per-frame assertions stay green (the `pub fn draw*` signatures are preserved verbatim, only body changes)
- [ ] `just test-tui` + `just test-runtime-thread` pass

### WU-3 (FU-1 Agent-thread offload) [HIGH]
- [ ] `Event.ValidateApiRequest` added to `src/channels.zig::Event` (16→17 variants). All 3 docs/grep sites that count variants stay in sync (no automated test exists for this — manual `git grep` confirmation only)
- [ ] `agentRunValidate(args, req: Event.ValidateApiRequest)` helper added in `src/runtime.zig`
- [ ] `agentThreadLoop` drains `Event.ValidateApiRequest` → routes to `agentRunValidate` → posts `Event.ValidateApiReply` on `submit_reply` (existing reply channel, unchanged)
- [ ] `src/modal.zig::runValidateWorker` + `ValidateCtx` + `LoadCtx` removed; `submitKeyEntryAsync`/`submitUnlockAsync` now post `Event.ValidateApiRequest` on `tui_to_agent`
- [ ] `std.Thread.spawn` call sites in `modal.zig:853` removed (the runtime already owns the Agent thread; no new spawns)
- [ ] New RED→GREEN fixture in `tests/tui/runtime_thread.zig` covers the validate-via-Agent path end-to-end (cancel-pipe roundtrip via existing CAP-09 wiring, success + error + cancel cases)
- [ ] `just test-runtime-thread` + `just test-cancel-path` pass

### WU-4 (tool_calls parsing)
- [ ] `src/api_sse.zig` extracts `delta.tool_calls[i]` and `message.tool_calls[i]` from SSE events
- [ ] `function.arguments` (JSON-encoded string) parsed via `std.json.parseFromSlice` then re-serialized to canonical string for `UserToolArgs.args`
- [ ] `agentThreadLoop` consumes parsed tool_calls and synthesizes `Event.DispatchToolRequest { id, name, args }` per element, posts via `agentDispatchTool`
- [ ] (Optional) `Event.ToolCallsDetected` variant added to `channels.zig` (17→18) + consumed by TUI for status indicator
- [ ] RED→GREEN fixtures in `tests/tui/runtime_thread.zig` cover: (a) streaming delta.tool_calls, (b) single-shot message.tool_calls, (c) the existing `UserToolRequest` verbatim-forward path stays green (fallback when no tool_calls present)
- [ ] `just test-runtime-thread` passes

### Global
- [ ] `just build` + `just build-safe` + `just build-fast` pass (AGENTS.md §10 order: builds FIRST)
- [ ] `just check` (QA 0..5 static guards: fmt, syscalls, TDD, co-author) passes
- [ ] `just test-all` (umbrella + embedded) passes
- [ ] `just verify` (3-mode compile gamut) passes
- [ ] `just ci` (independent Podman Alpine verification) passes — last gate before merge
- [ ] No AI co-author in commit messages
- [ ] All 4 WUs land as separate work-unit commits on `chore/post-roadmap-hygiene-and-offload` per `work-unit-commits` skill
- [ ] Push to origin + PR creation is user's decision per ordinary repository policy

## Work-unit breakdown

### PR boundary

- **PR-1 (hygiene slice)** — WU-1 + WU-2, ~50-80 LoC, fast ship, low risk, independent files (`api_client.zig` + `modal.zig`)
- **PR-2 (HIGH slice)** — WU-3, 180-260 LoC, the main work
- **PR-3 (follow-up slice)** — WU-4, 120-180 LoC, ships after PR-2 lands so channels.zig variant counts stay sequential

Stacked-to-main chain (per project precedent: tclib tracker, Phase 2 stack).

### WU-1: api_client.zig audit + regression test

**LoC**: 0-12

**Commit** (1 commit):
```
test(api-client): regression test guards testing.allocator never reaches production

Closes the audit opened by the 2026-09-26 status inventory. The 44 hits
of testing.allocator / testing.io in src/api_client.zig were verified
already inside test "…" { … } blocks (none leaked to production).
This adds a self-checking regression test that parses the source file
and fails if any literal reference appears outside a test block —
defending against the regression that bit modal.zig and api_auth.zig
in PR #15.

No behavior change. The audit is a no-op confirmation; the test is
the durable artifact.
```

### WU-2: WindowMock.printAt + draw fn cursor plumbing

**LoC**: 40-70

**Commit** (1 commit):
```
fix(modal): WindowMock.printAt + draw fns use advancing coords

WindowMock.print always started at (0,0), so drawConsentPrompt (5
sequential calls) and drawErrorModal (with em-dash fragmentation
at :1646-1647) silently overwrote each other's fragments. The
render*ToGrid mirrors already use advancing writeCell(col, row, ...)
coords — the WindowMock path was never fixed.

- Add WindowMock.printAt(self, col, row, text, style)
- Keep WindowMock.print(text, style) as printAt(0, 0, ...) for
  back-compat (12+ tests rely on legacy overwrite behavior)
- Update drawConsentPrompt, drawErrorModal, drawKeyEntry,
  drawUnlock, drawAgentLoopView to call printAt with advancing
  cursor — T-SG-8 pub fn signatures preserved verbatim
- Update tests/tui/screen_grid.zig T-2.4.1 cases 3+4 to assert
  corrected layout (no overwrite); UTF-8 atomicity preserved

Closes FU-2 [P3 hygiene].
```

### WU-3: FU-1 — validateViaApi offload to Agent thread

**LoC**: 180-260

**Commit** (1 commit):
```
feat(runtime): offload validateViaApi to Agent thread

Closes FU-1 [HIGH]. The per-submit modal path spawned a one-shot
worker (runValidateWorker at src/modal.zig:953) that duplicated the
threading + cancel-pipe plumbing the runtime already owns. The
reply event Event.ValidateApiReply + channels.submit_reply drain
already existed (WU-2 of tui-input-flow-bugfixes-2), so only the
request side was missing.

- Add Event.ValidateApiRequest { kind, key_or_pass, key_len }
  to src/channels.zig::Event (16→17 variants)
- Add agentRunValidate(args, req) helper in src/runtime.zig
- agentThreadLoop routes ValidateApiRequest → agentRunValidate →
  posts Event.ValidateApiReply on submit_reply
- Drop runValidateWorker, ValidateCtx, LoadCtx, and std.Thread.spawn
  in src/modal.zig:807, :853, :1137
- submitKeyEntryAsync / submitUnlockAsync now post
  Event.ValidateApiRequest on tui_to_agent (cancel-pipe ownership
  unchanged — runtime-owned)

Format pre-flight (api_auth.validateFormat) stays synchronous on
the TUI thread — ≤1ms check. Only the network probe moves off the
caller's path.

Verified end-to-end via new RED→GREEN fixtures covering success,
error, and cancel-via-existing-CAP-09-pipe cases.
```

### WU-4: tool_calls JSON parsing in SSE stream

**LoC**: 120-180

**Commit** (1 commit):
```
feat(sse): parse LLM tool_calls JSON from streaming + single-shot paths

Closes the tool-subprocess-pool v1-conservative verbatim-forward
fallback. The Anthropic API returns tool_calls inside:
  - delta.tool_calls[i]        (streaming)
  - message.tool_calls[i]       (single-shot)
Each call carries { id, type="function", function.{ name, arguments=JSON-encoded string } }.
The previous SSE parser (src/api_sse.zig:285-295) only walked
choices[0].delta for content / reasoning_content and silently
dropped tool_calls.

- Extend api_sse.zig Parser to extract delta.tool_calls and
  message.tool_calls via std.json.parseFromSlice (same pattern
  as :269)
- Serialize function.arguments (JSON-encoded string) to canonical
  string for UserToolArgs.args
- agentThreadLoop consumes parsed tool_calls and synthesizes
  one Event.DispatchToolRequest { id=generated, name, args }
  per element, posts via agentDispatchTool
- Existing UserToolRequest verbatim-forward path stays green
  (fallback when no tool_calls present)

Optional Event.ToolCallsDetected variant deferred if budget tight.
```

## Verification

### Per-WU (apply phase)
- **WU-1**: `just build-safe && just build-fast && just test-api-client`
- **WU-2**: `just test-tui && just test-runtime-thread`
- **WU-3**: `just test-runtime-thread && just test-cancel-path`
- **WU-4**: `just test-runtime-thread`

### Pre-merge (AGENTS.md §10 order — builds FIRST)
1. `just build` (Debug)
2. `just build-safe` (ReleaseSafe)
3. `just build-fast` (ReleaseFast)
4. `just check` (QA 0..5: fmt + ast + syscalls + TDD + co-author)
5. `just test-all` (umbrella + embedded workaround)
6. `just verify` (3-mode compile gamut + comprehensive QA)
7. `just ci` (independent Podman Alpine verification — last gate)

### Forbidden shortcuts
- ❌ Skip builds and rely on tests passing — `test-*` targets have isolated module wiring that does not validate the production binary
- ❌ Skip `just ci` and merge based on local Podman only — only env-isolated check
- ❌ Skip `just verify` because `just ci` passed — verify does 3-mode compile optimization checks that ci skips

## Risk register

> **R-1 (MEDIUM):** WU-3 cross-cutting — `modal.zig`, `runtime.zig`, `channels.zig`, `api_auth.zig` all change in one commit. Mitigation: RED→GREEN fixture MUST cover the full Agent-arm validate path end-to-end before the `runValidateWorker` drop, so the working state is provable at every step.

> **R-2 (LOW):** WU-2 `printAt` changes affect 5 `draw*` functions. Mitigation: T-SG-8 contract test (`modal.zig:59` + `runtime_thread.zig:1649`) enforces verbatim signature preservation; review the diff to confirm no signature churn.

> **R-3 (LOW):** WU-4 depends on WU-3 landing first (channels.zig 16→17 variants in WU-3, then 17→18 if `ToolCallsDetected` ships). Mitigation: ship WU-4 as PR-3 after PR-2 merges; do not start WU-4 on the local branch until PR-2 is merged to main.

> **R-4 (NEGLIGIBLE):** WU-1 audit is a no-op confirmation. Risk: future leak goes undetected. Mitigation: the regression test parses its own source on each run; build flags (ReleaseSafe/ReleaseFast) reject `testing.allocator` in production paths.

> **R-5 (LOW):** Push to origin / PR creation is the user's decision per ODD §6. This slice lands commits on the feature branch locally; push + PR are out of scope per ordinary repository policy.

## References

- Engram obs#1800 — Handoff consolidated (2026-09-25): defines FU-1, FU-2, audit, tool-subprocess follow-up as the post-roadmap backlog
- Engram obs#1791 — Manual code review of Phase 2 stack (originated FU-2 + audit item)
- Engram obs#1794 — Workflow decision (SDD → ODD + TDD + RDD)
- Engram obs#1799 — Final stack closeout summary
- Engram `zargeant/mapping-2026-09-28-fu1-p3-hygiene` — Mapping handoff from explore subagent (2026-09-28)
- `src/api_auth.zig:145` — current `validateViaApi` signature
- `src/api_auth.zig:471-485` — `tryDecrypt` (already-gated `testing.allocator` pattern; template for the audit regression test)
- `src/modal.zig:1944-1955` — `io_allocator` helper (already-gated pattern)
- `src/runtime.zig:497-613` — `agentThreadLoop` (template for the new arm)
- `src/runtime.zig:663-671` — `agentDispatchTool` (template for `agentRunValidate`)
- `src/channels.zig:79-189` — `Event` union (current 16 variants; will become 17 after WU-3)
- `src/api_sse.zig:269` — `std.json.parseFromSlice` reference pattern
- `src/api_sse.zig:285-295` — current SSE parser (only walks `delta.content` / `.reasoning_content`)
- `tests/tui/runtime_thread.zig:1414, :1467, :1649, :1893, :1974, :2018, :2797, :2837, :2877, :3033, :3053, :3072, :3089` — existing T-SG-8 + per-frame assertions
- `tests/tui/screen_grid.zig:1414-1574` — T-2.4.1 WindowMock tests
- `tests/tui/cancel_path.zig:69` — CAP-09 cancel-pipe roundtrip invariant (unchanged)
- `odd/tasks/tui-ship-fast-phase2.md` — precedent for 4-PR Phase 2 stack (option D split)
- `odd/tasks/docs-housekeeping-status-sync.md` — precedent for 2-WU PR with work-unit commits
- `odd/tasks/tool-subprocess-pool.md` — slice 7 spec (where the tool_calls follow-up was deferred)
- AGENTS.md §10 — Pre-Merge QA Gate Ordering (builds-FIRST)
- AGENTS.md §9.2 — `test-embedded` recipe caveat (Zig 0.16 std.zig.Server hang)