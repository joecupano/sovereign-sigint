#!/usr/bin/env bash
# Phase 1 — Hardware and drivers. Kernel/USB/GPU-level, plus the
# toolchain needed to BUILD drivers from source (the RX-888 MkII has no
# packaged driver — rx888_stream must be compiled here). See
# docs/build-order.md for the full phase rationale and exit criteria.
#
# This script INSTALLS. It does not validate. Run
# scripts/phase1-validate-sdrs.sh and
# scripts/phase1-validate-protocol-tools.sh afterward — enumeration
# alone (lsusb) is not a pass per docs/build-order.md.
#
# git/build-essential/cmake/pkg-config are installed here, not in Phase 2
# — they're not general dev tooling in this context, they're what Phase 1
# needs to build its own from-source drivers. Phase 2 still owns the
# broader OS-level dev environment (Python, general runtime tooling);
# Phase 6's later from-source builds (ka9q-radio, GNU Radio) can rely on
# this toolchain already being present and already proven working.
#
# DEVICE SELECTION: hardware you don't have yet (or don't want to touch
# right now) doesn't need to be installed just because it's supported —
# you'll be prompted to choose which devices to install. Non-interactive
# override: set DEVICES to a space-separated list of keys (see the menu
# below) before running, e.g.:
#   DEVICES="hackrf rtlsdr" sudo -E ./scripts/phase1-hardware-drivers.sh
#
# Usage: sudo ./scripts/phase1-hardware-drivers.sh

set -euo pipefail

SRC_ROOT="/opt/sovereign-sigint/src"
TARGET_USER="${SUDO_USER:-$(id -un)}"

# =======================================================================
# Base / always-run — GPU, mDNS, and the shared build toolchain. Not
# device-specific, so not part of the selection menu below.
# =======================================================================
install_base() {
  echo "== Base: GPU, mDNS, build toolchain =="
  sudo apt update

  echo "-- NVIDIA driver --"
  # ubuntu-drivers auto-selects the recommended driver rather than
  # pinning a version — the RTX 5060 Ti is recent hardware and the
  # correct minimum branch shifts as NVIDIA updates packaging. Verify
  # against NVIDIA's current Ubuntu 24.04 (noble) install docs if this
  # is running against a new image.
  sudo apt install -y ubuntu-drivers-common
  sudo ubuntu-drivers autoinstall

  echo "-- CUDA toolkit --"
  # Confirm this URL is still current at
  # https://developer.nvidia.com/cuda-downloads (Linux > x86_64 >
  # Ubuntu > 24.04 > deb (network)) before relying on it long-term.
  local cuda_keyring_deb="cuda-keyring_1.1-1_all.deb"
  local cuda_keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/${cuda_keyring_deb}"
  local tmp_deb
  tmp_deb="$(mktemp -d)/${cuda_keyring_deb}"
  wget -qO "${tmp_deb}" "${cuda_keyring_url}"
  sudo dpkg -i "${tmp_deb}"

  # IMPORTANT: the CUDA repo ships its OWN NVIDIA *driver* packages, which can
  # be a different point release than Ubuntu's recommended driver (installed
  # above by ubuntu-drivers). If apt pulls a driver from the CUDA repo it can
  # collide with Ubuntu's — producing an alarming "held broken packages" error
  # mid-run (e.g. nvidia-kernel-common-580 from CUDA vs linux-modules-nvidia-580
  # from Ubuntu wanting an older point release). apt refuses the bad combo and
  # continues, so it's self-correcting and NOT fatal — but we prevent it
  # entirely by pinning the CUDA repo so it can supply the CUDA *toolkit* but
  # never NVIDIA driver packages. The Ubuntu-recommended driver stays intact.
  echo "-- pin CUDA repo away from driver packages --"
  sudo tee /etc/apt/preferences.d/cuda-no-driver >/dev/null <<'PIN'
Package: nvidia-driver-* nvidia-kernel-common-* nvidia-kernel-source-* linux-modules-nvidia-*
Pin: origin developer.download.nvidia.com
Pin-Priority: -1
PIN

  sudo apt update
  sudo apt install -y cuda-toolkit
  echo "NOTE: a reboot is required before nvidia-smi will report the GPU."
  echo "NOTE: if you saw an apt 'held broken packages' complaint about"
  echo "      nvidia-*-580 during this step, it is expected and harmless —"
  echo "      apt correctly refused a CUDA-repo driver that conflicts with the"
  echo "      Ubuntu-recommended one; the pin above prevents it going forward."

  echo "-- avahi (mDNS) --"
  sudo apt install -y avahi-daemon avahi-utils libnss-mdns
  sudo systemctl enable --now avahi-daemon

  echo "-- Build toolchain (RX-888/Ubertooth from-source builds) + libusb --"
  sudo apt install -y git build-essential cmake pkg-config \
    libusb-1.0-0 libusb-1.0-0-dev

  sudo mkdir -p "${SRC_ROOT}"
  sudo chown "${TARGET_USER}:${TARGET_USER}" "${SRC_ROOT}"
}

