#!/usr/bin/env bash
# scripts/phase5-ai-ingest.sh
#
# Phase 5 — AI ingest pipeline. See docs/build-order.md for full
# rationale. Sets up the ai-ingest venv (per docs/venvs.md) and deploys
# the systemd --user timer that runs ingest.py on a schedule.
#
# Run as your normal user, NOT with sudo — matches the rootless
# Podman/systemd-user pattern established in Phases 2 and 4.
#
# This script INSTALLS. Run scripts/phase5-validate.sh afterward.
#
# Usage: ./scripts/phase5-ai-ingest.sh

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run this as root/sudo — the venv and systemd --user timer" >&2
  echo "need to be owned by and run as your normal user. Re-run without sudo." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_PYTHON="/opt/sovereign-sigint/venvs/ai-ingest/bin/python3"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

echo "== Phase 5: AI ingest pipeline =="

# ---------------------------------------------------------------------
# Venv (per docs/venvs.md conventions — reuses the existing setup-venvs.sh)
# ---------------------------------------------------------------------
echo "-- Setting up ai-ingest venv --"
"${REPO_ROOT}/scripts/setup-venvs.sh" ai-ingest

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "ERROR: expected venv interpreter not found at ${VENV_PYTHON}" >&2
  exit 1
fi

# tesseract-ocr is a system binary pytesseract shells out to — not a
# pip package, so it doesn't belong in ai-ingest/requirements.txt.
# Installing it here since Phase 5 is what actually needs it.
echo "-- Installing tesseract-ocr (system binary pytesseract depends on) --"
sudo apt install -y tesseract-ocr

# ---------------------------------------------------------------------
# /data directories this pipeline reads/writes
# ---------------------------------------------------------------------
for d in /data/corpus/source /data/corpus/processed /data/imagery /data/audio; do
  if [[ ! -d "${d}" ]]; then
    echo "ERROR: ${d} does not exist. Run scripts/setup-data-dirs.sh first." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------
# systemd --user timer — template substitution, not a static file, so
# this works regardless of where the repo was cloned to.
# ---------------------------------------------------------------------
echo "-- Installing systemd --user timer --"
mkdir -p "${SYSTEMD_USER_DIR}"

sed -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    -e "s|__VENV_PYTHON__|${VENV_PYTHON}|g" \
    "${REPO_ROOT}/systemd/ai-ingest.service" > "${SYSTEMD_USER_DIR}/ai-ingest.service"

cp "${REPO_ROOT}/systemd/ai-ingest.timer" "${SYSTEMD_USER_DIR}/ai-ingest.timer"

systemctl --user daemon-reload
systemctl --user enable --now ai-ingest.timer

cat <<EOF

== Phase 5 install complete ==

Timer installed: runs ingest.py every 4 hours (see systemd/ai-ingest.timer).
Check status:    systemctl --user status ai-ingest.timer
Run immediately:  systemctl --user start ai-ingest.service
View logs:        journalctl --user -u ai-ingest.service -f

Next: run scripts/phase5-validate.sh to confirm a real document, image,
and audio file each round-trip through ingest into /data/corpus/processed.
EOF
