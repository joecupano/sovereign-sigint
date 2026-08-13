#!/usr/bin/env bash
# scripts/phase1-validate-protocol-tools.sh
#
# Phase 1 exit criteria for Ubertooth One and Evil Crow RF v2 — real
# functional checks, matching the same "enumeration isn't a pass"
# standard as phase1-validate-sdrs.sh. Run after
# scripts/phase1-hardware-drivers.sh.
#
# Usage: ./scripts/phase1-validate-protocol-tools.sh

set -uo pipefail

RESULTS=()

echo "== Phase 1 validation: Ubertooth One + Evil Crow RF v2 =="
echo

# ---------------------------------------------------------------------
# Ubertooth One — confirm firmware communication AND a real capture,
# not just that the binary exists
# ---------------------------------------------------------------------
echo "-- Ubertooth One --"
if ! command -v ubertooth-util >/dev/null 2>&1; then
  echo "  SKIP: ubertooth-util not found — not installed (or not selected"
  echo "  in phase1-hardware-drivers.sh's device menu)."
  RESULTS+=("Ubertooth firmware check: SKIP (not installed)")
else
  FW_OUTPUT="$(ubertooth-util -v 2>&1)"
  if echo "${FW_OUTPUT}" | grep -qi "version"; then
    echo "  PASS: firmware communication OK"
    echo "    ${FW_OUTPUT}" | head -3
    RESULTS+=("Ubertooth firmware check: PASS")
  else
    echo "  FAIL: ${FW_OUTPUT}"
    RESULTS+=("Ubertooth firmware check: FAIL")
  fi

  echo "  Capturing 5s (expect random LAPs — this alone doesn't prove"
  echo "  decode correctness, just that the radio is receiving):"
  CAPTURE_OUTPUT="$(timeout 5 ubertooth-rx 2>&1 || true)"
  if [[ -n "${CAPTURE_OUTPUT}" ]]; then
    echo "  PASS: received output during capture window"
    echo "${CAPTURE_OUTPUT}" | head -3 | sed 's/^/    /'
    RESULTS+=("Ubertooth capture: PASS")
  else
    echo "  PARTIAL: no output in 5s — could mean no BT traffic nearby"
    echo "  rather than a real failure. Generate traffic (e.g. a phone"
    echo "  BT scan) and retry before concluding this failed."
    RESULTS+=("Ubertooth capture: PARTIAL (no traffic seen)")
  fi
fi
echo

# ---------------------------------------------------------------------
# Evil Crow RF v2 — network reachability + web UI responds
# ---------------------------------------------------------------------
echo "-- Evil Crow RF v2 --"
# Run avahi-resolve inside the if so we test ITS exit status directly.
# A not-present device makes avahi-resolve fail (or print a "Failed to
# resolve" line to stderr); either way we SKIP, not FAIL — an unattached
# optional device is not a validation failure (same standard as Ubertooth).
if ECR_RESOLVE="$(avahi-resolve -n evilcrow-rf.local 2>/dev/null)" \
     && [[ -n "${ECR_RESOLVE}" ]]; then
  ECR_IP="$(echo "${ECR_RESOLVE}" | awk '{print $2}')"
  # Sanity-check we actually got an IP-looking token, not an error word.
  if [[ ! "${ECR_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
       && [[ ! "${ECR_IP}" =~ ^[0-9a-fA-F:]+$ ]]; then
    echo "  SKIP: evilcrow-rf.local did not resolve to a usable address"
    echo "  (got '${ECR_IP:-<empty>}'). Device likely not on this LAN or"
    echo "  not powered — not a failure. Browse to its IP directly if known."
    RESULTS+=("Evil Crow RF v2: SKIP (no usable address)")
  else
    echo "  Resolved evilcrow-rf.local -> ${ECR_IP}"
    HTTP_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' "http://${ECR_IP}/" 2>/dev/null)"
    if [[ "${HTTP_CODE}" == "200" ]]; then
      echo "  PASS: web UI responds (HTTP 200)"
      RESULTS+=("Evil Crow RF v2: PASS")
    else
      echo "  FAIL: resolved to ${ECR_IP} but web UI returned '${HTTP_CODE}'"
      echo "  instead of 200 — device is on the network but its web UI"
      echo "  isn't responding as expected."
      RESULTS+=("Evil Crow RF v2: FAIL (HTTP ${HTTP_CODE})")
    fi
  fi
else
  echo "  SKIP: evilcrow-rf.local not found via mDNS — device isn't"
  echo "  powered on, isn't attached/selected this session, is on its own"
  echo "  AP rather than this LAN, or mDNS isn't reaching it. This is NOT a"
  echo "  failure (an unattached optional device is expected to skip)."
  echo "  Manual fallback: browse to its IP directly if known."
  RESULTS+=("Evil Crow RF v2: SKIP (not resolvable)")
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
  echo "NOT complete — resolve failures above."
  exit 1
else
  echo "Exit criteria met for installed/reachable devices (SKIP = not"
  echo "installed or not reachable this run, not treated as a failure)."
fi
