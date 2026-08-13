#!/usr/bin/env bash
# scripts/phase2-os-packages.sh
#
# Phase 2 — OS packages and runtime prerequisites. See
# docs/build-order.md for full rationale. git/build-essential/cmake/
# pkg-config are NOT here — they moved to Phase 1 (needed to build the
# RX-888 MkII driver from source).
#
# This script INSTALLS. Run scripts/phase2-validate.sh afterward — do
# not consider Phase 2 done until that passes, per the same "installed
# isn't verified" principle Phase 1 uses.
#
# Usage: sudo ./scripts/phase2-os-packages.sh

set -euo pipefail

TARGET_USER="${SUDO_USER:-$(id -un)}"

echo "== Phase 2: OS packages and runtime prerequisites =="
echo "Target user for rootless Podman / venvs: ${TARGET_USER}"

sudo apt update

# ---------------------------------------------------------------------
# Podman (rootless)
# ---------------------------------------------------------------------
echo "-- Podman --"
sudo apt install -y podman uidmap slirp4netns fuse-overlayfs

# Rootless Podman needs a subuid/subgid range for the target user.
# Ubuntu auto-assigns these for users created via adduser/useradd on
# 18.04+, but accounts created before Podman was ever installed, or via
# other means, may not have entries. Check rather than assume.
echo "-- Checking subuid/subgid ranges for ${TARGET_USER} --"
if ! grep -q "^${TARGET_USER}:" /etc/subuid 2>/dev/null; then
  echo "  No /etc/subuid entry for ${TARGET_USER} — adding one."
  sudo usermod --add-subuids 100000-165535 "${TARGET_USER}"
fi
if ! grep -q "^${TARGET_USER}:" /etc/subgid 2>/dev/null; then
  echo "  No /etc/subgid entry for ${TARGET_USER} — adding one."
  sudo usermod --add-subgids 100000-165535 "${TARGET_USER}"
fi

# Phase 4 runs Open WebUI (and later, other services) as systemd
# Quadlet units under systemd --user. Without lingering enabled,
# rootless containers/services stop the moment ${TARGET_USER} logs out
# — fine for interactive testing, not fine for something meant to run
# as a persistent service. Enable it now so this isn't a surprise in
# Phase 4.
echo "-- Enabling systemd lingering for ${TARGET_USER} --"
sudo loginctl enable-linger "${TARGET_USER}"

# cgroups v2 — Ubuntu 24.04 defaults to unified cgroup v2, which
# rootless Podman needs for resource limits/delegation. Verify rather
# than assume, in case this box was provisioned from a nonstandard image.
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  echo "-- cgroups v2: confirmed unified hierarchy --"
else
  echo "  WARNING: /sys/fs/cgroup/cgroup.controllers not found — this"
  echo "  system may not be on unified cgroups v2. Rootless Podman"
  echo "  resource delegation may not work correctly; investigate before"
  echo "  relying on it in Phase 4."
fi

# ---------------------------------------------------------------------
# Python 3 + venv + pip
# ---------------------------------------------------------------------
echo "-- Python 3 / venv / pip --"
# python3-venv is a separate package from python3 on Ubuntu — `python3
# -m venv` silently fails without it. Installing the versioned package
# too since Ubuntu sometimes splits venv support per Python minor version.
PYTHON_MINOR="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
sudo apt install -y python3 python3-pip "python3-venv" "python3-${PYTHON_MINOR}-venv" 2>/dev/null || \
  sudo apt install -y python3 python3-pip python3-venv

# ---------------------------------------------------------------------
# curl
# ---------------------------------------------------------------------
echo "-- curl --"
sudo apt install -y curl

echo "-- sqlite3 (CLI) --"
# Only Python's built-in sqlite3 module was guaranteed present before
# this — confirmed via real testing that the separate CLI binary
# wasn't installed anywhere, needed for ad-hoc inspection of the
# occupancy DB (6.6) and other SQLite files in this build without
# writing a one-off Python snippet each time.
sudo apt install -y sqlite3

