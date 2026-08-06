## What does this PR change?

<!-- Brief description. -->

## Slice context

<!-- Which SDD cycle? Reference engram observation IDs and commits. -->

- Explore: `engram:sdd/<change>/explore`
- Proposal: `engram:sdd/<change>/proposal`
- Spec: `engram:sdd/<change>/spec`
- Design: `engram:sdd/<change>/design`
- Tasks: `engram:sdd/<change>/tasks`
- Apply: `engram:sdd/<change>/apply-progress`
- Verify: `engram:sdd/<change>/verify-report`
- Archive: `engram:sdd/<change>/archive-report`

## Tests

- [ ] `zig build test --summary all` exits 0
- [ ] `zig build test --summary all -Doptimize=ReleaseSafe` exits 0
- [ ] `zig build test --summary all -Doptimize=ReleaseFast` exits 0
- [ ] New tests written FIRST (RED), then implementation (GREEN), then refactor
- [ ] No `Co-Authored-By: AI` line in commit messages

## Conventional Commit format

- [ ] Title follows `<type>(<scope>): <subject>` (e.g., `feat(logger): add headless /tmp/ai-harness-debug.log`)
- [ ] Type is `feat`, `fix`, `chore`, `docs`, `test`, `refactor`, or `perf`
- [ ] Subject is ≤ 50 chars
- [ ] Body explains WHY (not WHAT — the diff shows what)

## Checklist

- [ ] I've read the related slice's `proposal.md` / `design.md`
- [ ] I've verified the tests fail without my changes
- [ ] I've updated memory if any non-obvious discoveries surfaced
- [ ] I've reviewed my own diff for accidental `Co-Authored-By` lines
