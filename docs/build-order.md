# Build order

## Quickstart

Bare command sequence, in order. Each phase's full rationale, exit
criteria, and flagged unknowns are in the sections below — read those
before debugging a failure, not just this list. Only run install
scripts with `sudo` where shown; several are deliberately rootless.

```
# Phase 1 — select only the devices you actually have connected
sudo ./scripts/phase1-hardware-drivers.sh
# reboot
./scripts/phase1-validate-sdrs.sh
./scripts/phase1-validate-protocol-tools.sh

# Phase 2
sudo ./scripts/phase2-os-packages.sh
./scripts/phase2-validate.sh

# Security hardening — recommended HERE, before Phase 3+ brings up any
# network-facing service (Ollama, Open WebUI, OpenWebRX+). See
# docs/security-hardening.md. Not phase-numbered — cross-cutting,
# applies regardless of build progress.
sudo ./scripts/security-hardening.sh
./scripts/security-hardening-validate.sh

# Phase 3
sudo ./scripts/phase3-ollama.sh
./scripts/phase3-validate.sh

# Phase 4  (plain HTTP :8000 by default; for HTTPS see the TLS options below)
./scripts/phase4-open-webui.sh
./scripts/phase4-validate.sh
#   TLS options (optional):
#     CADDY_TLS=1 ./scripts/phase4-open-webui.sh          # self-signed local CA, :8443
#     CADDY_TLS=cert CADDY_CERT=… CADDY_KEY=… CADDY_HOSTNAME=… \
#       ./scripts/phase4-open-webui.sh                    # your own certificate
#   (see docs/security-hardening.md § Caddy for details + client trust steps)

# Phase 5
./scripts/phase5-ai-ingest.sh
./scripts/phase5-validate.sh

# Phase 6.1 — only if RX-888 MkII is connected
sudo ./scripts/phase6-ka9q-radio.sh
./scripts/phase6-ka9q-radio-validate.sh

# Phase 6.2 — must precede 6.4 (OpenWebRX+ auto-detects these)
sudo ./scripts/phase6-decode-tools.sh
./scripts/phase6-decode-tools-validate.sh

# Phase 6.3
./scripts/phase6-sigid-mirror.sh
./scripts/phase6-sigid-mirror-validate.sh

# Phase 6.4 — only if HackRF and/or RTL-SDR is connected
sudo ./scripts/phase6-openwebrx.sh
# then add SDR devices manually: web UI -> Settings -> SDR devices
./scripts/phase6-openwebrx-validate.sh
#   RX-888 HF waterfall in OpenWebRX+ (optional, CPU-only, separate from the
#   AI/radiod path — see the "Phase 6.4" section below and the script's own
#   NEXT STEPS output for the exact device-type label, allowed sample rates,
#   and the restart-required-before-selectable gotcha):
sudo ./scripts/phase6-openwebrx-rx888.sh

# Phase 6.5
./scripts/phase6-sigmf-writer.sh
./scripts/phase6-sigmf-writer-validate.sh

# Phase 6.6 — occupancy DB schema/access-layer, then the real producer
./scripts/phase6-occupancy-db-validate.sh
./scripts/phase6-occupancy-producer.sh
#   (installs a continuous systemd --user service that sweeps radiod's HF
#   channels into the occupancy DB — confirmed on real hardware to actively
#   grow the sightings table; requires Phase 6.1's radiod already running)
```

`git pull` before each phase if picking this up across multiple
sessions — scripts and docs have both been revised as issues surfaced
during this build.

Six core phases, each depending only on what came before it. The AI stack
(Phases 3–5) is built and proven independently of SIGINT-specific
software (Phase 6) so the SIGINT layer can lean on already-working
ingest/OCR/audio infrastructure instead of duplicating it. A seventh
phase (Phase 7 — RF/Protocol Security Tooling: Kismet, WiFi/BT capture)
was added later; it sits at the packet/protocol layer, deliberately
separate from Phase 6's spectrum-occupancy model, and depends only on the
base OS/toolchain from Phases 1–2.

## Phase 1 — Hardware and drivers

Kernel/USB/GPU-level only, plus the toolchain needed to *build* drivers
from source (the RX-888 MkII has no packaged driver — `rx888_stream`
must be compiled). No SDR *application* software here — that's Phase 6.

Scripts: `scripts/phase1-hardware-drivers.sh` (install), then
`scripts/phase1-validate-sdrs.sh` (the actual exit-criteria test — do
not consider Phase 1 done until this passes for all three SDRs).

- Ubuntu 24.04 Server base install
- Mount and `/etc/fstab`-mount the `/data` drive (see `docs/data-layout.md`)
  *before* anything in later phases writes to it
- NVIDIA driver + CUDA for the RTX 5060 Ti — needed before Ollama so it
  can find the GPU at first run rather than falling back to CPU
- `avahi-daemon` — ka9q-radio (Phase 6) depends on mDNS `.local`
  resolution; installing it now means one less thing to debug later
- `git`, `build-essential`, `cmake`, `pkg-config` — not general dev
  tooling here, but the toolchain required to build the RX-888 MkII's
  driver stack (`rx888_stream`, from source) below. Phase 2 still owns
  the broader OS-level dev environment (Python, generic build tooling
  for later from-source builds like ka9q-radio/GNU Radio in Phase 6);
  installing these four packages here isn't duplicating that scope, it's
  Phase 1 owning what it needs to build its own drivers rather than
  quietly depending on a later phase for something the driver build
  itself requires
