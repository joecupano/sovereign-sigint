#!/usr/bin/env bash
# scripts/capture-to-sigmf.sh
#
# Captures raw IQ from RTL-SDR or HackRF (the two devices with no
# OpenWebRX+ raw-capture path — see docs/build-order.md Phase 6.5) and
# wraps it into a SigMF recording via decode/sigmf_writer.py.
#
# Not a phaseN-*.sh script — this is a reusable operational utility
# (matches scripts/setup-data-dirs.sh / setup-venvs.sh's naming
# pattern), not a one-time install step.
#
# Usage:
#   ./scripts/capture-to-sigmf.sh --device rtlsdr --freq 100000000 \
#       --sample-rate 2048000 --duration 5 --output-name my_capture \
#       --description "FM broadcast test capture" --author "NE2Z"
#
#   ./scripts/capture-to-sigmf.sh --device hackrf --freq 915000000 \
#       --sample-rate 8000000 --duration 3 --output-name lora_915

set -euo pipefail

VENV_PYTHON="/opt/sovereign-sigint/venvs/sigint-processing/bin/python3"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_ROOT="/data/signals/raw"

DEVICE=""
FREQ=""
SAMPLE_RATE=""
DURATION=""
OUTPUT_NAME=""
DESCRIPTION=""
AUTHOR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --freq) FREQ="$2"; shift 2 ;;
    --sample-rate) SAMPLE_RATE="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --output-name) OUTPUT_NAME="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

for required in DEVICE FREQ SAMPLE_RATE DURATION OUTPUT_NAME; do
  if [[ -z "${!required}" ]]; then
    echo "ERROR: --${required,,} is required" >&2
    exit 1
  fi
done

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "ERROR: sigint-processing venv not found at ${VENV_PYTHON}" >&2
  echo "Run scripts/phase6-sigmf-writer.sh first." >&2
  exit 1
fi

mkdir -p "${RAW_ROOT}"

NUM_SAMPLES=$(python3 -c "print(int(${SAMPLE_RATE} * ${DURATION}))")

case "${DEVICE}" in
  rtlsdr)
    INPUT_FORMAT="cu8"
    RAW_FILE="${RAW_ROOT}/${OUTPUT_NAME}.cu8"
    echo "-- Capturing ${DURATION}s from RTL-SDR at ${FREQ} Hz --"
    rtl_sdr -f "${FREQ}" -s "${SAMPLE_RATE}" -n "${NUM_SAMPLES}" "${RAW_FILE}"
    ;;
  hackrf)
    INPUT_FORMAT="ci8"
    RAW_FILE="${RAW_ROOT}/${OUTPUT_NAME}.ci8"
    echo "-- Capturing ${DURATION}s from HackRF at ${FREQ} Hz --"
    hackrf_transfer -r "${RAW_FILE}" -f "${FREQ}" -s "${SAMPLE_RATE}" -n "${NUM_SAMPLES}"
    ;;
  *)
    echo "ERROR: --device must be 'rtlsdr' or 'hackrf', got '${DEVICE}'" >&2
    exit 1
    ;;
esac

RAW_SIZE=$(stat -c%s "${RAW_FILE}" 2>/dev/null || echo 0)
if [[ "${RAW_SIZE}" -lt 1000 ]]; then
  echo "ERROR: capture file suspiciously small (${RAW_SIZE} bytes) — check device/antenna" >&2
  exit 1
fi
echo "  Captured ${RAW_SIZE} bytes to ${RAW_FILE}"

echo "-- Wrapping into SigMF (${INPUT_FORMAT}) --"
cd "${REPO_ROOT}/decode"
"${VENV_PYTHON}" sigmf_writer.py \
  --input "${RAW_FILE}" \
  --output-name "${OUTPUT_NAME}" \
  --sample-rate "${SAMPLE_RATE}" \
  --center-freq "${FREQ}" \
  --input-format "${INPUT_FORMAT}" \
  --description "${DESCRIPTION}" \
  --author "${AUTHOR}"

echo
echo "Raw capture:   ${RAW_FILE}"
echo "SigMF output:  /data/signals/generated/${OUTPUT_NAME}.sigmf-meta / .sigmf-data"
