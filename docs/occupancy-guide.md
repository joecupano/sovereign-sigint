# Understanding and Using Occupancy

A standalone reference for the occupancy concept in this build: what
it means, why it's designed the way it is, what's actually built and
validated, and how to use it today. Consolidates decisions scattered
across `docs/build-order.md` Phase 6.6 and this project's own build
history into one place for anyone learning the concept fresh.

## What "Occupancy" Actually Means

Standard RF/spectrum-management terminology, not invented for this
build — the question occupancy answers is narrow and specific: **was a
given frequency in use, over what time window, for how long.**
Regulatory bodies run occupancy surveys for exactly this reason —
knowing how much allocated spectrum is actually used, and when, is
foundational spectrum-management information on its own.

This is deliberately **not** the same question as "what is this
signal." Identification is a separate, optional layer that can sit on
top of an occupancy record — a signal can be logged as occupying
144.390 MHz from 08:14:02 to 08:14:19 whether or not anything ever
determines it was APRS. Keeping these two questions separate was a
conscious design choice, not an oversight.

## Why Kismet, and What Had to Change

Kismet — the established WiFi/Bluetooth monitoring tool — was used as
the **design reference**, specifically its `DEVICES`/`PACKETS` split:
a long-lived aggregate record per tracked entity, plus a lean,
high-volume table of individual detection events. That pattern
transferred cleanly to this build's `signals`/`sightings` tables.

**Worth being precise about:** kismetdb is Kismet's own native format,
not a broader interoperability standard — other tools consume Kismet's
*exports* (pcap, wiglecsv), not the native schema directly. Using it as
a reference means borrowing a proven pattern, not building toward
compatibility with anything.

**The real adaptation required:** WiFi/BT devices get a durable
identity for free from their MAC address. Most RF signals don't have
an equivalent — a beacon, a pager transmission, an ISM sensor doesn't
carry a persistent unique ID the way a network interface does. The
substitute: aggregate on **frequency (binned) + mode** instead of a
hardware address. This is the single most important design decision in
the whole schema, and the one place a naive port of Kismet's model
would have failed silently.

**Timestamp convention, also borrowed deliberately:** paired
epoch-seconds + milliseconds fields per record, mirroring kismetdb's
actual design (which itself mirrors C's `tv_sec`/`tv_usec` struct
timeval split) — not a single combined millisecond integer the way
OpenWebRX+'s own MQTT reporting does it. The paired approach keeps the
common case (querying by whole seconds) working against a clean,
index-friendly integer, while preserving sub-second precision
separately for when it's actually needed.

## What's Actually Built

**Schema** (`db/occupancy_schema.sql`):

| Table | Role | Kismet analog |
|---|---|---|
| `schema_version` | Tracks schema evolution from day one, given how much this build's own schemas have already changed | — |
| `signals` | Aggregate per `(frequency_hz bin, mode)` — `first_seen`, `last_seen`, `total_sightings`, optional `candidate_sigid` link into the Phase 6.3 SigID mirror | `DEVICES` |
| `sightings` | One row per detection event — exact frequency, bandwidth, source, mode, optional `raw_capture_ref` pointing into a Phase 6.5 SigMF file | `PACKETS` |

**Access layer** (`db/occupancy_db.py`) — zero dependencies beyond the
Python standard library, deliberately. Any future producer, whether it
runs under a venv or system Python (recall the GNU Radio/venv boundary
from Phase 6.2), can `import occupancy_db` directly with no
cross-environment bridging.

- `make_signal_key(frequency_hz, mode)` — the binning/aggregation logic
- `record_sighting(...)` — the single write path every producer calls
- `get_signal(...)` / `get_sightings(...)` — read-side query helpers

**`FREQUENCY_BIN_HZ` is a placeholder (1000 Hz), flagged as such in the
code, not asserted as correct.** Reasonable for narrowband HF/VHF/UHF
(ham, APRS, pagers); almost certainly wrong at the extremes — too
coarse for tightly-packed HF digital channels, too fine for a 20MHz
WiFi channel or a 125kHz LoRa channel that should collapse to one
`signals` row despite reported-center jitter. This needs real sighting
data before it's worth tuning further, not a guess refined in the
abstract.

