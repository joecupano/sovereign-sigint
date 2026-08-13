# sovereign-sigint

A web-accessible software-defined radio platform with a local ("sovereign")
AI layer for SIGINT. Signals captured by your own hardware become a structured,
queryable record that a **local LLM** reasons over in natural language —
what's active on the RF bands, what WiFi devices are present, and what a given
signal is likely to be — with **no cloud dependency** for the core pipeline.

Everything runs on-prem. The design principle is **local by default, cloud by
exception**: cloud LLMs, if used at all, are a deliberate opt-in for sanitized,
non-sensitive queries — never a silent dependency in the main pipeline.

This repo documents a **reproducible build** so others with comparable hardware
can stand up the same platform at their own location.

## Status

**Working end to end.** The capture → database → AI loop is closed and
reboot-durable, with three live AI data sources and calibrated RF sensors. See
[docs/build-order.md](docs/build-order.md) for the phase-by-phase build and
[docs/README.md](docs/README.md) for the full guide index. A companion
classroom curriculum (article, deck, and 13 lab sessions) lives in
[`classroom/`](classroom/).

## What it does

**Three AI data sources, each queried live by the local LLM through native
Open WebUI tools:**

| Source | Answers | Backed by |
|---|---|---|
| **RF occupancy** | What's active on the bands, when, how often? | `radiod` HF producer (wired, running) → occupancy DB |
| **WiFi device intelligence** | What access points / clients were seen? | Kismet capture → kismetdb |
| **Signal reference** | What *is* this signal? | Local mirror of the sigidwiki catalog |

Plus a **vision-assisted identification workflow**: a local vision model
describes an unknown signal's waterfall shape, the signal-reference tool
supplies candidate matches, and your own receiver's measured frequency
confirms — a three-way triangulation, entirely local. See
[docs/vision-signal-identification-guide.md](docs/vision-signal-identification-guide.md).

## Reference hardware

Your build will differ; this is the reference platform the docs were validated
against. **Calibration values, antennas, and receivable reference signals are
location-specific** — the guides teach how to re-derive them for your site.

| Component | Spec |
|---|---|
| Server | Dell Precision Tower 5820 |
| RAM | 64 GB |
| GPU | NVIDIA GeForce RTX 5060 Ti (16 GB) |
| HF SDR | RX-888 MkII (direct sampling) |
| VHF/UHF SDR | HackRF One (primary), RTL-SDR (backup) |
| WiFi capture | MT7612U (Kismet) |
| Bluetooth / sub-GHz (future) | Ubertooth One, Evil Crow RF v2 |
| OS | Ubuntu 24.04 Server |

## Architecture