- **RX-888 MkII: the "stuck at USB2 (480M)" trap — READ THIS FIRST, it
  will save you days.** The single most important RX-888 gotcha in this
  whole build, learned the hard way over an extended debugging session
  that chased entirely the wrong cause. The core fact:

  **An RX-888 with no firmware loaded sits in Cypress FX3 DFU/bootloader
  mode (`lsusb` shows `04b4:00f3 ... DFU mode`, `Driver=[none]`), and in
  that state it enumerates at USB2 (480M) BY DESIGN.** It only
  re-enumerates onto a USB3 (5000M) bus AFTER application firmware
  (`SDDC_FX3.img`) is uploaded to it. So a fresh, unconfigured RX-888
  *always* shows 480M in `lsusb -t` — and that is NOT evidence of a USB3
  host/port/cable fault. It's just firmware-not-loaded-yet.

  **How this misleads you:** the 480M reading looks identical to a real
  USB3 problem. In this build it triggered a long detour — swapping every
  rear port on a Dell T5820, two cables, BIOS spelunking (all xHCI/USB3
  settings were already correct), and ultimately buying a Renesas
  uPD720201 USB3 PCIe card — all trying to force a 5000M link that the
  device was never going to show *while sitting in DFU mode*. The moment
  firmware was uploaded (`rx888_stream -f SDDC_FX3.img -s 32000000`), the
  device re-enumerated to USB3 and streamed at ~60 MB/s (486 MB in ~8s —
  proof positive of USB3, since that rate is impossible over USB2).

  **What actually matters, in order:**
  1. Confirm the device is present in DFU mode: `lsusb | grep 04b4`
     should show `04b4:00f3 ... DFU mode`. Seeing 480M here is EXPECTED
     and fine — do not debug it.
  2. Validation uploads firmware (`-f`), which triggers re-enumeration to
     USB3. Check the *post-firmware* speed if you want to confirm USB3,
     not the pre-firmware DFU-mode speed.
  3. The device returns to DFU mode only on a real power cycle (unplug
     ~15s, or reboot) — NOT when a process merely closes. After a
     successful streaming run it's left in loaded (non-DFU) state, so a
     second validation run without a power cycle will FAIL with
     `LIBUSB_ERROR_NO_DEVICE` / `bootloader PID (0x00f3) not found` —
     because there's no bootloader to upload to anymore. This is not a
     failure of the hardware; re-run needs a fresh DFU state (reboot or
     unplug/replug the device first).

  **On the USB3 PCIe card:** it turned out not to be *necessary* to reach
  USB3 (the onboard controller could have worked once firmware was the
  real variable under test) — but it's still worth having: a dedicated
  controller gives the RX-888 its own uncontended 5 Gbps, which is the
  right architecture for sustained wideband capture regardless. No regret,
  just not the fix it was bought as.
- `libusb`, RX-888 MkII firmware blob (`SDDC_FX3.img`) present on disk
- **RX-888 MkII streaming validation via `rx888_stream`** (from
  `rx888_tools`, bundled with the SDDC_FX3/firmware repo) — a standalone
  firmware-uploader-and-capture tool, fully independent of
  `radiod`/ka9q-radio. `lsusb` showing the device only confirms it's
  physically present (and in DFU mode, at USB2 — see the gotcha above).
  **CLI, confirmed on real hardware:** `-f <SDDC_FX3.img>` uploads
  firmware and MUST be passed (the device sits in DFU mode and does NOT
  auto-load firmware on open — an earlier assumption that it would was
  wrong, and an earlier script version that omitted `-f` failed every
  time). `rx888_stream` streams int16 real samples to **stdout** (redirect
  with `>`), NOT via a `-o` flag; `-s` sets the sample rate (only
  32000000 or 135000000 Hz); capture duration is controlled by how long
  the stream runs (a `timeout`), not a flag. A `timeout`-killed stream
  exits 124 with a full-sized capture file — that's the PASS path.
  `scripts/phase1-validate-sdrs.sh` has the corrected invocation
  (locates `SDDC_FX3.img`, always uploads it).
- HackRF host tools: `libhackrf`, `hackrf-tools` — `hackrf_info`/
  `hackrf_transfer` confirm the device enumerates and streams, same
  reasoning as above, before any GNU Radio/OpenWebRX+ work depends on it
- RTL-SDR host tools: `librtlsdr`, `rtl-sdr` — `rtl_test` confirms
  streaming; also blacklist the kernel's built-in DVB-T driver
  (`dvb_usb_rtl28xxu`), which otherwise claims the device before your
  SDR tools can
- **Ubertooth One** — `libbtbb` + `ubertooth-tools`, built from source
  (no apt package for the tools themselves, same situation as the
  RX-888). Validated standalone via `ubertooth-util -v` (firmware
  comms) and a real `ubertooth-rx` capture window — before any
  consuming application (not yet built) touches it. Release tag pinned
  to a confirmed-working version in the script; check upstream for
  newer tags before relying on it long-term.
- **Evil Crow RF v2** — not a USB peripheral with a host driver; it's a
  standalone WiFi-networked ESP32 device with its own onboard firmware.
  "Standalone install" here means confirming network reachability
  (mDNS resolution of `evilcrow-rf.local` + HTTP 200 on its web UI) —
  the equivalent validation to a driver-presence check for a device
  that has no driver to install on this box.

Scripts for the two protocol-security devices:
`scripts/phase1-validate-protocol-tools.sh` (Ubertooth capture check,
Evil Crow RF reachability check) — installed alongside the SDRs in
`scripts/phase1-hardware-drivers.sh`, validated by a separate script
since the checks are a different shape (capture vs. network
reachability) than the SDR streaming tests. Same underlying principle
throughout Phase 1 either way: prove the hardware/driver layer works
before any upstream application (RFQuack, GNU Radio, OpenWebRX+) is in
the picture to confuse the diagnosis if something's wrong.

**Exit criteria:** GPU visible to `nvidia-smi`; `/data` mounted and
owned correctly; and for each SDR, a real sustained data capture —
not just enumeration — confirms the driver/USB layer works standalone:
- RX-888 MkII: clean `rx888_stream` capture at target sample rate
- HackRF: clean `hackrf_transfer` capture
- RTL-SDR: clean `rtl_test`/`rtl_sdr` capture
- Ubertooth One: firmware communication confirmed, capture window
  produces output
- Evil Crow RF v2: resolvable on the network, web UI responds

Any hardware or USB3 problem should surface here, fully decoupled from
`radiod`, GNU Radio, RFQuack, or any other later-phase software — so a
later failure is known to be a software/config issue, not a hardware
one still hiding underneath it.

## Phase 2 — OS packages and runtime prerequisites

General-purpose system software that every later phase depends on but
that isn't hardware-specific (Phase 1) or use-case-specific (Phases
3–6). The point of a separate phase: things installed here get their
own verification step instead of sitting "installed but unverified"
until whichever later phase happens to use them first.

Scripts: `scripts/phase2-os-packages.sh` (install, run with `sudo`),
then `scripts/phase2-validate.sh` (the actual exit-criteria test — run
as your normal user, NOT with `sudo`, since rootless Podman and venv
creation need to run as the real user later services will run as).

- Podman — container runtime for Phase 4 (Open WebUI) and beyond, run
  rootless. This needs a `/etc/subuid`/`/etc/subgid` range for the
  target user (usually auto-assigned on account creation, but not
  guaranteed for pre-existing accounts) and `loginctl enable-linger`
  for that user — without lingering, rootless systemd-user-managed
  containers stop the moment the user logs out, which would surface as
  a confusing intermittent failure in Phase 4 rather than a clear
  problem here