## Producers — What Actually Writes to It

> **Single-owner rule (critical):** every SDR is a single-owner USB
> device. An SDR held by OpenWebRX+ is NOT available to any occupancy
> producer while OpenWebRX+ holds it, and vice versa. If OpenWebRX+ is
> configured to use all SDRs, occupancy capture has **no devices left**.
> Different SDRs can run different jobs at once (RX-888 → radiod for HF
> occupancy *while* HackRF → OpenWebRX+ for a VHF waterfall), but no
> single SDR does both. `scripts/sdr-mode.sh status` shows current
> ownership; the same script switches each device via
> `sdr-mode.sh {rx888|hackrf|rtlsdr} {ai|interactive}` (RX-888 delegates
> to `scripts/rx888-mode.sh`; HackRF/RTL-SDR enable/disable their
> per-device `vhf-uhf-occupancy@<device>.service` instance).

Three distinct integration shapes, at three different stages of
completion. **Status corrected against ground truth (the occupancy DB is
currently empty — 0 signals — so nothing has meaningfully populated it
yet):**

| Producer | Status | Notes |
|---|---|---|
| HackRF (key VHF/UHF freqs) | **WORKING — wired as templated service (primary)** | `decode/vhf_uhf_key_freq_producer.py --device hackrf`, run by `systemd/vhf-uhf-occupancy@hackrf.service` (installed by `scripts/phase6-vhf-uhf-producer.sh`; enabled per-device via `sdr-mode.sh hackrf ai`, disabled via `sdr-mode.sh hackrf interactive`). Monitors a fixed list of 2m/70cm key frequencies (APRS 144.39, simplex calling, local repeaters) matched to the Comet GP-1 antenna, via `hackrf_transfer`. Calibrated LNA 40/VGA 48, -14 dBFS. Note: `hackrf_transfer`'s power readout clamps ~-30 below ~LNA 40, so it only discriminates at high gain. Operator-elected between AI and OpenWebRX+ modes so the HackRF can stay free for the waterfall when not sweeping. |
| RTL-SDR (key VHF/UHF freqs) | **WORKING — wired as templated service (backup)** | Same producer, `--device rtlsdr`, run by `systemd/vhf-uhf-occupancy@rtlsdr.service` (same install script; enabled via `sdr-mode.sh rtlsdr ai`, disabled via `sdr-mode.sh rtlsdr interactive`), via `rtl_sdr` (unsigned uint8, offset-127 decode). Backup for the HackRF, on a broadband antenna. Calibrated gain 0, -18 dBFS — counterintuitively the RTL-SDR discriminates best at MINIMUM gain (the R820T compresses at high gain), validated over multiple sweeps (floor ~-25, a real 145.100 key-up read -4.7). One producer script, two systemd instances (`@hackrf` and `@rtlsdr`), independent enable/disable state per device; `source_device` still distinguishes their sightings in the DB. |
| GNU Radio monitors (old) | **Superseded, never hardware-validated** | `decode/gnuradio-flowgraphs/{hackrf,rtlsdr}_occupancy_monitor.py` — the older single-frequency GNU Radio monitors, never hardware-run. Superseded by the key-freq producer above for both devices. |
| `radiod` (RX-888) | **WORKING — built, calibrated, continuous** | `decode/radiod_occupancy_producer.py`, run continuously by `systemd/radiod-occupancy.service`. Reads each of radiod's ~17 demodulated HF channels via `pcmrecord`, measures per-channel power, records sightings above a calibrated -30 dBFS threshold. This is the FIRST producer to actually populate the occupancy DB, and it closed the capture→DB→AI loop end to end. Reboot-validated. |
| OpenWebRX+ (MQTT) | **Not built** | Would need a broker (Mosquitto); MQTT per-mode JSON topics are the natural fit. Discussed, not actioned. |
| Kismet (protocol layer) | **Bridge WORKING — separate AI source** | Kismet captures WiFi/BT into its own `kismetdb`. It is deliberately NOT flattened into the occupancy DB — instead a **native Open WebUI tool** (`openwebui-tools/sovereign_sigint_kismet_tool.py`) queries kismetdb directly, giving the AI device-centric WiFi intelligence (APs, clients, MACs, SSIDs, signal) alongside RF occupancy. Semi-live via a 15-min refresh timer. See `docs/kismet-to-ai-bridge.md`. |

