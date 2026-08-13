#!/usr/bin/env bash
# scripts/kismet-refresh.sh
#
# Semi-live Kismet->AI bridge: stage the newest Kismet capture to the stable
# path the native tool reads (kismet-data/latest.kismet, mounted into the
# Open WebUI container). Run on a timer (systemd/kismet-refresh.timer) so the
# AI always queries the most recent completed capture, without running Kismet
# continuously.
#
# WHY a copy rather than mounting the live file: Kismet is used on-demand here,
# not 24/7, and it writes a NEW timestamped .kismet file per run. Copying the
# newest one to a stable name keeps the tool's valve path fixed and avoids
# reading a file mid-write. See docs/kismet-to-ai-bridge.md.
#
# Default behavior: stage the newest .kismet even if Kismet is currently
# writing to it. SQLite in WAL mode (which Kismet uses) supports concurrent
# reads-while-writing, and the AI tool opens the file with PRAGMA query_only,
# so a live copy is safe — SQLite's WAL machinery gives the reader a
# consistent point-in-time snapshot. Under the always-on Kismet model (system
# service enabled by phase7-kismet.sh), Kismet is always writing, so this
# default lets the timer actually stage captures instead of skipping forever.
# Pass --session-only to opt back into the older behavior of skipping while
# Kismet is running (appropriate if you run Kismet on-demand instead of as a
# service).

set -euo pipefail

# Where Kismet writes its .kismet files (default: the user's home, Kismet's
# default log dir). Override with KISMET_LOG_DIR.
KISMET_LOG_DIR="${KISMET_LOG_DIR:-${HOME}}"
# Stable destination the container mounts and the tool reads.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/kismet-data/latest.kismet"

INCLUDE_RUNNING=1
case "${1:-}" in
  --include-running) INCLUDE_RUNNING=1 ;;   # explicit; same as default now, kept for backward-compat
  --session-only)    INCLUDE_RUNNING=0 ;;   # opt back into skip-while-running (session-model)
  "")                ;;
  *) echo "kismet-refresh: unknown flag: ${1}" >&2
     echo "  usage: kismet-refresh.sh [--include-running | --session-only]" >&2
     exit 2 ;;
esac

mkdir -p "$(dirname "${DEST}")"

# Find the newest .kismet file by mtime.
newest="$(find "${KISMET_LOG_DIR}" -maxdepth 1 -name "*.kismet" -type f \
          -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"

if [[ -z "${newest}" ]]; then
  echo "kismet-refresh: no .kismet files found in ${KISMET_LOG_DIR}; nothing to stage."
  exit 0
fi

# If Kismet is running, the newest file is likely the one it's writing. Skip
# unless explicitly told to include it.
if [[ "${INCLUDE_RUNNING}" -eq 0 ]] && (systemctl is-active --quiet kismet 2>/dev/null || pgrep -x kismet >/dev/null 2>&1); then
  echo "kismet-refresh: Kismet is running and --session-only was passed — skipping"
  echo "  refresh to avoid copying a mid-write capture. The last completed capture"
  echo "  stays staged. Re-run without --session-only to stage the live file too"
  echo "  (SQLite WAL makes this safe; it is now the default)."
  exit 0
fi

# Only copy if the newest file is actually newer than what's staged (avoid
# re-copying a large file every tick unnecessarily).
if [[ -f "${DEST}" && ! "${newest}" -nt "${DEST}" ]]; then
  echo "kismet-refresh: staged capture is already current ($(basename "${newest}")); no copy needed."
  exit 0
fi

echo "kismet-refresh: staging $(basename "${newest}") -> ${DEST}"
# Copy to a temp name then move, so the tool never sees a half-copied file.
tmp="${DEST}.tmp.$$"
cp "${newest}" "${tmp}"
mv -f "${tmp}" "${DEST}"
echo "kismet-refresh: done ($(du -h "${DEST}" | cut -f1))."
