#!/usr/bin/env bash
# =====================================================================
# rx888-mode.sh — switch the RX-888 between AI mode and interactive mode
# =====================================================================
# The RX-888 is a single USB device: exactly one process can hold it
# open at a time. radiod (the AI/occupancy path) and OpenWebRX+ (the
# interactive HF waterfall) BOTH want it, and cannot both have it. This
# script enforces the "only one owner" rule so you never get a
# device-busy collision, and makes switching between the two a single,
# explicit command.
#
# Two modes:
#   ai           radiod owns the RX-888. It multicasts wideband +
#                demodulated streams that the AI/occupancy consumers
#                (and any decoders) subscribe to continuously. This is
#                the "always watching" default posture for a sovereign
#                SIGINT box. OpenWebRX+ is NOT using the RX-888 here
#                (it can still serve HackRF/RTL-SDR for VHF/UHF).
#
#   interactive  OpenWebRX+ owns the RX-888 directly, giving you the
#                full 0-30 MHz tunable HF waterfall for hands-on
#                exploration. radiod is stopped, so AI HF occupancy
#                pauses for the duration. A deliberate "I'm driving"
#                mode.
#
#   status       Show which (if either) currently owns the device.
#
# Usage:
#   sudo ./scripts/rx888-mode.sh ai
#   sudo ./scripts/rx888-mode.sh interactive
#   ./scripts/rx888-mode.sh status
#
# NOTE on OpenWebRX+ and the RX-888: for OpenWebRX+ to use the RX-888,
# its config must have an RX-888 (sddc/soapy_sddc) SDR profile ENABLED.
# This script stops/starts the OpenWebRX+ *service*; it does not edit
# OpenWebRX+'s SDR device config. If OpenWebRX+ has no RX-888 profile,
# 'interactive' mode frees the hardware but you must still add/enable
# that profile in the OpenWebRX+ web UI (Settings -> SDR devices) for it
# to actually pick the device up. See docs/openwebrx-sdr-quickstart.md.
# ---------------------------------------------------------------------
set -euo pipefail

RADIOD_INSTANCE="rx888-hf"
RADIOD_UNIT="radiod@${RADIOD_INSTANCE}"
OWRX_UNIT="openwebrx"

# --- helpers ---------------------------------------------------------
is_active()  { systemctl is-active --quiet "$1"; }

rx888_usb_state() {
  # DFU/bootloader = no owner has loaded firmware; f1 = loaded/streaming.
  if lsusb 2>/dev/null | grep -q "04b4:00f3"; then
    echo "present (DFU/bootloader — no active owner has loaded firmware)"
  elif lsusb 2>/dev/null | grep -qi "04b4:00f1\|RX888"; then
    echo "present (firmware loaded — a process has it open)"
  else
    echo "NOT visible on USB (check connection / power-cycle if needed)"
  fi
}

show_status() {
  echo "== RX-888 ownership status =="
  printf '  %-28s %s\n' "radiod (${RADIOD_UNIT}):" \
    "$(is_active "${RADIOD_UNIT}" && echo ACTIVE || echo inactive)"
  printf '  %-28s %s\n' "OpenWebRX+ (${OWRX_UNIT}):" \
    "$(is_active "${OWRX_UNIT}" && echo ACTIVE || echo inactive)"
  printf '  %-28s %s\n' "RX-888 USB:" "$(rx888_usb_state)"
  echo
  if is_active "${RADIOD_UNIT}" && is_active "${OWRX_UNIT}"; then
    echo "  WARNING: both services are active. If OpenWebRX+ has an RX-888"
    echo "  profile enabled, they are contending for the device — run"
    echo "  'sudo $0 ai' or 'sudo $0 interactive' to enforce a single owner."
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This mode switch changes system services — run with sudo." >&2
    exit 1
  fi
}

# --- helpers for the two bugs this script's failure mode taught us -----

# The occupancy producer is a systemd --user service under the operator's
# user (radiod-occupancy.service, installed by phase6-occupancy-producer.sh).
# When we run under sudo, systemctl --user doesn't reach that session by
# default -- we have to invoke it as SUDO_USER with the right runtime dir.
# Bug it prevents: earlier versions of this script left radiod-occupancy
# spinning against a dead radiod after switching to interactive mode; it
# would keep launching pcmrecord subprocesses that failed immediately.
occupancy_svc() {
  # $1 is a systemctl verb (start/stop/is-active/status)
  local verb="$1"
  if [[ -z "${SUDO_USER:-}" ]]; then
    echo "  WARNING: SUDO_USER not set; can't $verb radiod-occupancy.service" >&2
    echo "  (running as root without sudo -- manage the --user service manually)" >&2
    return 0
  fi
  local user_uid
  user_uid=$(id -u "${SUDO_USER}")
  sudo -u "${SUDO_USER}" \
      XDG_RUNTIME_DIR="/run/user/${user_uid}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_uid}/bus" \
      systemctl --user "$verb" radiod-occupancy.service 2>/dev/null || true
}

