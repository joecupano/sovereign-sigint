# Security Hardening

Cross-cutting, not tied to a SIGINT-functionality phase number — applies
regardless of build progress, and ideally runs early. Scripts:
`scripts/security-hardening.sh` (selectable menu, same pattern as Phase 1's
device selection), `scripts/security-hardening-validate.sh`.

Prompted by an explicit checklist review against this build. One item
(Podman rootless/no-privileged-containers) was **already true** — confirmed
in Phase 2/4, nothing to do. The other eight are addressed below, two with
real safety gates given genuine lockout/disruption risk.

## 1. SSH — key-only auth, no root login

**Optional, and safe to skip** — this item is opt-in (selected from the
hardening menu, not applied automatically), and safe to leave out if you
prefer password SSH or aren't certain you have working key-based login
yet. Nothing about the rest of the build depends on it.

**Safety-gated.** The script refuses to disable password authentication
unless a real key is already confirmed present in the invoking user's
`authorized_keys` — disabling password auth without one locks the operator
out with no recovery short of console/IPMI access. If you haven't installed
a key yet:

```
ssh-copy-id <user>@<host>
```

Then re-run the SSH item. The resulting config is a drop-in
(`/etc/ssh/sshd_config.d/99-hardening.conf`), validated with `sshd -t`
*before* restarting — a broken config never gets applied. Verify a fresh
key-based login works from a **new** terminal before closing the session
that ran the script.

## 2. auditd — syscall/file-integrity auditing

A deliberately narrow baseline, not exhaustive syscall auditing (which
generates enormous log volume for little benefit without a SIEM actually
consuming it): watches `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`,
`/etc/ssh/sshd_config` for tampering, and logs root-executed commands.
Extending this to a fuller ruleset is real, separate work if a specific
compliance framework requires it.

## 3. fail2ban — brute-force protection

**Honest tradeoff:** once SSH is key-only (item 1), password brute-forcing
is already cryptographically infeasible — fail2ban's marginal value against
SSH specifically drops once that's done. It still earns its keep by
reducing log noise and connection-attempt resource use, and as
defense-in-depth if `sshd_config` ever regresses to allowing passwords.

## 4. unattended-upgrades — automatic security patches

Security updates apply automatically; **automatic reboot is deliberately
disabled.** A real, deliberate tradeoff: this box may have a live SDR
capture or GPU inference running when a kernel/driver update lands — an
unattended reboot mid-capture is a worse operational risk than a delayed,
deliberate reboot window. Check `/var/run/reboot-required` periodically
rather than assume no news is good news.

## 5. AppArmor — confirmed enabled, one real demonstrated profile

Ubuntu ships AppArmor active by default — confirmed, not assumed, via
`aa-status`. **Custom confining profiles for Ollama, Open WebUI, or `radiod`
are NOT included.** Writing a correct profile requires running the service
in complain mode, observing its actual real-world filesystem/capability
access, then refining with `aa-logprof` — genuine, per-service work, not a
template copied blindly across unrelated services. A demonstrated pattern
is provided for Caddy only, in **complain mode** (logs violations, does not
enforce or risk breaking anything):

```
journalctl -k | grep -i "audit.*apparmor.*DENIED"
```

Review that output over real use before ever switching to `aa-enforce`.

## 6. Telemetry purge

`apport`, `whoopsie`, `popularity-contest` purged if present; `motd-news`
disabled. **Left alone deliberately:** Ubuntu Pro/ESM nag messages
(`ubuntu-advantage-tools`) are a separate mechanism — purging it can affect
legitimately Pro-subscribed systems. Revisit explicitly if this box isn't
Pro-subscribed and the nag is unwanted.

## 7. Caddy local CA — real HTTPS on the LAN

**Primary path is Phase 4's `CADDY_TLS=1` flag** (`CADDY_TLS=1
./scripts/phase4-open-webui.sh`) — this hardening item is the
after-the-fact toggle for an already-deployed HTTP setup. Both produce
the same config.

Uses this box's mDNS hostname (`<hostname>.local`, via avahi — already
installed in Phase 1) with Caddy's `tls internal` directive, on **port
8443, not 443**.

**Real bug, learned the hard way — the `auto_https disable_redirects`
global block is REQUIRED, not optional.** Choosing :8443 for the site
block is NOT sufficient on its own: `tls internal` makes Caddy
*automatically* open privileged **:80** as well (for the HTTP→HTTPS
redirect and cert plumbing), and rootless Podman cannot bind :80, so
Caddy crashes on startup with `listening on :80: bind: permission
denied` — despite the site block being :8443, and despite Open WebUI
being reachable. The symptom is nasty: Caddy logs a *clean* startup
(local CA created, :8443 listener up) and then exits, so it looks like
it worked. The global block below stops Caddy from opening :80 at all;
HTTPS on :8443 still works fully. The generated config is:

```
{
	auto_https disable_redirects
}

