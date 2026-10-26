# S1/WU-1.1 — Sandbox fail-closed restoration

**Feature**: `s1-wu-1.1-sandbox-fail-closed` (mirror de ODD-REMEDIATION-PLAN §S1/WU-1.1)
**Mode**: ODD + Strict TDD (RED→GREEN)
**Source-of-truth priority**: code > plan > this feature doc. If they conflict, code wins and this doc is updated.
**Branch**: `s1-wu-1.1-sandbox-fail-closed` (off `origin/main @ 588b439`)

## Goal

Restore the isolation order (`caps → PR_SET_NO_NEW_PRIVS → landlock → seccomp → execve`) and fail-closed behavior on every step. Closes **P0-01** (Landlock never applied in fail-open) and **P0-02** (seccomp return-code discarded in fail-open).

## Etapa 1 verification (2026-09-29)

Verified against the code:

| Claim (plan + audit) | Reality |
|---|---|
| `sandbox.zig:755` `restrictSelf` called BEFORE `PR_SET_NO_NEW_PRIVS` | ✅ Confirmed. `restrictSelf` at `:755`, prctl(NO_NEW_PRIVS) at `:772` — 17 lines apart, wrong order. |
| `sandbox.zig:755` error swallowed with `catch {}` | ✅ Confirmed: `_ = sandbox_linux.Landlock.restrictSelf(applied.landlock_fd) catch {};` |
| `sandbox.zig:772` prctl return discarded | ✅ Confirmed: `_ = std.os.linux.prctl(...)` |
| `sandbox.zig:782-786` seccomp return discarded | ✅ Confirmed: `_ = std.os.linux.seccomp(...)` |
| `sandbox_linux.zig:234` `Seccomp.loadFilter` exists and checks both rc + sets NO_NEW_PRIVS | ✅ Confirmed (lines 234-248) |
| `Seccomp.loadFilter` is dead code | ✅ Confirmed: 1 definition, 0 call sites (only mentioned in `AUDIT-REPORT.md:144,146` and `ODD-REMEDIATION-PLAN.md:260`) |
| `runtime.zig:1108` `SubprocessExit` enum | ✅ Confirmed: 3 variants `exited`, `signaled_other`, `sigsys_sandbox` — NO `sandbox_setup_failed` |
| `channels.zig:57-62` `ToolErrorKind` enum | ✅ Confirmed: 4 variants `spawn_failed`, `timeout`, `nonzero_exit`, `sandbox_violation` — NO `sandbox_setup_failed` |
| Plan's example `exit_group(125)` for buildFromProfile fail | ⚠️ Current code already does `exit_group(1)` at `sandbox.zig:745`. Drift — keeping the existing code, only changing semantics for the OTHER paths. |

## Drift (out of scope, NOT fixed in this WU)

1. **`sandbox.zig:107`** comment lies: `26, // ptrace -- NO, denied` but 26 is IN the allowlist array. This is a P5 finding, not P0-01. Tracked separately.
2. **`sandbox.zig:762-768`** duplicated comment in close_range. Cosmetic. Tracked separately.
3. **`sandbox.zig:508-510`** `startup_allow_syscalls` is hardcoded, not profile-driven. P0-05 finding. Tracked separately.
4. **Existing tests `sandbox.zig:872-940`** pass via Unix permissions, not Landlock (P5-04). The fix in this WU doesn't break them; they're orthogonal.

## Scope of WU-1.1

Per `ODD-REMEDIATION-PLAN.md §S1/WU-1.1`:

### Files modified

| File | Change |
|---|---|
| `src/sandbox.zig` | Reorder `:744-786`: `prctl(NO_NEW_PRIVS)` FIRST, then `Landlock.restrictSelf` (fail-closed), then `close_range`, then `Seccomp.loadFilter(&tool_bpf_prog)` (replaces inline seccomp + swallows errors). Distinct `exit_group` codes per failure mode. |
| `src/channels.zig` | Add `sandbox_setup_failed` to `ToolErrorKind` (5th variant). |
| `src/runtime.zig` | `toolsWorkerMain` (`:1008-1047`): when `wait_status & 0x7f == 0` AND exit code in {123, 124, 125, 126} → emit `ToolError.kind = .sandbox_setup_failed` with code-aware message. |
| `build.zig` | Add `sandbox_order_test_mod` + `test-sandbox-order` step, depend on umbrella `test_decl`. |
| `justfile` | Add `test-sandbox-order` recipe. |
| `tests/sandbox_order.zig` | NEW file with the structural RED test (per plan). |

