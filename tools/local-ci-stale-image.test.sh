#!/usr/bin/env bash
# tools/local-ci-stale-image.test.sh — behavioral regression guard for S5.
#
# S5 (odd/tasks/zig-0.17.1-toolchain-bump.md): `tools/local-ci.sh` must
# re-bake the Podman CI image whenever the Zig version *inside* the image is
# not the one the script expects. A stale image silently verifies the OLD
# toolchain — `build.zig.zon`'s `.minimum_zig_version` is a pin, not a guard
# (log L12) — which is exactly how the repo managed to declare Zig 0.17.1
# while the local CI was still verifying 0.17.0 (log L11).
#
# This guard exercises `tools/local-ci.sh` with a **stubbed** `podman`.
# It never touches the real podman, the real image, the network or the repo:
#   - the child runs under `env -i` with a controlled PATH/HOME/TMPDIR, so
#     nothing from the user's environment leaks in;
#   - that PATH is a symlink sandbox holding only the handful of coreutils
#     the script under test needs, so the real `podman` is unreachable by
#     name (it is resolved to the stub instead);
#   - the stub logs every invocation to a file inside the scratch dir, and
#     the assertions inspect that log.
#
# Cases (each one is a hard failure — non-zero exit + a clear message — if
# the behavior regresses):
#   1. image already carries the expected Zig -> NO bake (`podman build`
#      must not appear in the stub log)
#   2. image carries a different Zig           -> bake + re-bake message
#      naming both versions
#   3. `podman run` fails (image unreadable)    -> NO abort, fail-safe bake,
#      exit 0
#   4. `podman build` fails                     -> non-zero exit and NO
#      version banner (no green banner over a failed bake)
#   5. `--rebuild-image`                        -> forces the bake and skips
#      the version probe
#   6. `--clean`                                -> exit 0, no probe at all
#
# Usage: tools/local-ci-stale-image.test.sh
# Exit:   0 = every case passed, 1 = at least one regression, 2 = setup error.

set -euo pipefail

# ─── Repo root, resolved from this script's own location ─────────────────────
# Works from any cwd: the script under test is located through BASH_SOURCE.
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT_UNDER_TEST="${REPO_ROOT}/tools/local-ci.sh"

if [[ ! -f "${SCRIPT_UNDER_TEST}" ]]; then
  echo "FATAL: script under test not found: ${SCRIPT_UNDER_TEST}" >&2
  exit 2
fi

# The expected Zig version is read from the script under test, so this guard
# stays valid across toolchain bumps (it compares behavior, not a literal).
EXPECTED_ZIG="$(grep -m1 -E '^readonly ZIG_VERSION="' "${SCRIPT_UNDER_TEST}" \
  | sed -E 's/^readonly ZIG_VERSION="([^"]*)"$/\1/' || true)"
if [[ -z "${EXPECTED_ZIG}" ]]; then
  echo "FATAL: cannot read ZIG_VERSION from ${SCRIPT_UNDER_TEST}" >&2
  exit 2
fi
# A deliberately different version, used as the "stale image" content.
readonly STALE_ZIG="0.17.0"
if [[ "${STALE_ZIG}" == "${EXPECTED_ZIG}" ]]; then
  echo "FATAL: STALE_ZIG must differ from EXPECTED_ZIG (${EXPECTED_ZIG})" >&2
  exit 2
fi

# ─── Scratch (outside the worktree) ──────────────────────────────────────────
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-stale-image.XXXXXX")"
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "${SCRATCH:-}" && -d "${SCRATCH}" \
        && "${SCRATCH}" == *"/local-ci-stale-image."* ]]; then
    rm -rf -- "${SCRATCH}"
  fi
  exit "${rc}"
}
trap cleanup EXIT

readonly STUB_BIN="${SCRATCH}/stub-bin"
readonly SANDBOX_BIN="${SCRATCH}/sandbox-bin"
mkdir -p "${STUB_BIN}" "${SANDBOX_BIN}"

# ─── PATH sandbox: only the coreutils the script under test needs ────────────
# No `podman` here: the real one lives in /usr/bin, which is NOT in this PATH,
# so the child can only reach the stub.
for tool in bash env timeout tail grep sed head cat rm mkdir dirname; do
  tool_path="$(command -v "${tool}" || true)"
  if [[ -z "${tool_path}" ]]; then
    echo "FATAL: required tool not found on this host: ${tool}" >&2
    exit 2
  fi
  ln -s "${tool_path}" "${SANDBOX_BIN}/${tool}"
