#!/usr/bin/env bash
# scripts/phase6-openwebrx.sh
#
# Phase 6.4 — OpenWebRX+ for the HackRF/RTL-SDR VHF/UHF+ chain. See
# docs/build-order.md Phase 6. Native install, NOT containerized —
# containerizing would isolate it from the direwolf/multimon-ng
# binaries Phase 6.2 built specifically so OpenWebRX+ could
# auto-detect them; bundled Docker images ship their own internal
# decoders instead, which would make 6.2's ordering pointless.
#
# Ubuntu 24.04 (noble) support in luarvique's PPA is explicitly marked
# "experimental" upstream — flagging that rather than treating it as
# a confirmed-stable path.
#
# This script does NOT configure SDR devices/profiles (settings.json).
# That's the officially-supported guided web UI flow, and a documented
# real-world failure mode (missing rf_gain, wrong direct_sampling
# value) makes scripting a guessed config riskier than doing it once
# by hand on first login.
#
# Usage: sudo ./scripts/phase6-openwebrx.sh

set -euo pipefail

echo "== Phase 6.4: OpenWebRX+ =="

# ---------------------------------------------------------------------
# Add the PPA (noble build — experimental upstream)
# ---------------------------------------------------------------------
echo "-- Adding luarvique PPA (Ubuntu 24.04/noble, experimental) --"
curl -s https://luarvique.github.io/ppa/openwebrx-plus.gpg | \
  sudo gpg --yes --dearmor -o /etc/apt/trusted.gpg.d/openwebrx-plus.gpg
sudo tee /etc/apt/sources.list.d/openwebrx-plus.list <<< \
  "deb [signed-by=/etc/apt/trusted.gpg.d/openwebrx-plus.gpg] https://luarvique.github.io/ppa/noble ./"
sudo apt update

# ---------------------------------------------------------------------
# Install — package name per the PPA's own docs is "openwebrx" (the
# fork replaces the original package rather than coexisting under a
# different name). Fallback to "openwebrx-plus" if that's wrong for
# this PPA snapshot.
# ---------------------------------------------------------------------
echo "-- Installing OpenWebRX+ --"
sudo apt install -y openwebrx || sudo apt install -y openwebrx-plus

sudo systemctl enable --now openwebrx

sleep 3
echo
echo "-- Service status --"
sudo systemctl status openwebrx --no-pager -l | head -15

# ---------------------------------------------------------------------
# Admin user — via CLI if available, otherwise leave to first-login
# web setup.
# ---------------------------------------------------------------------
echo
echo "-- Admin user --"
if command -v openwebrx >/dev/null 2>&1; then
  echo "  Run this manually to create the admin account (interactive):"
  echo "    sudo openwebrx admin adduser <username>"
  echo "  (exact subcommand syntax not verified against this PPA build —"
  echo "  check 'openwebrx admin --help' if that errors)"
else
  echo "  'openwebrx' CLI not found on PATH — create the admin account"
  echo "  via the web UI's first-run setup instead."
fi

cat <<'EOF'

== Phase 6.4 install complete (pending SDR device setup) ==

OpenWebRX+ listens on port 8073 by default: http://<this-box>:8073

REQUIRED before this is actually useful: add your HackRF and RTL-SDR
devices via the web UI's admin panel (Settings -> SDR devices) — see
docs/build-order.md Phase 6.4 for the reasoning on why this isn't
scripted. Confirm HackRF with `hackrf_info` and RTL-SDR with `rtl_test`
first if either device add fails (Phase 1 validation should already
cover this, but hardware can move ports).

Next: run scripts/phase6-openwebrx-validate.sh.
EOF
