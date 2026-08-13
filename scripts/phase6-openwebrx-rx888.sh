#!/usr/bin/env bash
# =====================================================================
# phase6-openwebrx-rx888.sh — enable the RX-888 in OpenWebRX+ via the
# CPU-only SoapySDR path (soapy_sddc), building libsddc + SoapySDDC from
# source.
# =====================================================================
# WHY THIS EXISTS
# OpenWebRX+'s Feature Report on this box shows every native SDDC path as
# NO (sddc, sddc_connector, sddc_soapy) EXCEPT that soapy_connector is
# YES. The report itself recommends soapy_sddc as the alternative to
# sddc_connector: it "relies solely on the CPU and does not require an
# NVIDIA GPU" — which is what we want, since the RTX 5060 Ti is reserved
# for Ollama/vision, not for feeding a waterfall. soapy_sddc is provided
# by the SoapySDDC module, which is NOT packaged and must be built from
# source (along with its libsddc dependency).
#
# WHAT THIS GIVES YOU
# A full 0-30 MHz HF waterfall in OpenWebRX+ driven by the RX-888 — the
# interactive, tune-anywhere view. This is the "sit and explore" use
# case the RX-888 was originally bought for. It is SEPARATE from the AI
# mission, where radiod already drives the RX-888 for continuous
# multichannel occupancy.
#
# CRITICAL: TWO DRIVER STACKS, ONE DEVICE
# This installs a SECOND, independent RX-888 driver stack (libsddc +
# SoapySDDC) alongside radiod's existing stack (ka9q's own libusb code +
# SDDC_FX3.img). They CANNOT run at the same time — the RX-888 is a
# single-owner USB device. Use scripts/rx888-mode.sh to switch:
#   sudo ./scripts/rx888-mode.sh interactive   # OpenWebRX+ owns it (this)
#   sudo ./scripts/rx888-mode.sh ai            # radiod owns it (default)
# Each stack loads its OWN firmware onto the FX3 when it opens the
# device, and the FX3 takes fresh firmware on each power cycle, so
# switching is clean AS LONG AS you power-cycle / let the mode script
# fully release the device between owners. If OpenWebRX+ can't open the
# RX-888 after switching, power-cycle the device (unplug ~15s) so its
# FX3 returns to DFU/bootloader mode, then retry — same DFU behavior
# documented for radiod in docs/build-order.md.
#
# Usage:  sudo ./scripts/phase6-openwebrx-rx888.sh
# Override source commits with LIBSDDC_COMMIT / SOAPYSDDC_REPO if needed.
# ---------------------------------------------------------------------
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo (installs libraries + udev rules)." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-baldrick}"
SRC_ROOT="/opt/sovereign-sigint/src"

# Canonical upstream libsddc (Franco Venturi) — the reference Linux
# library the SoapySDR module builds against. The ON5HB/RX888MK2-Soapy
# fork bundles libsddc + SoapySDDC + firmware together and is the more
# actively-maintained "just works on Linux for websdr" option; we use it
# for the SoapySDDC module and its embedded firmware, since it's built
# and tested specifically for the websdr use case.
SOAPYSDDC_REPO="${SOAPYSDDC_REPO:-https://github.com/ON5HB/RX888MK2-Soapy.git}"

echo "== Phase 6 (optional): RX-888 in OpenWebRX+ via SoapySDDC =="
echo

# --- 0. Preconditions ------------------------------------------------
echo "-- Checking preconditions --"
# SoapySDR dev headers are required to build a Soapy module. If OpenWebRX+
# reports soapy_connector=YES, the runtime is present, but we need -dev.
if ! pkg-config --exists SoapySDR 2>/dev/null && \
   ! ls /usr/include/SoapySDR/Device.hpp >/dev/null 2>&1; then
  echo "  Installing SoapySDR development headers..."
  apt-get update -qq
  apt-get install -y libsoapysdr-dev soapysdr-tools
else
  echo "  SoapySDR dev headers present."
fi

echo "  Installing build dependencies (fftw3, libusb, cmake)..."
apt-get install -y git build-essential cmake pkg-config \
  libfftw3-dev libusb-1.0-0-dev

# --- 1. Build the SoapySDDC module (bundles libsddc + firmware) -------
echo "-- Cloning + building SoapySDDC (${SOAPYSDDC_REPO}) --"
mkdir -p "${SRC_ROOT}"
DEST="${SRC_ROOT}/RX888MK2-Soapy"
if [[ ! -d "${DEST}" ]]; then
  git clone --depth 1 "${SOAPYSDDC_REPO}" "${DEST}"
