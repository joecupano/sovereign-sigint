#!/usr/bin/env bash
# scripts/phase6-sigid-mirror-validate.sh
#
# Phase 6.3 exit criteria: real content mirrored, AND a second run
# demonstrably does incremental sync (near-instant, near-zero new
# pages) rather than re-fetching everything — that's the actual point
# of this being reusable/periodic, not just "it ran once."
#
# Usage: ./scripts/phase6-sigid-mirror-validate.sh

set -uo pipefail

VENV_PYTHON="/opt/sovereign-sigint/venvs/sigint-processing/bin/python3"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ROOT="/data/reference/sigid"

RESULTS=()

echo "== Phase 6.3 validation: SigID mirror =="
echo

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "FAIL: sigint-processing venv not found at ${VENV_PYTHON}"
  exit 1
fi

# ---------------------------------------------------------------------
# Content actually landed
# ---------------------------------------------------------------------
echo "-- Checking mirrored content --"
METADATA_COUNT=$(find "${OUTPUT_ROOT}/metadata" -name "*.json" 2>/dev/null | wc -l)
IMAGE_COUNT=$(find "${OUTPUT_ROOT}/images" -type f 2>/dev/null | wc -l)

if [[ "${METADATA_COUNT}" -gt 0 ]]; then
  echo "  PASS: ${METADATA_COUNT} page(s) mirrored, ${IMAGE_COUNT} image(s)"
  RESULTS+=("Content: PASS (${METADATA_COUNT} pages, ${IMAGE_COUNT} images)")

  SAMPLE_FILE="$(find "${OUTPUT_ROOT}/metadata" -name "*.json" | head -1)"
  echo "  Sample: ${SAMPLE_FILE}"
  python3 -c "
import json
with open('${SAMPLE_FILE}') as f:
    d = json.load(f)
print(f\"    title={d['title']!r} revision_id={d['revision_id']} wikitext_len={len(d['wikitext'])}\")
"
else
  echo "  FAIL: no metadata found under ${OUTPUT_ROOT}/metadata"
  RESULTS+=("Content: FAIL")
fi
echo

# ---------------------------------------------------------------------
# Second run is actually incremental — the real point of this being
# built for periodic reuse rather than a one-shot script
# ---------------------------------------------------------------------
echo "-- Confirming second run is incremental (not a full re-crawl) --"
cd "${REPO_ROOT}/reference"
START=$(date +%s)
SECOND_RUN_OUTPUT="$("${VENV_PYTHON}" sigid_mirror.py 2>&1)"
END=$(date +%s)
ELAPSED=$((END - START))

echo "${SECOND_RUN_OUTPUT}" | tail -5
echo "  Elapsed: ${ELAPSED}s"

if echo "${SECOND_RUN_OUTPUT}" | grep -q "mode=incremental"; then
  echo "  PASS: second run used incremental mode"
  RESULTS+=("Incremental mode: PASS")
else
  echo "  FAIL: second run did not report incremental mode — check output above"
  RESULTS+=("Incremental mode: FAIL")
fi

if [[ "${ELAPSED}" -lt 60 ]]; then
  echo "  PASS: second run completed quickly (${ELAPSED}s) — consistent with"
  echo "  checking recent-changes only, not re-crawling the whole wiki"
  RESULTS+=("Incremental speed: PASS (${ELAPSED}s)")
else
  echo "  PARTIAL: second run took ${ELAPSED}s — slower than expected for an"
  echo "  incremental check. Could be normal (large recentchanges window on"
  echo "  first delta) or could indicate it's not actually skipping unchanged"
  echo "  pages. Check manifest.db's sync_runs table for pages_synced count."
  RESULTS+=("Incremental speed: PARTIAL (${ELAPSED}s)")
fi
echo

# ---------------------------------------------------------------------
# Timer is actually scheduled
# ---------------------------------------------------------------------
echo "-- Checking systemd timer --"
if systemctl --user is-active --quiet sigid-mirror.timer 2>/dev/null; then
  echo "  PASS: sigid-mirror.timer is active"
  RESULTS+=("Timer: PASS")
else
  echo "  FAIL: sigid-mirror.timer is not active"
  RESULTS+=("Timer: FAIL")
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
  echo "Phase 6.3 NOT complete — resolve failures above."
  exit 1
else
  echo "Phase 6.3 exit criteria met."
fi
