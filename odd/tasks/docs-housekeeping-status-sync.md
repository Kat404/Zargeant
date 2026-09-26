# Docs housekeeping — status sync (paths B + C)

**Feature**: `docs-housekeeping-status-sync`
**Type**: Housekeeping (documentation sync + untracked artefact archival)
**Priority**: P2 (correctness/clarity, no functional impact)
**Mode**: ODD (no TDD — pure docs; no RDD — docs-only diff)
**Branch**: `chore/docs-housekeeping-status-sync` (from `main @ 7e5488a`)
**Pre-conditions**: Local == origin/main; working tree clean except 2 untracked files (`.gga/`, `odd/tasks/tool-subprocess-pool.md`)

---

## Goal

Close two housekeeping gaps surfaced during the 2026-09-26 status inventory:

1. **Path B — Untracked artefacts.** `odd/tasks/tool-subprocess-pool.md` (113 lines) is the slice 7 ODD feature doc. The implementation shipped in PR #56 (merged 2026-09-26), but the doc itself was never `git add`-ed before the squash merge, so it is absent from origin/main's tree. Action: archive by committing to the existing convention (completed feature docs live in `odd/tasks/`; no `odd/archive/` convention exists).

2. **Path C — Stale README.md on origin/main.** The README on `origin/main` is stale on four fronts:
   - §Status (line 52) says *"Five of seven planned slices are shipped"* — but all 7 shipped (slice 7 = PR #56).
   - §Status table (line 61) labels TUI as *"🚧 6-PR chain ready, awaiting merge"* — but PRs #31, #32, #34, #35, #36 all MERGED 2026-09-11 (PR #33 closed without merge, superseded by Phase 2).
   - §Road to v1.0 item 1 (line 241) still says *"TUI merge — merge the 6-PR ... chain"* — but TUI is already merged.
   - §Development workflow (lines 247-253) still advertises the SDD cycle — but the project officialised the switch to ODD + TDD + RDD on 2026-09-26 (engram obs#1794).

## Scope

| File                                                | Action                                                                |
| --------------------------------------------------- | --------------------------------------------------------------------- |
| `odd/tasks/tool-subprocess-pool.md`                 | `git add` + commit (no content edit — historical record)              |
| `odd/tasks/docs-housekeeping-status-sync.md`        | `git add` + commit (this feature doc, created in WU-1)                |
| `README.md`                                         | Surgical edits to §Why, §Status, §Slice status — TUI, §Road to v1.0, §Development workflow |

**Out of scope (intentional non-goals for this slice):**

- `.gga/` — local tool config, ignore per `.gitignore` candidate. User decision deferred.
- Branch cleanup (`feat-tclib-pr3..6`, `tui-keyentry-rebuild`, `phase2-slice2/4-clean`, `feat/tool-subprocess-pool-pr1/3`, `feat/tui-ship-fast-phase2*`) — separate housekeeping slice.
- New `odd/archive/` folder — convention doesn't exist; completed docs stay in `odd/tasks/` (verified: phase0/0.5/2/build-blocker-fix all live there).
- README rewrite — surgical refresh only, preserve the existing structure + voice.
- Tech-debt issues #51–#54 — separate slice (path A, ~50 LoC, non-blocking).

## Acceptance criteria

- [ ] `odd/tasks/tool-subprocess-pool.md` is committed to the feature branch with historical fidelity (no content edits — the doc is a snapshot of slice 7's pre-implementation plan, including the "PRE-MERGE" framing).
- [ ] `odd/tasks/docs-housekeeping-status-sync.md` (this file) is committed alongside as the feature doc for this slice.
- [ ] `README.md` §Status reflects: all 7 slices shipped, slice 7 row added (PR #56), Phase 2 row added (PRs #44 + #49 + #50), tech-debt issues linked (#51–#54).
- [ ] `README.md` §Slice status — TUI reflects real merge dates; PR #33 marked as CLOSED (superseded); Phase 2 PRs (#44, #49, #50) appended as additional rows.
- [ ] `README.md` §Road to v1.0 item 1 replaced from "TUI merge" to "Tech debt" (links to #51–#54).
- [ ] `README.md` §Development workflow updated from SDD to ODD + TDD + RDD (per engram obs#1794).
- [ ] `just fmt-check` passes (README.md is a Markdown file — `zig fmt` does not format it, but the QA gate verifies there are no regressions).
- [ ] No AI co-author on commits.
- [ ] Push to origin remains the user's decision (do NOT push in this slice).

## Work-unit breakdown

### WU-1: Archive `tool-subprocess-pool.md` + create this feature doc

**Commits** (1 commit, both files):

```
docs(odd): archive tool-subprocess-pool slice 7 spec + housekeeping task doc

The slice 7 feature doc was lost in the PR #56 squash merge (untracked
in working tree before merge). Archiving as-is for historical fidelity —
the doc is a snapshot of the pre-implementation plan, including the
PRE-MERGE framing.

Also adding the docs-housekeeping-status-sync feature doc that records
the scope and acceptance criteria for paths B + C of the 2026-09-26
status inventory (path A = tech-debt issues #51-54, deferred).
```

### WU-2: Surgical README refresh

**Commits** (1 commit):

```
docs(readme): sync status with shipped slice 7 + Phase 2 retrofit

Four stale sections updated on origin/main:

- §Why: milestone marker updated to "slice 7 PR #56 + Phase 2 PR #50"
- §Status: "Five of seven" → "All seven"; slice 7 row + Phase 2 row added;
  tech-debt issues #51-54 linked
- §Slice status — TUI: real merge dates per PR; PR #33 marked CLOSED
  (superseded by Phase 2); Phase 2 PRs (#44, #49, #50) appended
- §Road to v1.0: "TUI merge" item replaced by "Tech debt" (issues #51-54)
- §Development workflow: SDD → ODD + TDD + RDD per engram obs#1794

No content rewrites — surgical edits only. Preserves existing voice,
structure, and links to engram obs IDs.
```

## Verification

- `just fmt-check` — must pass (no Zig source touched; QA gate for confidence)
- `git log -p` — inspect the diff for accuracy (line-by-line review against the original README)
- Manual cross-check against engram obs#1794 (workflow decision) and obs#1791 (per-slice verdict)

## Risk register

> **R-1 (LOW):** README surgical edits may anchor incorrectly if surrounding context shifts. Mitigation: read full README before editing; use `edit` tool with exact `oldString` matching.

> **R-2 (LOW):** `tool-subprocess-pool.md` contains now-stale references (PRE-MERGE framing, open PR numbers). Decision: archive as-is. Historical fidelity is the value; retrofitting to current state would lose that.

> **R-3 (NEGLIGIBLE):** No Zig source touched → zero compile/test risk. The only QA gate relevant is `just fmt-check` (which checks non-Zig files too in this project, per `zig build check`).

> **R-4 (LOW):** Push to origin is the user's decision. This slice lands the commits locally on the feature branch; push + PR are out of scope per ODD §6.

## References

- Engram obs#1794 — Phase 2 stack landed + PR #50 pending merge (2026-09-30 end-of-session)
- Engram obs#1818 — CI zombies cleanup session summary (2026-09-26)
- Engram obs#1804 — Markdown style preference (rich semantic structure)
- Engram obs#1794 — Workflow decision (SDD → ODD + TDD + RDD)
- `odd/tasks/phase2-build-blocker-fix.md` — precedent for feature doc living in `odd/tasks/` after the work ships
- `odd/tasks/tui-ship-fast-phase{0,0.5,2}.md` — additional precedent (completed feature docs stay in `odd/tasks/`)
- GitHub issues #51, #52, #53, #54 — tech-debt items (path A, deferred)
- PRs #31, #32, #34, #35, #36 — TUI slice merged 2026-09-11
- PR #33 — TUI slice closed without merge (superseded by Phase 2)
- PRs #44, #49, #50 — Phase 2 Tiger Style retrofit
- PR #56 — slice 7 tool subprocess pool (final, comprehensive tests + T-SG-12)
