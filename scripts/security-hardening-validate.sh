#!/usr/bin/env bash
# scripts/security-hardening-validate.sh
#
# Checks each hardening item independently — SKIP (not applied) is
# distinct from FAIL (applied but not working), same convention as
# every other validate script in this build.
#
# Needs sudo — confirmed via a real run that auditctl/fail2ban-client/ufw
# all require root to query, and without it they fail in ways that look
# identical to a real hardening failure rather than a permission gap.
# Enforced explicitly here instead of letting that happen silently again.
#
# Usage: sudo ./scripts/security-hardening-validate.sh

set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script needs sudo — auditctl, fail2ban-client, and ufw" >&2
  echo "status all require root to query correctly. Without it, several" >&2
  echo "checks below fail in a way that looks identical to a real" >&2
  echo "hardening problem but is actually just a permission gap." >&2
  exit 1
fi

RESULTS=()

echo "== Security Hardening Validation =="
echo

echo "-- SSH --"
if [[ -f /etc/ssh/sshd_config.d/99-hardening.conf ]]; then
  if grep -q "PermitRootLogin no" /etc/ssh/sshd_config.d/99-hardening.conf && \
     grep -q "PasswordAuthentication no" /etc/ssh/sshd_config.d/99-hardening.conf; then
    echo "  PASS: hardening drop-in present with expected directives"
    RESULTS+=("SSH: PASS")
  else
    echo "  FAIL: drop-in present but missing expected directives"
    RESULTS+=("SSH: FAIL")
  fi
else
  echo "  SKIP: not applied"
  RESULTS+=("SSH: SKIP")
fi
echo

echo "-- auditd --"
if systemctl is-active --quiet auditd 2>/dev/null; then
  RULE_COUNT="$(auditctl -l 2>/dev/null | wc -l)"
  if [[ "${RULE_COUNT}" -gt 0 ]]; then
    echo "  PASS: auditd active, ${RULE_COUNT} rules loaded"
    RESULTS+=("auditd: PASS")
  else
    echo "  FAIL: auditd active but no rules loaded"
    RESULTS+=("auditd: FAIL")
  fi
else
  echo "  SKIP: not applied"
  RESULTS+=("auditd: SKIP")
fi
echo

echo "-- fail2ban --"
if systemctl is-active --quiet fail2ban 2>/dev/null; then
  if fail2ban-client status sshd >/dev/null 2>&1; then
    echo "  PASS: fail2ban active, sshd jail responding"
    RESULTS+=("fail2ban: PASS")
  else
    echo "  FAIL: fail2ban active but sshd jail not responding"
    RESULTS+=("fail2ban: FAIL")
  fi
else
  echo "  SKIP: not applied"
  RESULTS+=("fail2ban: SKIP")
fi
echo

echo "-- unattended-upgrades --"
# NOTE: unattended-upgrades ships pre-installed on Ubuntu Server, so package
# presence alone does NOT indicate our hardening item ran. Our item is marked
# by the 51hardening-no-autoreboot drop-in — key the result on that file, not
# on dpkg, so skipping item 4 reports SKIP (not a false FAIL).
if [[ -f /etc/apt/apt.conf.d/51hardening-no-autoreboot ]]; then
  if grep -q 'Automatic-Reboot "false"' /etc/apt/apt.conf.d/51hardening-no-autoreboot 2>/dev/null; then
    echo "  PASS: installed, auto-reboot correctly disabled"
    RESULTS+=("unattended-upgrades: PASS")
  else
    echo "  FAIL: hardening drop-in present but auto-reboot not disabled in it"
    RESULTS+=("unattended-upgrades: FAIL")
  fi
else
  echo "  SKIP: not applied (hardening drop-in absent; the base package may"
  echo "  still be present — Ubuntu Server pre-installs it — but this item"
  echo "  wasn't selected)."
  RESULTS+=("unattended-upgrades: SKIP")
fi
echo

echo "-- AppArmor --"
if systemctl is-active --quiet apparmor 2>/dev/null; then
  if aa-status 2>/dev/null | grep -q "caddy-container-hardening"; then
    echo "  PASS: AppArmor active, demonstrated Caddy profile loaded"
    RESULTS+=("AppArmor: PASS")
  else
    echo "  PARTIAL: AppArmor active, but the demonstrated profile isn't loaded"
    RESULTS+=("AppArmor: PARTIAL")
  fi
else
  echo "  SKIP: not applied (or not active)"
  RESULTS+=("AppArmor: SKIP")
fi
echo

echo "-- Telemetry --"
APPORT_GONE=false
dpkg -l apport 2>/dev/null | grep -q "^ii" || APPORT_GONE=true
if [[ "${APPORT_GONE}" == true ]]; then
  echo "  PASS: apport not installed"
  RESULTS+=("Telemetry: PASS")
else
  echo "  SKIP: apport still installed (item not applied, or intentionally kept)"
  RESULTS+=("Telemetry: SKIP")
fi
echo

echo "-- Caddy local CA --"
# Match "tls internal" only as ACTIVE config, not the commented example line
# that ships in containers/Caddyfile (grep -v '^\s*#' strips comment lines) —
# otherwise this reports PASS from the docs comment even when item 7 wasn't run.
CADDYFILE="$(dirname "${BASH_SOURCE[0]}")/../containers/Caddyfile"
if [[ -f "${CADDYFILE}" ]] && grep -v '^[[:space:]]*#' "${CADDYFILE}" | grep -q "tls internal"; then
  echo "  PASS: Caddyfile configured for tls internal (active, not commented)"
  echo "  NOTE: this only confirms the config, not that Caddy actually"
  echo "  redeployed with it, or that a client has trusted the root CA."
  RESULTS+=("Caddy TLS: PASS (config only)")
else
  echo "  SKIP: not applied (no active 'tls internal' line in the Caddyfile;"
  echo "  the shipped file's commented example doesn't count)."
  RESULTS+=("Caddy TLS: SKIP")
fi
echo

echo "-- Ollama exposure (ufw) --"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  if ufw status | grep -q "11434"; then
    echo "  PARTIAL: ufw active, but an 11434 rule exists — confirm it's"
    echo "  scoped to a real, verified source, not left open broadly."
    RESULTS+=("Ollama exposure: PARTIAL")
  else
    echo "  PASS: ufw active, 11434 has no explicit allow rule (default-deny covers it)"
    RESULTS+=("Ollama exposure: PASS")
  fi
else
  echo "  SKIP: not applied"
  RESULTS+=("Ollama exposure: SKIP")
fi
echo

echo "-- Podman rootless (already confirmed elsewhere in this build) --"
TARGET_USER="${SUDO_USER:-$(id -un)}"
if [[ "${TARGET_USER}" == "root" ]]; then
  echo "  SKIP: no non-root SUDO_USER detected — can't check the actual rootless context this way."
  RESULTS+=("Podman rootless: SKIP")
elif sudo -u "${TARGET_USER}" podman info 2>/dev/null | grep -q "rootless: true"; then
  echo "  PASS: rootless confirmed (checked as ${TARGET_USER}, not root)"
  RESULTS+=("Podman rootless: PASS")
else
  echo "  FAIL: podman info (as ${TARGET_USER}) doesn't confirm rootless — check Phase 2/4"
  RESULTS+=("Podman rootless: FAIL")
fi
echo

echo "== Summary =="
for r in "${RESULTS[@]}"; do
  echo "  ${r}"
done