done

# ─── The `podman` stub ───────────────────────────────────────────────────────
# It only writes to the files it is given through the environment; it never
# touches a real podman, a real image or the network.
cat > "${STUB_BIN}/podman" <<'STUB_EOF'
#!/usr/bin/env bash
# Stubbed `podman` for tools/local-ci-stale-image.test.sh.
#
# Environment contract (all provided by the test harness):
#   PODMAN_STUB_LOG         file every invocation is appended to (required)
#   PODMAN_STUB_STATE_DIR    scratch dir for the stub's own marker files
#   PODMAN_STUB_IMAGE_ZIG    version printed by `podman run … zig version`
#   PODMAN_STUB_IMAGE_EXISTS 1 (default) => `podman image exists` succeeds
#   PODMAN_STUB_RUN_FAIL_MODE  none | until-build | always
#   PODMAN_STUB_BUILD_FAILS  1 => `podman build` fails
set -euo pipefail

: "${PODMAN_STUB_LOG:?stub podman requires PODMAN_STUB_LOG}"
: "${PODMAN_STUB_STATE_DIR:?stub podman requires PODMAN_STUB_STATE_DIR}"

printf 'podman %s\n' "$*" >> "${PODMAN_STUB_LOG}"

subcommand="${1:-}"
case "${subcommand}" in
  image)
    # `podman image exists <ref>`
    if [[ "${2:-}" == "exists" ]]; then
      if [[ "${PODMAN_STUB_IMAGE_EXISTS:-1}" == "1" ]]; then
        exit 0
      fi
      exit 1
    fi
    exit 0
    ;;
  ps)
    # `podman ps -aq --filter …` -> no containers
    exit 0
    ;;
  rm|rmi)
    exit 0
    ;;
  build)
    if [[ "${PODMAN_STUB_BUILD_FAILS:-0}" == "1" ]]; then
      echo "stub podman: simulated build failure" >&2
      exit 1
    fi
    : > "${PODMAN_STUB_STATE_DIR}/built"
    echo "stub podman: image built"
    exit 0
    ;;
  run)
    # The version probe/banner is exactly `… <image> zig version`.
    if [[ "${*: -2}" == "zig version" ]]; then
      fail_mode="${PODMAN_STUB_RUN_FAIL_MODE:-none}"
      if [[ "${fail_mode}" == "always" ]]; then
        echo "stub podman: simulated probe failure (cannot read image)" >&2
        exit 1
      fi
      if [[ "${fail_mode}" == "until-build" && ! -f "${PODMAN_STUB_STATE_DIR}/built" ]]; then
        echo "stub podman: simulated probe failure (cannot read image)" >&2
        exit 1
      fi
      printf '%s\n' "${PODMAN_STUB_IMAGE_ZIG:-0.17.1}"
      exit 0
    fi
    # Every CI step (`podman run … bash -c '…'`) is a no-op success.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB_EOF
chmod +x "${STUB_BIN}/podman"

# ─── Tiny TAP-ish harness ────────────────────────────────────────────────────
ASSERT_N=0
ASSERT_FAIL=0

# Per-case state, filled by run_ci().
CASE_DIR=""
CASE_LOG=""
CASE_OUT=""
CASE_ERR=""
CASE_RC=0

# run_ci <case-name> [VAR=VALUE …] -- <args for local-ci.sh>
CASE_ENV=()
run_ci() {
  local case_name="$1"
  shift
  CASE_ENV=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    CASE_ENV+=("$1")
    shift
  done
  if [[ "${1:-}" == "--" ]]; then shift; fi

  CASE_DIR="${SCRATCH}/case-${case_name}"
  mkdir -p "${CASE_DIR}/home" "${CASE_DIR}/tmp" "${CASE_DIR}/state"
  CASE_LOG="${CASE_DIR}/podman.log"
  CASE_OUT="${CASE_DIR}/stdout.log"
  CASE_ERR="${CASE_DIR}/stderr.log"
  : > "${CASE_LOG}"

  set +e
  /usr/bin/env -i \
    PATH="${STUB_BIN}:${SANDBOX_BIN}" \
    HOME="${CASE_DIR}/home" \
    TMPDIR="${CASE_DIR}/tmp" \
    STEP_TIMEOUT="15" \
    PODMAN_STUB_LOG="${CASE_LOG}" \
    PODMAN_STUB_STATE_DIR="${CASE_DIR}/state" \
    "${CASE_ENV[@]}" \
    bash "${SCRIPT_UNDER_TEST}" "$@" > "${CASE_OUT}" 2> "${CASE_ERR}"
  CASE_RC=$?
  set -e
}

