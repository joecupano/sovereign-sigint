#!/usr/bin/env bash
# scripts/phase6-openapi-tools.sh
#
# Install the OpenAPI SIGINT tool server as a systemd --user service. This
# is the DB->AI query path: it exposes the read-only occupancy tools to
# Open WebUI so the local LLM can query the occupancy database in natural
# language. See openapi-tools/README.md and
# docs/openapi-to-mcp-migration.md.
#
# Run as your normal user, NOT with sudo (rootless --user pattern, same as
# the radiod-occupancy producer service).
#
# Usage: ./scripts/phase6-openapi-tools.sh
#   The venv defaults to ~/openapi-venv (created here if missing). Override
#   with OPENAPI_VENV=/path/to/venv.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run this as root/sudo — the systemd --user service must run" >&2
  echo "as your normal user. Re-run without sudo." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENAPI_VENV="${OPENAPI_VENV:-${HOME}/openapi-venv}"
VENV_PYTHON="${OPENAPI_VENV}/bin/python"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

echo "== OpenAPI SIGINT tool server (DB->AI query path) =="

# ---------------------------------------------------------------------
# venv — create if missing, install deps. Kept in the user's home so it's
# writable without sudo (the /opt venvs are root-owned).
# ---------------------------------------------------------------------
if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "-- Creating venv at ${OPENAPI_VENV} --"
  python3 -m venv "${OPENAPI_VENV}"
fi
echo "-- Installing/refreshing dependencies --"
"${OPENAPI_VENV}/bin/pip" install -q -r "${REPO_ROOT}/openapi-tools/requirements.txt"

# ---------------------------------------------------------------------
# Preflight warnings (don't fail).
# ---------------------------------------------------------------------
OCC_DB="${REPO_ROOT}/db/occupancy.db"
if [[ -e "${OCC_DB}" && ! -r "${OCC_DB}" ]]; then
  echo "WARNING: ${OCC_DB} is not readable by you; the tools open it read-only."
fi
if ! sudo ufw status 2>/dev/null | grep -q "8130/tcp"; then
  echo "NOTE: ufw has no 8130/tcp allow rule. Open WebUI validates the tool"
  echo "      URL from your BROWSER, which must reach the LAN IP:8130. If the"
  echo "      connection test fails, run: sudo ufw allow 8130/tcp"
fi

# ---------------------------------------------------------------------
# Install the systemd --user service (path substitution, like the other
# --user services in this build).
# ---------------------------------------------------------------------
echo "-- Installing systemd --user service --"
mkdir -p "${SYSTEMD_USER_DIR}"

sed -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    -e "s|__VENV_PYTHON__|${VENV_PYTHON}|g" \
    "${REPO_ROOT}/systemd/sigint-openapi-tools.service" \
    > "${SYSTEMD_USER_DIR}/sigint-openapi-tools.service"

systemctl --user daemon-reload
systemctl --user enable --now sigint-openapi-tools.service

# ---------------------------------------------------------------------
# Lingering so the --user service survives logout / starts at boot.
# ---------------------------------------------------------------------
if command -v loginctl >/dev/null 2>&1; then
  if ! loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -q yes; then
    echo "-- Enabling lingering (requires sudo once) --"
    sudo loginctl enable-linger "$(id -un)" || \
      echo "   NOTE: could not enable lingering; service will stop at logout."
  fi
fi

echo
echo "== OpenAPI tool server service installed =="
echo "Status:  systemctl --user status sigint-openapi-tools.service"
echo "Logs:    journalctl --user -u sigint-openapi-tools.service -f"
echo "Test:    curl -s http://127.0.0.1:8130/openapi.json -o /dev/null -w '%{http_code}\\n'"
echo
echo "Register in Open WebUI: Settings -> External Tools -> Add (Type: OpenAPI),"
echo "URL http://<box-lan-ip>:8130 , Auth None. (ufw must allow 8130/tcp for"
echo "the browser-side connection test to reach it.)"
