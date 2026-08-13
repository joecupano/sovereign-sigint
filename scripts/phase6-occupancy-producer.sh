#!/usr/bin/env bash
# scripts/phase6-occupancy-producer.sh
#
# Phase 6.6 (producer) — install the radiod occupancy producer as a
# continuous systemd --user service. See docs/build-order.md Phase 6 and
# docs/occupancy-guide.md.
#
# The producer sweeps radiod's demodulated HF channels, measures per-channel
# power, and writes occupancy sightings to the occupancy DB. This script
# installs it as an always-on service so the occupancy DB is populated
# continuously ("always watching") rather than only when run by hand.
#
# Run as your normal user, NOT with sudo — same rootless --user pattern as
# the SigID and AI-ingest services.
#
# Usage: ./scripts/phase6-occupancy-producer.sh
#   Override the interpreter with VENV_PYTHON=... if the producer's deps
#   live in a specific venv (it only needs the stdlib + db/occupancy_db.py,
#   so system python3 is fine by default).

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run this as root/sudo — the systemd --user service must be" >&2
  echo "owned by and run as your normal user (it writes the occupancy DB as" >&2
  echo "you). Re-run without sudo." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The producer needs only the standard library plus db/occupancy_db.py, so
# system python3 is sufficient. Override VENV_PYTHON to pin a venv if desired.
VENV_PYTHON="${VENV_PYTHON:-$(command -v python3)}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

echo "== Phase 6.6: radiod occupancy producer (continuous service) =="

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "ERROR: python3 interpreter not found at ${VENV_PYTHON}" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Preflight: warn (don't fail) on the things that make the producer
# silently record nothing, so the operator isn't puzzled later.
# ---------------------------------------------------------------------
if ! systemctl is-active --quiet radiod@rx888-hf 2>/dev/null; then
  echo "NOTE: radiod@rx888-hf is not active right now. The producer will run"
  echo "      but every channel will read silent (nothing to measure) until"
  echo "      the RX-888 is in AI mode. See scripts/rx888-mode.sh / sdr-mode.sh."
fi

OCC_DB="${REPO_ROOT}/db/occupancy.db"
if [[ -e "${OCC_DB}" && ! -w "${OCC_DB}" ]]; then
  echo "WARNING: ${OCC_DB} is not writable by you. The producer writes as your"
  echo "         user; fix with: sudo chown $(id -un) ${OCC_DB}"
fi

# ---------------------------------------------------------------------
# Install the systemd --user service (substitute paths, like the SigID
# and AI-ingest installers do).
# ---------------------------------------------------------------------
echo "-- Installing systemd --user service --"
mkdir -p "${SYSTEMD_USER_DIR}"

sed -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    -e "s|__VENV_PYTHON__|${VENV_PYTHON}|g" \
    "${REPO_ROOT}/systemd/radiod-occupancy.service" \
    > "${SYSTEMD_USER_DIR}/radiod-occupancy.service"

systemctl --user daemon-reload
systemctl --user enable --now radiod-occupancy.service

# ---------------------------------------------------------------------
# Enable lingering so the --user service keeps running after logout.
# Continuous services (unlike the periodic SigID/AI-ingest timers) need
# this or they stop when your login session ends.
# ---------------------------------------------------------------------
if command -v loginctl >/dev/null 2>&1; then
  if ! loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -q yes; then
    echo "-- Enabling lingering so the service survives logout --"
    echo "   (requires sudo once):"
    sudo loginctl enable-linger "$(id -un)" || \
      echo "   NOTE: could not enable lingering; the service will stop at logout."
  fi
fi

echo
echo "== Phase 6.6 producer service installed =="
echo "Status:      systemctl --user status radiod-occupancy.service"
echo "Logs:        journalctl --user -u radiod-occupancy.service -f"
echo "Stop/free the RX-888 for OpenWebRX+:  systemctl --user stop radiod-occupancy.service"
echo "             (then scripts/rx888-mode.sh interactive)"
echo
echo "The producer sweeps every 60s. Confirm sightings are accumulating:"
echo "  sqlite3 ${OCC_DB} 'SELECT COUNT(*) FROM sightings;'"
