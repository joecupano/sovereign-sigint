# Kismet — WiFi / Bluetooth / RF protocol monitoring (Phase 7.1)

Kismet is the aggregation layer for protocol-level RF monitoring in this
build — the datastore + UI that capture sources (WiFi, Bluetooth, Ubertooth)
feed into. It is deliberately SEPARATE from Phase 6's spectrum-occupancy
pipeline: Kismet works at the packet/protocol layer (802.11, BT/BTLE,
802.15.4, etc.), not the tunable-receiver/waterfall/occupancy-DB model.

## What's built and validated

- **Kismet built from source** (`scripts/phase7-kismet.sh`) — NOT from the
  APT repo, which is broken on Ubuntu 24.04 (the prebuilt packages depend on
  `libwebsockets17`, unavailable in Noble; source build links against Noble's
  own `libwebsockets-dev`). Confirmed: Kismet 2026.07.0 builds clean.
- **All capture helpers compiled in** — `kismet_cap_linux_wifi`,
  `kismet_cap_linux_bluetooth`, `kismet_cap_ubertooth_one` (the full
  dependency set was installed so adding that hardware later needs no rebuild).
- **WiFi capture validated end-to-end** — a MediaTek MT7612U (mainline
  `mt76x2u` driver, monitor-capable, interface `wlx<MAC>`) captures live
  802.11 traffic; devices populate in the web UI.

## Feeding Kismet data to the local LLM

Kismet's captured devices are queryable by the local AI: a native Open WebUI
tool (`../openwebui-tools/sovereign_sigint_kismet_tool.py`) reads the
`kismetdb` directly and lets the LLM answer questions like "what access points
were seen, with SSIDs and signal." Kismet runs continuously as a system
service (`systemd/kismet.service`, installed by `scripts/phase7-kismet.sh`),
and a 15-minute timer stages the newest capture to a stable path
(`kismet-data/latest.kismet`) so the AI has fresh capture data available at
any moment.
See `docs/kismet-to-ai-bridge.md` for that bridge; this README covers Kismet
capture itself.

## Hardware note

The reference box's WiFi adapter is a **MediaTek MT7612U**, not the RTL8812AU
originally scoped. This is the better outcome: the MT7612U uses the mainline
`mt76x2u` kernel driver with native monitor-mode support — no out-of-tree
DKMS driver needed. If your adapter is an RTL8812AU (or another chipset
without mainline monitor support), you would need the appropriate DKMS driver
(e.g. morrownr/8812au) before Kismet can use it; verify with `iw list` that
`monitor` appears under "Supported interface modes".

## Configuration

`kismet_site.conf.example` — installed automatically to
`/usr/local/etc/kismet_site.conf` (flat path — Kismet's `--sysconfdir` is
`/usr/local/etc/`, not `/usr/local/etc/kismet/`) by `scripts/phase7-kismet.sh`.
It pre-defines the WiFi source (auto-opens on Kismet startup, no manual
"Add Data Source" step) and binds the web UI to :2501.

The shipped `source=` line targets the reference MT7612U at MAC
`00:c0:ca:a6:85:0f`. If your adapter differs, edit the installed file after
phase7-kismet.sh completes:

```
sudo sed -i 's/wlx00c0caa6850f/<your-iface>/' /usr/local/etc/kismet_site.conf
sudo systemctl restart kismet
```

## Running

`scripts/phase7-kismet.sh` installs `systemd/kismet.service` and enables it
(`systemctl enable --now kismet`), so Kismet is running immediately after
the phase completes and autostarts on every reboot. Check status:

```
sudo systemctl status kismet --no-pager
sudo journalctl -u kismet --no-pager -b | grep -iE "source|monitor|wlx"
```

For interactive debugging you can also run it in the foreground (stop the
service first to avoid two Kismet processes fighting for the same adapter):

```
sudo systemctl stop kismet
kismet                # foreground; or background with:  kismet 2>/tmp/kismet.log &
```

Web UI: `http://<box-ip>:2501` (LAN-accessible — ufw allows 2501/tcp, same
posture as OpenWebRX+). On first run, set an admin username/password via the
UI before any features work (stored per-user in `~/.kismet/kismet_httpd.conf`).

For loopback-only access instead, set `httpd_bind_address=127.0.0.1` in
`kismet_site.conf`, remove the ufw rule, and reach it via SSH tunnel:
`ssh -L 2501:localhost:2501 <user>@<box>` then browse `http://localhost:2501`.

## Access / firewall

The web UI port is opened on the LAN:
```
sudo ufw allow 2501/tcp comment "Kismet web UI"
```
This matches the OpenWebRX+ posture (LAN-accessible monitoring UI). If you
prefer it off the LAN, skip this rule and use the SSH tunnel above.

## Next capture sources (not yet added)

- **Ubertooth One** (`scripts/phase7-ubertooth.sh`) — Bluetooth/BLE. The
  Kismet helper is already compiled in; needs the device plugged in and the
  standalone `ubertooth-tools` built, then added as a Kismet source.
- **Evil Crow RF v2** — sub-GHz; standalone (NOT a Kismet source), separate
  log-retrieval tooling.
