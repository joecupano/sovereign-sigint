#!/usr/bin/env bash
# scripts/phase4-validate.sh
#
# Phase 4 exit criteria per docs/build-order.md: Open WebUI reachable
# through Caddy, can query the Phase 3 models, and RAG document upload
# lands in /data/rag on the host — not just "systemctl says active."
#
# Usage: ./scripts/phase4-validate.sh

set -uo pipefail

RESULTS=()

echo "== Phase 4 validation =="
echo

# ---------------------------------------------------------------------
# Open WebUI reachable directly (container health, bypassing Caddy)
# ---------------------------------------------------------------------
echo "-- Open WebUI direct (127.0.0.1:8080) --"
if curl -fsS -o /dev/null -w "  HTTP %{http_code}\n" http://127.0.0.1:8080/ 2>&1; then
  RESULTS+=("Open WebUI direct: PASS")
else
  echo "  FAIL: no response on 127.0.0.1:8080"
  RESULTS+=("Open WebUI direct: FAIL")
fi
echo

# ---------------------------------------------------------------------
# Reachable through Caddy — detect the ACTUAL DEPLOYED config, not the repo
# copy and not a commented example. The deployed Caddyfile lives in the
# systemd user quadlet dir; the repo Caddyfile ships a COMMENTED 'tls internal'
# example line, so we must (a) read the deployed file and (b) strip comments
# before matching, or a plain-HTTP deploy is misdetected as HTTPS/:8443.
# ---------------------------------------------------------------------
QUADLET_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"
DEPLOYED_CADDYFILE="${QUADLET_DIR}/Caddyfile"
DEPLOYED_ACTIVE="$(grep -v '^[[:space:]]*#' "${DEPLOYED_CADDYFILE}" 2>/dev/null)"

if echo "${DEPLOYED_ACTIVE}" | grep -qE "tls internal|tls /etc/caddy/certs"; then
  CADDY_HOST="$(hostname).local"
  echo "-- Via Caddy (https://${CADDY_HOST}:8443, TLS) --"
  # -k: the local CA won't be in curl's trust store unless this exact
  # client has already run the trust steps in docs/security-hardening.md
  # — that's a separate, client-side concern from "is Caddy serving
  # correctly," which is what this check actually verifies.
  if curl -fsSk -o /dev/null -w "  HTTP %{http_code}\n" "https://${CADDY_HOST}:8443/" 2>&1; then
    RESULTS+=("Via Caddy: PASS (HTTPS)")
  else
    echo "  FAIL: no response through Caddy on ${CADDY_HOST}:8443"
    echo "  Confirm avahi/mDNS resolves ${CADDY_HOST} from this machine."
    RESULTS+=("Via Caddy: FAIL")
  fi
else
  echo "-- Via Caddy (localhost:8000, plain HTTP) --"
  if curl -fsS -o /dev/null -w "  HTTP %{http_code}\n" http://localhost:8000/ 2>&1; then
    RESULTS+=("Via Caddy: PASS")
  else
    echo "  FAIL: no response through Caddy on port 8000"
    RESULTS+=("Via Caddy: FAIL")
  fi
fi
echo

# ---------------------------------------------------------------------
# Open WebUI's container can actually reach Ollama on the host
# (the real test — a UI that loads doesn't guarantee this)
# ---------------------------------------------------------------------
echo "-- Open WebUI -> Ollama connectivity --"
OLLAMA_CHECK="$(podman exec open-webui curl -fsS http://host.containers.internal:11434/api/tags 2>&1)"
if echo "${OLLAMA_CHECK}" | grep -q '"models"'; then
  MODEL_COUNT=$(echo "${OLLAMA_CHECK}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["models"]))' 2>/dev/null || echo "?")
  echo "  PASS: container reached host Ollama, ${MODEL_COUNT} model(s) visible"
  RESULTS+=("OWUI->Ollama: PASS (${MODEL_COUNT} models)")
else
  echo "  FAIL: ${OLLAMA_CHECK}"
  echo "  Check: is Ollama running (systemctl status ollama)? Does the"
  echo "  container resolve host.containers.internal? (podman exec"
  echo "  open-webui getent hosts host.containers.internal)"
  RESULTS+=("OWUI->Ollama: FAIL")
fi
echo

# ---------------------------------------------------------------------
# /data/rag bind mount — write a marker file on the host side, confirm
# it's visible inside the container at the expected internal path
# ---------------------------------------------------------------------
echo "-- /data/rag bind mount --"
MARKER="phase4-validate-$(date +%s).txt"
echo "validation marker" > "/data/rag/${MARKER}" 2>/tmp/phase4-rag-write.log
if [[ -f "/data/rag/${MARKER}" ]]; then
  if podman exec open-webui test -f "/app/backend/data/uploads/${MARKER}" 2>/dev/null; then
    echo "  PASS: file written to /data/rag is visible in the container"
    RESULTS+=("/data/rag mount: PASS")
  else
    echo "  FAIL: file on host but not visible inside container at"
    echo "  /app/backend/data/uploads/${MARKER} — check the Volume line"
    echo "  in containers/open-webui.container"
    RESULTS+=("/data/rag mount: FAIL (not visible in container)")
  fi
  rm -f "/data/rag/${MARKER}"
else
  echo "  FAIL: could not write to /data/rag — check ownership/permissions"
  echo "  (see /tmp/phase4-rag-write.log)"
  RESULTS+=("/data/rag mount: FAIL (host write failed)")
fi
echo

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo "== Summary =="
FAILED=0
for r in "${RESULTS[@]}"; do
  echo "  ${r}"
  [[ "${r}" == *FAIL* ]] && FAILED=1
done
echo

if [[ "${FAILED}" -eq 1 ]]; then
  echo "Phase 4 NOT complete — resolve failures above before Phase 5."
  exit 1
else
  echo "Phase 4 exit criteria met."
  echo "Log into Open WebUI at http://<this-box>/ to finish first-run setup"
  echo "(admin account creation) before moving on."
fi