- Python 3 + `venv`/`pip`, and `curl` — generic runtime tooling Phases
  5 and 6 need
- `git`, `build-essential`, `cmake`, `pkg-config` were moved to Phase 1
  (needed there to build the RX-888 MkII's driver from source) — not
  repeated here. Phase 6's later from-source builds (ka9q-radio, GNU
  Radio) can rely on them already being present and already proven
  working, since Phase 1's `rx888_stream` build is itself a working
  smoke test of that toolchain
- FFTW3 (`libfftw3-dev`, `libfftw3-bin`) + background baseline wisdom
  generation. General infrastructure both `radiod` (Phase 6.1) and GNU
  Radio (Phase 6.2) depend on, not specific to either — belongs here,
  not bundled into one tool's install script. Kicked off in the
  background at install time (can take hours) specifically so it runs
  across Phases 3–5 instead of being pure wait time once Phase 6 needs
  it. This generates a broad baseline of common transform sizes, not a
  guarantee of covering every transform this build's specific radiod
  config ends up using — Phase 6.1 checks for and fills any gap
- Any other baseline OS packages common across later phases — add here
  as they're identified, rather than as one-off installs buried inside
  a later phase's setup

**Exit criteria:** don't let "installed" stand in for "verified" —
run an actual smoke test for each:
- Podman: `podman run --rm hello-world` succeeds (catches rootless/
  cgroups v2/storage-driver misconfiguration here, not tangled up with
  your first real Quadlet unit in Phase 4)
- Python: a venv creates cleanly and `pip install` resolves from PyPI
- FFTW: no smoke test here beyond "the background job started without
  erroring" — actual verification happens implicitly in Phase 6.1 when
  radiod either finds the wisdom it needs or doesn't

## Phase 3 — Ollama and default models

Scripts: `scripts/phase3-ollama.sh` (install + pull default models, run
with `sudo`), then `scripts/phase3-validate.sh` (the actual exit-criteria
test — GPU inference and embedding checks, run as your normal user).

- Install Ollama natively (not containerized) — simpler GPU passthrough
  than routing a container through the NVIDIA Container Toolkit for a
  single service
- Set `OLLAMA_MODELS=/data/models` before the first `ollama pull`
- **`OLLAMA_HOST=0.0.0.0` required** — confirmed via a real install:
  Ollama defaults to binding `127.0.0.1` only, which Phase 4's Open
  WebUI container cannot reach through `host.containers.internal`
  (that hostname resolves to the box's real LAN-facing IP under
  rootless Podman's networking here, not an isolated container-only
  address). **Security implication, not glossed over:** this exposes
  Ollama's unauthenticated API on the LAN, not just to the local
  container — restrict at the firewall if this box sits on a network
  with untrusted hosts (see `scripts/phase3-ollama.sh` for a starting
  `ufw` example; verify the actual subnet to scope it to rather than
  assume one)
- **Ownership exception:** `/data` is otherwise owned by the human
  operator (see `docs/data-layout.md`), but Ollama's systemd service
  runs as its own `ollama` system user, which needs write access to
  pull models. `/data/models` is chowned to `ollama:ollama` specifically
  — a narrow, deliberate exception for this one subdirectory, not a
  change to the general `/data` ownership convention. **Chowning
  `/data/models` alone isn't sufficient** — confirmed via a real
  install (`mkdir /data/models: permission denied: ensure path
  elements are traversable`): `/data` itself is locked to `o-rwx`, so
  `ollama` (neither the owner nor in that group) can't traverse into
  `/data` at all regardless of `/data/models`'s own ownership. Fixed
  by adding `ollama` to whatever group owns `/data`, giving it
  legitimate group-level traverse access rather than loosening `/data`
  itself to fix one consumer.
- Pull default models for the use case. Don't hardcode specific tags
  here — the Ollama library moves fast; confirm current best-fit models
  at install time for each role:
  - a general-purpose instruct/reasoning model (chat, classification,
    natural-language query over the SIGINT DB)
  - an embedding model (RAG over `/data/rag`)
  - a vision-capable model if on-device image reasoning is wanted
    beyond OCR text extraction (Phase 5 covers OCR itself via Docling/
    pytesseract, not Ollama)
  - `scripts/phase3-ollama.sh` defaults to `qwen3:14b` / `nomic-embed-text`
    / `gemma3:12b` (verified against the live library as of June 2026),
    sized for the confirmed 16GB RTX 5060 Ti in this build

**Exit criteria:** `ollama run <model>` works from the CLI with GPU
utilization visible in `nvidia-smi`, models are physically on `/data/models`.

## Phase 4 — Open WebUI (Podman container)

Scripts: `scripts/phase4-open-webui.sh` (install, run WITHOUT sudo —
rootless Quadlet units run as your normal user), then
`scripts/phase4-validate.sh` (the actual exit-criteria test).

- Podman Quadlet units (`containers/open-webui.container`,
  `containers/caddy.container`), deployed rootless under
  `~/.config/containers/systemd/`, port 8080 for Open WebUI (bound to
  loopback only — Caddy is the actual public/LAN-facing entrypoint),
  Caddy reverse proxy in front of it on **port 8000, not 80** — a real
  install hit `bind: permission denied` on :80, since rootless Podman
  can't bind privileged ports without a system-wide policy change
  (`net.ipv4.ip_unprivileged_port_start`); moved Caddy's listen port
  instead of loosening that system-wide for one container's
  convenience (`containers/Caddyfile`; plain HTTP :8000 is the default —
  for local-CA HTTPS on :8443, run Phase 4 with `CADDY_TLS=1`, which
  generates a `tls internal` config that MUST include a global
  `auto_https disable_redirects` block or Caddy crashes trying to bind
  privileged :80 for the HTTP→HTTPS redirect; see docs/security-hardening.md)
- Since Ollama runs natively (Phase 3) rather than in a container, Open
  WebUI reaches it via `host.containers.internal`, added through
  `PodmanArgs=--add-host=...` rather than Quadlet's dedicated `AddHost=`
  key — confirmed via a real install that `AddHost=` isn't supported in
  the Podman version Ubuntu 24.04 ships (4.9.3); `PodmanArgs=` is the
  generic pass-through that works regardless of Quadlet's own key
  coverage for whatever Podman version is actually installed
