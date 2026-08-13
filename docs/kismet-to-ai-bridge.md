# The Kismet→AI Bridge — WiFi Device Intelligence for the Local LLM

**Status: WORKING.** The local LLM can query Kismet's captured WiFi data in
natural language — access points, clients, MACs, SSIDs, signal, manufacturer —
and answers from the real `kismetdb`. This is the **second AI data source**
after occupancy, and the first *non-occupancy* one: it is device/protocol
intelligence, deliberately kept in Kismet's device-centric shape rather than
flattened into the frequency-based occupancy DB.

## The working solution: a native Open WebUI tool over kismetdb

`openwebui-tools/sovereign_sigint_kismet_tool.py` — a `Tools` class with:
- **`query_wifi_devices`** — list/filter captured devices by type ("AP",
  "Client", "Bridged") and signal; returns MAC, type, signal (dBm), SSID (for
  APs), manufacturer, bytes, first/last-seen.
- **`kismet_summary`** — device counts by type/PHY and the capture time range.

It reads the `.kismet` SQLite file directly, read-only (`PRAGMA
query_only=ON`), the same proven pattern as the occupancy tool. SSID and
manufacturer come from the per-device JSON BLOB (plain JSON, gzip-handled);
the flat `devices` columns (`devmac`, `type`, `strongest_signal`,
`first_time`/`last_time`, `phyname`) are the primary data.

## Why kismetdb-direct, not the REST API

Kismet exposes a REST API on :2501, but we query the **file** because:
- **Kismet isn't always running** — the API is only up when it is; the
  `.kismet` file is queryable anytime.
- **The REST API needs HTTP basic auth** (credentials in
  `~/.kismet/kismet_httpd.conf`); the file needs none.
- **Reading a SQLite file read-only is the pattern that works** reliably with
  local Ollama models (external HTTP tools were unreliable to invoke — see
  `db-to-ai-query-path.md`).

## Deployment

Same shape as the occupancy DB mount. The tool runs inside the Open WebUI
container, so the `.kismet` file must be visible there.

1. **Install the refresh timer** — this creates the staging directory
   and stages `latest.kismet` automatically from Kismet's real captures.
   No manual copy step needed:
   ```
   ./scripts/phase7-kismet-refresh.sh
   ```
2. **Mount the staging dir into the container** (Quadlet
   `~/.config/containers/systemd/open-webui.container` — automatic if you
   used the shipped `containers/open-webui.container` template):
   ```
   Volume=/home/<user>/sovereign-sigint/kismet-data:/data/kismet
   ```
   **Not** `:ro` — a `.kismet` file is a live SQLite/WAL database, and
   SQLite in WAL mode needs the directory writable to create its
   `-wal`/`-shm` sidecars, even for a read-only workload. The tool
   enforces read-only at the query level (`PRAGMA query_only=ON`).
   Then `systemctl --user daemon-reload && systemctl --user restart open-webui`.
3. **Install the tool** in Open WebUI — full procedure in
   `docs/openwebui-setup-guide.md`. In brief: (Workspace → Tools → paste → Save),
   confirm the `KISMETDB_PATH` valve is `/data/kismet/latest.kismet`, attach
   it to your model, enable it in chat.

## Semi-live: auto-refreshed snapshot (not continuous-live)

The staged `latest.kismet` is a **copy of the newest capture**, kept current
automatically by a timer (`scripts/kismet-refresh.sh` +
`systemd/kismet-refresh.timer`, installed by
`scripts/phase7-kismet-refresh.sh`). Every 15 minutes it stages the newest
`.kismet` file to `latest.kismet`, so the AI sees fresh capture data within
~15 min without a manual copy. The refresh:
- finds the newest `.kismet` by mtime,
- **stages the live file by default** — safe because SQLite's WAL mode
  supports concurrent reads-while-writing, and the tool opens with
  `PRAGMA query_only=ON`; pass `--session-only` to opt back into the older
  skip-while-Kismet-is-running behavior (appropriate only if you run
  Kismet on-demand rather than as a service),
- no-ops if already current (won't re-copy a large file needlessly),
- copies via temp+rename so the tool never reads a half-copied file.

This is the deliberate **semi-live** design under the always-on Kismet
model: Kismet runs continuously as a system service
(`systemd/kismet.service`, installed by `scripts/phase7-kismet.sh`), the
refresh timer stages a fresh copy every 15 min, and the AI always has
current-within-15-min capture data. Truly continuous-live (querying
Kismet's actively-written file in real time) would need the container to
mount the live file directly; considered and set aside in favor of the
staged-copy pattern, which keeps a stable path (`latest.kismet`) that
doesn't change filename per session.

## Validated

Confirmed working end to end: the LLM called `kismet_summary` and reported the
real capture (30 devices — 21 clients, 5 bridged, 4 APs, all IEEE802.11, with
the correct multi-day time range), and `query_wifi_devices` returned the APs
with manufacturers (Epigram, HPE) and extracted SSIDs (e.g. "Excelsior") and
signal levels — all from the real kismetdb.

## Where this sits in the architecture

Two AI data sources now, both via native tools, each in its native shape:
- **RF occupancy** (frequency-domain) — three calibrated SDRs → occupancy DB →
  `sovereign_sigint_occupancy_tool.py`. See `db-to-ai-query-path.md`.
- **WiFi device intelligence** (protocol-domain) — Kismet → kismetdb →
  `sovereign_sigint_kismet_tool.py` (this doc).
