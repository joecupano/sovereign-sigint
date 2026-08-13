#!/usr/bin/env bash
# scripts/phase6-decode-tools.sh
#
# Phase 6.2 — decode layer: gnuradio, direwolf, multimon-ng, ffmpeg.
# See docs/build-order.md Phase 6. Built BEFORE 6.6 (OpenWebRX+)
# deliberately — OpenWebRX+ auto-detects direwolf and multimon-ng as
# optional runtime dependencies, so having them already installed and
# validated here means OpenWebRX+ picks them up automatically rather
# than being installed against tools that don't exist yet.
#
# This script INSTALLS. Run scripts/phase6-decode-tools-validate.sh
# afterward.
#
# Usage: sudo ./scripts/phase6-decode-tools.sh

set -euo pipefail

echo "== Phase 6.2: decode layer =="

# gnuradio was removed from this phase. Update the comment about universe:
# direwolf and multimon-ng live in Ubuntu's universe repo (confirmed for
# Noble/24.04) — make sure it's enabled rather than assume, since minimal
# server installs don't always have it on by default.
sudo apt install -y software-properties-common
sudo add-apt-repository -y universe
sudo apt update

# ---------------------------------------------------------------------
# GNU Radio — DEFERRED (not installed on the Sovereign AI server)
# ---------------------------------------------------------------------
# GNU Radio was originally installed here for occupancy flowgraphs, but
# nothing in the working build uses it: the occupancy producers capture
# directly via each device's own CLI (radiod's pcmrecord, hackrf_transfer,
# rtl_sdr) and compute power from the samples, and OpenWebRX+ provides
# interactive HackRF/RTL-SDR viewing with its own DSP. The only GNU Radio
# consumers were two occupancy flowgraphs in decode/gnuradio-flowgraphs/ that
# were never hardware-validated and are now superseded; they remain in the
# repo as reference only.
#
# Building real demodulation flowgraphs is a legitimate advanced topic, but
# it's better done on a desktop workstation than on this headless server, and
# it isn't needed for anything here. So GNU Radio (a large dependency) is
# intentionally NOT installed. To do flowgraph work later:
#   sudo apt install -y gnuradio gnuradio-dev gr-osmosdr
# See docs/occupancy-guide.md and decode/gnuradio-flowgraphs/README for the
# rationale and the superseded reference flowgraphs.

# ---------------------------------------------------------------------
# direwolf — APRS/AX.25 TNC, also an OpenWebRX+ optional dependency
# ---------------------------------------------------------------------
echo "-- direwolf --"
sudo apt install -y direwolf

# ---------------------------------------------------------------------
# aprs-symbols — REQUIRED alongside direwolf for OpenWebRX+'s "packet" mode.
# Confirmed via a real install: OpenWebRX+'s feature.py defines
#   "packet": ["direwolf", "aprs_symbols"]
# i.e. BOTH must be present, and has_aprs_symbols() is a simple
#   os.path.isdir("/usr/share/aprs-symbols")
# check — NOT an apt package (its own docstring saying "install the
# aprs-symbols package from the OpenWebRX repositories" is stale/wrong;
# no such apt package exists in the luarvique PPA or Ubuntu's repos,
# confirmed via apt-cache search returning nothing). direwolf alone
# satisfies its own check fine, so "packet" silently stays unavailable
# with NO error logged anywhere — easy to miss. The upstream jketterl
# OpenWebRX wiki's actual instruction is a git clone of the icon set:
# https://github.com/jketterl/openwebrx/wiki/Manual-Package-installation
# ---------------------------------------------------------------------
echo "-- aprs-symbols (required for OpenWebRX+ 'packet' mode, not an apt package) --"
if [ ! -d /usr/share/aprs-symbols ]; then
  sudo git clone --quiet https://github.com/hessu/aprs-symbols /usr/share/aprs-symbols
else
  echo "  /usr/share/aprs-symbols already present — skipping clone."
fi

# ---------------------------------------------------------------------
# multimon-ng — POCSAG/FLEX/AFSK/CW/DTMF/etc. decoder, also an
# OpenWebRX+ optional dependency
# ---------------------------------------------------------------------
echo "-- multimon-ng --"
sudo apt install -y multimon-ng

# ---------------------------------------------------------------------
# ffmpeg
# ---------------------------------------------------------------------
echo "-- ffmpeg --"
sudo apt install -y ffmpeg

cat <<'EOF'

== Phase 6.2 install complete ==

IMPORTANT — Python/venv boundary for GNU Radio:
GNU Radio's Python bindings are wired into system dist-packages by its
apt package, not installable via pip. The `sigint-processing` venv
(docs/venvs.md) does NOT have access to them by default — venvs are
isolated from system site-packages unless created with
--system-site-packages, which we deliberately have NOT done (that
would break the venv's dependency isolation for everything else in it).

Practical split going forward:
  - GNU Radio flowgraphs (.grc-generated .py files) run under SYSTEM
    Python, not the sigint-processing venv.
  - decode/requirements.txt (numpy, scipy, sigmf, etc.) — anything that
    consumes GNU Radio's OUTPUT (files, sockets, pipes) rather than
    importing gnuradio directly — stays in the sigint-processing venv
    as before.
  - If a future script genuinely needs both `import gnuradio` AND the
    venv's pinned dependencies in the same process, that's a real
    design decision to make deliberately (e.g. a dedicated venv with
    --system-site-packages), not something to paper over.

Next: run scripts/phase6-decode-tools-validate.sh to confirm each tool
actually works, not just "apt install succeeded."
EOF
