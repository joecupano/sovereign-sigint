#!/usr/bin/env bash
# scripts/phase1-validate-sdrs.sh
#
# Phase 1 exit criteria per docs/build-order.md: a real sustained data
# capture from each SDR, not just USB enumeration. Run this AFTER
# scripts/phase1-hardware-drivers.sh and a reboot.
#
# Captures are throwaway smoke-test data — written to a scratch dir, not
# /data/signals/raw (that's for real SIGINT captures once Phase 6 exists).
#
# Usage: ./scripts/phase1-validate-sdrs.sh [--keep]
#   --keep   don't delete the scratch capture files on success (for
#            manually inspecting them, e.g. in Audacity/inspectrum)

set -uo pipefail  # NOT -e — we want to run all three tests and report
                   # all results even if one SDR fails, not stop at the first.

KEEP=false
[[ "${1:-}" == "--keep" ]] && KEEP=true

SCRATCH="$(mktemp -d /tmp/sovereign-sigint-phase1-validation.XXXXXX)"
RESULTS=()

echo "== Phase 1 SDR validation =="
echo "Scratch dir: ${SCRATCH}"
echo

# ---------------------------------------------------------------------
# RX-888 MkII — via rx888_stream (built by phase1-hardware-drivers.sh)
# ---------------------------------------------------------------------
echo "-- RX-888 MkII --"
RX888_BIN="$(find /opt/sovereign-sigint/src/rx888-firmware -maxdepth 3 -name rx888_stream -type f 2>/dev/null | head -1)"
if [[ -z "${RX888_BIN}" ]]; then
  echo "  SKIP: rx888_stream not found — not installed (or not selected"
  echo "  in phase1-hardware-drivers.sh's device menu). If you expected"
  echo "  this device to be installed, check why the build didn't run."
  RESULTS+=("RX-888 MkII: SKIP (not installed)")
else
  RX888_CAPTURE="${SCRATCH}/rx888_test.bin"
  # Locate the FX3 firmware image built/installed by phase1. This is
  # REQUIRED, not optional: confirmed on real hardware that the RX-888
  # powers up in Cypress FX3 DFU/bootloader mode (VID:PID 04b4:00f3,
  # "DFU mode" in lsusb, Driver=[none]), which enumerates at USB2 (480M)
  # BY DESIGN. It only re-enumerates as the actual SDR at USB3 (5000M)
  # AFTER firmware is uploaded. Without -f, rx888_stream fails with
  # LIBUSB_ERROR_NO_DEVICE (nothing to open) or is stuck at 480M — which
  # earlier looked like a USB3 host/cable/port fault but was actually
  # just "firmware not loaded yet." The device also returns to DFU mode
  # between runs / on power cycle, so firmware must be uploaded EVERY run.
  RX888_FW="$(find /opt/sovereign-sigint/src/rx888-firmware -name 'SDDC_FX3.img' -type f 2>/dev/null | head -1)"
  echo "  Capturing ~5s from RX-888 to ${RX888_CAPTURE}..."
  # CLI confirmed against rx888_stream --help + real hardware (2026-07):
  #   - -f <img>  uploads firmware, device re-enumerates (REQUIRED, see above)
  #   - streams int16 real samples to STDOUT (redirect with >), no -o flag
  #   - -s sets sample rate; ONLY 32000000 or 135000000 supported. 32 MSPS
  #     x 2 bytes = 64 MB/s, so USB3 (5000M) is required to sustain it —
  #     but a 480M reading BEFORE firmware upload is normal DFU-mode
  #     behavior, not necessarily a USB3 fault. Check speed AFTER -f.
  #   - capture duration controlled by how long the stream runs (timeout)
  RX888_RATE=32000000
  if [[ -z "${RX888_FW}" ]]; then
    echo "  FAIL: SDDC_FX3.img firmware not found under the rx888-firmware"
    echo "  build tree — re-run phase1-hardware-drivers.sh (rx888 selected)."
    RESULTS+=("RX-888 MkII: FAIL (firmware image missing)")
  else
    if timeout 10 "${RX888_BIN}" -f "${RX888_FW}" -s "${RX888_RATE}" > "${RX888_CAPTURE}" 2>"${SCRATCH}/rx888.log"; then
      RX888_RC=0
    else
      RX888_RC=$?
    fi
    SIZE=$(stat -c%s "${RX888_CAPTURE}" 2>/dev/null || echo 0)
    # timeout returns 124 when it kills a still-running stream — the
    # EXPECTED success path (stream runs until stopped), so 124 with a
    # real-sized file is a PASS.
    if [[ "${SIZE}" -gt 1000000 ]]; then
      echo "  PASS: captured ${SIZE} bytes (firmware uploaded, device streaming)"
      RESULTS+=("RX-888 MkII: PASS (${SIZE} bytes)")
    else
      echo "  FAIL: capture too small (${SIZE} bytes) — check ${SCRATCH}/rx888.log"
      echo "  If rx888.log shows firmware uploaded but then overruns, AND"
      echo "  lsusb -t shows the device still at 480M AFTER upload, only then"
      echo "  is it a genuine USB3 host/port issue. A NO_DEVICE error usually"
      echo "  means the firmware/re-enumeration handoff didn't complete."
      RESULTS+=("RX-888 MkII: FAIL (see rx888.log)")
    fi
  fi