- `/data/rag` is bind-mounted specifically to
  `/app/backend/data/uploads` — the confirmed internal path Open WebUI
  actually stores uploaded RAG documents at (per Open WebUI's own
  database-schema docs). App state that lives alongside it internally
  (`webui.db`, `vector_db/`, `cache/`) stays in a separate
  Podman-managed named volume rather than also landing under `/data` —
  that's app internals, not "static documents for RAG" in the sense
  `docs/data-layout.md` means, and letting Podman manage it avoids
  fighting Open WebUI's internal directory layout on a host path.
  **This directory is for manual UI uploads only** — Open WebUI tracks
  uploads in its own database (DB record + embedding is what makes a
  file actually searchable in chat), so a script dropping files here
  directly wouldn't make them part of RAG. Phase 5's automated ingest
  pipeline is deliberately NOT wired to this directory; see Phase 5 and
  `docs/data-layout.md` for where it lands instead

**Exit criteria:** Open WebUI reachable through Caddy, can query the
Phase 3 models (verified by the container actually reaching Ollama's
API, not just the login page loading), RAG document upload lands in
`/data/rag` on the host (verified both directions — host-to-container
and the reverse).

## Phase 5 — AI ingest pipeline: OCR, imagery, baseline audio

Scripts: `scripts/phase5-ai-ingest.sh` (venv + systemd timer install, run
WITHOUT sudo), then `scripts/phase5-validate.sh` (real round-trip test —
generates and processes actual test files, not just a service-status
check). Pipeline code lives in `ai-ingest/` (`ingest.py`,
`extractors/documents.py`, `extractors/images.py`, `extractors/audio.py`,
`manifest.py`); scheduling in `systemd/ai-ingest.{service,timer}`.

General-purpose ingest infrastructure — not SIGINT-specific yet. This is
the corpus pipeline: Python venv, `docling` (DOCX/PDF, with built-in OCR
for scanned PDFs — auto-selects the RapidOCR ONNX backend on this build,
not `pytesseract`), `pytesseract` (used only by `extractors/images.py`
for standalone image OCR — PNG/JPG/HEIC in `/data/imagery`, not for
scanned PDFs), `faster-whisper` ("medium" model — ~1.5GB VRAM, fully
local on the 5060 Ti) for baseline spoken-word/audio transcription.

**GPU-accelerated end-to-end.** Docling's OCR (via RapidOCR onnxruntime)
and layout model both engage `cuda:0` when the accelerator is available;
faster-whisper likewise runs on GPU. On the 5060 Ti a single-page
scanned PDF converts in ~6 seconds (layout + OCR + doc assembly); on a
CPU-only box the same work is 5-10× slower. This is a real feature
worth being explicit about — a rebuild on hardware without a GPU still
works but the ingest window will be dominated by OCR/layout time, not
whisper.

**Airgap-capable.** `systemd/ai-ingest.service` sets
`Environment=HF_HUB_OFFLINE=1` so Docling doesn't reach out to HuggingFace
on every startup for a version check on its cached models. Models are
downloaded once during phase5 install and cached locally; the offline
flag keeps the ingest run's outbound network footprint at zero,
consistent with the sovereign-by-design thesis. Unset temporarily if you
need to pull updated Docling models.

**Deliberately decoupled from Open WebUI's chat RAG.** Open WebUI
tracks uploads in its own database (DB record + embedding is what
makes a file searchable in chat) — a script writing files straight
into `/data/rag` wouldn't actually make them part of RAG, just files
sitting in a directory Open WebUI happens to also read from. Rather
than have ingest fight that by calling Open WebUI's upload API for
every document, this pipeline stays a standalone corpus that other
consumers (scripts, future SIGINT correlation, etc.) can read from
directly. Revisit this if there's a real need for ingest output to be
chat-searchable in Open WebUI specifically — that's an API-integration
project, not a filesystem one.

- Python virtualenv + dependency install (docling, pytesseract,
  faster-whisper, python-docx if resume/doc generation is reused) —
  isolated in the `ai-ingest` venv; see `docs/venvs.md` for the venv
  registry and conventions
- Ingest scripts read originals from `/data/corpus/source` and write
  extracted/normalized text to `/data/corpus/processed`, namespaced by
  type (`processed/document/`, `processed/image/`, `processed/audio/`)
  to avoid path collisions between source roots. Original images and
  audio stay in `/data/imagery` and `/data/audio` respectively; only
  derived text lands in `/data/corpus/processed`. Idempotent via a
  SQLite manifest keyed on content hash (`ai-ingest/manifest.py`) — a
  re-run only reprocesses new or changed files. See `docs/data-layout.md`
- Scheduling: `systemd --user` timer (`systemd/ai-ingest.timer`), every
  4 hours — same cadence as the Job Hunter pipeline's poll timer, for
  consistency across this box's scheduled jobs rather than a technical
  requirement
- This phase proves OCR, image handling, and speech-to-text work
  end-to-end, producing usable extracted text in `/data/corpus/processed`,
  *before* SIGINT-specific audio (demodulated signal audio, not general
  speech) enters the picture

**Exit criteria:** a DOCX, a scanned PDF, an image, and a spoken-word
audio clip each round-trip through ingest — original in
`/data/corpus/source` (or `/data/imagery`/`/data/audio` as
appropriate), extracted text lands in
`/data/corpus/processed/<type>/...`. MET (2026-07-28: scanned-PDF path
verified end-to-end with a genuinely-scanned test PDF; extracted text
was legible with only minor OCR ambiguities like `l`/`1`, and a
distinctive term census caught all six content lines).

## Phase 6 — SIGINT software and processing

Everything that consumes the Phase 1 hardware and leans on the Phase
3–5 AI stack for classification/enrichment rather than reimplementing it.
Built and validated one at a time like the earlier phases. Numbering
was reordered once already (see 6.2's note on why decode-layer tools
had to precede OpenWebRX+) and again here — cheap to do before a
sub-step has scripts/artifacts referencing its old number, which is
true of everything below except 6.1 and 6.2.

**6.1 — ka9q-radio (`radiod`) — HF ingest.** Scripts:
`scripts/phase6-ka9q-radio.sh` (build from source, run with `sudo`),
`scripts/phase6-ka9q-radio-validate.sh` (real capture via `pcmrecord`,
not just service-active status). Built from source per ka9q-radio's own
docs — no apt package exists. `radiod` drives the RX-888 MkII directly
via libusb (its own code path, separate from `rx888_stream`), so this
is where the hardware validated in Phase 1 gets its first real
workload, not where it gets tested for the first time. Config:
`ingest/ka9q-radio/radiod@rx888-hf.conf` (drafted earlier in this build).