else
  echo "  Source already present, pulling latest..."
  git -C "${DEST}" pull --ff-only || true
fi

cd "${DEST}"
rm -rf build
mkdir build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
# The project's 'unittest' target fails to build on Ubuntu 24.04 (test
# harness issue) and takes the whole 'make all' down with it — but the
# actual driver module (libSDDCSupport.so) and libsddc build fine before
# that. Build the specific targets we need rather than 'all', so the
# broken unittest can't block us. Confirmed on real hardware 2026-07.
echo "-- Building (this can take a few minutes) --"
make -j"$(nproc)" sddc SDDCSupport || make -j"$(nproc)" || true
echo "-- Build step finished, proceeding to install --"

# Locate the built Soapy module and install it into SoapySDR's ACTIVE
# module directory (the one SoapySDRUtil actually scans — version-specific,
# e.g. modules0.8). 'make install' is unreliable here because it runs
# through the broken 'all' target, so we place the module directly.
echo "-- Locating built module --"
SDDC_MODULE="$(find "${DEST}/build" -name 'libSDDCSupport.so' -type f 2>/dev/null | head -1)"
if [[ -z "${SDDC_MODULE}" ]]; then
  echo "  ERROR: libSDDCSupport.so was not built — check the cmake/make output." >&2
  exit 1
fi
echo "  Found: ${SDDC_MODULE}"
# Ask SoapySDR itself where its (existing, non-missing) module dir is.
# Defensively guarded: under 'pipefail', a nonzero from EITHER command in this
# pipeline would otherwise silently kill the whole script right here with no
# visible error — confirmed as a real, hard-to-diagnose failure mode on a real
# run (build succeeded, script exited 0, but every step after this point never
# ran or logged). The || true + explicit fallback below means a lookup hiccup
# degrades to the sane default path instead of an unexplained silent stop.
echo "-- Asking SoapySDR for its active module directory --"
SOAPY_MOD_DIR="$( (SoapySDRUtil --info 2>/dev/null \
  | awk '/Search path:/ && $0 !~ /missing/ {print $3; exit}') || true )"
SOAPY_MOD_DIR="${SOAPY_MOD_DIR:-/usr/lib/x86_64-linux-gnu/SoapySDR/modules0.8}"
echo "  Using: ${SOAPY_MOD_DIR}"
echo "-- Installing ${SDDC_MODULE##*/} -> ${SOAPY_MOD_DIR} --"
install -Dm644 "${SDDC_MODULE}" "${SOAPY_MOD_DIR}/libSDDCSupport.so"
echo "-- Installing libsddc runtime dependency --"
# Also install libsddc so the module's runtime dependency resolves.
find "${DEST}/build" -name 'libsddc.so*' -exec cp -a {} /usr/local/lib/ \; 2>/dev/null || true
ldconfig
echo "-- Module install complete --"

# --- 2. udev rule so the device is accessible without root -----------
# libsddc ships a udev rule; if present use it, else write a minimal one
# covering the RX-888 FX3 bootloader (04b4:00f3) and loaded (04b4:00f1)
# identities so both OpenWebRX+ (this stack) and the mode switch work.
echo "-- Installing udev rule for RX-888 USB access --"
UDEV_RULE=/etc/udev/rules.d/99-rx888-sddc.rules
if [[ -f "${DEST}/libsddc/misc/99-sddc.rules" ]]; then
  cp "${DEST}/libsddc/misc/99-sddc.rules" "${UDEV_RULE}"
  echo "  Installed vendored libsddc udev rule."
else
  cat > "${UDEV_RULE}" <<'EOF'
# RX-888 / SDDC-family USB access for non-root (OpenWebRX+ soapy_sddc)
SUBSYSTEM=="usb", ATTRS{idVendor}=="04b4", ATTRS{idProduct}=="00f3", MODE="0666"
SUBSYSTEM=="usb", ATTRS{idVendor}=="04b4", ATTRS{idProduct}=="00f1", MODE="0666"
EOF
  echo "  Wrote minimal RX-888 udev rule (DFU 00f3 + loaded 00f1)."
fi
udevadm control --reload-rules
udevadm trigger || true

