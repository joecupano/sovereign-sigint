#!/usr/bin/env bash
# scripts/phase7-kismet.sh
#
# Phase 7, part 1 — Kismet, the WiFi/Bluetooth/RF protocol-monitoring
# aggregation layer. See docs/build-order.md Phase 7. This is the
# foundation the rest of Phase 7 (Ubertooth capture, and any other
# protocol capture sources) plugs INTO — Kismet is the datastore/UI, the
# capture sources feed it.
#
# BUILT FROM SOURCE, deliberately — NOT from Kismet's APT repo. The
# prebuilt packages for 2025 releases depend on `libwebsockets17`, which
# is NOT installable on Ubuntu 24.04 (Noble) — its repos carry a
# different libwebsockets version. This is a confirmed, still-open issue
# (kismetwireless/kismet#574). Building from source links against Noble's
# own `libwebsockets-dev` (4.3.x), sidestepping the pin entirely — the
# same source-build approach this project already uses for ka9q-radio,
# libsddc, and SoapySDDC.
#
# The FULL dependency list is installed (including libubertooth-dev,
# libbtbb-dev, librtlsdr-dev) so that Kismet's Ubertooth, BT, and RTL
# capture sources are COMPILED IN now. Kismet selects which capture
# helpers to build at configure time based on which -dev libs are
# present — installing them now means adding that hardware later is just
# "enable the source", not "rebuild Kismet". The hardware does NOT need
# to be plugged in for this.
#
# This script INSTALLS. Run scripts/phase7-kismet-validate.sh afterward.
#
# Usage: sudo ./scripts/phase7-kismet.sh
#   Override the pinned release with KISMET_REF=<git-ref> (branch/tag).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_USER="${SUDO_USER:-$(id -un)}"
SRC_ROOT="/opt/sovereign-sigint/src"

# Pin to a release tag by default rather than tracking master, per the
# lesson from ka9q-radio (a moving upstream can break the default build).
# Override with KISMET_REF=master to track tip, or another tag.
KISMET_REF="${KISMET_REF:-master}"

echo "== Phase 7.1: Kismet (build from source) =="

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo (installs packages + suid capture helpers)." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Build dependencies — the full list from Kismet's official Linux install
# docs (https://www.kismetwireless.net/docs/readme/installing/linux/),
# PLUS the capture-source dev libs so all helpers compile in.
#   libwebsockets-dev  -> Noble's own 4.3.x, avoids the libwebsockets17
#                         packaging bug that breaks the APT install
#   libubertooth-dev,
#   libbtbb-dev        -> Ubertooth + Bluetooth baseband capture helpers
#   librtlsdr-dev      -> rtl433/rtladsb/rtlamr capture helpers
#   protobuf + protoc-c-> Kismet's IPC to its capture helpers
# ---------------------------------------------------------------------
echo "-- Installing build dependencies --"
apt update
apt install -y \
  build-essential git pkg-config \
  libwebsockets-dev \
  zlib1g-dev libnl-3-dev libnl-genl-3-dev \
  libcap-dev libpcap-dev libnm-dev libdw-dev \
  libsqlite3-dev libsensors-dev libusb-1.0-0-dev \
  libprotobuf-dev libprotobuf-c-dev protobuf-compiler \
  protobuf-c-compiler libprotobuf-c-dev \
  librtlsdr-dev \
  libubertooth-dev libbtbb-dev libmosquitto-dev \
  libpcre2-dev libssl-dev

# ---------------------------------------------------------------------
# Clone + build
# ---------------------------------------------------------------------
echo "-- Cloning Kismet (${KISMET_REF}) --"
mkdir -p "${SRC_ROOT}"
chown "${TARGET_USER}:${TARGET_USER}" "${SRC_ROOT}"

if [[ ! -d "${SRC_ROOT}/kismet" ]]; then
  sudo -u "${TARGET_USER}" git clone --quiet \
    https://www.kismetwireless.net/git/kismet.git "${SRC_ROOT}/kismet"
fi
cd "${SRC_ROOT}/kismet"
sudo -u "${TARGET_USER}" git fetch --quiet origin
sudo -u "${TARGET_USER}" git checkout --quiet "${KISMET_REF}"
sudo -u "${TARGET_USER}" git pull --quiet --ff-only 2>/dev/null || true