**Honest current state:** the occupancy DB has a producer-agnostic schema
and a concurrency-ready DB layer (WAL + busy_timeout, so multiple
producers write simultaneously without contention). It is **actively
populated**: the radiod producer runs continuously (thousands of HF
sightings), and the HackRF and RTL-SDR key-freq producers run as
per-device templated services (`vhf-uhf-occupancy@hackrf` /
`vhf-uhf-occupancy@rtlsdr`) that the operator opts in to per device
via `sdr-mode.sh`. All producers call the identical
`record_sighting()`; the schema assumes nothing about any specific
capture tool.

## Calibration — Why It Matters More Than It Sounds

Every producer uses a **fixed, hand-calibrated detection threshold**, not
an adaptive one — deliberately not disguised as more sophisticated than it
is. Each threshold was set by measuring the real noise floor for that
device+antenna against known-strong and known-quiet references, and placing
the threshold in the gap between them.

> **Calibrate for YOUR site — the numbers below are one location's results,
> not universal constants.** The thresholds and gains in this repo
> (radiod -30, HackRF -14 at LNA 40/VGA 48, RTL-SDR -18 at g0) were derived
> at one location, with specific antennas, in a specific noise environment.
> **Yours will differ** — different antennas, different local noise, different
> nearby transmitters. Copy them as a *starting point*, then re-derive using
> the method below. Do NOT trust the shipped defaults as correct for your
> site without verifying.
>
> **The portable method (works anywhere):**
> 1. **Find a known-QUIET reference** — a frequency in-band that should be
>    idle right now (an unused simplex channel; or a spot away from any
>    resonant/active signal). This gives your noise floor.
> 2. **Find a known-STRONG reference** — any signal you're certain is present
>    and loud. Use whatever your location and antenna actually receive:
>    - *VHF/UHF:* a strong local FM broadcast station (pick one YOU know is
>      strong — the frequency varies by region), a local repeater's output,
>      or a nearby transmitter. (The examples in this repo used one site's
>      strong FM station; substitute your own.)
>    - *HF:* a time/standard station you can actually hear, or a strong
>      broadcast. **Note:** US **WWV** (2.5/5/10/15/20 MHz) is still on air,
>      but Canada's **CHU** shortwave time station **shut down 22 June 2026**
>      — do not use CHU as a reference. In regions without a receivable time
>      station, use a strong local/regional HF broadcaster instead.
> 3. **Sweep both, several times.** Note the dBFS of quiet vs. strong. A real
>    signal should sit well above the floor; if they read the same, something
>    is wrong (wrong gain regime, wrong antenna, or you're reading a clamp —
>    see the HackRF lesson below).
> 4. **Set the threshold in the gap** — comfortably above the quiet floor so
>    idle channels read quiet, comfortably below real activity so signals
>    register. Pass it via `--threshold-dbfs` (and `--gain-args`) to verify
>    before baking it into `DEVICE_CONFIG`.

**The real lessons from actually calibrating three different devices** (one
site's worked example — the *method* transfers, the *numbers* won't):

- **radiod (RX-888/HF):** the demodulators sit at a ~-33 dBFS residual
  floor; a cluster of unrelated bands all reading -32..-36 at once was the
  tell that this was the floor, not real per-band occupancy. Threshold -30.

- **HackRF (VHF/UHF):** `hackrf_transfer`'s own power readout **clamps near
  -30 dBFS below ~LNA 40** — at low gain *every* frequency, even a strong FM
  broadcast, read identical -30. Discrimination only appears at high gain.
  Threshold -14 at LNA 40/VGA 48.

- **RTL-SDR (VHF/UHF backup):** the **opposite** — it discriminates best at
  *minimum* gain (the R820T compresses at high gain); at g0 there was a ~21
  dB spread between strong and quiet. Threshold -18.