### Test RED

Per plan:

```zig
test "PR_SET_NO_NEW_PRIVS se establece ANTES de landlock_restrict_self" {
    const src = @embedFile("../src/sandbox.zig");
    const prctl_idx = std.mem.indexOf(u8, src, "PR_SET_NO_NEW_PRIVS") orelse return error.NotFound;
    const restrict_idx = std.mem.indexOf(u8, src, "restrictSelf") orelse return error.NotFound;
    try testing.expect(prctl_idx < restrict_idx);
}
```

> ⚠️ This is a grep-test. Acceptable HERE because the order of two syscalls is a structural property, and an empirical test would require a kernel with Landlock in a privileged container (not available in CI).
> The empirical test from AUDIT-REPORT P0-01 (real fork + read `/etc/hostname` = 0 bytes) is BETTER but requires a kernel in CI that supports Landlock from the test runner. Documented as a follow-up if/when CI gains that capability.

### Test verification matrix

- BEFORE fix: `prctl_idx > restrict_idx` → `expect` fails → RED captured.
- AFTER fix: `prctl_idx < restrict_idx` → `expect` passes → GREEN captured.

### Exit code conventions (per plan §"Nota sobre el exit code")

| Code | Meaning |
|---|---|
| 1 | (legacy) `buildFromProfile` failed |
| 123 | `Seccomp.loadFilter` failed |
| 124 | `Landlock.restrictSelf` failed |
| 125 | (unused — kept for symmetry; `buildFromProfile` still uses 1) |
| 126 | `prctl(PR_SET_NO_NEW_PRIVS)` failed |
| 127 | (legacy) `execve` failed |

> Refining the plan's example: keep `buildFromProfile` exit code at `1` (existing behavior) rather than migrating to `125`. Adding a new code (125) would break the assumption that any non-{123,124,126} code at this point is a "binario corrió y falló" signal. Documented as plan simplification — `1` stays.

## Risks

> **R-1 (LOW)**: Adding a 5th variant to `ToolErrorKind` forces every exhaustive switch in the codebase to handle it. Mitigation: grep for `ToolErrorKind` usages before commit; update all switch arms.
>
> **R-2 (LOW)**: `runtime.zig:toolsWorkerMain` is large (~200 LoC). Mitigation: add the new branch AFTER the existing `wait_status` cascade, never replace; smoke-test with the existing tests (`tests/tui/runtime_thread.zig`).
>
> **R-3 (NEGLIGIBLE)**: RED test is grep-based; a sufficiently motivated refactor could pass the grep without restoring the actual order. Mitigation: peer review of the diff and the inline comment block. Empirical fork-test deferred to a CI with Landlock kernel.

## Verification

- `just test-sandbox-order` → RED then GREEN
- `just build && just build-safe && just build-fast` (AGENTS.md §10 order)
- `just check`
- `just test-all` (umbrella + embedded)
- `just verify` (3-mode compile)
- `just ci` (Podman Alpine independent verification)

## References

- `ODD-REMEDIATION-PLAN.md §S1/WU-1.1` (lines 88-176)
- `AUDIT-REPORT.md §P0-01` (lines 40-136) + §P0-02 (lines 138-176)
- `AGENT-AUDIT-PROTOCOL.md §3, §4`
- `sandbox.zig:744-786` (current wrong order)
- `sandbox_linux.zig:234-248` (`Seccomp.loadFilter` — adopted in this WU)
- `runtime.zig:1008-1047` (tool worker wait-status cascade — extended)
- `channels.zig:57-62` (`ToolErrorKind` — extended)