#!/usr/bin/env bash
# tools/local-ci.sh — Local CI parity runner using Podman (--rm, no garbage).
#
# Mirrors .github/workflows/ci.yml with one known workaround:
#   - Runs all available `zig build test-*` targets individually
#     (test-terminal, test-tui, test-tui-runtime-thread, test-api-client,
#      test-tools, test-cancel-e2e, test-cancel-path) which together cover
#     225+ tests.
#   - Runs the embedded src/*.zig tests directly from the cached test binary
#     in standalone mode (197 tests). This bypasses the `zig build test`
#     listen protocol which has a reproducible hang in non-CI environments.
#   - Strict TDD guard (every src/*.zig has test blocks).
#   - No Co-Authored-By AI in commits (origin/main..HEAD).
#   - Zig fmt + ast-check via `zig build check`.
#
# Strategy:
#   - Pre-bake a "zargeant-ci:latest" image with Zig + git + curl installed.
#   - Mount the project + persistent cache dirs for incremental builds.
#   - --rm on every run, no containers left behind.
#
# Usage:
#   ./tools/local-ci.sh                  # full verify equivalent (default)
#   ./tools/local-ci.sh --skip-build     # only fast checks (TDD + co-author)
#   ./tools/local-ci.sh --rebuild        # wipe .zig-cache before build
#   ./tools/local-ci.sh --rebuild-image  # rebuild the Zig image from scratch
#   ./tools/local-ci.sh --shell          # drop into container shell for debug
#   ./tools/local-ci.sh --clean          # remove image + cache (full reset)

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BASE_IMAGE="docker.io/library/alpine:3.20"
readonly CI_IMAGE="localhost/zargeant-ci:latest"
readonly ZIG_VERSION="0.17.0"
readonly CACHE_DIR="${HOME}/.cache/zargeant-podman-ci"
readonly ZIG_CACHE_DIR="${CACHE_DIR}/zig-cache"
readonly GLOBAL_ZIG_CACHE_DIR="${CACHE_DIR}/zig-global-cache"
readonly CONTAINERFILE="${PROJECT_ROOT}/tools/zargeant-ci.Containerfile"

mkdir -p "${ZIG_CACHE_DIR}" "${GLOBAL_ZIG_CACHE_DIR}"

# ─── Argument parsing ─────────────────────────────────────────────────────────
SKIP_BUILD=0
REBUILD=0
REBUILD_IMAGE=0
SHELL_MODE=0
CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)     SKIP_BUILD=1;     shift ;;
    --rebuild)        REBUILD=1;        shift ;;
    --rebuild-image)  REBUILD_IMAGE=1;  shift ;;
    --shell)          SHELL_MODE=1;     shift ;;
    --clean)          CLEAN=1;         shift ;;
    -h|--help)
      sed -n '2,38p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ─── Clean mode ───────────────────────────────────────────────────────────────
if [[ "${CLEAN}" -eq 1 ]]; then
  echo "==> Removing CI image and cache"
  podman rmi -f "${CI_IMAGE}" 2>/dev/null || true
  rm -rf "${CACHE_DIR}"
  echo "✓ Clean"
  exit 0
fi

# ─── Pre-flight: kill orphan descendants of the CI image ─────────────────────
# --rm only catches clean exits; a SIGKILL'd parent `podman run` (or a previous
# `podman rmi -f` racing with a still-running container) leaves zombies that
# re-running this script would detach from a freshly baked image. Clean them
# before any rmi/build/run step.
podman rm -f "$(podman ps -aq --filter "ancestor=${CI_IMAGE}" 2>/dev/null)" 2>/dev/null || true

# ─── Graceful-interrupt trap ──────────────────────────────────────────────────
# On Ctrl-C / SIGTERM, remove any descendant container we left behind so the
# next run starts clean. SIGKILL is still untrappable, but the pre-flight
# above covers that on the next invocation.
cleanup() {
  podman rm -f "$(podman ps -aq --filter "ancestor=${CI_IMAGE}" 2>/dev/null)" 2>/dev/null || true
}
trap cleanup INT TERM

# ─── CI image bake ────────────────────────────────────────────────────────────
NEEDS_BAKE=0
if [[ "${REBUILD_IMAGE}" -eq 1 ]] || ! podman image exists "${CI_IMAGE}" 2>/dev/null; then
  NEEDS_BAKE=1
fi

