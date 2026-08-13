#!/usr/bin/env bash
# scripts/phase3-ollama.sh
#
# Phase 3 — Ollama and default models. See docs/build-order.md for full
# rationale. Installed natively (not containerized) for simpler GPU
# passthrough.
#
# This script INSTALLS + pulls default models. Run
# scripts/phase3-validate.sh afterward.
#
# Usage: sudo ./scripts/phase3-ollama.sh

set -euo pipefail

echo "== Phase 3: Ollama and default models =="

# ---------------------------------------------------------------------
# Default model selection — confirmed for the 16GB RTX 5060 Ti variant.
# Verified against the live Ollama library as of June 2026 — re-check
# https://ollama.com/library before relying on these tags long-term,
# the catalog moves fast and this is a snapshot, not a guarantee.
# ---------------------------------------------------------------------
INSTRUCT_MODEL="${INSTRUCT_MODEL:-qwen3:14b}"     # general chat/reasoning,
                                                    # NL query over SIGINT DB
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"    # RAG over /data/rag —
                                                    # the standard pick,
                                                    # ~274MB, 8192-token chunks
VISION_MODEL="${VISION_MODEL:-gemma3:12b}"        # image reasoning over
                                                    # /data/imagery; also
                                                    # handles OCR-adjacent
                                                    # tasks reasonably, though
                                                    # the ai-ingest pipeline's
                                                    # docling/pytesseract path
                                                    # (Phase 5) remains the
                                                    # primary OCR mechanism
TOOL_MODEL="${TOOL_MODEL:-llama3-groq-tool-use:8b}" # dedicated tool/function-
                                                    # calling model (~4.7GB),
                                                    # fine-tuned by Groq for
                                                    # reliable tool invocation.
                                                    # Pulled ALONGSIDE the
                                                    # instruct model: the SIGINT
                                                    # native tools were proven
                                                    # reliable against this in
                                                    # the working build. It's an
                                                    # older model (Llama 3, Jul
                                                    # 2024), so also try the
                                                    # newer INSTRUCT_MODEL
                                                    # (qwen3:14b) for tools and
                                                    # keep whichever invokes
                                                    # them more reliably. Set
                                                    # TOOL_MODEL=skip to omit.

echo "Models to pull: ${INSTRUCT_MODEL}, ${EMBED_MODEL}, ${VISION_MODEL}, ${TOOL_MODEL}"
echo "(override by exporting INSTRUCT_MODEL / EMBED_MODEL / VISION_MODEL / TOOL_MODEL before running)"
echo

# ---------------------------------------------------------------------
# Install Ollama (official installer — creates an 'ollama' system user
# and a systemd service)
# ---------------------------------------------------------------------
echo "-- Installing Ollama --"
curl -fsSL https://ollama.com/install.sh | sh

# ---------------------------------------------------------------------
# Point Ollama at /data/models BEFORE the first pull — moving weights
# after the fact works but means re-pointing manifests/symlinks rather
# than just pulling clean. See docs/data-layout.md.
# ---------------------------------------------------------------------
echo "-- Configuring OLLAMA_MODELS=/data/models and OLLAMA_HOST --"
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<'EOF'
[Service]
Environment="OLLAMA_MODELS=/data/models"
Environment="OLLAMA_HOST=0.0.0.0"
EOF

# OLLAMA_HOST=0.0.0.0 — confirmed necessary via a real install: Ollama
# defaults to binding 127.0.0.1 only, which Open WebUI's container
# (Phase 4) cannot reach through host.containers.internal — that
# hostname resolves to the box's real LAN-facing IP under this rootless
# Podman networking setup, not an isolated container-only address, so
# loopback-only binding is unreachable from the container regardless of
# DNS resolution working correctly.
#
# SECURITY IMPLICATION, stated directly rather than glossed over:
# binding 0.0.0.0 exposes Ollama's API on the LAN itself, not just to
# the local container — Ollama has no built-in authentication. If this
# box sits on a network with untrusted hosts, restrict at the firewall
# rather than leave the full LAN able to reach it, e.g.:
#   sudo ufw allow from 127.0.0.1 to any port 11434
#   sudo ufw deny 11434
# (adjust the allow rule to the container's actual gateway/subnet if
# you want the container specifically reachable without opening it to
# the whole LAN — verify that subnet with your own network setup
# rather than assume one here.)

# /data is owned by the human operator (see scripts/setup-data-dirs.sh),
# but Ollama's systemd service runs as its own 'ollama' system user —
# that account needs write access to /data/models specifically, or model
# pulls will fail with a permissions error. This is a deliberate,
# narrowly-scoped exception to the general /data ownership convention:
# /data/models is Ollama's exclusive territory, so it gets chowned to
# the ollama service account rather than the human user.
echo "-- Granting the ollama service account ownership of /data/models --"
sudo mkdir -p /data/models
sudo chown -R ollama:ollama /data/models
# Group-write + setgid on directories so that any subdirectory Ollama
# creates on future pulls inherits the group and stays writable — prevents
# a later pull failing with "permission denied" on a freshly-created
# registry subpath. Consistent with scripts/setup-data-dirs.sh.
sudo chmod -R u+rwX,g+rwX /data/models
sudo find /data/models -type d -exec chmod g+s {} \;

# Chowning /data/models alone is NOT sufficient — confirmed via a real
# install ("mkdir /data/models: permission denied: ensure path elements
# are traversable"). /data itself is locked to o-rwx (no access outside
# the owning user/group) per scripts/setup-data-dirs.sh, so the 'ollama'
# user — being neither the owner nor in that group — can't even
# traverse INTO /data to reach /data/models, regardless of what
# /data/models itself is owned by. Fix: add 'ollama' to whatever group
# owns /data, giving it legitimate group-level traverse access
# consistent with the existing permission model, rather than loosening
# /data's own permissions to fix one consumer.
DATA_GROUP="$(stat -c '%G' /data)"
echo "-- Adding 'ollama' to '${DATA_GROUP}' (the group owning /data) so it can traverse into it --"
sudo usermod -aG "${DATA_GROUP}" ollama

sudo systemctl daemon-reload
sudo systemctl enable --now ollama
sudo systemctl restart ollama

echo "Waiting for Ollama to come up..."
for i in $(seq 1 15); do
  if curl -fsS http://localhost:11434/ >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# ---------------------------------------------------------------------
# Pull default models
# ---------------------------------------------------------------------
echo "-- Pulling models (this can take a while on first run) --"
ollama pull "${INSTRUCT_MODEL}"
ollama pull "${EMBED_MODEL}"
ollama pull "${VISION_MODEL}"
if [[ "${TOOL_MODEL}" != "skip" ]]; then
  ollama pull "${TOOL_MODEL}"
else
  echo "  (TOOL_MODEL=skip — not pulling a dedicated tool-calling model)"
fi

echo
echo "-- Installed models --"
ollama list

cat <<EOF

== Phase 3 install complete ==

Next: run scripts/phase3-validate.sh to confirm GPU inference actually
works and models physically live on /data/models — do not consider
Phase 3 done until that passes.
EOF