Two habits proved essential every time. First, **a single reference sample
can mislead** — the RTL-SDR's first sweep looked alarmingly busy (five 2m
channels "active"); three sweeps revealed the true ~-25 floor and a single
real transmission standing 20 dB above it. Second, **a clean, error-free
capture still deserves sanity-checking against physical expectation** — the
identical clamped readings weren't an error, they were a tool quietly
reporting a floor. A calibration run succeeding is not the same claim as the
number it produced being meaningful.

## How Occupancy Data Is Utilized Today

**Direct query — works right now, no additional setup:**

```python
import sqlite3
conn = sqlite3.connect("db/occupancy.db")
conn.row_factory = sqlite3.Row
for row in conn.execute("SELECT * FROM signals ORDER BY last_seen_sec DESC LIMIT 10"):
    print(dict(row))
```

Or via `occupancy_db.py`'s own `get_signal()`/`get_sightings()` methods
directly in a script.

**Natural-language querying — TWO paths, both working:**

1. **Live tool query (primary) — `docs/db-to-ai-query-path.md`.** A native
   Open WebUI tool (`openwebui-tools/sovereign_sigint_occupancy_tool.py`)
   queries `occupancy.db` directly and live: the local LLM calls
   `query_occupancy`/`radiod_status` and answers from current data. Confirmed
   working — the model returned real WWV and 20m signals with live sighting
   counts. This is the closed capture→DB→AI loop.
2. **Knowledge-base snapshot (secondary) — `docs/signal-knowledge-base-guide.md`.**
   Exports `signals`/`sightings` into markdown loaded into Open WebUI's
   Knowledge feature. Useful for broader RAG-style questions, but **snapshot,
   not live** — only as current as the last export.

## Real-World Validation

Confirmed working end to end on real hardware: the **radiod occupancy
producer** reads radiod's live demodulated HF channels, and — calibrated
against the ~-33 dBFS demodulator floor with a -30 dBFS threshold —
correctly logs sightings for genuinely active signals (WWV carriers, FT8,
active CW) while treating quiet channels as quiet. The full chain from
antenna through RX-888, radiod, the producer, and into structured
`signals`/`sightings` rows is proven, running continuously, and
reboot-validated. The occupancy DB holds thousands of real sightings.

(Note: the HackRF/RTL-SDR GNU Radio monitors are NOT part of this
validation — they remain code-written but never hardware-run, per the
producer table above.)

`scripts/phase6-occupancy-db-validate.sh` additionally confirms, with
synthetic but real functional tests: frequency-binning correctly
collapses near-duplicate sightings into one `signals` row, correctly
keeps genuinely distinct signals separate, and correctly handles a
null-mode (energy-only, unidentified) detection.

## Honest Current Limitations

- **`FREQUENCY_BIN_HZ` is an untested placeholder**, not a tuned value
  — see above.
- **HackRF/RTL-SDR monitors watch one frequency/mode at a time** and
  remain hardware-unvalidated. `radiod`'s producer provides continuous
  wideband HF coverage; the single-tuner monitors would add VHF/UHF once
  validated (gated on confirmed antennas).
- **OpenWebRX+ has no occupancy producer** — the schema and access layer
  are producer-agnostic and ready, but that path isn't wired (would need
  MQTT/Mosquitto). The `radiod` path IS wired and running.
- **Detection thresholds are fixed per producer run**, not adaptive to
  changing conditions over a long unattended run — a calibration done at
  2pm may not hold at 2am on a noisier band. The radiod producer's -30
  dBFS default is calibrated to the demodulator floor, which is stable,
  but real-signal activity is propagation-dependent.

None of these are defects hiding as features — they're the honest
current edge of what's built, worth knowing before assuming more
capability than exists.

## See Also

- `docs/build-order.md` Phase 6.6 — the original build-log record of
  these decisions, in the order they were made
- `docs/signal-knowledge-base-guide.md` — natural-language querying via
  Open WebUI
- `docs/vision-signal-identification-guide.md` — visual signal
  comparison, a complementary but separate capability
- `db/occupancy_schema.sql`, `db/occupancy_db.py` — the actual
  implementation
- `decode/gnuradio-flowgraphs/hackrf_occupancy_monitor.py`,
  `rtlsdr_occupancy_monitor.py` — the two working producers
