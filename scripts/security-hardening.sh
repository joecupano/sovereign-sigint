#!/usr/bin/env bash
# scripts/security-hardening.sh
#
# Cross-cutting security baseline — not tied to a SIGINT-functionality
# phase number, since it applies regardless of build progress and
# ideally runs early. See docs/security-hardening.md for full rationale,
# residual risk on each item, and the manual steps that can't be
# scripted (client-side CA trust, determining a real firewall source).
#
# Selectable menu, same pattern as scripts/phase1-hardware-drivers.sh —
# NOT all-or-nothing. Two items carry real lockout/disruption risk
# (SSH, Ollama network exposure) and are gated accordingly; run them
# deliberately, not by default.
#
# Usage: sudo ./scripts/security-hardening.sh
#        ITEMS="ssh auditd" sudo -E ./scripts/security-hardening.sh   (skip the prompt)

set -uo pipefail  # NOT set -e — one item's failure shouldn't abort the rest

TARGET_USER="${SUDO_USER:-$(id -un)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script needs sudo (most items modify system config)." >&2
  exit 1
fi

# =======================================================================
# 1. SSH: key-only auth, no root login — SAFETY-GATED
# =======================================================================
harden_ssh() {
  echo "== SSH: key-only auth, no root login =="
  echo "  OPTIONAL and safe to skip: this disables SSH PASSWORD login and"
  echo "  root login, leaving key-based auth only. Skip it entirely if you"
  echo "  prefer password SSH, or aren't sure you have working key auth yet."
  echo "  It changes nothing until it confirms a key is already in place"
  echo "  (safety gate below) — it will not lock you out by surprise."
  echo

  local key_file="/home/${TARGET_USER}/.ssh/authorized_keys"
  if [[ "${TARGET_USER}" == "root" ]]; then
    key_file="/root/.ssh/authorized_keys"
  fi

  # SAFETY GATE: refuse to disable password auth unless a real key is
  # already installed for the account actually running this script.
  # Disabling password auth without one locks the operator out with no
  # recovery short of console/IPMI access — confirmed present, not
  # assumed, before touching sshd_config.
  if [[ ! -s "${key_file}" ]]; then
    echo "  REFUSING: no authorized_keys found at ${key_file} (or it's empty)." >&2
    echo "  Add your public key there FIRST — e.g. from your workstation:" >&2
    echo "    ssh-copy-id ${TARGET_USER}@$(hostname -I | awk '{print $1}')" >&2
    echo "  Then re-run this item. No changes made." >&2
    return 1
  fi
  echo "  Confirmed: ${key_file} has at least one key. Proceeding."

  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
# Managed by scripts/security-hardening.sh — a drop-in, not an edit to
# the main sshd_config, so this is easy to identify and revert.
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
EOF

  # Fail-safe: verify the resulting config is actually valid BEFORE
  # restarting sshd — a broken config on restart could drop the
  # existing connection with no way back in.
  if ! sshd -t; then
    echo "  ERROR: sshd -t reports invalid config — reverting, NOT restarting sshd." >&2
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    return 1
  fi

  systemctl restart sshd
  echo "  Done. Verify from a NEW terminal/session before closing this one —"
  echo "  do not close this session until a fresh key-based login is confirmed working."
}

# =======================================================================
# 2. auditd — syscall/file-integrity auditing baseline
# =======================================================================
harden_auditd() {
  echo "== auditd: syscall and file-integrity auditing =="
  apt update
  apt install -y auditd audispd-plugins

  # A deliberately narrow, high-value baseline — not exhaustive syscall
  # auditing (which generates enormous log volume for little benefit
  # without a SIEM actually consuming it). Watches the files that
  # matter most for detecting privilege/identity tampering.
  cat > /etc/audit/rules.d/99-hardening.rules <<'EOF'
# Managed by scripts/security-hardening.sh
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/sudoers.d/ -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid!=4294967295 -k root_exec
EOF

  augenrules --load
  systemctl enable --now auditd
  echo "  Done. Baseline rules watch /etc/passwd, /etc/shadow, sudoers,"
  echo "  sshd_config for changes, and log root-executed commands."
}