# =======================================================================
# Device-specific installs
# =======================================================================

install_hackrf() {
  echo "== HackRF =="
  sudo apt install -y hackrf libhackrf0 libhackrf-dev
}

install_rtlsdr() {
  echo "== RTL-SDR =="
  # librtlsdr0 was renamed to librtlsdr2 on Ubuntu 24.04 (noble) — SONAME
  # bump between library versions. Confirmed via packages.ubuntu.com;
  # if this breaks again on a future release, check
  # `apt-cache search librtlsdr` for the current name rather than guess.
  sudo apt install -y rtl-sdr librtlsdr2 librtlsdr-dev
  echo "-- Blacklisting kernel DVB-T driver (dvb_usb_rtl28xxu) --"
  echo 'blacklist dvb_usb_rtl28xxu' | sudo tee /etc/modprobe.d/rtlsdr-blacklist.conf
  sudo update-initramfs -u
}

install_rx888() {
  echo "== RX-888 MkII =="
  # firmware + rx888_stream (from ringof/rx888-firmware, MIT-licensed,
  # includes the rx888_tools submodule this needs)
  if [[ ! -d "${SRC_ROOT}/rx888-firmware" ]]; then
    git clone --quiet https://github.com/ringof/rx888-firmware.git \
      "${SRC_ROOT}/rx888-firmware"
  fi
  (
    cd "${SRC_ROOT}/rx888-firmware"
    git submodule update --init
    # This project's own test harness (in tests/) is the documented
    # build path as of this writing — verify against the repo's current
    # README/docs before relying on it, since this firmware/tooling
    # stack has an active recovery-cascade rewrite in progress.
    if [[ -d tests ]]; then
      (cd tests && make)
    fi
    # udev rules — grants the running user access to both the
    # bootloader (PID 00f3) and programmed (PID 00f1) device endpoints.
    # Without this, rx888_stream/fx3_cmd fail with LIBUSB_ERROR_ACCESS
    # unless run as root.
    if [[ -f tests/rx888_tools/udev/99-rx888.rules ]]; then
      sudo cp tests/rx888_tools/udev/99-rx888.rules /etc/udev/rules.d/
      sudo udevadm control --reload-rules
      sudo udevadm trigger
    fi
  )

  # usbfs memory limit — sustained USB3 streaming submits many large
  # transfers concurrently; Linux's default 16MB per-device usbfs
  # buffer limit isn't enough and causes LIBUSB_ERROR_NO_MEM.
  echo "-- Raising usbfs_memory_mb limit --"
  sudo sh -c 'echo 1000 > /sys/module/usbcore/parameters/usbfs_memory_mb' || \
    echo "WARNING: could not set usbfs_memory_mb at runtime — check manually."

  # Persistence: confirmed in real-world testing that the modprobe.d
  # approach silently does nothing when usbcore is built into the
  # kernel rather than loaded as a module — which is the common case
  # on generic Ubuntu x86 kernels. The GRUB kernel boot parameter
  # method works either way (built-in or loadable), so use that as the
  # actual persistence mechanism rather than relying on modprobe.d.
  echo "-- Persisting usbfs_memory_mb via GRUB kernel parameter --"
  if grep -q "usbcore.usbfs_memory_mb=" /etc/default/grub 2>/dev/null; then
    echo "  Already present in /etc/default/grub — leaving as-is."
  else
    sudo cp /etc/default/grub /etc/default/grub.bak
    sudo sed -i \
      's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 usbcore.usbfs_memory_mb=1000"/' \
      /etc/default/grub
    sudo update-grub
    echo "  Added and ran update-grub. This needs a REBOOT to take effect —"
    echo "  verify afterward: cat /sys/module/usbcore/parameters/usbfs_memory_mb"
  fi
  # Kept as a harmless secondary in case usbcore ever does load as a
  # module on some future kernel/config on this box.
  echo "options usbcore usbfs_memory_mb=1000" | sudo tee /etc/modprobe.d/usbcore-rx888.conf
}

install_ubertooth() {
  echo "== Ubertooth One =="
  sudo apt install -y libbluetooth-dev libpcap-dev

  local libbtbb_version="2020-12-R1"
  local ubertooth_version="2020-12-R1"

  if [[ ! -d "${SRC_ROOT}/libbtbb-${libbtbb_version}" ]]; then
    wget -qO "/tmp/libbtbb-${libbtbb_version}.tar.gz" \
      "https://github.com/greatscottgadgets/libbtbb/archive/${libbtbb_version}.tar.gz"
    tar -xzf "/tmp/libbtbb-${libbtbb_version}.tar.gz" -C "${SRC_ROOT}"
  fi
  mkdir -p "${SRC_ROOT}/libbtbb-${libbtbb_version}/build"
  (cd "${SRC_ROOT}/libbtbb-${libbtbb_version}/build" && cmake .. && make -j"$(nproc)" && sudo make install)
  sudo ldconfig

  if [[ ! -d "${SRC_ROOT}/ubertooth-${ubertooth_version}" ]]; then
    wget -qO "/tmp/ubertooth-${ubertooth_version}.tar.xz" \
      "https://github.com/greatscottgadgets/ubertooth/releases/download/${ubertooth_version}/ubertooth-${ubertooth_version}.tar.xz"
    tar -xJf "/tmp/ubertooth-${ubertooth_version}.tar.xz" -C "${SRC_ROOT}"
  fi
  mkdir -p "${SRC_ROOT}/ubertooth-${ubertooth_version}/host/build"
  (cd "${SRC_ROOT}/ubertooth-${ubertooth_version}/host/build" && cmake .. && make -j"$(nproc)" && sudo make install)
  sudo ldconfig

  echo "  NOTE: release tag ${ubertooth_version} is what's confirmed in"
  echo "  upstream docs as of this script's writing — check"
  echo "  https://github.com/greatscottgadgets/ubertooth/releases for a"
  echo "  newer tag before relying on this long-term."
}