**CONFIRMED WORKING on real hardware (2026-07):** first real-hardware run
succeeded. `radiod` uploaded the RX-888 firmware itself, the device
re-enumerated to USB3 (04b4:00f1 on a 5000M bus), the `radio` system
user's USB permissions worked without intervention, **18 demodulators
started** (WWV 2.5/5/10/15 MHz AM, 20m/40m FT8, 2m APRS, CW, LSB/USB,
wideband-iq — channelization HackRF/RTL-SDR cannot do; channel list is site-specific, and note CHU shut down 22 Jun 2026), and
validation captured 716,892 bytes of real WWV 10 MHz AM audio via
`pcmrecord`. Both areas that had been flagged as unconfirmed turned out
fine: the firmware path worked as configured, and `pcmrecord`'s CLI
matched. The one real build break was **`fobos.h: No such file`** — a
later ka9q-radio `main` tree pulled `fobos.c` into the default build
path (it should only compile with `make FOBOS=1`, needs third-party
libfobos headers, no Fobos device present). Fixed by pinning to commit
`e1224dcd` (the commit projecthorus/auto_rx pins); override with
`KA9Q_COMMIT=<sha>` if needed. See the RX-888 DFU-mode gotcha earlier in
this doc — the device must be in DFU/bootloader mode for radiod to load
firmware, which a reboot or power-cycle guarantees.

**RX-888 is a single-owner device — radiod vs OpenWebRX+.** Only one
process can hold the RX-888 open. radiod (this phase, the AI/occupancy
path) and OpenWebRX+ (interactive HF waterfall) both want it and cannot
coexist on the hardware, and there is no clean native path for
OpenWebRX+ to consume radiod's streams. Use `scripts/rx888-mode.sh`
(`ai` | `interactive` | `status`) to time-share safely: it stops the
other owner and waits for USB release before starting the new one.
`ai` (radiod owns it — continuous all-HF occupancy) is the default
"always watching" posture; `interactive` hands the device to OpenWebRX+
for hands-on tuning and pauses AI HF occupancy. See
`docs/openwebrx-sdr-quickstart.md` for the full rationale, including why
the RX-888 is a *peer* to RTL-SDR/HackRF for a single AI channel but
*non-peer* (uniquely capable) for continuous all-band occupancy. FFTW3 itself
and a background baseline wisdom generation job moved to Phase 2 (it's
general infrastructure, not ka9q-radio-specific, and starting it there
means it runs across Phases 3–5 instead of tacked-on wait time here) —
this script checks radiod's own config-specific "suggest running" log
message for anything the Phase 2 baseline didn't cover and surfaces it
for you to run, rather than assuming the baseline was sufficient.
**Cross-phase permission check:** `radiod` runs as a dedicated `radio`
system user (created by `make install`), not the interactive user
Phase 1's RX-888 udev rule was validated against — the script inspects
that rule for group-based access and adds `radio` to it if needed,
rather than assuming Phase 1's validation (which never ran as `radio`)
already proved this works.

**6.2 — Decode layer: `direwolf`, `multimon-ng`, `ffmpeg`.**
Scripts: `scripts/phase6-decode-tools.sh` (install, run with `sudo`),
`scripts/phase6-decode-tools-validate.sh` (direwolf/multimon-ng get a startup
check — full decode-path validation needs real captured APRS/POCSAG/FLEX
audio, not synthesized here, same kind of coverage gap as the scanned-PDF case
in Phase 5). Built and validated standalone before 6.6 (OpenWebRX+),
deliberately — this isn't just testing-order preference. OpenWebRX+ treats
`direwolf` and `multimon-ng` as optional runtime dependencies it auto-detects
at startup (`direwolf` for Packet Radio/APRS I-gate, `multimon-ng` for
FLEX/POCSAG paging decode) — building them first means OpenWebRX+ picks them up
automatically when it's installed, rather than being installed against tools
that don't exist yet and needing to be verified as correctly detected after the
fact.

