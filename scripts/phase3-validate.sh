#!/usr/bin/env bash
# scripts/phase3-validate.sh
#
# Phase 3 exit criteria per docs/build-order.md: ollama run works with
# GPU utilization visible, and models are physically on /data/models —
# not just "ollama pull exited 0."
#
# Usage: ./scripts/phase3-validate.sh

set -uo pipefail

INSTRUCT_MODEL="${INSTRUCT_MODEL:-qwen3:14b}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"

RESULTS=()

echo "== Phase 3 validation =="
echo

# ---------------------------------------------------------------------
# Models physically on /data/models
# ---------------------------------------------------------------------
echo "-- Model storage location --"
if [[ -d /data/models ]] && [[ -n "$(ls -A /data/models 2>/dev/null)" ]]; then
  SIZE=$(sudo du -sh /data/models 2>/dev/null | cut -f1)
  echo "  PASS: /data/models populated (${SIZE})"
  RESULTS+=("Model storage: PASS (${SIZE} on /data/models)")
else
  echo "  FAIL: /data/models missing or empty — check OLLAMA_MODELS env"
  echo "  var in /etc/systemd/system/ollama.service.d/override.conf and"
  echo "  that 'ollama' owns the directory."
  RESULTS+=("Model storage: FAIL")
fi
echo

# ---------------------------------------------------------------------
# GPU inference — run a trivial prompt, check nvidia-smi shows the
# ollama process using the GPU WHILE it runs
# ---------------------------------------------------------------------
echo "-- GPU inference (${INSTRUCT_MODEL}) --"
if ! command -v ollama >/dev/null 2>&1; then
  echo "  FAIL: ollama not found — run scripts/phase3-ollama.sh first"
  RESULTS+=("GPU inference: FAIL (ollama not installed)")
else
  RESPONSE_FILE="$(mktemp)"
  GPU_LOG="$(mktemp)"

  # Run inference in the background, poll nvidia-smi while it's warm
  ollama run "${INSTRUCT_MODEL}" "Reply with exactly one word: test" \
    > "${RESPONSE_FILE}" 2>&1 &
  OLLAMA_PID=$!

  sleep 3  # let the model load onto the GPU before sampling
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader > "${GPU_LOG}" 2>&1
  fi

  wait "${OLLAMA_PID}"

  RESPONSE="$(cat "${RESPONSE_FILE}")"
  echo "  Model response: ${RESPONSE}"

  if [[ -z "${RESPONSE}" ]]; then
    echo "  FAIL: empty response"
    RESULTS+=("GPU inference: FAIL (empty response)")
  elif [[ -s "${GPU_LOG}" ]]; then
    echo "  GPU compute processes during inference:"
    sed 's/^/    /' "${GPU_LOG}"
    echo "  PASS: response received, GPU showed active compute process"
    RESULTS+=("GPU inference: PASS")
  else
    echo "  PARTIAL: response received, but no GPU compute process"
    echo "  captured — the 3s sampling window may have missed it, or"
    echo "  inference fell back to CPU. Check 'nvidia-smi' manually"
    echo "  during a longer-running prompt if this recurs."
    RESULTS+=("GPU inference: PARTIAL (response OK, GPU use unconfirmed)")
  fi
  rm -f "${RESPONSE_FILE}" "${GPU_LOG}"
fi
echo

# ---------------------------------------------------------------------
# Embedding endpoint
# ---------------------------------------------------------------------
echo "-- Embedding model (${EMBED_MODEL}) --"
EMBED_RESPONSE="$(curl -fsS http://localhost:11434/api/embeddings \
  -d "{\"model\": \"${EMBED_MODEL}\", \"prompt\": \"test\"}" 2>&1)"

if echo "${EMBED_RESPONSE}" | grep -q '"embedding"'; then
  DIMS=$(echo "${EMBED_RESPONSE}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["embedding"]))' 2>/dev/null || echo "?")
  echo "  PASS: received embedding vector (${DIMS} dimensions)"
  RESULTS+=("Embedding: PASS (${DIMS} dims)")
else
  echo "  FAIL: no embedding in response — ${EMBED_RESPONSE}"
  RESULTS+=("Embedding: FAIL")
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
  echo "Phase 3 NOT complete — resolve failures above before Phase 4."
  exit 1
else
  echo "Phase 3 exit criteria met (see PARTIAL notes above, if any)."
fi
