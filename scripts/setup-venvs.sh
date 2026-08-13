#!/usr/bin/env bash
# scripts/setup-venvs.sh
#
# Creates (or updates) one venv per capability domain under
# /opt/sovereign-sigint/venvs/, installing from each domain's
# requirements.txt. See docs/venvs.md for the registry and conventions
# this script implements.
#
# Usage:
#   sudo ./scripts/setup-venvs.sh          # all domains
#   sudo ./scripts/setup-venvs.sh ai-ingest # single domain
#
# Requires Phase 2 (OS packages: python3-venv, pip) to already be done.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_ROOT="/opt/sovereign-sigint/venvs"

# domain -> path to its requirements.txt, relative to repo root.
# Keep in sync with the table in docs/venvs.md when adding a domain.
declare -A DOMAINS=(
  [ai-ingest]="ai-ingest/requirements.txt"
  [sigint-processing]="decode/requirements.txt"
)

TARGETS=("${1:-}")
if [[ -z "${TARGETS[0]}" ]]; then
  TARGETS=("${!DOMAINS[@]}")
fi

sudo mkdir -p "${VENV_ROOT}"

for domain in "${TARGETS[@]}"; do
  req_rel="${DOMAINS[$domain]:-}"
  if [[ -z "$req_rel" ]]; then
    echo "Unknown domain: ${domain}" >&2
    echo "Known domains: ${!DOMAINS[*]}" >&2
    exit 1
  fi

  req_path="${REPO_ROOT}/${req_rel}"
  venv_path="${VENV_ROOT}/${domain}"

  echo "== ${domain} =="
  echo "  requirements: ${req_path}"
  echo "  venv path:    ${venv_path}"

  if [[ ! -d "${venv_path}" ]]; then
    sudo python3 -m venv "${venv_path}"
    sudo chown -R "${SUDO_USER:-$(id -un)}:${SUDO_USER:-$(id -un)}" "${venv_path}"
  fi

  "${venv_path}/bin/pip" install --upgrade pip
  "${venv_path}/bin/pip" install -r "${req_path}"

  echo "  done: ${venv_path}/bin/python3"
  echo
done

cat <<'EOF'
Next steps:
  - Point each domain's systemd ExecStart at its venv interpreter, e.g.
      ExecStart=/opt/sovereign-sigint/venvs/ai-ingest/bin/python3 /path/to/script.py
  - Re-run this script (with no args, or a single domain name) any time
    a requirements.txt changes — it's safe to run repeatedly.
EOF