fi
echo

# ---------------------------------------------------------------------
# HackRF — via hackrf_transfer
# ---------------------------------------------------------------------
echo "-- HackRF --"
if ! command -v hackrf_transfer >/dev/null 2>&1; then
  echo "  SKIP: hackrf_transfer not found — not installed (or not selected"
  echo "  in phase1-hardware-drivers.sh's device menu)."
  RESULTS+=("HackRF: SKIP (not installed)")
else
  HACKRF_CAPTURE="${SCRATCH}/hackrf_test.bin"
  echo "  Capturing 3s at 100 MHz to ${HACKRF_CAPTURE}..."
  if timeout 10 hackrf_transfer -r "${HACKRF_CAPTURE}" -f 100000000 -s 8000000 -n 24000000 \
      2>&1 | tee "${SCRATCH}/hackrf.log"; then
    SIZE=$(stat -c%s "${HACKRF_CAPTURE}" 2>/dev/null || echo 0)
    if [[ "${SIZE}" -gt 1000000 ]]; then
      echo "  PASS: captured ${SIZE} bytes"
      RESULTS+=("HackRF: PASS (${SIZE} bytes)")
    else
      echo "  FAIL: capture file too small (${SIZE} bytes) — check ${SCRATCH}/hackrf.log"
      RESULTS+=("HackRF: FAIL (capture too small)")
    fi
  else
    echo "  FAIL: hackrf_transfer exited with an error — check ${SCRATCH}/hackrf.log"
    RESULTS+=("HackRF: FAIL (see hackrf.log)")
  fi
fi
echo

# ---------------------------------------------------------------------
# RTL-SDR — via rtl_test (enumeration + sample-rate/dropped-sample check)
# and a short rtl_sdr capture for good measure
# ---------------------------------------------------------------------
echo "-- RTL-SDR --"
if ! command -v rtl_test >/dev/null 2>&1; then
  echo "  SKIP: rtl_test not found — not installed (or not selected in"
  echo "  phase1-hardware-drivers.sh's device menu)."
  RESULTS+=("RTL-SDR: SKIP (not installed)")
else
  echo "  Running rtl_test for 5s (checks for dropped samples)..."
  timeout 8 rtl_test -t 2>&1 | tee "${SCRATCH}/rtl_test.log" || true
  if grep -qi "dropped" "${SCRATCH}/rtl_test.log" && ! grep -q "dropped samples: 0" "${SCRATCH}/rtl_test.log"; then
    echo "  WARNING: rtl_test reported dropped samples — check ${SCRATCH}/rtl_test.log"
  fi

  RTL_CAPTURE="${SCRATCH}/rtl_test.bin"
  echo "  Capturing 3s at 100 MHz to ${RTL_CAPTURE}..."
  if timeout 10 rtl_sdr -f 100000000 -s 2048000 -n 6144000 "${RTL_CAPTURE}" \
      2>&1 | tee "${SCRATCH}/rtl_sdr.log"; then
    SIZE=$(stat -c%s "${RTL_CAPTURE}" 2>/dev/null || echo 0)
    if [[ "${SIZE}" -gt 1000000 ]]; then
      echo "  PASS: captured ${SIZE} bytes"
      RESULTS+=("RTL-SDR: PASS (${SIZE} bytes)")
    else
      echo "  FAIL: capture file too small (${SIZE} bytes) — check ${SCRATCH}/rtl_sdr.log"
      RESULTS+=("RTL-SDR: FAIL (capture too small)")
    fi
  else
    echo "  FAIL: rtl_sdr exited with an error — check ${SCRATCH}/rtl_sdr.log"
    RESULTS+=("RTL-SDR: FAIL (see rtl_sdr.log)")
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
echo

if [[ "${FAILED}" -eq 1 ]]; then
  echo "Phase 1 NOT complete — resolve failures above before Phase 2."
  echo "Capture logs kept at: ${SCRATCH}"
  exit 1
else
  echo "Phase 1 exit criteria met for all installed SDRs (SKIP = not"
  echo "installed, not a failure)."
  if [[ "${KEEP}" == true ]]; then
    echo "Captures kept at: ${SCRATCH}"
  else
    rm -rf "${SCRATCH}"
  fi
fi