- **HF ingest** — [ka9q-radio](https://github.com/ka9q/ka9q-radio) (`radiod`)
  drives the RX-888 MkII directly, wideband-sampling HF and channelizing it
  into many simultaneous demodulated channels over IP multicast. Native
  RX-888 support; no SoapySDR layer.
- **VHF/UHF ingest** — OpenWebRX+ provides the web waterfall/tuning UI for the
  HackRF/RTL-SDR chain.
- **Occupancy producers** — `radiod` (continuous HF, measuring power on each
  demodulated channel) is the one running as a continuous default: installed
  as a continuous systemd `--user` service by
  `scripts/phase6-occupancy-producer.sh`, confirmed on real hardware to
  actively grow the occupancy DB from live HF traffic. A second producer,
  `decode/vhf_uhf_key_freq_producer.py` (device-flexible: HackRF primary or
  RTL-SDR backup, key-frequency monitoring for VHF/UHF), runs as a
  **templated per-device systemd service** (`vhf-uhf-occupancy@hackrf` /
  `vhf-uhf-occupancy@rtlsdr`, installed by
  `scripts/phase6-vhf-uhf-producer.sh`). The operator opts in per device
  via `scripts/sdr-mode.sh hackrf ai` / `sdr-mode.sh rtlsdr ai` (and back
  to `interactive` to free the device for OpenWebRX+), because HackRF and
  RTL-SDR serve dual purposes — occupancy vs. interactive waterfall — and
  defaulting either to a running producer would grab a device the
  operator might want for OpenWebRX+. Both capture directly via the
  device's own CLI (`pcmrecord`, `hackrf_transfer`, `rtl_sdr`) and record
  a sighting when a channel crosses a per-device calibrated threshold. See
  [docs/occupancy-guide.md](docs/occupancy-guide.md).
- **Decode layer** — `direwolf` (APRS/AX.25), `multimon-ng` (POCSAG/FLEX/etc.),
  `ffmpeg` for archival recording. (These are also OpenWebRX+'s auto-detected
  decoders.)
- **AI layer** — Ollama + Open WebUI, GPU-accelerated locally. The LLM reaches
  each data source through **native in-process Open WebUI tools** — the
  reliable path for local models (external HTTP/OpenAPI tool-calling proved
  unreliable to invoke; that journey is documented in
  [docs/db-to-ai-query-path.md](docs/db-to-ai-query-path.md)). Models:
  `qwen3:14b` (reasoning + tools), `gemma3:12b` (vision), `nomic-embed-text`
  (embeddings). Setup: [docs/openwebui-setup-guide.md](docs/openwebui-setup-guide.md).
- **Services** — rootless Podman Quadlet units + systemd `--user` timers;
  Caddy fronts Open WebUI for LAN/TLS access.

**GNU Radio** was used early for occupancy flowgraphs but has been **removed**:
nothing in the working build needs it (direct-CLI captures replaced it, and
OpenWebRX+ handles interactive viewing). Flowgraph/demodulation work is a
deferred advanced topic, better suited to a desktop workstation — the reference
flowgraphs remain in [`decode/gnuradio-flowgraphs/`](decode/gnuradio-flowgraphs/).

## Repo layout

```
docs/               build order, guides, and architecture notes (start at docs/README.md)
scripts/            phased build + validation scripts (phase1 … phase7)
systemd/            systemd --user service/timer units
containers/         Podman Quadlet unit files (Open WebUI, Caddy)
ingest/
  ka9q-radio/       radiod configs for the RX-888 MkII (HF)
  openwebrx/        OpenWebRX+ profiles for HackRF/RTL-SDR
  direwolf/         APRS/AX.25 TNC configs
decode/             occupancy producers, SigMF writer, reference flowgraphs
db/                 occupancy database schema + access layer
reference/          SigID (sigidwiki) sovereign mirror
openwebui-tools/    the three native AI tools (occupancy, Kismet, SigID)
openapi-tools/      alternative OpenAPI tool server (superseded by native tools)
protocol-security/  Kismet and related protocol/WiFi tooling
ai-ingest/          document/image/audio ingest for the RAG knowledge feature
classroom/          teaching material — article, deck, and 13 lab sessions
```

## Not yet built / deferred

Kept honest: **CW and voice callsign-tracking** (`decode/cw-decode/`,
`decode/voice-transcribe/`) are placeholders, not implemented. **Ubertooth**
(Bluetooth) and **Evil Crow RF** (sub-GHz) hardware is planned but not yet
wired into the AI layer. **GNU Radio flowgraph** work is deferred. Some
integrations are parked on upstream fixes (see the guides).

## License

AGPL-3.0 — see [LICENSE](./LICENSE). Chosen deliberately given the copyleft
stack this build orchestrates (ka9q-radio, direwolf, multimon-ng under GPL;
OpenWebRX+ under AGPL): it keeps this repo's own code consistent with that
philosophy, includes an explicit patent grant, and closes the "hosted service"
loophole plain GPL leaves open — relevant since this repo includes actual
network-facing services.

## Contributing

Issues and PRs welcome. This is a from-scratch public build intended to be
reproducible on comparable hardware. If you build it at your own site,
real-world notes on where the docs or scripts didn't match your hardware or
signal environment are especially valuable.