# ---------------------------------------------------------------------
# FFTW3 + baseline wisdom generation
#
# FFTW is general infrastructure, not specific to any one Phase 6 tool
# — both radiod (ka9q-radio) and GNU Radio depend on it, so it belongs
# here rather than bundled into either tool's own install script.
#
# Wisdom generation is kicked off in the BACKGROUND now, deliberately,
# rather than waited on synchronously or deferred to Phase 6: it can
# take hours, and starting it here means it runs across Phases 3-5
# (Ollama pulls, Open WebUI setup, ingest pipeline work) instead of
# being pure tacked-on wait time once Phase 6 actually needs it.
#
# This generates a BROAD baseline covering common transform sizes seen
# across typical ka9q-radio/RX-888 configs in the community — it is
# NOT guaranteed to cover every transform this build's specific channel
# set uses. Phase 6.1 checks radiod's own logs for anything the
# baseline missed and generates that supplementally. Think of this as
# "cover the common case early," not "the only wisdom generation step."
# ---------------------------------------------------------------------
echo "-- FFTW3 + background baseline wisdom generation --"
sudo apt install -y libfftw3-dev libfftw3-bin

# radiod (ka9q-radio, Phase 6.1) imports FFTW wisdom from these paths, in order:
#   /etc/fftw/wisdomf              (system single-precision wisdom)
#   /var/lib/ka9q-radio/wisdom     (ka9q's own location)
# NOT /etc/fftw/fftwf-wisdom — an earlier version generated there and radiod
# silently ran WITHOUT the wisdom ("... not readable"), wasting the whole
# multi-hour generation. Generate to the ka9q path and also install it as the
# system wisdomf so radiod finds it either way.
WISDOM_KA9Q="/var/lib/ka9q-radio/wisdom"
sudo mkdir -p /etc/fftw /var/lib/ka9q-radio
if pgrep -f fftwf-wisdom >/dev/null 2>&1; then
  echo "  A fftwf-wisdom process is already running — not starting another."
elif [ -s "${WISDOM_KA9Q}" ]; then
  echo "  Wisdom already present at ${WISDOM_KA9Q} — not regenerating."
else
  echo "  Starting baseline wisdom generation in the background."
  echo "  This can take HOURS — that's expected and fine to let run."
  echo "  Progress/log: /tmp/fftw-wisdom-phase2.log"
  echo "  Output: ${WISDOM_KA9Q} (+ /etc/fftw/wisdomf) — the paths radiod reads."
  # Generate to a temp file, then install to BOTH locations radiod checks, so a
  # half-written file is never seen as complete and radiod finds it either way.
  nohup sudo sh -c '
    fftwf-wisdom -v -T 1 -o /tmp/fftwf-wisdom.partial \
      rof3240000 rof1620000 rof500000 cof36480 \
      cob1920 cob1200 cob960 cob800 cob600 cob480 cob320 cob300 cob200 cob160 cob150 \
    && cp /tmp/fftwf-wisdom.partial /var/lib/ka9q-radio/wisdom \
    && cp /tmp/fftwf-wisdom.partial /etc/fftw/wisdomf \
    && rm -f /tmp/fftwf-wisdom.partial \
    && echo "WISDOM INSTALLED to /var/lib/ka9q-radio/wisdom and /etc/fftw/wisdomf"
  ' > /tmp/fftw-wisdom-phase2.log 2>&1 &
  disown
fi

cat <<EOF

== Phase 2 install complete ==

Next: run scripts/phase2-validate.sh (as ${TARGET_USER}, NOT root/sudo —
rootless Podman and venv creation both need to run as the real user).

FFTW baseline wisdom generation is running in the background — check
on it any time with: tail -f /tmp/fftw-wisdom-phase2.log
EOF