**GNU Radio — removed / deferred.** GNU Radio was originally installed in this
phase for occupancy flowgraphs, but nothing in the working build uses it: the
occupancy producers capture directly via `hackrf_transfer` / `rtl_sdr` /
radiod's `pcmrecord` and compute power from the samples, and OpenWebRX+ handles
interactive HackRF/RTL-SDR viewing with its own DSP. The only GNU Radio
consumers were two occupancy flowgraphs
(`decode/gnuradio-flowgraphs/`) that were never hardware-validated and are now
superseded; they remain as reference (see that dir's README). Because GNU Radio
is a large dependency with no current use, it's intentionally **not installed**.
Building real demodulation flowgraphs is a legitimate advanced topic, but better
done on a desktop workstation than this headless server — deferred until a
concrete need arises (`sudo apt install -y gnuradio gnuradio-dev gr-osmosdr`
when it does).

**6.3 — SigID mirror.** Scripts: `scripts/phase6-sigid-mirror.sh`
(sets up `/data/reference/sigid`, venv dependency, weekly systemd timer,
runs an initial bootstrap sync), `scripts/phase6-sigid-mirror-validate.sh`
(confirms real content landed AND that a second run is genuinely
incremental — the actual point of building this for reuse). Code:
`reference/sigid_mirror.py`, `reference/sigid_manifest.py`.

Design supersedes the earlier plan to import a static Internet Archive
snapshot: since this needs to stay current via periodic re-runs (manual
or cron/timer), a one-time archive import isn't enough on its own — the
mirror is instead an **incremental sync against the live MediaWiki
API** (`api.php`), not HTML scraping. MediaWiki's API is the respectful,
designed-for-this-purpose path for programmatic access — a different
thing, ToS-wise, than scraping rendered HTML. First run bootstraps via
`list=allpages`; subsequent runs use `list=recentchanges` since the
last successful sync, so re-runs only fetch what actually changed.
State (per-page revision ID, per-file content hash) tracked in a SQLite
manifest (`reference/sigid_manifest.py`, same pattern as Phase 5's
ingest manifest) — idempotent, safe to run on any schedule.

**Unconfirmed, flagged in the script rather than guessed:** whether
`api.php` is actually open on this specific wiki install (some
installs restrict it — the script auto-discovers at `/api.php` and
`/w/api.php` and fails clearly with next steps if neither works, rather
than silently falling back to something fragile), and whether
namespace-0 page enumeration cleanly captures "signal entries"
specifically vs. other wiki content (about pages, guides) — worth
revisiting once real API responses are visible.

**Confirmed via a real bootstrap run:** the initial static 1.5s delay
between requests wasn't sufficient — the site rate-limited (HTTP 429)
partway through page 3, and the original code treated that as fatal,
killing the whole run. Fixed with retry-with-backoff (honoring the
server's `Retry-After` header when present) shared across both the
MediaWiki API calls and the raw file-download requests, which had been
on a separate, unprotected code path. A 429 across a run that can make
hundreds of calls is an expected condition, not an exceptional one.

~589 signals (frequency ranges, modulation notes, waterfall images,
audio) land in `/data/reference/sigid/{metadata,images,audio}` — a new
top-level `/data/reference/` category, distinct from `/data/rag`
(manual Open WebUI uploads) and `/data/corpus` (Phase 5's own ingest
output), since this is external reference material with different
provenance and update cadence than either. Feeds a future lookup table
for cross-referencing detected signal characteristics against known
entries (see 6.6's occupancy DB discussion), and optionally the Phase
5 ingest pipeline for RAG-queryable text. Sync runs weekly by default
(`systemd/sigid-mirror.timer`) — SigID is a slow-changing curated wiki,
no reason to hit it more often. Licensing note: the site's own
contributors describe the content as unlicensed/public-domain-in-
practice ("recordings of an RF environment," no copyright claimed per
site commentary) — informal, not a legal grant, but about as
permissive a signal as an unlicensed wiki gets.

**6.4 — OpenWebRX+ for the HackRF/RTL-SDR VHF/UHF+ chain.** Scripts:
`scripts/phase6-openwebrx.sh` (install via luarvique's PPA, run with
`sudo`), `scripts/phase6-openwebrx-validate.sh` (service reachability
only — SDR device setup is a manual web UI step, not scripted). Native
install, deliberately not containerized — containerizing would isolate
OpenWebRX+ from the direwolf/multimon-ng binaries 6.2 built specifically
so it could auto-detect them; the readily-available Docker images ship
their own bundled decoders instead, which would make 6.2's build-order
reasoning pointless. Ubuntu 24.04 (noble) support in the PPA is marked
"experimental" upstream. SDR device/profile configuration
(`settings.json`) is intentionally left to the officially-supported
guided web UI flow rather than scripted — a documented real-world
failure mode (missing `rf_gain`, wrong `direct_sampling` value for
RTL-SDR v3 vs v4) makes a guessed config riskier than doing it once by
hand. Built ahead of 6.5/6.6 by request, while those two get more
design discussion first (SigMF writer scope is settled; occupancy DB
storage engine and schema are not) — no dependency blocked this
reordering, and having OpenWebRX+ live alongside `radiod`'s HF stream
gives real concurrent-write behavior to observe while 6.6 gets designed.

**6.5 — SigMF writer.** Scripts: `scripts/phase6-sigmf-writer.sh`
(venv setup, run WITHOUT sudo), `scripts/phase6-sigmf-writer-validate.sh`
(real round-trip against synthetic IQ data — writes, reads back via
direct JSON parsing per this project's read-path convention, verifies
SHA512 integrity). Code: `decode/sigmf_writer.py`, usable as a CLI or
a library (the hook other pieces — a future SigID cross-reference, an
occupancy-DB record ID — would call into, via `write_sigmf()`'s
`extra_capture_metadata` parameter, not wired to anything yet since
6.3/6.6 don't produce that data today).

**Input format support, corrected from an earlier version of this
doc/code:** `ci16_le` is native to RX-888 (`rx888_stream`) only — RTL-SDR
and HackRF are NOT `ci16_le` natively, they're `cu8` (unsigned 8-bit,
offset-binary, RTL-SDR) and `ci8` (signed 8-bit, HackRF) respectively.
All three are supported with correct per-format normalization (the
unsigned/signed offset distinction matters — get it wrong and you get
a DC-offset artifact, not an obvious failure). `scripts/capture-to-sigmf.sh`
wraps `rtl_sdr`/`hackrf_transfer` capture and this writer into one step,
since OpenWebRX+ has no raw-capture path for either device (confirmed
via the Feature Report — no `iq_recording` feature exists).

Output lands in `/data/signals/generated` (raw captures land in
`/data/signals/raw` first, via `capture-to-sigmf.sh`), pinned dependency
(`sigmf==1.11.1`) already staged in `decode/requirements.txt` from
earlier in this build.

**API confidence — fully confirmed via real hardware, not asserted.**
Every call in `write_sigmf()` (`sigmf.fromarray()`, `meta.sample_rate =
...`, `meta.add_capture()`, `meta.tofile()`, and `meta.set_global_info()`
for author/description) was verified against a real RTL-SDR capture
(100 MHz FM) — `core:author` and `core:description` both came back
correct in the written `.sigmf-meta`, closing out the one call that had
been a best-guess method name rather than a confirmed one. The
complex64 conversion for `cu8`/`ci8` is an 8x file-size increase (vs.
2x for `ci16_le`) — worth revisiting via the lower-level `SigMFFile`
API if that overhead matters, now that real captures exist to test
native-bit-depth writing against.

**Real gap, not yet resolved:** input is normalized from raw `ci16_le`
(the native output format of `rx888_stream`/RTL-SDR/HackRF) to
`cf32_le` before writing, since sigmf-python's high-level `fromarray()`
API is documented primarily against floating-point arrays. This works,
but doubles file size and discards native bit depth. Worth revisiting
via the lower-level `SigMFFile` API once a real hardware capture is
available to test against — untestable from here without one.

**6.6 — Occupancy database schema.** Code: `db/occupancy_schema.sql`
(DDL), `db/occupancy_db.py` (access layer — `OccupancyDB.record_sighting()`
is the single write path any ingestion source calls into). **Wired and
running**: `scripts/phase6-occupancy-producer.sh` installs the radiod-based
producer as a continuous systemd `--user` service, confirmed on real
hardware to actively grow the `sightings` table from live HF traffic once
Phase 6.1's radiod is up. See "Producers" below for the current picture
across all three device types.

**Design reference: Kismet's `kismetdb`**, deliberately — not because
it's a broader interoperability standard (confirmed it isn't: Kismet
*exports out* of kismetdb into already-standard formats like pcap and
wiglecsv for other tools to consume; nothing reads the native schema
directly except Kismet's own official `python-kismet-db`), but because
its `DEVICES`/`PACKETS` split is a proven, directly analogous pattern
for exactly this shape of problem — a real adaptation of that pattern:

- **`sightings`** (→ `PACKETS`) — per-detection event, lean columns
- **`signals`** (→ `DEVICES`) — long-lived aggregate, keyed by
  `make_signal_key()`: **frequency (binned) + mode**, substituting for
  the durable per-emitter identity Kismet gets for free from a MAC
  address, which RF signals generally don't have
- **Timestamp convention**: paired epoch-seconds + milliseconds fields
  per signal/sighting, matching kismetdb's actual design (mirrors C's
  `tv_sec`/`tv_usec` struct timeval split) — deliberately not
  OpenWebRX+'s single combined millisecond-epoch integer, since the
  paired-field approach keeps the coarse field a clean, index-friendly
  integer for most queries while preserving sub-second precision
  separately when needed
- **`schema_version` table** from day one — this build's own history
  (Phase 2's insertion, SigMF format additions) is reason enough not
  to retrofit versioning later

**Unresolved, flagged rather than guessed:** `FREQUENCY_BIN_HZ` (1000,
in `occupancy_db.py`) is a placeholder — reasonable for narrowband
HF/VHF/UHF (ham, APRS, pagers) but almost certainly wrong at the
extremes (too coarse for tightly-packed HF digital channels, too fine
for a 20 MHz WiFi channel or a 125 kHz LoRa channel that should still
collapse to one `signals` row despite reported-center jitter). A real
functional test confirmed the binning mechanism itself works correctly
(two sightings 50 Hz apart correctly aggregated to one signal), but the
bin *size* needs revisiting once real sighting data exists — don't tune
it blind.

**Storage engine:** SQLite for now, matching every other DB in this
build — still worth reconsidering TimescaleDB if writes turn out to be
genuinely concurrent across multiple front ends (`radiod` +
OpenWebRX+/GNU Radio), since SQLite's single-writer lock becomes a real
constraint in that case. Confirm the actual write topology before that
decision, not before.

Signal captures land in `/data/signals/raw`, generated SigMF recordings
in `/data/signals/generated`, extracted SIGINT audio in `/data/audio` —
same data root as Phase 5, so retention/backup policy is consistent
across both AI and SIGINT audio. See `docs/data-layout.md`.

**Producers.** **`radiod` is the one currently wired and running
producer**: `scripts/phase6-occupancy-producer.sh` installs it as a
continuous systemd `--user` service that sweeps radiod's demodulated HF
channels, measures per-channel power, and calls `record_sighting()` —
confirmed on real hardware to actively grow the `sightings` table (live
WWV/ham-band traffic). Two other integration shapes were designed/
prototyped but are NOT currently wired (see chat history for the full
comparison): HackRF/RTL-SDR via GNU Radio (flowgraphs below — GNU Radio
itself isn't installed in this build, see the note earlier in this phase;
would need to be added if these are revived), and OpenWebRX+ via MQTT
(needs a broker installed first). Confirmed acceptable: HackRF/RTL-SDR
producers are single-frequency/mode monitors, not wideband-simultaneous —
neither device has `radiod`'s overlap-save architecture, and blanket
coverage was never realistic for them.

Built: `decode/gnuradio-flowgraphs/hackrf_occupancy_monitor.py` and
`rtlsdr_occupancy_monitor.py` — standalone GNU Radio flowgraphs (source
→ magnitude-squared → boxcar average/decimate → a custom
`OccupancyDetector` sink block) implementing fixed-threshold-with-hang-
time energy detection, calling `record_sighting()` directly. RTL-SDR
monitor **confirmed working against real hardware** (WWV via direct
sampling at 10 MHz) — HackRF monitor still syntax-checked only, not
yet run.

**Threshold calibration built:** `--calibrate SECONDS` runs the same
source/power-estimate pipeline into a `NoiseFloorCalibrator` sink
instead of the detector — accumulates samples for the given duration,
reports mean/std/max noise floor in dB, and suggests
`--threshold-db` = mean + a configurable margin (`--margin-db`,
default 10). Must be run on a genuinely quiet moment/frequency — a
signal present during calibration inflates the measured floor and the
resulting suggested threshold. Addresses the "don't tune blind"
caution below directly, rather than leaving it as an open warning.

One thing still flagged deliberately rather than resolved:
- **Timestamps are wall-clock** (`time.time()` when a buffer is
  processed), not derived from GNU Radio stream tags — accurate to the
  block's processing granularity, not sample-precise. Fine for
  occupancy tracking at second-level granularity, not a general timing
  reference.

RTL-SDR's monitor defaults to **manual gain**, not auto — confirmed
during Phase 6.4's OpenWebRX+ work that auto gain produced a faint,
indistinguishable signal on this exact hardware; the same real finding
applies here, not a generic default choice.

**Correction to an earlier claim in this project's history:** RTL-SDR
*can* reach HF, on exactly this hardware (RTL-SDR Blog v3/v4) — an
earlier statement that it couldn't without a hardware mod was wrong.
`--direct-sampling` enables gr-osmosdr's `direct_samp=2` (Q-branch,
correct for v3/v4 boards) device argument, no physical modification,
same antenna connector. Real tradeoff: direct sampling bypasses the
tuner chip's amplification entirely, so sensitivity is markedly lower
than normal VHF/UHF reception through the tuner path — expect to need
strong local signals or a decent antenna.

**Callsign-over-time tracking — deferred, not currently in scope.**
Was previously reserved as a numbered sub-step; dropped from the
active numbering in this reorder rather than kept as a placeholder,
since the current renumbering is deliberate and user-directed rather
than an unplanned insertion (unlike Phase 2's earlier mid-sequence
insertion, which did warrant preserving stable numbers around it). If
this resumes, it'll get whatever number fits at the time. Was: APRS
direct decode, CW + FCC ULS cross-reference, spoken-callsign
transcription reusing the Phase 5 Whisper pipeline.
`decode/requirements.txt` already had its callsign-tracking-specific
dependencies trimmed when this was first deferred.

**Exit criteria:** a live signal on HF or VHF/UHF is captured and logged
to the occupancy DB with correct frequency/timestamp/duration —
confirmed on real hardware via the radiod producer (live WWV/ham-band
sightings accumulating). Note: the producer itself does power-threshold
detection only, not LLM classification — that happens separately, when a
model reasons over logged sightings via the occupancy Open WebUI tool
(Phase 4), not at capture time. An earlier version of this criterion
described "classified via the Phase 3 model" as part of ingest; that's
not how the built system works and has been corrected here.

---

## Phase 7 — RF/Protocol Security Tooling

Deliberately separate from Phase 6's spectrum-occupancy pipeline. Phase 6
is the tunable-receiver / waterfall / occupancy-DB model (what's on the
air, where, when). Phase 7 works one layer up, at the **packet/protocol**
level — 802.11, Bluetooth/BLE, 802.15.4, and other framed protocols —
where the unit of interest is a device/emitter and its traffic, not a
slice of spectrum. Neither the WiFi adapter nor Ubertooth fits the
Phase 6 receiver model, hence a distinct phase.

**Structure:**
```
protocol-security/
  kismet/          # site config + notes (the aggregation layer)
  ubertooth/       # BT/BLE capture wrappers (planned)
  evilcrow-rf/     # sub-GHz log retrieval/parsing (planned)
scripts/
  phase7-kismet.sh            + -validate.sh
  phase7-ubertooth.sh         (planned)
  phase7-evilcrow.sh          (planned)
```

### 7.1 — Kismet (aggregation layer) — BUILT & VALIDATED

Kismet is the datastore + UI that all protocol capture sources feed into.
Scripts: `scripts/phase7-kismet.sh` (build from source, run with `sudo`),
`scripts/phase7-kismet-validate.sh`.

**Built from source, NOT from Kismet's APT repo — this is required, not a
preference.** The prebuilt packages for 2025+ releases depend on
`libwebsockets17`, which is NOT installable on Ubuntu 24.04 (Noble carries
a different libwebsockets version). Confirmed still-open upstream issue
(kismetwireless/kismet#574): `apt install kismet` hard-fails with
`Depends: libwebsockets17 but it is not installable`. Building from source
links against Noble's own `libwebsockets-dev` (4.3.x), sidestepping the
pin — the same source-build approach used for ka9q-radio, libsddc, and
SoapySDDC elsewhere in this build.

The **full** dependency list is installed (including `libubertooth-dev`,
`libbtbb-dev`, `librtlsdr-dev`) so Kismet's Ubertooth, Bluetooth, and RTL
capture helpers are COMPILED IN now — Kismet chooses which capture helpers
to build at `./configure` time from the `-dev` libs present. Installing
them all now means adding that hardware later is "enable the source", not
"rebuild Kismet". The hardware does not need to be attached for the build.
`make suidinstall` is used: only the small capture helpers are
setuid-root, the server runs as a normal user in the `kismet` group
(least-privilege capture model).

**CONFIRMED on real hardware (2026-07):** Kismet 2026.07.0 built clean from
source; all three capture helpers present (`kismet_cap_linux_wifi`,
`kismet_cap_linux_bluetooth`, `kismet_cap_ubertooth_one`); server serves
its web UI on :2501; and **WiFi capture validated end-to-end** — live
802.11 devices populate the UI.

**WiFi adapter — the scoped blocker evaporated.** Phase 7 was originally
scoped around an AWUS036AC (RTL8812AU chipset), whose out-of-tree DKMS
driver and monitor-mode support were an unverified blocker. The box's
actual adapter is a **MediaTek MT7612U** (mainline `mt76x2u` driver,
interface `wlx<MAC>`), which supports monitor mode natively — no DKMS, no
blocker. If your adapter IS an RTL8812AU or similar without mainline
monitor support, install the appropriate DKMS driver first and confirm
`iw list` shows `monitor` under "Supported interface modes" before Kismet
can use it.

**Config:** `protocol-security/kismet/kismet_site.conf.example` is
installed automatically to `/usr/local/etc/kismet_site.conf` (flat path —
Kismet's `--sysconfdir` is `/usr/local/etc/`, not `/usr/local/etc/kismet/`)
by `scripts/phase7-kismet.sh`. It pre-defines the WiFi source (auto-opens
on launch, no manual "Add Data Source" step) and binds the web UI to :2501.
The UI port is opened on the LAN via ufw (`allow 2501/tcp`), matching the
OpenWebRX+ posture; for loopback-only, bind 127.0.0.1 and use an SSH tunnel
instead.

**Autostart:** `scripts/phase7-kismet.sh` also installs `systemd/kismet.service`
and enables it, so the daemon autostarts on boot and survives reboot without
manual intervention. See `protocol-security/kismet/README.md` for the running
model and `docs/kismet-to-ai-bridge.md` for the AI-side path.

### 7.2+ — Ubertooth, Evil Crow RF — PLANNED

- **Ubertooth One** (BT Classic + BLE) — the Kismet capture helper is
  already compiled in; remaining work is building the standalone
  `ubertooth-tools` (libbtbb + host binaries, cmake), validating the device
  with `ubertooth-rx`, then adding it as a Kismet source. Device was not
  attached at 7.1 build time.
- **Evil Crow RF v2** (sub-GHz) — standalone ESP32 tool, NOT a Kismet
  capture source; separate log-retrieval/parsing scripts. Fully decoupled.

**Exit criteria (7.1):** Kismet builds from source, serves its UI, captures
live 802.11 traffic from a monitor-capable adapter, autostarts on boot, and
the AI-side native tool returns real device intelligence via `kismet_summary`
and `query_wifi_devices`. MET (end-to-end, verified on rubberduck).

### Scope: thin on Kismet operation, deep on Kismet → AI

This project's value is **applying AI to SIGINT**, not re-documenting
Kismet. Kismet's own installation and operation are covered only as far as
needed to stand it up as a *source* (7.1 above) — its extensive
operational documentation already exists elsewhere and is not duplicated
here. The work that matters, and where depth belongs, is the **Kismet → AI
bridge**: getting Kismet's device/protocol observations out of kismetdb
and into the AI layer the same way every other source is (radiod, the
occupancy DB, the SigID mirror all feed the AI as things it reasons over).

**Status: DONE.** As of 7.1 Kismet captured WiFi/BT but the data
dead-ended in kismetdb. The bridge now exists: a **native Open WebUI tool**
(`openwebui-tools/sovereign_sigint_kismet_tool.py`) reads kismetdb directly
(read-only) and surfaces device/protocol observations — APs, clients, MACs,
SSIDs, signal, manufacturer — to the AI as things it reasons over in natural
language, exactly like radiod/occupancy do for RF. It is kept in Kismet's
device-centric shape (NOT flattened into the occupancy DB), because the two
are different kinds of intelligence: frequency occupancy vs. protocol/device
presence. kismetdb-direct was chosen over the REST API (the API needs auth
and reading SQLite is the pattern that works cleanly with local models under
`PRAGMA query_only`). Semi-live: Kismet runs continuously as a system service
(`systemd/kismet.service`), and a 15-min timer stages the newest capture to a
stable path (`latest.kismet`) so the AI has fresh capture data within ~15 min.
See `docs/kismet-to-ai-bridge.md`. This also unblocks a Kismet
classroom lab (a Kismet→AI path now exists to teach).