# Wait for the RX-888 to actually be released by radiod/soapy_connector
# before letting the next owner try to open it. A bare `sleep 2` after
# `systemctl stop` is not enough: on tonight's failure, radiod exited with
# status 66 and OpenWebRX+ hit LIBUSB_ERROR_BUSY on the very next line
# because the USB fd hadn't finished tearing down. Polls up to 10 seconds
# for both known holders to be gone.
wait_for_rx888_release() {
  local timeout=10 elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if ! pgrep -x radiod >/dev/null 2>&1 && \
       ! pgrep -x soapy_connector >/dev/null 2>&1; then
      # Give the kernel one more beat to close the USB fd fully.
      sleep 1
      return 0
    fi
    sleep 1
    ((elapsed++))
  done
  echo "  WARNING: radiod or soapy_connector still running after ${timeout}s;" >&2
  echo "  the next owner may hit LIBUSB_ERROR_BUSY. Check: pgrep -af 'radiod|soapy_connector'" >&2
  return 1
}

# --- modes -----------------------------------------------------------
mode_ai() {
  require_root
  echo "-- Switching to AI mode: radiod owns the RX-888 --"
  # Stop OpenWebRX+ FIRST so it releases the device before radiod grabs it.
  # (If OpenWebRX+ has no RX-888 profile, stopping it is harmless; we stop
  #  it anyway to guarantee the device is free. If you want OpenWebRX+ to
  #  keep serving HackRF/RTL-SDR, see the note below.)
  if is_active "${OWRX_UNIT}"; then
    echo "  Stopping ${OWRX_UNIT} to release the RX-888..."
    systemctl stop "${OWRX_UNIT}"
  fi
  # Poll for actual device release, not a bare sleep -- see helper comment.
  echo "  Waiting for RX-888 USB release..."
  wait_for_rx888_release
  echo "  Starting ${RADIOD_UNIT}..."
  systemctl start "${RADIOD_UNIT}"
  sleep 3
  if is_active "${RADIOD_UNIT}"; then
    echo "  OK: radiod is active — AI/occupancy consumers can subscribe to"
    echo "  its multicast streams. RX-888 is in AI mode."
    # Bring the occupancy producer back up too. Otherwise the operator has to
    # remember to 'systemctl --user start radiod-occupancy.service' by hand
    # every time — verified from a real failure.
    echo "  Starting radiod-occupancy.service..."
    occupancy_svc start
  else
    echo "  ERROR: radiod did not become active. Check:" >&2
    echo "    journalctl -u ${RADIOD_UNIT} -n 50 --no-pager" >&2
    echo "  (If the RX-888 was mid-transition, a device power-cycle then" >&2
    echo "   re-run may be needed — see the DFU-mode notes in build-order.)" >&2
    exit 1
  fi
  echo
  echo "  NOTE: OpenWebRX+ was stopped. If you want it running for"
  echo "  HackRF/RTL-SDR (VHF/UHF) WHILE radiod owns the RX-888, start it"
  echo "  again with 'sudo systemctl start ${OWRX_UNIT}' — just make sure"
  echo "  its RX-888 profile is DISABLED so it doesn't grab the device."
}

mode_interactive() {
  require_root
  echo "-- Switching to interactive mode: OpenWebRX+ owns the RX-888 --"
  # Stop the occupancy producer FIRST, so it doesn't keep spinning after
  # radiod goes away (verified from a real failure: producer kept trying
  # to subprocess pcmrecord against a dead radiod).
  echo "  Stopping radiod-occupancy.service (AI HF occupancy paused)..."
  occupancy_svc stop
  # Stop radiod so it releases the device before OpenWebRX+ opens it.
  if is_active "${RADIOD_UNIT}"; then
    echo "  Stopping ${RADIOD_UNIT}..."
    systemctl stop "${RADIOD_UNIT}"
  fi
  # Poll for actual device release, not a bare sleep -- see helper comment.
  echo "  Waiting for RX-888 USB release..."
  wait_for_rx888_release
  echo "  Starting ${OWRX_UNIT}..."
  systemctl start "${OWRX_UNIT}"
  sleep 3
  if is_active "${OWRX_UNIT}"; then
    echo "  OK: OpenWebRX+ is active. Open its web UI and select the RX-888"
    echo "  profile to get the full 0-30 MHz HF waterfall."
    echo "  (If no RX-888 profile exists yet: Settings -> SDR devices ->"
    echo "   add one using the sddc/soapy_sddc driver.)"
  else
    echo "  ERROR: OpenWebRX+ did not become active. Check:" >&2
    echo "    journalctl -u ${OWRX_UNIT} -n 50 --no-pager" >&2
    exit 1
  fi
  echo
  echo "  When done exploring, return to AI mode with:"
  echo "    sudo $0 ai"
}

# --- dispatch --------------------------------------------------------
case "${1:-}" in
  ai)          mode_ai ;;
  interactive) mode_interactive ;;
  status)      show_status ;;
  *)
    echo "Usage: $0 {ai|interactive|status}"
    echo
    echo "  ai           radiod owns the RX-888 (continuous AI/occupancy;"
    echo "               the always-watching default posture)"
    echo "  interactive  OpenWebRX+ owns the RX-888 (hands-on HF waterfall;"
    echo "               AI HF occupancy pauses)"
    echo "  status       show which service currently owns the device"
    exit 2
    ;;
esac
