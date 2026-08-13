#!/usr/bin/env bash
# scripts/phase6-openwebrx-validate.sh
#
# Phase 6.4 exit criteria: OpenWebRX+ actually reachable and serving
# its web UI. Does NOT validate SDR device streaming — that's a manual
# step (web UI device setup) per phase6-openwebrx.sh's own notes, and
# needs to happen before this validation is meaningful for the
# "receiving real signals" sense of "working."
#
# Usage: ./scripts/phase6-openwebrx-validate.sh

set -uo pipefail

RESULTS=()

echo "== Phase 6.4 validation: OpenWebRX+ =="
echo

echo "-- Service status --"
if systemctl is-active --quiet openwebrx; then
  echo "  PASS: openwebrx service is active"
  RESULTS+=("Service active: PASS")
else
  echo "  FAIL: openwebrx service is not active"
  echo "  Check: journalctl -u openwebrx -n 50 --no-pager"
  RESULTS+=("Service active: FAIL")
fi
echo

echo "-- Web UI reachable --"
HTTP_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:8073/ 2>&1)"
if [[ "${HTTP_CODE}" == "200" ]]; then
  echo "  PASS: HTTP 200 on port 8073"
  RESULTS+=("Web UI: PASS")
else
  echo "  FAIL: got '${HTTP_CODE}' instead of 200"
  RESULTS+=("Web UI: FAIL (HTTP ${HTTP_CODE})")
fi
echo

echo "NOTE: this only confirms the service is up and serving pages —"
echo "not that any SDR device is actually configured and streaming."
echo "Add HackRF/RTL-SDR devices via the web UI's admin panel (Settings"
echo "-> SDR devices) if you haven't yet, then confirm a live waterfall"
echo "manually — that step isn't automatable from here without a"
echo "browser session."
echo

echo "== Summary =="
FAILED=0
for r in "${RESULTS[@]}"; do
  echo "  ${r}"
  [[ "${r}" == *FAIL* ]] && FAILED=1
done
echo

if [[ "${FAILED}" -eq 1 ]]; then
  echo "Phase 6.4 NOT complete — resolve failures above."
  exit 1
else
  echo "Phase 6.4 exit criteria met (service reachable) — SDR device"
  echo "setup and waterfall confirmation still needed manually."
fi
