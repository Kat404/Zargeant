# justfile — Zargeant task runner
#
# Quick recipes for the most common Zargeant workflows. Mirrors and supersedes
# the verbose zig build invocations + the Podman local CI runner.
#
# Usage:
#   just                     # show this help (default)
#   just <recipe>            # run a recipe
#   just -u                  # show inline docs for each recipe
#
# Conventions:
#   - All recipes are idempotent (safe to re-run).
#   - Test recipes avoid `zig build test` (Zig 0.16.0 `--listen=-` IPC bug)
#     by invoking each `zig build test-*` target individually.
#   - The Podman CI recipes wrap `tools/local-ci.sh` (Alpine + Zig 0.16.0,
#     --rm no garbage) for full parity with GitHub Actions.

set dotenv-load := false
set shell := ["bash", "-uc"]
set positional-arguments := true

# Paths — used via {{var}} interpolation in recipe bodies.
# NOTE: justfile variables can NOT appear in recipe prerequisite lists,
# so the CI recipes don't declare `tools/local-ci.sh` as a prerequisite
# (just checks the file at runtime via the literal call, which fails
# naturally if the file is missing).
ci_sh := "./tools/local-ci.sh"

# ─── Meta ────────────────────────────────────────────────────────────────────

# List all available recipes (default)
default:
    @just --list --unsorted

# Show this help with full inline comments
help:
    @just --help

# ─── Build ───────────────────────────────────────────────────────────────────

# Compile debug binary (zig build) — fastest iteration
build:
    zig build

# Compile ReleaseSafe binary — production parity without ReleaseFast LTO
build-safe:
    zig build -Doptimize=ReleaseSafe

# Compile ReleaseFast binary — fully optimized, may need separate verify
build-fast:
    zig build -Doptimize=ReleaseFast

# Wipe build artifacts (.zig-cache + zig-out) — forces fresh compile next time
clean:
    rm -rf .zig-cache zig-out

# ─── Run ─────────────────────────────────────────────────────────────────────

# Run the production binary
run *args:
    zig build run {{args}}

# Run with mock server (no real HTTP, for offline TUI testing)
run-mock:
    zig build run -- --mock

# ─── Test (bypasses zig build test --listen=- bug) ───────────────────────────

# Run all individual test targets — fast, no IPC hang
test:
    just test-terminal
    just test-tui
    just test-runtime-thread
    just test-api-client
    just test-tools
    just test-cancel-path
    just test-cancel-e2e

# Run the in-tree src/terminal/ + tests/terminal/ in isolation (140 tests)
test-terminal:
    zig build test-terminal --summary all

# Run tests/tui/terminal_smoke.zig (3 tests, public-surface compile guard)
test-tui:
    zig build test-tui --summary all

# Run tests/tui/screen_grid.zig (T-2.1.1 — Phase 2 ScreenGrid value type)
test-tui-screen-grid:
    zig build test-tui-screen-grid --summary all

# Run tests/tui/runtime_thread.zig (69 tests, PR1+PR1.5 TUI fix coverage)
test-runtime-thread:
    zig build test-tui-runtime-thread --summary all

# Run tests/api_client.zig (3 tests, REQ-NEW-003 socket guard)
test-api-client:
    zig build test-api-client --summary all

# Run tools/ in-file tests (4 tests)
test-tools:
    zig build test-tools --summary all

# Run tests/tui/cancel_path.zig (4 tests, CAP-09 wiring guard)
test-cancel-path:
    zig build test-cancel-path --summary all

# Run tests/cancel_e2e.zig (2 tests, end-to-end cancel pipe, env-gated)
test-cancel-e2e:
    ZARGEANT_RUN_TUI_CANCEL_E2E=1 zig build test-cancel-e2e --summary all