<hostname>.local:8443 {
	tls internal
	reverse_proxy 127.0.0.1:8080
}
```

**`tls internal` alone does not stop browser warnings** — that requires
trusting Caddy's local root CA on every client machine that connects.
Extract it after Caddy's first start with the new config (path is a
best-known location — confirm it exists rather than assume):

```
podman cp caddy:/data/caddy/pki/authorities/local/root.crt ./sovereign-sigint-root-ca.crt
```

Then trust it per client OS:
- **Linux:** `sudo cp sovereign-sigint-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`
- **macOS:** import into Keychain Access, set to "Always Trust"
- **Windows:** import into Certificate Manager, "Trusted Root Certification Authorities"

**Without DNS**, `<hostname>.local` also has to resolve on each client —
either via working mDNS/avahi, or a hosts-file entry
(`<this-box-ip>  <hostname>.local`). A single-operator box with no DNS
is a legitimate reason to skip TLS entirely and run plain HTTP on :8000;
the encryption is between your own browser and your own box on a LAN you
control. TLS here is a real choice with real client-side setup cost, not
a free default.

### Bringing your own certificate

If you already have a certificate — from an internal/corporate CA, an
existing wildcard, or your own PKI — you can use it instead of Caddy's
self-signed local CA. The big advantage: if that cert chains to a CA
your clients **already trust** (e.g. a corporate root already pushed to
every machine), there is **no per-client trust step at all** — no
browser warnings, nothing to install on each client.

```
CADDY_TLS=cert \
  CADDY_CERT=/path/to/fullchain.pem \
  CADDY_KEY=/path/to/privkey.pem \
  CADDY_HOSTNAME=host.example.com \
  ./scripts/phase4-open-webui.sh
```

- `CADDY_CERT` / `CADDY_KEY` are required; both are validated as readable
  before anything is changed.
- `CADDY_HOSTNAME` should match a name in the cert (defaults to
  `<hostname>.local` if unset). Clients must be able to resolve it.
- The cert and key are copied into
  `~/.config/containers/systemd/caddy-certs/` (key chmod 0600) and mounted
  read-only into the Caddy container; the unit's Volume list is updated
  automatically.
- The same required `auto_https disable_redirects` block applies — the
  :80-bind crash is unrelated to which cert is used.
- On cert renewal, replace the files in `caddy-certs/` and restart Caddy
  (`systemctl --user restart caddy`). This is a manual step — unlike a
  public-CA/ACME setup, an operator-provided cert isn't auto-renewed by
  Caddy.

## 8. Ollama network exposure

**Confirmed via research, not assumed:** Ollama's local server has **no
built-in authentication**. `OLLAMA_API_KEY` only authenticates *to*
ollama.com's cloud service — it is never checked on the local `:11434`
port. "API key auth" as literally requested isn't buildable against
Ollama itself; the real fix is network-layer restriction.

`ufw` is configured default-deny, with SSH allowed *before* enabling it
(safety gate — enabling default-deny without this first would lock out
the session running the script), plus this build's actual served ports
(8000/8443, 8073). **Port 11434 is deliberately left with no rule.**

Determining the correct rule requires knowing the real source address
Open WebUI's container uses to reach Ollama — confirmed earlier in this
build's history that rootless Podman's `host.containers.internal`
resolves to the box's real LAN-facing IP, not a distinct, narrower
container-bridge address, so this cannot be guessed correctly from
outside the live system:

```
sudo tcpdump -i any -n port 11434 &
# trigger a real chat message in Open WebUI, then read the source IP
sudo ufw allow from <confirmed-source-ip> to any port 11434
```

**More robust alternative**, avoiding the need to firewall-scope a
container's shifting network identity at all — an authenticated Caddy path
in front of Ollama:

```
{
	auto_https disable_redirects
}

<hostname>.local:8443 {
	tls internal
	reverse_proxy 127.0.0.1:8080

	handle /ollama-api/* {
		basicauth {
			<username> <bcrypt-hash>
		}
		uri strip_prefix /ollama-api
		reverse_proxy 127.0.0.1:11434
	}
}
```

Generate the bcrypt hash with `caddy hash-password`. This gives genuine
credential-gated access for anyone needing Ollama access beyond Open
WebUI's own direct container connection — without Ollama itself ever
needing to support authentication it doesn't have.

## Podman rootless / no privileged containers

**Already true** — confirmed rootless throughout (subuid/subgid ranges,
Phase 2), no privileged containers in any Quadlet unit (Phase 4). Nothing
to do here; included in this list only for completeness against the
original checklist.
