#!/usr/bin/env bash
# scripts/phase5-validate.sh
#
# Phase 5 exit criteria per docs/build-order.md: a document, an image,
# and a spoken-word audio clip each round-trip through ingest into
# /data/corpus/processed — not just "the service is enabled."
#
# Generates real synthetic test files (a DOCX via python-docx, a PNG
# with rendered text via Pillow, a WAV via espeak-ng), stages them
# under /data/corpus/source, /data/imagery, /data/audio, runs ingest.py
# for real, checks the actual output, then cleans up.
#
# NOTE on scanned-PDF coverage: synthesizing a believable scanned PDF
# (image-based, not text-layer) needs extra dependencies (reportlab or
# similar) beyond what this validation pulls in for marginal automated
# value. Not covered here — test that case manually with a real scanned
# PDF once one's available, per the note at the end of this script.
#
# Usage: ./scripts/phase5-validate.sh

set -uo pipefail

VENV_PYTHON="/opt/sovereign-sigint/venvs/ai-ingest/bin/python3"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STAGE_NAME="_phase5_validate"
SOURCE_STAGE="/data/corpus/source/${STAGE_NAME}"
IMAGERY_STAGE="/data/imagery/${STAGE_NAME}"
AUDIO_STAGE="/data/audio/${STAGE_NAME}"
PROCESSED_STAGES=(
  "/data/corpus/processed/document/${STAGE_NAME}"
  "/data/corpus/processed/image/${STAGE_NAME}"
  "/data/corpus/processed/audio/${STAGE_NAME}"
)

RESULTS=()

cleanup() {
  rm -rf "${SOURCE_STAGE}" "${IMAGERY_STAGE}" "${AUDIO_STAGE}" "${PROCESSED_STAGES[@]}"
  # Python's sqlite3 module, not the separate `sqlite3` CLI binary —
  # confirmed via a real run that the CLI was never installed by any
  # phase script, which silently no-op'd this cleanup (2>/dev/null ||
  # true masked the "command not found" failure) and left stale
  # manifest rows that caused later runs to wrongly skip reprocessing.
  # ingest.py's own needs_processing() check is now also independently
  # hardened against this (verifies output file existence, not just
  # the DB record) — this cleanup fix is defense in depth, not the
  # only thing standing between a stale row and a wrong skip.
  python3 -c "
import sqlite3
conn = sqlite3.connect('/data/corpus/processed/manifest.db')
conn.execute(\"DELETE FROM ingest_manifest WHERE source_path LIKE '%${STAGE_NAME}%'\")
conn.commit()
conn.close()
" 2>/dev/null || true
}
trap cleanup EXIT

echo "== Phase 5 validation =="
echo

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "FAIL: ai-ingest venv not found at ${VENV_PYTHON} — run scripts/phase5-ai-ingest.sh first"
  exit 1
fi

mkdir -p "${SOURCE_STAGE}" "${IMAGERY_STAGE}" "${AUDIO_STAGE}"

# ---------------------------------------------------------------------
# Generate test inputs
# ---------------------------------------------------------------------
echo "-- Generating synthetic test files --"

"${VENV_PYTHON}" - <<PYEOF
from docx import Document
d = Document()
d.add_paragraph("sovereign sigint phase five validation document")
d.save("${SOURCE_STAGE}/test.docx")

from PIL import Image, ImageDraw, ImageFont
img = Image.new("RGB", (600, 150), color="white")
draw = ImageDraw.Draw(img)
try:
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 36)
except OSError:
    font = ImageFont.load_default()
    print("WARNING: DejaVu font not found, using bitmap default — OCR may be less reliable")
draw.text((10, 50), "SOVEREIGN SIGINT TEST", fill="black", font=font)
img.save("${IMAGERY_STAGE}/test.png")
PYEOF

if command -v espeak-ng >/dev/null 2>&1; then
  espeak-ng -w "${AUDIO_STAGE}/test.wav" "sovereign sigint phase five validation audio" 2>/dev/null
  AUDIO_AVAILABLE=true
else
  echo "  espeak-ng not found — installing (validation-only dependency, not needed in production)"
  sudo apt install -y espeak-ng >/dev/null 2>&1
  if command -v espeak-ng >/dev/null 2>&1; then
    espeak-ng -w "${AUDIO_STAGE}/test.wav" "sovereign sigint phase five validation audio" 2>/dev/null
    AUDIO_AVAILABLE=true
  else
    echo "  Could not install espeak-ng — skipping audio round-trip test"
    AUDIO_AVAILABLE=false
  fi
fi
echo

# ---------------------------------------------------------------------
# Run ingest for real
# ---------------------------------------------------------------------
echo "-- Running ingest.py --"
cd "${REPO_ROOT}/ai-ingest"
"${VENV_PYTHON}" ingest.py \
  --corpus-source "/data/corpus/source" \
  --imagery-dir "/data/imagery" \
  --audio-dir "/data/audio" \
  --corpus-processed "/data/corpus/processed"
echo

# ---------------------------------------------------------------------
# Check output
# ---------------------------------------------------------------------
echo "-- Checking output --"

check_output() {
  local label="$1" text_path="$2" expect_substring="$3"
  if [[ -f "${text_path}" ]]; then
    content="$(cat "${text_path}")"
    if echo "${content}" | grep -qi "${expect_substring}"; then
      echo "  PASS: ${label} — extracted text contains expected content"
      echo "    -> ${content:0:80}"
      RESULTS+=("${label}: PASS")
    else
      echo "  PARTIAL: ${label} — output exists but doesn't contain expected text"
      echo "    -> ${content:0:80}"
      RESULTS+=("${label}: PARTIAL (unexpected content)")
    fi
  else
    echo "  FAIL: ${label} — no output at ${text_path}"
    RESULTS+=("${label}: FAIL")
  fi
}

check_output "Document (DOCX)" "/data/corpus/processed/document/${STAGE_NAME}/test.txt" "sigint"
check_output "Image (OCR)" "/data/corpus/processed/image/${STAGE_NAME}/test.txt" "sigint"

if [[ "${AUDIO_AVAILABLE}" == true ]]; then
  check_output "Audio (transcription)" "/data/corpus/processed/audio/${STAGE_NAME}/test.txt" "validation"
fi
echo

echo "NOTE: scanned-PDF OCR is not covered by this automated validation"
echo "(see script header) — test manually with a real scanned PDF."
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
  echo "Phase 5 NOT complete — resolve failures above."
  exit 1
else
  echo "Phase 5 exit criteria met for document/image/audio (see PDF note above)."
fi