if [[ "${NEEDS_BAKE}" -eq 1 ]]; then
  echo "==> Baking CI image (Alpine ${BASE_IMAGE##*:} + Zig ${ZIG_VERSION} + git + curl + gcompat)"
  podman rmi -f "${CI_IMAGE}" 2>/dev/null || true
  if [[ ! -f "${CONTAINERFILE}" ]]; then
    echo "ERROR: Containerfile not found at ${CONTAINERFILE}" >&2
    exit 1
  fi
  podman build -t "${CI_IMAGE}" -f "${CONTAINERFILE}" "${PROJECT_ROOT}" 2>&1 | tail -8
  echo "✓ Image baked: ${CI_IMAGE}"
fi

# ─── Wipe project .zig-cache if asked ────────────────────────────────────────
if [[ "${REBUILD}" -eq 1 ]]; then
  echo "==> Wiping project .zig-cache for fresh build"
  rm -rf "${PROJECT_ROOT}/.zig-cache"
fi

# ─── Shared podman args (--rm, mounts, env) ──────────────────────────────────
PODMAN_ARGS=(
  run --rm
  --tmpfs /tmp:rw,size=2g
  -v "${PROJECT_ROOT}:/workspace:rw"
  -v "${ZIG_CACHE_DIR}:/workspace/.zig-cache:rw"
  -v "${GLOBAL_ZIG_CACHE_DIR}:/root/.cache/zig:rw"
  -w /workspace
  -e "ZIG_GLOBAL_CACHE_DIR=/root/.cache/zig"
  -e "ZIG_LOCAL_CACHE_DIR=/workspace/.zig-cache"
  -e "ZARGEANT_RUN_TUI_CANCEL_E2E=1"
)

# ─── Shell mode ──────────────────────────────────────────────────────────────
if [[ "${SHELL_MODE}" -eq 1 ]]; then
  echo "==> Dropping into shell inside ${CI_IMAGE}"
  exec podman "${PODMAN_ARGS[@]}" -it "${CI_IMAGE}" bash
fi

# ─── CI verification ─────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
echo " Local CI (Podman, --rm, no garbage)"
echo " Image:  ${CI_IMAGE}"
echo " Zig:    $(podman run --rm "${CI_IMAGE}" zig version)"
echo " Build:  $([[ ${SKIP_BUILD} -eq 1 ]] && echo SKIP || echo RUN)"
echo "════════════════════════════════════════════════════════════════"

FAILED=0
PASSED=0

# Per-step wall-clock ceiling. Without it a single hung step (a test that
# blocks on a pipe, a build that waits on a lock) stalls the whole CI
# silently — the container keeps running and nothing reports progress.
# Generous enough for the 3-mode builds, short enough to fail the run
# instead of hanging forever.
readonly STEP_TIMEOUT="${STEP_TIMEOUT:-600}"

run_step() {
  local label="$1"; shift
  echo ""
  echo "─── ${label} ───"
  if timeout --signal=TERM --kill-after=30 "${STEP_TIMEOUT}" "$@"; then
    echo "✓ ${label} PASSED"
    PASSED=$((PASSED + 1))
  else
    local rc=$?
    if [[ "${rc}" -eq 124 || "${rc}" -eq 137 ]]; then
      echo "✗ ${label} TIMED OUT after ${STEP_TIMEOUT}s"
    else
      echo "✗ ${label} FAILED (exit ${rc})"
    fi
    FAILED=$((FAILED + 1))
  fi
}

# Step 1: QA 0 — format + ast-check
run_step "QA 0: zig build check (fmt + ast-check)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c 'zig build check'

# Step 2: QA 0.5 — forbidden syscalls (mirror of GitHub Actions step)
run_step "QA 0.5: forbidden syscall guard" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c '
    set -e
    matches=$(grep -rn "std\.os\.linux\.\(socket\|connect\|bind\|listen\)" src/ --include="*.zig" --exclude="mock_server.zig" --exclude="fixtures_test.zig" 2>/dev/null | grep -v "// allowed:" || true)
    if [ -n "$matches" ]; then
      echo "FORBIDDEN: std.os.linux.{socket,connect,bind,listen} found outside mock_server.zig:"
      echo "$matches"
      exit 1
    fi
    echo "OK — no forbidden syscalls"
  '

# Step 3: individual test targets (bypass the listen-protocol hang)
run_step "test-terminal (140 tests, in-tree src/terminal/)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c 'zig build test-terminal --summary all'

run_step "test-tui (3 tests, terminal smoke canary)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c 'zig build test-tui --summary all'

