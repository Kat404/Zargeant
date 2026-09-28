# Tool Subprocess Pool (Slice 7 of 7-slice Roadmap)

**Feature**: `tool-subprocess-pool`
**Type**: Substantial implementation slice (file-scoped to `src/runtime.zig` + `src/sandbox.zig` + `src/channels.zig` + `tests/runtime_thread.zig`)
**Priority**: P1 (closes the 7-slice roadmap; unblocks FU-1 Agent-thread offload of `validateViaApi`)
**Mode**: ODD + strict TDD (RED→GREEN per WU) + RDD at the end
**Pre-condition**: PR #15 (tui-input-wiring) merged → user keystroke can trigger tool invocation

---

## Goal

Replace the current stub `toolsRealMain` (sequential, one-tool-at-a-time, no stdout capture, no timeout, no cancel) with a proper tool execution pipeline: argv splitting, stdout/stderr capture, timeout enforcement, cancel via cancel_pipe, concurrent pool (configurable N), proper Agent→Tools wiring, comprehensive tests.

## Current state (baseline)

`src/runtime.zig:630` `toolsRealMain` is a stub:
- Sequential — processes one tool at a time
- argv = `[d.name]` only (no args split)
- No stdout capture — output discarded via `_ = sub.wait()`
- No timeout — relies on tool subprocess to self-terminate
- No cancel — `.CancelTool => |id| { _ = id; }` is a no-op
- No pool — single concurrent tool
- No sandbox violation detection — `tool_bpf_prog` (in sandbox.zig) returns SECCOMP_RET_KILL_PROCESS for violations, but the parent never inspects `waitpid` status to detect this

The sandbox.zig `spawnToolSubprocess` does the heavy lifting (fork → Landlock → Seccomp → close_range → execve) but the runtime.zig side never reads stdout/stderr pipes back.

The channels infrastructure exists:
- `Event.DispatchToolRequest(UserToolArgs)` (TUI→Tools)
- `Event.CancelTool(u64)` (informational, no-op currently)
- `Event.ToolResult(ToolResultPayload)` (Tools→TUI)
- `Event.ToolError(ToolErrorPayload)` (Tools→TUI)
- `UserToolArgs { id, name, args }` (command + args as one string)

`ToolErrorKind` enum has all 4 variants: `spawn_failed`, `timeout`, `nonzero_exit`, `sandbox_violation`. Only `spawn_failed` is currently emitted.

## Approach (single PR, ~250-400 LoC)

**WU-1: argv splitting** — Parse `d.name + " " + d.args` into argv via whitespace split (handle quoted args if needed). Pass proper argv to spawnToolSubprocess. RED test: `parse_argv("tool arg1 arg2")` → `["tool", "arg1", "arg2"]`. RED test: `parse_argv("tool")` → `["tool"]`. GREEN: implement `parse_argv(args: []const u8) ![][:0]const u8` in src/runtime.zig.

**WU-2: stdout capture + ToolResult** — Spawn with `pipe(2)` for stdout; after exec, read stdout until EOF; on subprocess exit, post `ToolResult { id, output = captured_stdout }`. RED test: spawn `echo hello`, expect ToolResult.output == "hello\n". GREEN: implement.

**WU-3: sandbox_violation detection** — Inspect `waitpid` status; if `WIFSIGNALED(status) && WTERMSIG(status) == SIGSYS` (or 31 = SIGSYS), post `ToolError.sandbox_violation` with stderr captured. RED test: spawn a tool that triggers SIGSYS via static-grep-detectable pattern (or just unit-test the waitpid parser). GREEN: implement.

**WU-4: timeout enforcement** — Pass `timeout_ms: u32` to spawnToolSubprocess; spawn with `timer_create(CLOCK_MONOTONIC, ...)` or use `poll([stdout_fd, cancel_fd], timeout_ms)` pattern; on timeout, `kill(child_pid, SIGKILL)` and post `ToolError.timeout`. RED test: spawn a tool that sleeps longer than timeout, expect ToolError.timeout within timeout+grace_ms. GREEN: implement.

**WU-5: cancel via cancel_pipe** — On `.CancelTool` event (or global cancel_pipe close), kill in-flight subprocess + drain output + post no result (cancel is silent per spec). RED test: spawn a sleeping tool, send cancel, verify subprocess is killed + no ToolResult/ToolError posted. GREEN: implement.

**WU-6: Pool / concurrency** — Replace sequential loop with worker pool of N threads (configurable, default N=4). Each worker pulls DispatchToolRequest from `tui_to_tools` channel; bounded by channel + worker count. RED test: spawn 2 long-running tools in quick succession; verify both run concurrently (both ToolResults posted). GREEN: implement worker pool.