# =======================================================================
# 3. fail2ban — brute-force protection
# =======================================================================
harden_fail2ban() {
  echo "== fail2ban: brute-force protection =="
  apt update
  apt install -y fail2ban

  # Honest tradeoff, not glossed over: once SSH is key-only (see
  # harden_ssh), password brute-forcing is already cryptographically
  # infeasible — fail2ban's marginal value against SSH specifically
  # drops once that's done. It still earns its keep by reducing log
  # noise/connection-attempt resource use, and as defense-in-depth if
  # sshd_config ever regresses to allowing passwords again.
  cat > /etc/fail2ban/jail.d/99-hardening.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
findtime = 10m
EOF

  systemctl enable --now fail2ban
  sleep 2
  fail2ban-client status sshd || echo "  WARNING: sshd jail did not report status cleanly — check manually."
  echo "  Done."
}

# =======================================================================
# 4. unattended-upgrades — automatic security patches
# =======================================================================
harden_unattended_upgrades() {
  echo "== unattended-upgrades: automatic security patches =="
  apt update
  apt install -y unattended-upgrades apt-listchanges

  # Security updates only, applied automatically — but NOT an automatic
  # reboot. A real, deliberate tradeoff: this box may have a live SDR
  # capture or GPU inference running when a kernel/driver update lands;
  # an unattended reboot mid-capture is a worse operational risk than
  # waiting for a manual, deliberate reboot window. Patches still apply
  # automatically; only the reboot stays manual.
  cat > /etc/apt/apt.conf.d/51hardening-no-autoreboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  systemctl enable --now unattended-upgrades
  echo "  Done. Security patches apply automatically; reboot stays manual —"
  echo "  check /var/run/reboot-required periodically rather than assume no news is good news."
}

