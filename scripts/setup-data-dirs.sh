#!/usr/bin/env bash
# scripts/setup-data-dirs.sh
#
# Creates the /data directory structure used by sovereign-sigint for all
# large/growable data: LLM models, manually-uploaded RAG documents,
# the automated ingest corpus, imagery, SDR signal captures, and
# extracted audio.
#
# /data is treated as a single mount point deliberately — if it starts on
# the T5820's primary SSD and later needs to move to a dedicated drive,
# the move is a `rsync` + fstab entry, not a rewrite of every container's
# volume mounts and every script's hardcoded paths.
#
# Usage:
#   sudo ./scripts/setup-data-dirs.sh [owner[:group]]
#
# If no owner is given, directories are owned by the user invoking sudo
# (via $SUDO_USER) — that's usually correct for a rootless-Podman setup
# where containers run as your own user, not root.

set -euo pipefail

DATA_ROOT="/data"
OWNER="${1:-${SUDO_USER:-$(id -un)}}"

SUBDIRS=(
  "models"             # Ollama / local LLM model weights
  "rag"                # Documents manually uploaded through Open WebUI's
                       # UI ONLY — bind-mounted into its uploads/ path.
                       # NOT for automated ingest output; see corpus/ below.
  "corpus/source"      # Phase 5 automated ingest: original documents
                       # (DOCX, PDF, TXT, MD) before extraction
  "corpus/processed"   # Phase 5 automated ingest: extracted/normalized
                       # text — from documents, OCR'd images, and audio
                       # transcripts alike, unified in one place
  "reference/sigid/metadata"  # Phase 6.3: SigID mirror page text/revision info
  "reference/sigid/images"    # Phase 6.3: SigID mirror waterfall/example images
  "reference/sigid/audio"     # Phase 6.3: SigID mirror example audio
  "imagery"            # Static images: GIF, PNG, JPG, JPEG, HEIC, etc.
  "signals/raw"        # Raw SDR captures (IQ, unprocessed SigMF pairs)
  "signals/generated"  # SigMF recordings WE generate for external consumption
  "audio"              # Audio extracted from SDR streams (voice, decoded modes)
)

echo "Creating ${DATA_ROOT} structure, owner: ${OWNER}"

sudo mkdir -p "${DATA_ROOT}"
for d in "${SUBDIRS[@]}"; do
  sudo mkdir -p "${DATA_ROOT}/${d}"
done

sudo chown -R "${OWNER}:${OWNER}" "${DATA_ROOT}"
sudo chmod -R u+rwX,g+rX,o-rwx "${DATA_ROOT}"

# The SigID reference mirror is read by the SigID Open WebUI tool, which runs
# inside the Open WebUI container as a NON-owner UID (rootless Podman maps it
# through subuid ranges — it's neither ${OWNER} nor in ${OWNER}'s group). The
# blanket o-rwx above therefore blocks the container from reading the mirror.
# SigID is PUBLIC reference data (a mirror of sigidwiki), so world-read is
# appropriate here. Open just the traversal path into it and make the tree
# world-readable — without loosening the rest of /data.
if [ -d "${DATA_ROOT}/reference/sigid" ]; then
  echo "Making SigID reference tree container-readable (public reference data)"
  sudo chmod o+x "${DATA_ROOT}" "${DATA_ROOT}/reference"
  sudo chmod -R o+rX "${DATA_ROOT}/reference/sigid"
fi

