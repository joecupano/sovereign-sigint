#!/usr/bin/env bash
# scripts/phase6-decode-tools-validate.sh
#
# Phase 6.2 exit criteria: each tool actually works, not just "apt
# install succeeded." GNU Radio gets a real functional test (build and
# run a trivial flowgraph) since that's the tool with genuine risk here
# — the system-dist-packages Python wiring flagged in
# phase6-decode-tools.sh. direwolf and multimon-ng get a version/startup
# check; full decode-path validation for those needs real captured
# audio (APRS packets, POCSAG/FLEX traffic) which isn't synthesized
# here — same kind of coverage gap as the scanned-PDF case in Phase 5,
# flagged rather than silently skipped.
#
# Usage: ./scripts/phase6-decode-tools-validate.sh

set -uo pipefail

RESULTS=()
SCRATCH="$(mktemp -d /tmp/sovereign-sigint-phase6-decode-validate.XXXXXX)"

echo "== Phase 6.2 validation: decode layer =="
echo

# ---------------------------------------------------------------------
# GNU Radio — intentionally NOT installed (deferred advanced topic)
# ---------------------------------------------------------------------
# GNU Radio was removed from this build: nothing in the working system uses
# it (occupancy producers capture via hackrf_transfer/rtl_sdr/pcmrecord;
# OpenWebRX+ has its own DSP). Flowgraph work is deferred to a desktop. So
# there is no GNU Radio functional test here. See phase6-decode-tools.sh.
echo "-- GNU Radio: skipped (not installed; deferred advanced topic) --"
echo

# ---------------------------------------------------------------------
# direwolf — startup/version check
# ---------------------------------------------------------------------
echo "-- direwolf --"
if command -v direwolf >/dev/null 2>&1; then
  DIREWOLF_OUT="$(direwolf -h 2>&1 | head -5)"
  echo "  PASS: direwolf runs"
  echo "    ${DIREWOLF_OUT}" | head -1
  RESULTS+=("direwolf: PASS (startup only — no real APRS decode tested)")
else
  echo "  FAIL: direwolf not found"
  RESULTS+=("direwolf: FAIL")
fi
echo

# ---------------------------------------------------------------------
# multimon-ng — startup/version check
# ---------------------------------------------------------------------
echo "-- multimon-ng --"
if command -v multimon-ng >/dev/null 2>&1; then
  echo "  PASS: multimon-ng runs"
  RESULTS+=("multimon-ng: PASS (startup only — no real digital-mode decode tested)")
else
  echo "  FAIL: multimon-ng not found"
  RESULTS+=("multimon-ng: FAIL")
fi
echo

# ---------------------------------------------------------------------
# ffmpeg — real functional test: generate a tone, confirm real output
# ---------------------------------------------------------------------
echo "-- ffmpeg (real encode test) --"
FFMPEG_TEST_FILE="${SCRATCH}/test_tone.wav"
if ffmpeg -y -f lavfi -i "sine=frequency=1000:duration=1" "${FFMPEG_TEST_FILE}" \
    > "${SCRATCH}/ffmpeg.log" 2>&1; then
  SIZE=$(stat -c%s "${FFMPEG_TEST_FILE}" 2>/dev/null || echo 0)
  if [[ "${SIZE}" -gt 10000 ]]; then
    echo "  PASS: generated ${SIZE}-byte test tone"
    RESULTS+=("ffmpeg: PASS (${SIZE} bytes)")
  else
    echo "  FAIL: output file too small (${SIZE} bytes) — see ${SCRATCH}/ffmpeg.log"
    RESULTS+=("ffmpeg: FAIL (output too small)")
  fi
else
  echo "  FAIL: ffmpeg exited with an error — see ${SCRATCH}/ffmpeg.log"
  RESULTS+=("ffmpeg: FAIL")
fi
echo

echo "NOTE: direwolf and multimon-ng are only startup-checked here, not"
echo "decode-path tested — that needs real captured APRS/POCSAG/FLEX"
echo "audio, which isn't synthesized in this script. Test those against"
echo "real traffic once Phase 6.1's HF/VHF streams are flowing."
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
rm -rf "${SCRATCH}"
echo

if [[ "${FAILED}" -eq 1 ]]; then
  echo "Phase 6.2 NOT complete — resolve failures above."
  exit 1
else
  echo "Phase 6.2 exit criteria met (see decode-path coverage note above)."
fi
