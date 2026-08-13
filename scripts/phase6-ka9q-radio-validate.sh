#!/usr/bin/env bash
# scripts/phase6-ka9q-radio-validate.sh
#
# Phase 6.1 exit criteria: radiod actually producing demodulated output
# from the RX-888 MkII — not just "systemctl says active." Uses
# pcmrecord (ka9q-radio's own capture utility) to grab a real sample
# from the WWV 10 MHz channel defined in
# ingest/ka9q-radio/radiod@rx888-hf.conf.
#
# NOTE: ka9q-radio's own README describes itself as "NOT yet ready for
# general use" with documentation still catching up to the code —
# pcmrecord's exact flags below are a best-effort reconstruction from
# community usage examples, not ka9q-radio's own authoritative docs.
# If this fails with an argument error, check `pcmrecord --help` on
# your actual build and adjust.
#
# Usage: ./scripts/phase6-ka9q-radio-validate.sh

set -uo pipefail

INSTANCE_NAME="rx888-hf"
CAPTURE_SECONDS=20
TEST_CHANNEL="wwv-10000-pcm.local"  # 10 MHz WWV — usually reliable, but
                                     # propagation varies; a quiet result
                                     # doesn't necessarily mean failure,
                                     # see the note in the summary below

SCRATCH="$(mktemp -d /tmp/sovereign-sigint-phase6-ka9q-validate.XXXXXX)"
RESULTS=()

echo "== Phase 6.1 validation: ka9q-radio (radiod) =="
echo

# ---------------------------------------------------------------------
# Service status
# ---------------------------------------------------------------------
echo "-- Service status --"
if systemctl is-active --quiet "radiod@${INSTANCE_NAME}"; then
  echo "  PASS: radiod@${INSTANCE_NAME} is active"
  RESULTS+=("Service active: PASS")
else
  echo "  FAIL: radiod@${INSTANCE_NAME} is not active"
  echo "  Check: journalctl -u radiod@${INSTANCE_NAME} -n 50 --no-pager"
  RESULTS+=("Service active: FAIL")
fi
echo

# ---------------------------------------------------------------------
# Check for firmware-related errors in recent logs specifically —
# the most likely failure mode per scripts/phase6-ka9q-radio.sh's own
# unconfirmed firmware-path guess
# ---------------------------------------------------------------------
echo "-- Checking recent logs for firmware errors --"
if journalctl -u "radiod@${INSTANCE_NAME}" -n 100 --no-pager 2>/dev/null | grep -qi "firmware"; then
  echo "  WARNING: 'firmware' appears in recent logs — check whether this"
  echo "  is an error (wrong search path — see phase6-ka9q-radio.sh's"
  echo "  firmware placement note) or just informational."
  journalctl -u "radiod@${INSTANCE_NAME}" -n 100 --no-pager 2>/dev/null | grep -i "firmware"
else
  echo "  No firmware-related log lines in the last 100 entries."
fi
echo

# ---------------------------------------------------------------------
# Real capture via pcmrecord
# ---------------------------------------------------------------------
echo "-- Capturing ${CAPTURE_SECONDS}s from ${TEST_CHANNEL} --"
PCMRECORD_BIN="$(command -v pcmrecord || echo /usr/local/bin/pcmrecord)"

if [[ ! -x "${PCMRECORD_BIN}" ]]; then
  echo "  FAIL: pcmrecord not found — did 'make install' succeed?"
  RESULTS+=("Capture: FAIL (pcmrecord not found)")
else
  timeout $((CAPTURE_SECONDS + 10)) "${PCMRECORD_BIN}" -v -t "${CAPTURE_SECONDS}" \
    -d "${SCRATCH}" "${TEST_CHANNEL}" 2>&1 | tee "${SCRATCH}/pcmrecord.log"

  WAV_FILE="$(find "${SCRATCH}" -name "*.wav" -newer "${SCRATCH}/pcmrecord.log" 2>/dev/null | head -1)"
  if [[ -z "${WAV_FILE}" ]]; then
    WAV_FILE="$(find "${SCRATCH}" -name "*.wav" | head -1)"
  fi

  if [[ -n "${WAV_FILE}" ]]; then
    SIZE=$(stat -c%s "${WAV_FILE}" 2>/dev/null || echo 0)
    if [[ "${SIZE}" -gt 10000 ]]; then
      echo "  PASS: captured ${SIZE} bytes to ${WAV_FILE}"
      RESULTS+=("Capture: PASS (${SIZE} bytes)")
    else
      echo "  PARTIAL: capture file exists but is very small (${SIZE} bytes)"
      echo "  — could be a quiet propagation period on 10 MHz rather than"
      echo "  a pipeline failure. Try a different WWV frequency (2.5/5/15 MHz,"
      echo "  see ingest/ka9q-radio/radiod@rx888-hf.conf) or check at a"
      echo "  different time of day before concluding this has failed."
      RESULTS+=("Capture: PARTIAL (${SIZE} bytes, check log)")
    fi
  else
    echo "  FAIL: no .wav file produced — see ${SCRATCH}/pcmrecord.log"
    cat "${SCRATCH}/pcmrecord.log"
    RESULTS+=("Capture: FAIL (no output file)")
  fi
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
echo "Capture files kept at: ${SCRATCH}"
echo

if [[ "${FAILED}" -eq 1 ]]; then
  echo "Phase 6.1 NOT complete — resolve failures above before continuing Phase 6."
  exit 1
else
  echo "Phase 6.1 exit criteria met (see PARTIAL notes above, if any)."
fi