# ─── Predicates over the per-case state ──────────────────────────────────────
rc_is_zero()      { [[ "${CASE_RC}" -eq 0 ]]; }
rc_is_nonzero()   { [[ "${CASE_RC}" -ne 0 ]]; }
out_has()         { grep -qF -- "$1" "${CASE_OUT}"; }
out_lacks()       { ! grep -qF -- "$1" "${CASE_OUT}"; }
# A bake is exactly one stub-log line starting with "podman build ".
log_has_bake()    { grep -q '^podman build ' "${CASE_LOG}"; }
log_lacks_bake()  { ! grep -q '^podman build ' "${CASE_LOG}"; }
# The version probe (and the banner) are `podman run … <image> zig version`.
log_has_probe()   { grep -qE '^podman run .* zig version$' "${CASE_LOG}"; }
log_lacks_run()   { ! grep -qE '^podman run ' "${CASE_LOG}"; }
# No version probe may happen before the bake (that is what --rebuild-image
# has to skip: the probe decides whether to bake, so it must not run first).
no_probe_before_bake() {
  local bake_line probe_lines
  bake_line="$(awk '/^podman build /{print NR; exit}' "${CASE_LOG}")"
  [[ -n "${bake_line}" ]] || return 1
  probe_lines="$(awk -v limit="${bake_line}" \
    'NR < limit && /^podman run .* zig version$/{print NR}' "${CASE_LOG}")"
  [[ -z "${probe_lines}" ]]
}

# dump_file <path> <max lines> — echo a file as TAP comments (never fails).
dump_file() {
  local path="$1" max="$2"
  if [[ -n "${path}" && -f "${path}" ]]; then
    sed 's/^/#   /' "${path}" | head -"${max}" || true
  fi
}

assert() {
  local desc="$1"; shift
  ASSERT_N=$((ASSERT_N + 1))
  if "$@"; then
    printf 'ok %d - %s\n' "${ASSERT_N}" "${desc}"
  else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    printf 'not ok %d - %s\n' "${ASSERT_N}" "${desc}"
    printf '#   exit code: %s\n' "${CASE_RC}"
    printf '#   --- stdout ---\n'
    dump_file "${CASE_OUT}" 30
    printf '#   --- stderr ---\n'
    dump_file "${CASE_ERR}" 15
    printf '#   --- podman stub log ---\n'
    dump_file "${CASE_LOG}" 30
  fi
}

printf '# tools/local-ci-stale-image.test.sh — S5 behavioral guard\n'
printf '# expected Zig in tools/local-ci.sh: %s\n' "${EXPECTED_ZIG}"
printf '# script under test: %s\n' "${SCRIPT_UNDER_TEST}"
printf '# sandbox PATH: %s:%s (no real podman)\n' "${STUB_BIN}" "${SANDBOX_BIN}"
printf '\n'

# ─── Case 0: the real podman is unreachable ──────────────────────────────────
# The child PATH must resolve `podman` to the stub and to nothing else.
RESOLVED_PODMAN="$(/usr/bin/env -i PATH="${STUB_BIN}:${SANDBOX_BIN}" \
  /usr/bin/env bash -c 'command -v podman' || true)"
podman_resolves_to_stub() { [[ "${RESOLVED_PODMAN}" == "${STUB_BIN}/podman" ]]; }
sandbox_has_no_real_podman() { [[ ! -e "${SANDBOX_BIN}/podman" ]]; }
assert "sandbox PATH resolves podman to the stub (${RESOLVED_PODMAN})" \
  podman_resolves_to_stub
assert "sandbox PATH carries no real podman" sandbox_has_no_real_podman

# ─── Case 1: image already at the expected Zig -> NO bake ────────────────────
printf '# case 1: image already carries Zig %s\n' "${EXPECTED_ZIG}"
run_ci "1-match" "PODMAN_STUB_IMAGE_ZIG=${EXPECTED_ZIG}" -- --skip-build
assert "case 1: script exits 0" rc_is_zero
assert "case 1: stub log has NO 'podman build' line (no re-bake)" log_lacks_bake
assert "case 1: stub log shows the version probe did run" log_has_probe
assert "case 1: stdout has NO re-bake message" out_lacks "re-baking"
assert "case 1: stdout reached the CI banner" out_has "Local CI (Podman"