# =======================================================================
# 5. AppArmor — confirm enabled, one real demonstrated profile
# =======================================================================
harden_apparmor() {
  echo "== AppArmor: confirm enabled, demonstrate one real profile =="
  apt update
  apt install -y apparmor apparmor-utils

  systemctl enable --now apparmor
  aa-status | head -5

  # Honest scope limit: writing a correct CONFINING profile for a
  # service like Ollama, Open WebUI, or radiod requires running it in
  # complain mode, observing its actual filesystem/capability access
  # over real use, then refining with aa-logprof — a genuine,
  # per-service undertaking, not a one-line addition. Faking a profile
  # that's either a no-op or breaks the service on first real request
  # is worse than being honest that this is future work.
  #
  # Caddy demonstrated here, in COMPLAIN mode (logs violations, does
  # NOT enforce/break anything) as a real starting pattern — narrow to
  # what Caddy's Quadlet container actually needs, not a template
  # copied blindly from an unrelated service.
  mkdir -p /etc/apparmor.d
  cat > /etc/apparmor.d/caddy-container-hardening <<'EOF'
# Managed by scripts/security-hardening.sh — COMPLAIN mode deliberately.
# Review `journalctl -k | grep audit.*apparmor.*DENIED` for real Caddy
# behavior before ever switching this to enforce mode with aa-enforce.
#include <tunables/global>

profile caddy-container-hardening flags=(complain) {
  #include <abstractions/base>
  network inet stream,
  network inet6 stream,
  network inet dgram,
  network inet6 dgram,
  /usr/bin/caddy mr,
  /etc/caddy/** r,
  /data/** rw,
  /config/** rw,
}
EOF
  apparmor_parser -r /etc/apparmor.d/caddy-container-hardening || \
    echo "  WARNING: profile failed to parse — left in complain mode intent, check syntax manually."

  echo "  Done. AppArmor confirmed active. Caddy has a COMPLAIN-mode profile"
  echo "  as a demonstrated pattern — Ollama/Open WebUI/radiod profiles are"
  echo "  NOT included; each needs the same complain-mode-then-refine process"
  echo "  applied deliberately, not templated blindly. See docs/security-hardening.md."
}

# =======================================================================
# 6. Telemetry purge
# =======================================================================
harden_telemetry() {
  echo "== Telemetry purge: apport, whoopsie, motd-news =="
  apt purge -y apport whoopsie popularity-contest 2>/dev/null || true

  if [[ -f /etc/default/motd-news ]]; then
    sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
  fi
  systemctl disable --now motd-news.timer 2>/dev/null || true

  echo "  Done. apport/whoopsie/popularity-contest purged if present,"
  echo "  motd-news disabled. Ubuntu Pro/ESM nag messages in motd are a"
  echo "  separate mechanism (ubuntu-advantage-tools) — left alone here"
  echo "  since purging it can affect legitimate Pro-subscribed systems;"
  echo "  revisit explicitly if this box isn't Pro-subscribed and the"
  echo "  nag is unwanted."
  echo
  echo "  NOTE: purging apport also removes the 'ubuntu-server' and"
  echo "  'ubuntu-server-minimal' METAPACKAGES (apport is a dependency of"
  echo "  them). This is harmless — metapackages only define a grouping;"
  echo "  the actual server components (kernel, systemd, networking, etc.)"
  echo "  remain installed and functional. BUT it leaves some packages"
  echo "  marked 'autoremovable'. Do NOT run a blind 'apt autoremove' now —"
  echo "  run 'apt autoremove --dry-run' and read the list first (watch for"
  echo "  python3-systemd and other still-wanted libs) before removing."
}

# =======================================================================
# 7. Caddy local CA — real HTTPS on the LAN, no public domain needed
# =======================================================================
harden_caddy_tls() {
  echo "== Caddy: local CA for LAN HTTPS =="
  local hostname_local
  hostname_local="$(hostname).local"

  # This item enables TLS after the fact. The primary, setup-time way to
  # choose TLS is Phase 4's CADDY_TLS=1 flag:
  #   CADDY_TLS=1 ./scripts/phase4-open-webui.sh
  # Both produce the same config (including the required auto_https
  # disable_redirects block); this one exists to flip an already-deployed
  # HTTP setup over to HTTPS without a full Phase 4 redeploy.
  echo "  Using mDNS hostname: ${hostname_local} (confirm avahi/mDNS"
  echo "  resolves this from your client machines before relying on it)."

  # Port 8443, deliberately NOT 443 — reopening privileged-port binding
  # would reintroduce the exact rootless-Podman bug already fixed once
  # in Phase 4 (bind: permission denied without a system-wide sysctl
  # change). Staying consistent with that earlier decision rather than
  # re-litigating it here.
  #
  # CRITICAL (real bug, caught live): choosing :8443 for the site block
  # is NOT sufficient on its own. `tls internal` makes Caddy AUTOMATICALLY
  # open :80 as well, for the HTTP->HTTPS redirect and cert plumbing —
  # and rootless Podman can't bind :80, so Caddy exits with
  # "listening on :80: bind: permission denied" and never serves 8443 at
  # all. The global `auto_https disable_redirects` below stops Caddy from
  # opening that :80 listener. HTTPS on :8443 still works fully; only the
  # (impossible-anyway) port-80 redirect is dropped.
  cat > "${REPO_ROOT}/containers/Caddyfile" <<EOF
# Caddyfile — sovereign-sigint (HTTPS via local CA)
# Managed by scripts/security-hardening.sh — see docs/security-hardening.md
# for client-side CA trust steps, without which browsers will still warn.
{
	auto_https disable_redirects
}

${hostname_local}:8443 {
	tls internal
	reverse_proxy 127.0.0.1:8080
}
EOF

  echo "  Caddyfile updated. Redeploy: ./scripts/phase4-open-webui.sh"
  echo "  Then extract the local root CA for client trust (exact command"
  echo "  in docs/security-hardening.md — the internal path is a best-known"
  echo "  location, verify it exists after Caddy's first start):"
  echo "    podman cp caddy:/data/caddy/pki/authorities/local/root.crt ./sovereign-sigint-root-ca.crt"
}

# =======================================================================
# 8. Ollama network exposure — no native API-key auth exists (confirmed)
# =======================================================================
harden_ollama_exposure() {
  echo "== Ollama: restrict network exposure =="
  echo "  CONFIRMED (not assumed): Ollama's local server has NO built-in"
  echo "  authentication. OLLAMA_API_KEY only authenticates to ollama.com's"
  echo "  cloud service — it is never checked on the local :11434 port."
  echo "  'API key auth' as literally stated isn't buildable against Ollama"
  echo "  itself. The real fix is network-layer restriction."
  echo

  apt update
  apt install -y ufw

  # SAFETY GATE: allow SSH explicitly BEFORE enabling ufw's default-deny,
  # or enabling it could lock out the very session running this script.
  ufw allow OpenSSH

  echo "  ufw will default-deny incoming and explicitly allow SSH + the"
  echo "  ports this build actually serves on (8000 or 8443, 8073)."
  ufw allow 8000/tcp comment 'Caddy (plain HTTP variant)'
  ufw allow 8443/tcp comment 'Caddy (local-CA HTTPS variant)'
  ufw allow 8073/tcp comment 'OpenWebRX+'

  echo
  echo "  Ollama's port 11434 is NOT allowed above — deliberately. Before"
  echo "  adding a rule for it, determine the REAL source address Open"
  echo "  WebUI's container uses to reach it, rather than guessing:"
  echo "    sudo tcpdump -i any -n port 11434 &"
  echo "    (then send a chat message in Open WebUI to trigger real traffic)"
  echo "  Confirm the source IP in the capture, then:"
  echo "    sudo ufw allow from <confirmed-source-ip> to any port 11434"
  echo "  This is deliberately a manual step, not automated — a wrong guess"
  echo "  here either breaks Open WebUI or leaves the port open to more"
  echo "  than intended."
  echo
  echo "  Enabling ufw now (SSH and web ports already allowed above)..."
  ufw --force enable
  ufw status verbose

  echo
  echo "  OPTIONAL, more robust alternative: an authenticated Caddy path"
  echo "  for anyone needing Ollama access beyond Open WebUI's own direct"
  echo "  container connection — see docs/security-hardening.md for a"
  echo "  basicauth-fronted reverse-proxy block example."
}

# =======================================================================
# Item selection — same pattern as phase1-hardware-drivers.sh
# =======================================================================
declare -A ITEM_FUNCS=(
  [ssh]=harden_ssh
  [auditd]=harden_auditd
  [fail2ban]=harden_fail2ban
  [unattended-upgrades]=harden_unattended_upgrades
  [apparmor]=harden_apparmor
  [telemetry]=harden_telemetry
  [caddy-tls]=harden_caddy_tls
  [ollama-exposure]=harden_ollama_exposure
)
declare -A ITEM_LABELS=(
  [ssh]="SSH key-only auth, no root login (OPTIONAL, safe to skip — needs your key installed first; safety-gated)"
  [auditd]="auditd — syscall/file-integrity auditing"
  [fail2ban]="fail2ban — brute-force protection"
  [unattended-upgrades]="unattended-upgrades — automatic security patches, manual reboot"
  [apparmor]="AppArmor — confirm enabled, one demonstrated Caddy profile"
  [telemetry]="Telemetry purge — apport, whoopsie, motd-news"
  [caddy-tls]="Caddy local CA — real HTTPS on the LAN (port 8443)"
  [ollama-exposure]="Ollama network exposure — ufw restriction (SAFETY-GATED — SSH allowed first)"
)
ITEM_ORDER=(ssh auditd fail2ban unattended-upgrades apparmor telemetry caddy-tls ollama-exposure)

select_items() {
  if [[ -n "${ITEMS:-}" ]]; then
    echo "${ITEMS}"
    return
  fi

  echo "== Security Hardening ==" >&2
  echo "Podman rootless/no-privileged-containers is ALREADY true in this" >&2
  echo "build (confirmed Phase 2/4) — not included below, nothing to do." >&2
  echo >&2
  local i=1
  local -A index_to_key
  for key in "${ITEM_ORDER[@]}"; do
    echo "  ${i}) ${ITEM_LABELS[$key]}" >&2
    index_to_key[${i}]="${key}"
    i=$((i + 1))
  done
  echo >&2
  echo "Enter numbers separated by spaces, or 'all':" >&2
  read -r -p "> " selection

  if [[ "${selection}" == "all" ]]; then
    echo "${ITEM_ORDER[@]}"
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

SELECTED="$(select_items)"
if [[ -z "${SELECTED}" ]]; then
  echo "No items selected."
  exit 0
fi

echo
echo "Applying: ${SELECTED}"
FAILED_ITEMS=()
for key in ${SELECTED}; do
  func="${ITEM_FUNCS[$key]:-}"
  if [[ -z "${func}" ]]; then
    echo "Unknown item '${key}', skipping." >&2
    continue
  fi
  echo
  if ! "${func}"; then
    FAILED_ITEMS+=("${key}")
  fi
done

echo
echo "== Summary =="
if [[ ${#FAILED_ITEMS[@]} -eq 0 ]]; then
  echo "All selected items completed. Run scripts/security-hardening-validate.sh to confirm."
else
  echo "Completed with issues in: ${FAILED_ITEMS[*]}"
  echo "Review the output above for each — several are safety gates that"
  echo "refused to act rather than risk lockout, which is the correct"
  echo "outcome, not a bug to force past."
fi