install_evilcrow() {
  echo "== Evil Crow RF v2 =="
  # Nothing to install on this box — standalone WiFi-networked ESP32
  # device with its own onboard firmware, not a USB peripheral with a
  # host driver. "Install" here means confirming network reachability,
  # the equivalent of a driver-presence check for a device with no
  # driver to install here.
  if avahi-resolve -n evilcrow-rf.local >/dev/null 2>&1; then
    echo "  Resolved evilcrow-rf.local via mDNS."
  else
    echo "  Could not resolve evilcrow-rf.local via mDNS — device may be"
    echo "  on its own AP (not joined to this LAN) or mDNS isn't reaching"
    echo "  it. Check the device's own display/config, or connect to its"
    echo "  AP directly and browse to its IP."
  fi
}

# =======================================================================
# Device selection
# =======================================================================
declare -A DEVICE_FUNCS=(
  [hackrf]=install_hackrf
  [rtlsdr]=install_rtlsdr
  [rx888]=install_rx888
  [ubertooth]=install_ubertooth
  [evilcrow]=install_evilcrow
)
declare -A DEVICE_LABELS=(
  [hackrf]="HackRF"
  [rtlsdr]="RTL-SDR v3/v4"
  [rx888]="RX-888 MkII (HF)"
  [ubertooth]="Ubertooth One (Bluetooth Classic/BLE)"
  [evilcrow]="Evil Crow RF v2 (sub-GHz, network reachability check only)"
)
# Fixed order for display and for DEVICES= parsing consistency.
DEVICE_ORDER=(hackrf rtlsdr rx888 ubertooth evilcrow)

select_devices() {
  if [[ -n "${DEVICES:-}" ]]; then
    echo "${DEVICES}"
    return
  fi

  echo "== Phase 1: Hardware and drivers ==" >&2
  echo "Which devices do you have connected/available and want to install now?" >&2
  echo >&2
  local i=1
  local -A index_to_key
  for key in "${DEVICE_ORDER[@]}"; do
    echo "  ${i}) ${DEVICE_LABELS[$key]}" >&2
    index_to_key[${i}]="${key}"
    i=$((i + 1))
  done
  echo >&2
  echo "Enter numbers separated by spaces (e.g. '1 2'), or 'all':" >&2
  read -r -p "> " selection

  if [[ "${selection}" == "all" ]]; then
    echo "${DEVICE_ORDER[@]}"
    return
  fi

  local chosen=()
  for num in ${selection}; do
    if [[ -n "${index_to_key[$num]:-}" ]]; then
      chosen+=("${index_to_key[$num]}")
    else
      echo "  (ignoring unrecognized selection: ${num})" >&2
    fi
  done
  echo "${chosen[@]}"
}

# =======================================================================
# Main
# =======================================================================
install_base

SELECTED_DEVICES="$(select_devices)"
if [[ -z "${SELECTED_DEVICES}" ]]; then
  echo "No devices selected — nothing device-specific to install."
else
  echo
  echo "Installing: ${SELECTED_DEVICES}"
  for key in ${SELECTED_DEVICES}; do
    func="${DEVICE_FUNCS[$key]:-}"
    if [[ -z "${func}" ]]; then
      echo "Unknown device key '${key}', skipping." >&2
      continue
    fi
    echo
    "${func}"
  done
fi

cat <<EOF

== Phase 1 install complete ==

A reboot is required before continuing (NVIDIA driver, usbfs_memory_mb
persistence, initramfs blacklist all need it to take effect).

After reboot:
  1. Verify GPU:        nvidia-smi
  2. Verify usbfs limit: cat /sys/module/usbcore/parameters/usbfs_memory_mb
  3. Run validation:     ./scripts/phase1-validate-sdrs.sh
  4. Run validation:     ./scripts/phase1-validate-protocol-tools.sh

Only the devices you installed above need to pass their respective
validation checks — see docs/build-order.md Phase 1 exit criteria.

Re-run this script any time to add more devices later (DEVICES="rx888"
sudo -E ./scripts/phase1-hardware-drivers.sh to skip the prompt).
EOF
