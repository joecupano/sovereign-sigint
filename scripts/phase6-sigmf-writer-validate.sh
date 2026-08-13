#!/usr/bin/env bash
# scripts/phase6-sigmf-writer-validate.sh
#
# Phase 6.5 exit criteria: a real round-trip — synthetic IQ data in,
# spec-compliant SigMF out, metadata verified against what was
# requested. Covers all three supported input formats (ci16_le/RX-888,
# cu8/RTL-SDR, ci8/HackRF), not just the original ci16_le-only test —
# each has different normalization in decode/sigmf_writer.py and a bug
# in one wouldn't necessarily show up in another. Still synthetic, not
# real hardware capture — see scripts/capture-to-sigmf.sh for that.
#
# Usage: ./scripts/phase6-sigmf-writer-validate.sh

set -uo pipefail

VENV_PYTHON="/opt/sovereign-sigint/venvs/sigint-processing/bin/python3"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date +%s)"
SCRATCH="$(mktemp -d /tmp/sovereign-sigint-phase6-sigmf-validate.XXXXXX)"

RESULTS=()
CLEANUP_NAMES=()

cleanup() {
  rm -rf "${SCRATCH}"
  for name in "${CLEANUP_NAMES[@]}"; do
    rm -f "/data/signals/generated/${name}.sigmf-meta" \
          "/data/signals/generated/${name}.sigmf-data"
  done
}
trap cleanup EXIT

echo "== Phase 6.5 validation: SigMF writer =="
echo

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "FAIL: sigint-processing venv not found at ${VENV_PYTHON}"
  exit 1
fi

TEST_SAMPLE_RATE=1000000
TEST_CENTER_FREQ=14074000
TEST_NUM_SAMPLES=10000

# ---------------------------------------------------------------------
# Generate synthetic test data for one format — a known complex
# sinusoid scaled to that format's actual range, not noise, so the raw
# bytes are also sanity-checkable rather than just checking file sizes.
# ---------------------------------------------------------------------
generate_test_signal() {
  local fmt="$1" out_path="$2"
  "${VENV_PYTHON}" - <<PYEOF
import numpy as np
n = ${TEST_NUM_SAMPLES}
t = np.arange(n) / ${TEST_SAMPLE_RATE}
tone_freq = 1000
iq = np.exp(2j * np.pi * tone_freq * t)

fmt = "${fmt}"
if fmt == "ci16_le":
    scaled = iq * 20000
    i = np.real(scaled).astype(np.int16)
    q = np.imag(scaled).astype(np.int16)
    interleaved = np.empty(n * 2, dtype=np.int16)
elif fmt == "cu8":
    # RTL-SDR convention: unsigned 0-255, centered at 127.5
    scaled = iq * 100 + (127.5 + 127.5j)
    i = np.clip(np.real(scaled), 0, 255).astype(np.uint8)
    q = np.clip(np.imag(scaled), 0, 255).astype(np.uint8)
    interleaved = np.empty(n * 2, dtype=np.uint8)
elif fmt == "ci8":
    # HackRF convention: signed -128 to 127
    scaled = iq * 100
    i = np.clip(np.real(scaled), -128, 127).astype(np.int8)
    q = np.clip(np.imag(scaled), -128, 127).astype(np.int8)
    interleaved = np.empty(n * 2, dtype=np.int8)
else:
    raise ValueError(fmt)

interleaved[0::2] = i
interleaved[1::2] = q
interleaved.tofile("${out_path}")
print(f"Wrote {n} synthetic {fmt} samples ({interleaved.nbytes} bytes)")
PYEOF
}