**WU-7: Agent → Tools dispatch** — When Agent thread receives `UserToolRequest` from TUI, build `DispatchToolRequest` and post to `tui_to_tools` (or `agent_to_tools` if separate channel exists). RED test: post `UserToolRequest` to agent_thread (via mock); assert `DispatchToolRequest` appears in `tui_to_tools`. GREEN: implement in agentThreadLoop.

**WU-8: comprehensive tests + T-SG-12** — RED tests for all the above (8+ scenarios) + static-grep guard for the new patterns (e.g., `toolsRealMain spawnToolSubprocess` must include `envp.length == 0` path).

## Scope per WU (LoC estimates)

| WU | Scope | Prod LoC | Test LoC |
|----|-------|-----------|-----------|
| WU-1 | argv splitting in runtime.zig | ~30 | ~30 |
| WU-2 | stdout capture + ToolResult | ~40 | ~40 |
| WU-3 | sandbox_violation detection | ~15 | ~25 |
| WU-4 | timeout enforcement | ~25 | ~40 |
| WU-5 | cancel via cancel_pipe | ~10 | ~25 |
| WU-6 | pool/concurrency (N=4) | ~50 | ~40 |
| WU-7 | Agent → Tools dispatch | ~20 | ~20 |
| WU-8 | comprehensive tests + T-SG-12 | 0 | ~120 |
| **Total** | | **~190** | **~340** = **~530** |

Above the 400-line preflight budget by +130. Will need user authorization for `size:exception` OR chained split (e.g., WU-1..3 first, then WU-4..6, then WU-7..8).

## Risk register (deferred + new)

- R-1 (CRITICAL): v1 acceptable `validateViaApi` blocking call stays on TUI thread (carry-forward from tui-input-wiring)
- R-2 (CRITICAL): channel overflow drops oldest chunk (existing)
- R-3 (NEW, MEDIUM): Concurrent tool execution may exhaust file descriptors if N too high. Mitigate: N bounded by `tools_pool_size` config (default 4) + post-fork close_range inherited fds
- R-4 (NEW, MEDIUM): pool worker exits cleanly on shutdown. Workers must check `args.shutdown.load(.seq_cst)` between tool executions
- R-5 (NEW, LOW): argv injection if user input contains shell metacharacters. Mitigate: spawnToolSubprocess already bypasses shell (uses `execve` directly, no `sh -c`)
- R-6 (NEW, MEDIUM): stdout buffering — pipe(2) buffer is 64KB; long-output tools may block. Mitigate: read with O_NONBLOCK + drain in chunks; document as known limitation

## Out of scope (NOT in this slice)

- TLS-handrolled (already shipped)
- API client retry+cancel consolidation (separate slice)
- sigint-ke-upgrade (separate slice)
- api-client-testability-audit (separate slice — `std.testing.allocator` in src/api_client.zig:307)
- sandbox_violation end-to-end test (just unit-test the waitpid parser; actual SIGSYS triggering requires Linux sec integration test)
- argv shell-quote parsing (just whitespace split + double-quote aware; full shell parsing is out of scope)

## Acceptance criteria

- [ ] argv splitting: `parse_argv("tool arg1 arg2")` returns `["tool", "arg1", "arg2"]`
- [ ] stdout capture: spawned `echo hello` produces ToolResult.output == "hello\n"
- [ ] sandbox_violation detection: SIGSYS-killed subprocess → ToolError.sandbox_violation
- [ ] timeout: long-running subprocess killed + ToolError.timeout within timeout_ms + 100ms grace
- [ ] cancel: CancelTool → subprocess killed + no ToolResult/ToolError (silent)
- [ ] concurrent: 2 long-running tools run in parallel, both ToolResults posted
- [ ] Agent dispatch: UserToolRequest → DispatchToolRequest in tui_to_tools
- [ ] T-SG-12 static-grep guard: ensures new patterns present
- [ ] All tests green: existing 297+ tests + new WU-8 tests
- [ ] `just build` (Debug + Safe + Fast) — 3 builds clean (per AGENTS.md §10 builds-first rule)
- [ ] `just check` — fmt + ast + syscalls + TDD + co-author all green
- [ ] `just ci-fast` — 12/12 verde

## References

- `src/runtime.zig:630-686` — current `toolsRealMain` stub (the file to replace)
- `src/sandbox.zig:685` — `spawnToolSubprocess` (heavy lifting already done)
- `src/channels.zig` — Event union (DispatchToolRequest, CancelTool, ToolResult, ToolError variants)
- `src/channels.zig:130` — `UserToolArgs { id, name, args }`
- `src/channels.zig:46` — `ToolErrorKind` enum (4 variants)
- obs#1232 §10 — slice 7 description + FU list
- AGENTS.md §10 — Pre-Merge QA Gate Ordering (builds FIRST)
- AGENTS.md §9 — Task Runner (just recipes)
