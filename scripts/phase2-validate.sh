#!/usr/bin/env bash
# scripts/phase2-validate.sh
#
# Phase 2 exit criteria per docs/build-order.md: real smoke tests, not
# just "apt install succeeded." Run as your normal user — NOT with sudo
# — since rootless Podman and venv creation both need to run as the
# actual user Phase 4/5/6 services will run as.
#
# Usage: ./scripts/phase2-validate.sh

set -uo pipefail  # NOT -e — run both tests and report both results.

RESULTS=()

if [[ "$(id -u)" -eq 0 ]]; then
  echo "WARNING: running as root. Podman and venv checks below need to"
  echo "run as the real (non-root) user — results may not reflect what"
  echo "Phase 4/5/6 services will actually see. Re-run without sudo."
  echo
fi

echo "== Phase 2 validation =="
echo

# ---------------------------------------------------------------------
# Podman — rootless hello-world
# ---------------------------------------------------------------------
echo "-- Podman --"
if ! command -v podman >/dev/null 2>&1; then
  echo "  FAIL: podman not found — run scripts/phase2-os-packages.sh first"
  RESULTS+=("Podman: FAIL (not installed)")
else
  echo "  Running: podman run --rm hello-world"
  if timeout 60 podman run --rm hello-world 2>&1 | tee /tmp/phase2-podman.log; then
    echo "  PASS"
    RESULTS+=("Podman: PASS")
  else
    echo "  FAIL: see /tmp/phase2-podman.log"
    echo "  Common causes: missing subuid/subgid range, lingering not"
    echo "  enabled, cgroups v2 not active — see phase2-os-packages.sh"
    echo "  output for warnings from earlier."
    RESULTS+=("Podman: FAIL (see /tmp/phase2-podman.log)")
  fi
fi
echo

# ---------------------------------------------------------------------
# Python — venv creation + a real PyPI resolve
# ---------------------------------------------------------------------
echo "-- Python venv --"
VENV_TEST_DIR="$(mktemp -d /tmp/sovereign-sigint-phase2-venv-test.XXXXXX)"
if python3 -m venv "${VENV_TEST_DIR}/venv" 2>&1 | tee /tmp/phase2-venv.log; then
  if "${VENV_TEST_DIR}/venv/bin/pip" install --quiet --upgrade pip 2>&1 | tee -a /tmp/phase2-venv.log \
     && "${VENV_TEST_DIR}/venv/bin/pip" install --quiet wheel 2>&1 | tee -a /tmp/phase2-venv.log; then
    echo "  PASS: venv created, pip resolved and installed from PyPI"
    RESULTS+=("Python venv: PASS")
  else
    echo "  FAIL: venv created but pip install failed — check network/PyPI access, see /tmp/phase2-venv.log"
    RESULTS+=("Python venv: FAIL (pip install failed)")
  fi
else
  echo "  FAIL: venv creation failed — likely missing python3-venv package"
  RESULTS+=("Python venv: FAIL (venv creation failed)")
fi
rm -rf "${VENV_TEST_DIR}"
echo

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo "== Summary =="
FAILED=0
for r in "${RESULTS[@]}"; do
  echo "  ${r}"
  [[ "${r}" == *FAIL* ]] && FAILED=1
done
echo

if [[ "${FAILED}" -eq 1 ]]; then
  echo "Phase 2 NOT complete — resolve failures above before Phase 3."
  exit 1
else
  echo "Phase 2 exit criteria met."
fi
