#!/usr/bin/env bash
# scripts/phase6-vhf-uhf-producer.sh
#
# Phase 6.6 (VHF/UHF producer) — install the VHF/UHF key-frequency
# occupancy producer as a TEMPLATED systemd --user service, so it can
# be enabled per device (hackrf or rtlsdr) independently. See
# docs/build-order.md Phase 6 and docs/occupancy-guide.md.
#
# The producer sweeps a fixed list of key 2m/70cm frequencies (APRS,
# simplex calling channels, local repeaters), measures per-frequency
# power, and writes sightings to the occupancy DB via
# OccupancyDB.record_sighting(). One process per USB device -- HackRF and
# RTL-SDR are independent single-owner devices.
#
# This install step DOES NOT auto-enable either instance. Rationale:
# HackRF and RTL-SDR both serve dual purposes on this build (occupancy vs.
# OpenWebRX+ waterfall), and defaulting either to a running producer
# would grab a device the operator might want for interactive use.
# Operator opts in per device via scripts/sdr-mode.sh:
#     sudo ./scripts/sdr-mode.sh hackrf ai        # enable+start hackrf
#     sudo ./scripts/sdr-mode.sh rtlsdr ai        # enable+start rtlsdr
#     sudo ./scripts/sdr-mode.sh hackrf interactive   # disable+stop hackrf
#
# Run as your normal user, NOT with sudo -- same rootless --user pattern
# as the radiod-occupancy, SigID, and AI-ingest services.
#
# Usage: ./scripts/phase6-vhf-uhf-producer.sh
#   Override the interpreter with VENV_PYTHON=... if the producer's deps
#   live in a specific venv. The producer only needs stdlib + numpy +
#   db/occupancy_db.py, so system python3 works if numpy is available;
#   otherwise use the sigint-processing venv.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run this as root/sudo — the systemd --user service must be" >&2
  echo "owned by and run as your normal user (it writes the occupancy DB as" >&2
  echo "you). Re-run without sudo." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Producer needs numpy (for power computation) plus stdlib and db/occupancy_db.py.
# The sigint-processing venv has numpy; fall back to system python3 if the
# venv isn't present but let the operator know they may need to install numpy.
VENV_PYTHON="${VENV_PYTHON:-}"
if [[ -z "${VENV_PYTHON}" ]]; then
  if [[ -x "/opt/sovereign-sigint/venvs/sigint-processing/bin/python3" ]]; then
    VENV_PYTHON="/opt/sovereign-sigint/venvs/sigint-processing/bin/python3"
  else
    VENV_PYTHON="$(command -v python3)"
    echo "NOTE: sigint-processing venv not found; using system python3."
    echo "      The producer needs numpy — ensure it's installed:"
    echo "      python3 -c 'import numpy' || sudo apt install python3-numpy"
  fi
fi
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

echo "== Phase 6.6: VHF/UHF occupancy producer (templated service) =="

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "ERROR: python3 interpreter not found at ${VENV_PYTHON}" >&2
  exit 1
fi

# Sanity: verify the two CLI tools the producer subprocesses are on PATH.
# Missing them isn't a hard error at install time (the operator may install
# them later) but we should warn.
for cli in hackrf_transfer rtl_sdr; do
  if ! command -v "$cli" >/dev/null 2>&1; then
    echo "WARNING: $cli not found on PATH. Install with:" >&2
    case "$cli" in
      hackrf_transfer) echo "  sudo apt install hackrf" >&2 ;;
      rtl_sdr)         echo "  sudo apt install rtl-sdr" >&2 ;;
    esac
    echo "  (You can install the unit now and add the CLI later.)" >&2
  fi
done

# Install the templated unit (substitute paths, like phase6-occupancy-producer.sh)
echo "-- Installing systemd --user templated service --"
mkdir -p "${SYSTEMD_USER_DIR}"
sed -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    -e "s|__VENV_PYTHON__|${VENV_PYTHON}|g" \
    "${REPO_ROOT}/systemd/vhf-uhf-occupancy@.service" \
    > "${SYSTEMD_USER_DIR}/vhf-uhf-occupancy@.service"

systemctl --user daemon-reload

echo
echo "== Installed =="
echo "The template unit is installed but no instance is enabled. Opt in"
echo "per device via sdr-mode.sh (which also handles the OpenWebRX+ side):"
echo
echo "  sudo ./scripts/sdr-mode.sh hackrf ai           # HackRF -> occupancy"
echo "  sudo ./scripts/sdr-mode.sh hackrf interactive  # HackRF -> free/OWRX+"
echo "  sudo ./scripts/sdr-mode.sh rtlsdr ai           # RTL-SDR -> occupancy"
echo "  sudo ./scripts/sdr-mode.sh rtlsdr interactive  # RTL-SDR -> free/OWRX+"
echo
echo "Manual (bypassing sdr-mode.sh):"
echo "  systemctl --user enable --now vhf-uhf-occupancy@hackrf.service"
echo "  systemctl --user status vhf-uhf-occupancy@hackrf.service"
echo "  journalctl --user -u vhf-uhf-occupancy@hackrf.service -f"
