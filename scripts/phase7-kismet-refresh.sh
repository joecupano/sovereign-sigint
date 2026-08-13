#!/usr/bin/env bash
# scripts/phase7-kismet-refresh.sh
#
# Install the semi-live Kismet->AI staging timer: every 15 min, stage the
# newest completed Kismet capture to kismet-data/latest.kismet (which the
# Open WebUI container mounts and the native tool reads). See
# docs/kismet-to-ai-bridge.md.
#
# Run as your normal user, NOT sudo (rootless --user pattern).

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run this as root/sudo — install as your normal user." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

echo "== Kismet refresh timer (semi-live AI bridge) =="

mkdir -p "${SYSTEMD_USER_DIR}"
mkdir -p "${REPO_ROOT}/kismet-data"

# Substitute repo root into the service unit; timer needs no substitution.
sed -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    "${REPO_ROOT}/systemd/kismet-refresh.service" \
    > "${SYSTEMD_USER_DIR}/kismet-refresh.service"
cp "${REPO_ROOT}/systemd/kismet-refresh.timer" \
   "${SYSTEMD_USER_DIR}/kismet-refresh.timer"

systemctl --user daemon-reload
systemctl --user enable --now kismet-refresh.timer

# Run once now to stage the current newest capture immediately.
echo "-- staging current capture now --"
"${REPO_ROOT}/scripts/kismet-refresh.sh" || true

# Lingering so the timer runs when logged out.
if command -v loginctl >/dev/null 2>&1; then
  if ! loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -q yes; then
    echo "-- enabling lingering (sudo once) --"
    sudo loginctl enable-linger "$(id -un)" || \
      echo "   NOTE: could not enable lingering; timer won't run while logged out."
  fi
fi

echo
echo "== Installed =="
echo "Timer:   systemctl --user list-timers kismet-refresh.timer"
echo "Run now: ${REPO_ROOT}/scripts/kismet-refresh.sh"
echo "Logs:    journalctl --user -u kismet-refresh.service"
echo
echo "The staged file kismet-data/latest.kismet is what the AI queries. It"
echo "refreshes to the newest COMPLETED capture every 15 min (skips while"
echo "Kismet is actively writing). If your Kismet logs aren't in \$HOME, set"
echo "KISMET_LOG_DIR in the service environment."