# Run src/*.zig embedded tests via standalone binary (workaround for listen IPC bug)
test-embedded:
    #!/usr/bin/env bash
    set -euo pipefail
    # Step A: trigger compilation via timeout — listen IPC hangs after compile
    timeout 10 zig build test --summary all > /dev/null 2>&1 || true
    # Step B: pick the largest test binary (embedded src/*.zig ~197 tests)
    bin=""
    best_count=0
    for b in $(find .zig-cache/o -name "test" -type f -executable 2>/dev/null); do
        ntests=$(timeout 15 "$b" 2>/dev/null | grep -cE "^[0-9]+/[0-9]+ " || true)
        if [ "$ntests" -gt "$best_count" ]; then
            best_count=$ntests
            bin="$b"
        fi
    done
    if [ -z "$bin" ] || [ "$best_count" -lt 50 ]; then
        echo "FAIL: no embedded-tests binary found (best: $best_count tests)" >&2
        exit 1
    fi
    echo "Running $bin ($best_count tests)"
    timeout 60 "$bin" 2>&1 | tail -5

# Full test suite: targets individually + embedded workaround
test-all:
    just test
    just test-embedded

# ─── QA / verify ─────────────────────────────────────────────────────────────

# Run the strict QA gamut (QA 0..6, compile-first in Debug + ReleaseSafe + ReleaseFast)
verify:
    zig build verify

# Check formatting + AST (QA 0)
fmt-check:
    zig build check

# Auto-format Zig sources in place (run from repo root)
fmt:
    zig fmt src/ tests/ tools/

# Forbidden syscall guard (QA 0.5 — REQ-NEW-003)
check-syscalls:
    zig build check-forbidden-syscalls

# Strict TDD guard: every src/*.zig must contain at least one test block
check-tdd:
    #!/usr/bin/env bash
    set -euo pipefail
    missing=""
    for f in src/*.zig; do
        tests=$(grep -c '^test ' "$f" || true)
        if [ "$tests" -eq 0 ]; then missing="$missing $f"; fi
    done
    if [ -n "$missing" ]; then
        echo "FAIL: src files missing test blocks:$missing" >&2
        exit 1
    fi
    echo "OK — all src/*.zig have test blocks"

# Co-Authored-By AI guard: no AI co-author lines in commits ahead of main
check-coauthor:
    #!/usr/bin/env bash
    set -euo pipefail
    bad=$(git log --format='%B' origin/main..HEAD 2>/dev/null \
          | grep -iE 'Co-Authored-By:.*(Claude|MiniMax|Anthropic|AI)' || true)
    if [ -n "$bad" ]; then
        echo "FAIL: AI co-author found in commits" >&2
        echo "$bad" >&2
        exit 1
    fi
    echo "OK — no AI co-author lines"

# Run every static guard (fmt + syscalls + TDD + co-author)
check: fmt-check check-syscalls check-tdd check-coauthor

# ─── Local CI (Podman, Alpine, --rm) ─────────────────────────────────────────

# Run the full local CI suite via Podman (Alpine + Zig 0.16.0, --rm no garbage)
ci:
    {{ci_sh}}

# Fast local CI: skip the heavy build steps, only run static guards
ci-fast:
    {{ci_sh}} --skip-build

# Rebuild project .zig-cache before running CI (forces fresh compile of changed code)
ci-rebuild:
    {{ci_sh}} --rebuild

# Force rebuild of the Podman image itself (Alpine + Zig version bump, etc)
ci-rebuild-image:
    {{ci_sh}} --rebuild-image

# Drop into a shell inside the CI image for debugging
ci-shell:
    {{ci_sh}} --shell

# Wipe the CI image + cache (full reset)
ci-clean:
    {{ci_sh}} --clean

# ─── Git ─────────────────────────────────────────────────────────────────────

# Show working tree status + ahead/behind main
git-status:
    @git status --short
    @echo "--- ahead/behind main ---"
    @git rev-list --left-right --count origin/main...HEAD 2>/dev/null || \
        git rev-list --left-right --count main...HEAD

# List commits on this branch that aren't in origin/main
git-log:
    git log --oneline origin/main..HEAD 2>/dev/null || git log --oneline main..HEAD

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Show ODD feature docs (working memory for substantial changes)
odd:
    @ls -la odd/tasks/

# Show this help
list:
    @just --list
