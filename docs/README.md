# Documentation Index

## Build

- **[build-order.md](build-order.md)** — the phase-by-phase build log
  (six core phases plus Phase 7 for RF/protocol tooling): what each phase
  does, why, every real bug hit along the way and how it was fixed. The
  primary reference for building this system from scratch.
- **[data-layout.md](data-layout.md)** — the `/data` directory structure
  and per-subsystem wiring: what lives where, ownership conventions, and
  the one deliberate exception (`/data/models`).
- **[venvs.md](venvs.md)** — the Python virtual environment registry
  (`ai-ingest`, `sigint-processing`) and the system-Python/venv boundary.
- **[security-hardening.md](security-hardening.md)** — the eight-item
  security baseline (SSH key-only [optional], auditd, fail2ban,
  unattended-upgrades, AppArmor, telemetry purge, Caddy HTTPS, Ollama
  network exposure), rationale and residual risk for each. Covers all
  three Caddy TLS modes: plain HTTP (default), self-signed local CA
  (`CADDY_TLS=1`), and bring-your-own-certificate (`CADDY_TLS=cert`).

## Hardware & SDR

- **[openwebrx-sdr-quickstart.md](openwebrx-sdr-quickstart.md)** —
  default OpenWebRX+ profiles for HackRF, RTL-SDR, and RX-888, plus a
  troubleshooting section built from real issues (gain configuration,
  the `aprs_symbols` dependency gap, PLL warnings).

## Occupancy (Signal Detection & Tracking)

- **[occupancy-guide.md](occupancy-guide.md)** — the concept, the
  Kismet-derived schema design, what's actually built and validated,
  producer status, the calibration lesson, and honest current
  limitations. Start here for anything occupancy-related.

- **[signal-to-occupancy-db-path.md](signal-to-occupancy-db-path.md)** —
  the mechanical path from antenna to a written `signals`/`sightings`
  row, per SDR (RX-888, HackRF, RTL-SDR): every program and process in
  each chain (`radiod`/`pcmrecord`, `hackrf_transfer`, `rtl_sdr`), the
  producer scripts, systemd units, and ownership switches, ending at
  the shared `record_sighting()` write path.

- **[db-to-ai-query-path.md](db-to-ai-query-path.md)** — how the local
  LLM queries the occupancy DB in natural language. The WORKING solution
  (a native Open WebUI tool), why the OpenAPI and MCP approaches were
  tried and set aside, and the WAL/mount details. Read for the DB→AI
  loop.

- **[kismet-to-ai-bridge.md](kismet-to-ai-bridge.md)** — the second
  AI data source: WiFi device intelligence from Kismet. A native tool over
  kismetdb (APs, clients, MACs, SSIDs, signal), why kismetdb-direct over the
  REST API, the mount setup, and the snapshot limitation.

## AI / RAG Guides

- **[openwebui-setup-guide.md](openwebui-setup-guide.md)** — START
  HERE for the AI front end. First-run setup, connecting Ollama, pulling
  the three models, and the canonical step-by-step procedure for
  installing/enabling a native tool (the one the occupancy, Kismet, and
  SigID docs link to). Captures the setup gotchas learned building this.

- **[rag-knowledge-base-guide.md](rag-knowledge-base-guide.md)** —
  building a local RAG knowledge base via Open WebUI's native Knowledge
  feature, worked example using an external antenna-design archive.
  Establishes the base pattern the other two RAG guides reuse.
- **[signal-knowledge-base-guide.md](signal-knowledge-base-guide.md)** —
  the same RAG pattern applied to this build's own occupancy DB and
  SigID mirror data, so `qwen3:14b` can answer natural-language
  questions about what's actually been observed. Snapshot-based, not
  live — the guide is explicit about that distinction.
- **[vision-signal-identification-guide.md](vision-signal-identification-guide.md)** —
  using `gemma3:12b` to visually compare a captured waterfall or
  spectrogram against SigID reference images, as identification triage.

## Reading Order for a New Operator

1. `build-order.md` — build the system
2. `occupancy-guide.md` — understand what it's actually tracking
3. `openwebrx-sdr-quickstart.md` — configure device profiles
4. `rag-knowledge-base-guide.md` → `signal-knowledge-base-guide.md` →
   `vision-signal-identification-guide.md` — the AI-assisted workflows,
   in order of increasing project-specificity