# ─── Case 2: image carries a different Zig -> bake + message ────────────────
printf '# case 2: image carries Zig %s (stale)\n' "${STALE_ZIG}"
run_ci "2-mismatch" "PODMAN_STUB_IMAGE_ZIG=${STALE_ZIG}" -- --skip-build
assert "case 2: script exits 0" rc_is_zero
assert "case 2: stub log HAS a 'podman build' line (re-bake)" log_has_bake
assert "case 2: stdout names the stale version" \
  out_has "CI image has Zig ${STALE_ZIG}"
assert "case 2: stdout names the expected version" \
  out_has "expected ${EXPECTED_ZIG}"
assert "case 2: stdout has the re-bake message" \
  out_has "CI image has Zig ${STALE_ZIG}, expected ${EXPECTED_ZIG}: re-baking"
assert "case 2: stdout confirms the bake" out_has "Image baked"

# ─── Case 3: `podman run` fails (probe cannot read the image) ───────────────
# Fail-safe direction: an unreadable image must not abort the script, it must
# re-bake (the mismatch direction) and still finish with exit 0.
printf '# case 3: podman run fails (image unreadable) -> fail-safe re-bake\n'
run_ci "3-probe-fails" \
  "PODMAN_STUB_IMAGE_ZIG=${STALE_ZIG}" \
  "PODMAN_STUB_RUN_FAIL_MODE=until-build" -- --skip-build
assert "case 3: script does NOT abort (exit 0)" rc_is_zero
assert "case 3: script continued past the probe (banner reached)" \
  out_has "Local CI (Podman"
assert "case 3: stdout has the fail-safe re-bake message" \
  out_has "CI image has Zig <unknown>, expected ${EXPECTED_ZIG}: re-baking"
assert "case 3: stub log HAS a 'podman build' line (fail-safe re-bake)" \
  log_has_bake
assert "case 3: stdout confirms the bake" out_has "Image baked"

# ─── Case 4: `podman build` fails -> non-zero exit, NO banner ────────────────
printf '# case 4: podman build fails -> hard failure, no green banner\n'
run_ci "4-build-fails" \
  "PODMAN_STUB_IMAGE_ZIG=${STALE_ZIG}" \
  "PODMAN_STUB_BUILD_FAILS=1" -- --skip-build
assert "case 4: script exits NON-zero" rc_is_nonzero
assert "case 4: stdout has NO version banner" out_lacks "Local CI (Podman"
assert "case 4: stdout has NO 'Zig:' banner line" out_lacks "Zig:"
assert "case 4: stdout shows the bake was attempted" out_has "Baking CI image"
assert "case 4: stub log HAS the failing 'podman build' line" log_has_bake
assert "case 4: stdout does NOT claim the image was baked" out_lacks "Image baked"

# ─── Case 5: --rebuild-image forces the bake and skips the probe ────────────
printf '# case 5: --rebuild-image forces the bake, skips the probe\n'
run_ci "5-rebuild-image" "PODMAN_STUB_IMAGE_ZIG=${EXPECTED_ZIG}" \
  -- --rebuild-image --skip-build
assert "case 5: script exits 0" rc_is_zero
assert "case 5: stub log HAS a 'podman build' line (forced bake)" log_has_bake
assert "case 5: NO version probe before the bake" no_probe_before_bake
assert "case 5: stdout shows the bake" out_has "Baking CI image"
assert "case 5: stdout has NO re-bake message (probe was skipped)" \
  out_lacks "re-baking"

# ─── Case 6: --clean exits 0 and never probes podman ────────────────────────
printf '# case 6: --clean exits 0 without any podman probe\n'
run_ci "6-clean" -- --clean
assert "case 6: script exits 0" rc_is_zero
assert "case 6: stub log has NO 'podman run' invocation (no probe)" log_lacks_run
assert "case 6: stub log has NO 'podman build' invocation" log_lacks_bake
assert "case 6: stdout reports the clean" out_has "Clean"

# ─── Summary ─────────────────────────────────────────────────────────────────
printf '\n1..%d\n' "${ASSERT_N}"
if [[ "${ASSERT_FAIL}" -eq 0 ]]; then
  printf '# PASS — %d assertions, 0 failures\n' "${ASSERT_N}"
  exit 0
fi
printf '# FAIL — %d assertions, %d failures\n' "${ASSERT_N}" "${ASSERT_FAIL}"
exit 1