echo "-- ./configure (watch its summary for which capture sources it finds) --"
# configure runs as the build user; it reports which optional capture
# helpers it will build based on the -dev libs found above.
sudo -u "${TARGET_USER}" ./configure

echo "-- Building (this takes a while) --"
sudo -u "${TARGET_USER}" make -j"$(nproc)"

# suidinstall: installs the capture binaries setuid-root but the Kismet
# server itself runs as a normal user in the 'kismet' group — the
# recommended least-privilege model (only the small capture helpers need
# elevated caps, not the whole server).
echo "-- Installing (suidinstall — least-privilege capture model) --"
make suidinstall

# ---------------------------------------------------------------------
# Group membership: users in the 'kismet' group may run the capture
# tools / control the server without full root.
# ---------------------------------------------------------------------
echo "-- Adding ${TARGET_USER} to the 'kismet' group --"
usermod -aG kismet "${TARGET_USER}"

# ---------------------------------------------------------------------
# Install the shipped kismet_site.conf so Kismet starts up with a data
# source configured. IMPORTANT PATH DETAIL: Kismet's --sysconfdir for
# a from-source install is /usr/local/etc/ (FLAT, no per-app subdir).
# Every other Kismet config (kismet.conf, kismet_httpd.conf,
# kismet_alerts.conf, etc.) lives directly at /usr/local/etc/, and
# Kismet looks for kismet_site.conf at exactly /usr/local/etc/
# kismet_site.conf — NOT /usr/local/etc/kismet/kismet_site.conf.
# Verified end-to-end on rubberduck: dropping it in a /kismet/ subdir
# results in "Optional sub-config file not present" on startup and no
# source is loaded; putting it flat, Kismet loads it correctly and the
# source comes up. If the operator has a different WiFi interface than
# the reference MT7612U at MAC 00:c0:ca:a6:85:0f, they'll need to edit
# the source= line after install (see NEXT STEPS below).
echo "-- Installing kismet_site.conf --"
cp "${REPO_ROOT}/protocol-security/kismet/kismet_site.conf.example" \
   /usr/local/etc/kismet_site.conf
chmod 644 /usr/local/etc/kismet_site.conf

# ---------------------------------------------------------------------
# Install the system-level kismet.service so the daemon autostarts on
# boot. Templated with __TARGET_USER__ (same pattern kismet-refresh uses
# for __REPO_ROOT__). System unit, not --user: 'make suidinstall'
# capture helpers behave more reliably under system session isolation
# than under a --user session; see systemd/kismet.service comments.
# ---------------------------------------------------------------------
echo "-- Installing systemd unit (kismet.service) for autostart --"
sed -e "s|__TARGET_USER__|${TARGET_USER}|g" \
    "${REPO_ROOT}/systemd/kismet.service" \
    > /etc/systemd/system/kismet.service
systemctl daemon-reload
systemctl enable --now kismet.service

echo
echo "== Phase 7.1 install complete =="
echo "IMPORTANT: group membership ('kismet') only takes effect on a new"
echo "login/session — log out and back in, or run 'newgrp kismet', before"
echo "running kismet interactively. (The system service just enabled runs"
echo "under a fresh session, so it already has the group.)"
echo
echo "First-time admin credentials: browse to http://<host>:2501/ and set an"
echo "administrator username/password (Kismet writes ~/.kismet/kismet_httpd.conf"
echo "under ${TARGET_USER}'s home directory)."
echo
echo "Data source: the shipped kismet_site.conf.example is installed to"
echo "/usr/local/etc/kismet_site.conf and its 'source=' line targets the"
echo "reference MT7612U interface (MAC 00:c0:ca:a6:85:0f). If your WiFi"
echo "adapter differs, edit that line to match your interface (find it"
echo "with 'ip link' — look for 'wlx<mac>') and 'sudo systemctl restart"
echo "kismet' to reload."
echo
echo "Semi-live AI bridge: after data is being captured, install the refresh"
echo "timer (runs as your normal user, no sudo):"
echo "  ./scripts/phase7-kismet-refresh.sh"
echo
echo "Next: scripts/phase7-kismet-validate.sh"
