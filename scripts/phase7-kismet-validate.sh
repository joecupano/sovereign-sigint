#!/usr/bin/env bash
# scripts/phase7-kismet-validate.sh
#
# Validate the Phase 7.1 Kismet install: binary present, capture helpers
# compiled in, the WiFi adapter is monitor-capable, and (optionally) the
# server starts. Does NOT require capture hardware beyond the WiFi
# adapter to confirm the build; Ubertooth etc. are validated separately.
#
# Usage: ./scripts/phase7-kismet-validate.sh
#   (run as your normal user, after logging back in for 'kismet' group)

set -uo pipefail  # not -e: we want to run all checks and summarize

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== Phase 7.1 validation: Kismet =="

# --- 1. Kismet binary present & version ---
echo "-- Kismet binary --"
if command -v kismet >/dev/null 2>&1; then
  ver="$(kismet --version 2>/dev/null | head -1)"
  ok "kismet on PATH (${ver:-version unknown})"
else
  bad "kismet not found on PATH — did 'make suidinstall' succeed?"
fi

# --- 2. Capture helpers compiled in ---
# These are the per-source helper binaries Kismet builds when the matching
# -dev libs are present. We care most about the WiFi one; Ubertooth/RTL
# are bonuses that confirm the full dependency set took.
echo "-- Capture helpers installed --"
for helper in kismet_cap_linux_wifi kismet_cap_linux_bluetooth \
              kismet_cap_ubertooth_one; do
  if command -v "$helper" >/dev/null 2>&1 || \
     ls /usr/local/bin/"$helper" >/dev/null 2>&1; then
    ok "$helper present"
  else
    # WiFi is required; the others are nice-to-have at this stage.
    if [[ "$helper" == "kismet_cap_linux_wifi" ]]; then
      bad "$helper MISSING — WiFi capture won't work (check configure output)"
    else
      echo "  note: $helper not present (fine unless you need that source)"
    fi
  fi
done

# --- 3. WiFi adapter present and monitor-capable ---
echo "-- WiFi adapter / monitor mode --"
if ! command -v iw >/dev/null 2>&1; then
  echo "  note: 'iw' not installed — run: sudo apt install -y iw"
else
  WIFI_IF="$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')"
  if [[ -n "${WIFI_IF}" ]]; then
    ok "wireless interface present: ${WIFI_IF}"
    if iw list 2>/dev/null | grep -A12 "Supported interface modes" \
         | grep -q "\* monitor"; then
      ok "adapter supports monitor mode"
    else
      bad "adapter does NOT report monitor mode — Kismet WiFi capture needs it"
    fi
  else
    bad "no wireless interface found (is the adapter plugged in?)"
  fi
fi

# --- 4. Kismet group membership ---
echo "-- Group membership --"
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx kismet; then
  ok "current session is in the 'kismet' group"
else
  bad "not in 'kismet' group in THIS session — log out/in or 'newgrp kismet'"
fi

# --- 5. Optional: server smoke test ---
# Kismet with no data source will still start its server + web UI. We do a
# short headless launch and confirm it comes up, then stop it. Skipped if
# the binary check already failed.
echo "-- Server smoke test (headless, 8s) --"
if command -v kismet >/dev/null 2>&1; then
  # --no-ncurses: don't take over the terminal; --no-line-wrap for clean logs
  timeout 8 kismet --no-ncurses -n 2>/tmp/kismet-smoke.log &
  KPID=$!
  sleep 6
  if ss -tlnp 2>/dev/null | grep -q ":2501"; then
    ok "Kismet server is listening on :2501 (web UI port)"
  else
    echo "  note: :2501 not observed in the smoke window — check"
    echo "        /tmp/kismet-smoke.log (may just need more startup time,"
    echo "        or a first-run config prompt)."
  fi
  kill "${KPID}" 2>/dev/null
  wait "${KPID}" 2>/dev/null
else
  echo "  skipped (kismet binary missing)"
fi

echo
echo "== Summary =="
echo "  PASS: ${PASS}   FAIL: ${FAIL}"
if [[ "${FAIL}" -eq 0 ]]; then
  echo "Phase 7.1 exit criteria met. Next: bring the WiFi source into Kismet"
  echo "(add it as a data source, put ${WIFI_IF:-<iface>} into monitor mode),"
  echo "or proceed to the Ubertooth capture source (phase7-ubertooth.sh)."
else
  echo "Resolve the FAIL items above before continuing Phase 7."
fi