# --- 3. Verify the SoapySDR module is registered ---------------------
echo "-- Verifying SoapySDR sees the SDDC driver --"
if command -v SoapySDRUtil >/dev/null 2>&1; then
  if SoapySDRUtil --info 2>/dev/null | grep -iq "sddc"; then
    echo "  OK: SoapySDR lists an SDDC driver module."
  else
    echo "  NOTE: SoapySDRUtil did not list 'sddc' in module search."
    echo "  Check: SoapySDRUtil --info   (look for the module path), and"
    echo "  ensure SOAPY_SDR_PLUGIN_PATH covers the install dir if the"
    echo "  module landed somewhere non-standard."
  fi
else
  echo "  NOTE: SoapySDRUtil not found; skipping module check."
fi

echo
echo "== Build complete =="
echo
echo "NEXT STEPS (manual — OpenWebRX+ side):"
echo "  1. Hand the RX-888 to OpenWebRX+ (stops radiod, frees the device):"
echo "       sudo ./scripts/rx888-mode.sh interactive"
echo "  2. Restart OpenWebRX+ so it re-reads its feature report:"
echo "       sudo systemctl restart openwebrx"
echo "  3. In the OpenWebRX+ web UI: Settings -> Feature report, confirm"
echo "     'soapy_sddc' now shows YES (was NO)."
echo "  4. Settings -> SDR devices -> Add device. Confirmed via a real run:"
echo "     the device-type list does NOT show a generic 'SoapySDR device'"
echo "     entry for this — pick the specific one:"
echo "       'BBRF103 / RX666 / RX888 / RX888 mkII (SDDC) device (via SoapySDR)'"
echo "     Sample rate is a FIXED discrete list, not free-entry MSPS — confirmed"
echo "     allowed values: 2, 4, 8, 16, 32, 64 (millions of samples/sec)."
echo "     64.8 (radiod's exact native rate) is REJECTED here; use 64."
echo "     Then add a profile: center frequency matters for a sane display —"
echo "     e.g. center ~15,000,000 Hz covers a sensible chunk of HF. A low"
echo "     center (e.g. 3.5 MHz) with a wide sample rate pushes much of the"
echo "     displayed span below 0 Hz and looks like a broken/confusing"
echo "     waterfall (confirmed on a real run) — it's a tuning choice, not a"
echo "     bug."
echo "  CONFIRMED WORKING CONFIG on this box's hardware (Xeon W-2145, this"
echo "  exact USB topology) — a good starting point rather than 64 MSPS:"
echo "     - 64 MSPS pegged soapy_connector + openwebrx near/above 180% CPU"
echo "       combined and caused audible audio stutter (verified via 'top')."
echo "     - 32 MSPS eliminated the stutter."
echo "     - Default FFT size (4096) at 32 MSPS gives ~7.8 kHz/bin -- too"
echo "       coarse, narrowband signals show as a wide blur rather than a"
echo "       thin trace."
echo "     - Raising the PRIMARY 'FFT size' (a GLOBAL setting, affects all"
echo "       receivers) from 4096 to 16384 (~1.95 kHz/bin at 32 MSPS) fixed"
echo "       the resolution with no stutter returning. Leave the secondary/"
echo "       audio FFT size field alone -- it's a different, smaller-scope"
echo "       display, not the waterfall's resolution."
echo "     - Net: center ~15 MHz, 32 MSPS, FFT size 16384 is a solid default"
echo "       for this hardware. 64 MSPS remains available for occasional"
echo "       wide-view sessions if you can tolerate the CPU cost."
echo "  5. Save the device AND the profile."
echo "  6. CRITICAL, confirmed via a real run: a newly added/edited profile"
echo "     will NOT appear in the main receiver page's selector until you"
echo "     restart the service again:"
echo "       sudo systemctl restart openwebrx"
echo "     The device/profile IS correctly saved to settings.json immediately"
echo "     (verify: 'sudo python3 -m json.tool /var/lib/openwebrx/settings.json"
echo "     | grep -A10 sddc' if in doubt) — it's the running process's in-memory"
echo "     receiver list that's stale, not a save failure. Without this restart"
echo "     it looks exactly like the profile silently vanished or never saved;"
echo "     it didn't — just restart and it appears."
echo "  7. Reload the main receiver page; select the RX-888 profile."
echo
echo "IMPORTANT: When done exploring, return the device to the AI path:"
echo "     sudo ./scripts/rx888-mode.sh ai"
echo "This second driver stack and radiod CANNOT both hold the RX-888."
echo "If OpenWebRX+ can't open the device, power-cycle it (unplug ~15s)"
echo "so its FX3 returns to DFU mode, then retry — see docs/build-order.md."