# ---------------------------------------------------------------------
# Run one full round-trip test for a given input format
# ---------------------------------------------------------------------
run_format_test() {
  local fmt="$1"
  local test_name="_phase6_5_validate_${fmt}_${RUN_ID}"
  local test_raw="${SCRATCH}/test_${fmt}.bin"
  CLEANUP_NAMES+=("${test_name}")

  echo "-- [${fmt}] Generating synthetic test IQ --"
  generate_test_signal "${fmt}" "${test_raw}"
  echo

  echo "-- [${fmt}] Running sigmf_writer.py --"
  cd "${REPO_ROOT}/decode"
  if "${VENV_PYTHON}" sigmf_writer.py \
    --input "${test_raw}" \
    --output-name "${test_name}" \
    --sample-rate "${TEST_SAMPLE_RATE}" \
    --center-freq "${TEST_CENTER_FREQ}" \
    --input-format "${fmt}" \
    --description "Phase 6.5 validation synthetic tone (${fmt})" \
    --author "sovereign-sigint-validate" \
    > "${SCRATCH}/${fmt}_writer.log" 2>&1; then
    echo "  Writer exited cleanly"
  else
    echo "  FAIL: sigmf_writer.py exited with an error — see ${SCRATCH}/${fmt}_writer.log"
    cat "${SCRATCH}/${fmt}_writer.log"
    RESULTS+=("[${fmt}] Writer execution: FAIL")
    return
  fi

  local meta_path="/data/signals/generated/${test_name}.sigmf-meta"
  local data_path="/data/signals/generated/${test_name}.sigmf-data"

  if [[ ! -f "${meta_path}" || ! -f "${data_path}" ]]; then
    echo "  FAIL: expected output files missing at ${meta_path} / ${data_path}"
    RESULTS+=("[${fmt}] Output files: FAIL")
    return
  fi
  echo "  PASS: both .sigmf-meta and .sigmf-data exist"
  RESULTS+=("[${fmt}] Output files: PASS")

  local meta_sample_rate meta_freq
  meta_sample_rate="$(python3 -c "import json; print(json.load(open('${meta_path}'))['global'].get('core:sample_rate'))")"
  meta_freq="$(python3 -c "import json; print(json.load(open('${meta_path}'))['captures'][0].get('core:frequency'))" 2>/dev/null || echo "MISSING")"

  if [[ "${meta_sample_rate}" == "${TEST_SAMPLE_RATE}.0" || "${meta_sample_rate}" == "${TEST_SAMPLE_RATE}" ]]; then
    echo "  PASS: sample_rate matches (${meta_sample_rate})"
    RESULTS+=("[${fmt}] Sample rate metadata: PASS")
  else
    echo "  FAIL: sample_rate mismatch — expected ${TEST_SAMPLE_RATE}, got ${meta_sample_rate}"
    RESULTS+=("[${fmt}] Sample rate metadata: FAIL")
  fi

  if [[ "${meta_freq}" == "${TEST_CENTER_FREQ}.0" || "${meta_freq}" == "${TEST_CENTER_FREQ}" ]]; then
    echo "  PASS: center frequency matches (${meta_freq})"
    RESULTS+=("[${fmt}] Frequency metadata: PASS")
  else
    echo "  FAIL: center frequency mismatch — expected ${TEST_CENTER_FREQ}, got ${meta_freq}"
    RESULTS+=("[${fmt}] Frequency metadata: FAIL")
  fi

  local verify_output verify_exit
  verify_output="$("${VENV_PYTHON}" -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/decode')
from sigmf_writer import verify_written_recording
from pathlib import Path
result = verify_written_recording(Path('${meta_path}'), Path('${data_path}'))
print(result)
if result['hash_match'] is False:
    sys.exit(1)
" 2>&1)"
  verify_exit=$?
  echo "  ${verify_output}"
  if [[ "${verify_exit}" -eq 0 ]]; then
    echo "  PASS: SHA512 hash check did not fail"
    RESULTS+=("[${fmt}] SHA512 integrity: PASS")
  else
    echo "  FAIL: hash mismatch detected"
    RESULTS+=("[${fmt}] SHA512 integrity: FAIL")
  fi
  echo
}

for fmt in ci16_le cu8 ci8; do
  run_format_test "${fmt}"
done

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
  echo "Phase 6.5 NOT complete — resolve failures above."
  exit 1
else
  echo "Phase 6.5 exit criteria met against synthetic data for all three"
  echo "formats (ci16_le/RX-888, cu8/RTL-SDR, ci8/HackRF). Still worth"
  echo "running scripts/capture-to-sigmf.sh against real hardware — this"
  echo "validates the writer's correctness, not real-world signal fidelity."
fi