# CRITICAL: /data/models is deliberately NOT owned by the human operator —
# phase3-ollama.sh hands it to the 'ollama' service account so Ollama can
# WRITE model weights and manifests there. The recursive chown/chmod above
# would clobber that (setting it back to ${OWNER} with group read-only,
# which makes 'ollama pull' fail at the manifest write with
# "permission denied"). So if /data/models exists, restore Ollama's
# ownership and group-write here. This makes setup-data-dirs.sh safe to
# re-run at any time without breaking Ollama — a real bug: re-running this
# script after Phase 3 silently broke model pulls.
if [ -d "${DATA_ROOT}/models" ]; then
  if id ollama >/dev/null 2>&1; then
    echo "Restoring ollama ownership of ${DATA_ROOT}/models (Ollama's territory)"
    sudo chown -R ollama:ollama "${DATA_ROOT}/models"
    # setgid so new model subdirs keep group + group-write, and group-write
    # so an ollama account that relies on group membership can still write.
    sudo chmod -R u+rwX,g+rwX "${DATA_ROOT}/models"
    sudo find "${DATA_ROOT}/models" -type d -exec chmod g+s {} \;

    # CRITICAL: restoring /data/models ownership is NOT enough on its own.
    # The recursive chmod above locks ${DATA_ROOT} itself to o-rwx (owner
    # ${OWNER}), so the 'ollama' service account — which is neither ${OWNER}
    # nor, by default, in ${OWNER}'s group — cannot TRAVERSE into ${DATA_ROOT}
    # to reach /data/models at all. Symptom: 'ollama list' / pulls fail with
    #   mkdir /data/models: permission denied: ensure path elements are traversable
    # even though /data/models itself is correctly owned. Fix: add ollama to
    # the group that owns ${DATA_ROOT} (which already has r-x on it), and
    # restart the service so the new group membership takes effect.
    DATA_GROUP="$(stat -c '%G' "${DATA_ROOT}")"
    if ! id -nG ollama | tr ' ' '\n' | grep -qx "${DATA_GROUP}"; then
      echo "Adding 'ollama' to group '${DATA_GROUP}' so it can traverse ${DATA_ROOT}"
      sudo usermod -aG "${DATA_GROUP}" ollama
      if systemctl is-active --quiet ollama; then
        echo "Restarting ollama.service to pick up new group membership"
        sudo systemctl restart ollama
      fi
    fi
  else
    echo "NOTE: ${DATA_ROOT}/models exists but no 'ollama' user yet —"
    echo "      Phase 3 (phase3-ollama.sh) will set its ownership. If you"
    echo "      re-run THIS script after Phase 3, it will hand models back"
    echo "      to ollama automatically."
  fi
fi

# ---------------------------------------------------------------------
# Initialize an empty occupancy database if one doesn't exist yet.
# The producers (Phase 6) auto-create it on first connect via
# db/occupancy_db.py, but the occupancy Open WebUI TOOL (installed as
# early as Phase 4) needs a schema-valid DB to open — otherwise it errors
# with "unable to open database file" before any producer has run. Creating
# an empty-but-valid DB here lets the tool return a clean "no signals
# recorded" result during early testing. Idempotent: only creates it if
# absent, so it NEVER clobbers a DB the producers have populated.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCC_DB="${REPO_ROOT}/db/occupancy.db"
OCC_SCHEMA="${REPO_ROOT}/db/occupancy_schema.sql"
if [ ! -e "${OCC_DB}" ] && [ -f "${OCC_SCHEMA}" ]; then
  if command -v sqlite3 >/dev/null 2>&1; then
    echo "Initializing empty occupancy DB at ${OCC_DB}"
    sqlite3 "${OCC_DB}" < "${OCC_SCHEMA}"
    chown "${OWNER}:${OWNER}" "${OCC_DB}" 2>/dev/null || true
  else
    echo "NOTE: sqlite3 not found — skipping occupancy DB init. Phase 2"
    echo "      installs sqlite3; the producers will create the DB in Phase 6"
    echo "      regardless. Only early tool-testing needs this pre-created."
  fi
elif [ -e "${OCC_DB}" ]; then
  echo "Occupancy DB already exists at ${OCC_DB} — left untouched"
fi

echo "Done. Layout:"
find "${DATA_ROOT}" -mindepth 1 -maxdepth 2 -type d -printf '  %p\n' | sort

cat <<'EOF'

Next steps:
  - If /data is meant to live on its own SSD from the start, mount that
    drive at /data BEFORE running this script, and add it to /etc/fstab
    so it survives reboots.
  - Point Ollama at /data/models: set OLLAMA_MODELS=/data/models in its
    environment (systemd unit or Quadlet) before first model pull —
    moving weights after the fact works but means re-pointing symlinks.
  - Mount /data/rag into Open WebUI's uploads/ path — this is for
    documents a human uploads through the UI only.
  - Point Phase 5's automated ingest scripts at /data/corpus/source
    (originals) and /data/corpus/processed (extracted text) — this is
    a decoupled corpus, not wired into Open WebUI's chat RAG. See
    docs/build-order.md Phase 5 for why.
  - Point sigint-ingest.py and other capture scripts at
    /data/signals/raw, and any SigMF-generation code (for external
    consumption) at /data/signals/generated — keep the two separate so
    consumers of generated output never have to sort them from raw
    captures.
  - See docs/data-layout.md for the full rationale and per-subsystem
    wiring notes.
EOF