run_step "test-tui-screen-grid (T-2.1.x + T-2.2.1, Phase 2 ScreenGrid + diffAndEmit)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c 'zig build test-tui-screen-grid --summary all'

run_step "test-tui-runtime-thread (69 tests, Phase 0+0.5 TUI fixes)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c 'zig build test-tui-runtime-thread --summary all'

run_step "test-api-client (3 tests, socket guard)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c 'zig build test-api-client --summary all'

run_step "test-tools (4 tests, tools/ in-file)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c 'zig build test-tools --summary all'

run_step "test-cancel-path (4 tests, CAP-09 wiring guard)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c 'zig build test-cancel-path --summary all'

# S1/WU-1.1 (P0-01 + P0-02 sandbox fail-closed restoration) — isolation
# order guard. Asserts child-block PR_SET_NO_NEW_PRIVS precedes
# Landlock.restrictSelf, and that sandbox_linux.Seccomp.loadFilter is
# invoked (replaces inline `_ = seccomp(...)` that swallowed rc).
run_step "test-sandbox-order (2 tests, S1/WU-1.1 isolation order guard)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c 'zig build test-sandbox-order --summary all'

run_step "test-cancel-e2e (2 tests, end-to-end cancel pipe)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c 'zig build test-cancel-e2e --summary all'

# Step 4: src/*.zig embedded tests (224) via the `test-embedded` build step.
#
# The umbrella artifact used to hang here: `zig build test` put the test
# artifact in stdio = .zig_test, which speaks the std.zig.Server protocol
# over stdio, and that handshake never completed inside this container.
# The build now runs the umbrella artifact with stdio = .inherit (exec the
# binary directly), so this step is a plain build step with no timeout
# hack. See AGENTS.md section 9.2.
if [[ "${SKIP_BUILD}" -eq 1 ]]; then
  echo ""
  echo "─── src/*.zig embedded tests (224) SKIPPED (--skip-build) ───"
else
  set +e
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c '
    zig build test-embedded --summary all 2>&1
  ' > /tmp/embedded-test.log 2>&1
  EXIT_CODE=$?
  set -e
  echo ""
  echo "─── src/*.zig embedded tests (224, via zig build test-embedded) ───"
  if [[ ${EXIT_CODE} -eq 0 ]]; then
    grep -E "Build Summary|tests passed" /tmp/embedded-test.log | head -3
    echo "✓ src/*.zig embedded tests PASSED"
    PASSED=$((PASSED + 1))
  else
    echo "ⓘ src/*.zig embedded tests FAILED — see /tmp/embedded-test.log"
    echo "  Note: a sandboxed child that cannot execve exits 127 (the exec"
    echo "  failed), and one that cannot install its seccomp filter exits"
    echo "  123. Both are environment-shaped failures, but neither is"
    echo "  automatically 'not the code' — read the log before assuming it."
    echo "  See: cat /tmp/embedded-test.log | tail -10"
    FAILED=$((FAILED + 1))
  fi
fi

# Step 5: strict TDD guard
run_step "Strict TDD guard (every src/*.zig has test blocks)" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c '
    missing=""
    for f in src/*.zig; do
      tests=$(grep -c "^test " "$f" || true)
      if [ "$tests" -eq 0 ]; then missing="$missing $f"; fi
    done
    if [ -n "$missing" ]; then echo "FAIL: src files missing tests:$missing"; exit 1; fi
    echo "OK — all src/*.zig have test blocks"
  '

# Step 6: co-author guard
run_step "Co-Authored-By AI guard" \
  podman "${PODMAN_ARGS[@]}" "${CI_IMAGE}" bash -c '
    if git log --format="%B" origin/main..HEAD | grep -iE "Co-Authored-By:.*(Claude|MiniMax|Anthropic|AI)"; then
      echo "FAIL: AI co-author found in commits"
      exit 1
    fi
    echo "OK — no AI co-author lines"
  '

echo ""
echo "════════════════════════════════════════════════════════════════"
if [[ "${FAILED}" -eq 0 ]]; then
  echo " ✓ Local CI PASSED — ${PASSED} steps OK (cache: ${CACHE_DIR})"
  echo "════════════════════════════════════════════════════════════════"
  exit 0
else
  echo " ✗ Local CI FAILED — ${FAILED} failures, ${PASSED} passes"
  echo "════════════════════════════════════════════════════════════════"
  exit 1
fi
