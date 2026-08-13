# Signal-to-Occupancy-DB Path, Per SDR

A step-by-step technical trace of what happens between RF hitting an
antenna and a row landing in `db/occupancy.db`, for each of the three
SDRs this build supports: **RX-888**, **HackRF**, **RTL-SDR**.

This is a companion to `docs/occupancy-guide.md` (the *concept* —
what occupancy means, why the schema looks like it does, calibration
methodology) and `docs/build-order.md` Phase 6.6 (the *build log* —
decisions in the order they were made). This document is neither —
it's the **mechanical path**: which program touches the signal at
each stage, what it does to it, and what it hands to the next stage,
for all three devices side by side.

All three paths converge on the same two calls, which is the single
most important fact about this architecture:

```python
from occupancy_db import OccupancyDB
db = OccupancyDB(db_path)
db.record_sighting(frequency_hz=..., source_type=..., source_device=..., mode=..., ...)
```

Everything upstream of that call differs per device. Everything
downstream of it (schema, indexing, read path) is identical regardless
of which SDR produced the sighting. See `docs/occupancy-guide.md` for
the "Single-owner rule" that governs which SDR is even allowed to be
running a producer at a given moment (`scripts/sdr-mode.sh`).

---

## Shared endpoint: the occupancy DB write path

Before the per-device paths, the common tail all three share:

1. **`db/occupancy_db.py` — `OccupancyDB.record_sighting()`**
   - Computes `signal_key = make_signal_key(frequency_hz, mode)` —
     rounds `frequency_hz` to the nearest `FREQUENCY_BIN_HZ` (1000 Hz
     placeholder) and appends `:<mode>` (or `:unknown` if mode is
     `None`). This is the aggregation key, substituting for the
     durable per-emitter identity (MAC address) that WiFi/BT devices
     get for free but RF signals don't.
   - Opens a SQLite connection with `PRAGMA journal_mode=WAL`,
     `synchronous=NORMAL`, `busy_timeout=30000` — this is what lets
     the RX-888, HackRF, and RTL-SDR producers all write to the same
     `occupancy.db` concurrently without contending for a lock.
   - **Inserts** one row into `sightings` (the exact measured
     frequency, bandwidth if known, source_type/source_device,
     mode, timestamps, optional `metadata_json`).
   - **Upserts** the aggregate `signals` row for that `signal_key`:
     inserts a new row on first sighting (`total_sightings = 1`), or
     updates `last_seen_sec/ms` and increments `total_sightings` on
     every subsequent one.
   - Both writes happen inside the same `with self._connect() as conn:`
     block, committed together.
2. **`db/occupancy_schema.sql`** — defines the two tables
   (`signals` = aggregate/DEVICES-analog, `sightings` =
   per-event/PACKETS-analog) plus `schema_version`, applied
   idempotently (`CREATE TABLE IF NOT EXISTS`) every time
   `OccupancyDB.__init__()` runs — this is why no separate "init the
   DB" step exists; the first producer to start creates it.

Every device-specific section below ends by calling into this same
code path — the schema, the binning logic, and the WAL concurrency
model are identical no matter which SDR triggered the write.

---

## RX-888 (HF) — via `radiod` / ka9q-radio

**Status:** WORKING — continuous, calibrated, reboot-validated. The
first producer to actually close the loop, and the only one that runs
unattended by default.

### Ownership precondition

The RX-888 is a single-owner USB device. It must be in **AI mode**
(`radiod` holding it), not **interactive mode** (OpenWebRX+ holding
it), for any of this to produce data. `scripts/rx888-mode.sh ai`
(delegated to by `scripts/sdr-mode.sh rx888 ai`) enforces this: it
stops OpenWebRX+, polls until the RX-888's USB fd is actually released
(`wait_for_rx888_release`, up to 10s — a bare `sleep` was proven
insufficient by a real LIBUSB_ERROR_BUSY failure), starts
`radiod@rx888-hf.service`, and then starts
`radiod-occupancy.service` (the producer) automatically so the
operator doesn't have to remember a second command.

### Step by step

1. **Antenna → RX-888 MkII front end.** Wideband HF (0–30 MHz at the
   configured 64.8 MSPS; up to 6 m at 129.6 MSPS if uncommented)
   arrives at the RX-888's ADC over native USB3.

2. **`radiod` (ka9q-radio), unit `radiod@rx888-hf.service`, config
   `ingest/ka9q-radio/radiod@rx888-hf.conf`.**
   - Loads `SDDC_FX3.img` firmware onto the RX-888 at attach.
   - Digitizes the full band once, then simultaneously demodulates
     **~17 fixed channels** defined as `[section]` blocks in the
     config — WWV time-standard carriers (2.5/5/10/15 MHz AM), ham
     voice/CW segments (80m–10m), digital-mode segments (40m/20m FT8),
     a 2m-APRS placeholder, and one wideband raw-IQ tap
     (`[wideband-iq]`, not consumed by this producer).
   - Each demodulated channel is published as its own PCM audio
     multicast stream, named via mDNS (`data = <name>.local` in each
     section, e.g. `wwv-10000-pcm.local`), so downstream consumers
     subscribe by name rather than by parsing SSRCs.
   - `radiod` itself never writes to the occupancy DB — it only
     produces the multicast audio streams. All measurement happens in
     the producer below.

3. **`decode/radiod_occupancy_producer.py`, unit
   `radiod-occupancy.service` (installed by
   `scripts/phase6-occupancy-producer.sh`, a systemd `--user` service,
   enabled with `linger` so it survives logout).**
   - `parse_channels()` re-reads `radiod@rx888-hf.conf` directly (not
     radiod's runtime API — radiod's own status/metadata tools didn't
     yield parseable per-channel levels in testing) to get each
     channel's `freq_hz`, `mode`, and multicast stream name. IQ-mode
     channels are skipped (RMS-on-audio is meaningless for raw IQ).
   - Every `--interval` seconds (default 60s), for each channel:
     a. Shells out to **`pcmrecord --catmode <stream>`**, which
        streams that channel's WAV audio to stdout.
     b. Reads for `--window` seconds (default 2s) via a
        `select()`-bounded loop — this specifically prevents a
        channel radiod defines but that isn't actually flowing (e.g.
        `2m-aprs` with no APRS traffic) from hanging the whole sweep.
     c. Parses the raw bytes as 16-bit signed mono PCM
        (`_extract_pcm_s16`, tolerant of pcmrecord's streaming
        RIFF header with unknown size), computes RMS, converts to
        dBFS relative to 16-bit full scale (32768).
     d. Compares against `--threshold-dbfs` (default **-30.0**,
        calibrated against the demodulators' ~-33 dBFS residual
        floor — see `docs/occupancy-guide.md` Calibration section for
        the full method and the WWV/FT8/CW reference readings that
        set this number).
     e. If `dbfs >= threshold`, calls
        `db.record_sighting(frequency_hz=ch["freq_hz"], source_type="radiod", source_device="rx888-hf", mode=ch["mode"], metadata_json='{"channel":..., "power_dbfs":..., "threshold_dbfs":...}')`.
   - Loops forever (`Restart=on-failure`, `RestartSec=10` in the unit)
     until interrupted; `--once` exists for manual single-sweep runs.

4. **Result:** thousands of real sightings recorded continuously,
   `source_type='radiod'`, `source_device='rx888-hf'` — the only
   producer validated across a reboot.

**Programs/processes in this path:** `radiod` (ka9q-radio) →
`pcmrecord` (ka9q-radio CLI, invoked as a subprocess per channel per
sweep) → `radiod_occupancy_producer.py` → `occupancy_db.py` →
`occupancy.db`.

---

## HackRF (VHF/UHF, primary) — via `hackrf_transfer`

**Status:** WORKING — wired as a templated systemd service, operator
opt-in per device.

### Ownership precondition

HackRF is a single-owner USB device, independent of the RX-888's
ownership state. `scripts/sdr-mode.sh hackrf ai` enables and starts
its dedicated instance; `sdr-mode.sh hackrf interactive` disables and
stops it, freeing the device for OpenWebRX+'s waterfall. If
OpenWebRX+ is actively holding the HackRF when the producer starts,
`hackrf_transfer` fails to open it — the sweep records nothing for
that device that cycle (logged, not fatal); `sdr-mode.sh` prints a
warning covering this case.

### Step by step

1. **Antenna (Comet GP-1, resonant 2m/70cm) → HackRF One.**

2. **`decode/vhf_uhf_key_freq_producer.py --device hackrf`, unit
   `vhf-uhf-occupancy@hackrf.service`** (instantiated from the
   template `systemd/vhf-uhf-occupancy@.service`, `%i` = `hackrf`;
   installed by `scripts/phase6-vhf-uhf-producer.sh`; **not**
   auto-enabled at install — the operator opts in via `sdr-mode.sh`).
   - Unlike radiod (many channels demodulated at once from one wide
     capture), the HackRF is a single tuner — the producer **retunes**
     to each of a fixed `KEY_FREQUENCIES` list in turn (2m APRS
     144.39, several 2m simplex/calling channels, several 70cm
     channels — edit the list in the script for local repeaters).
   - Every `--interval` seconds (default 60s), for each frequency:
     a. Shells out to **`hackrf_transfer -r - -f <freq_hz> -s 2000000
        -n <samples> -l 40 -g 48`** (gain args from `DEVICE_CONFIG`),
        capturing `--dwell` seconds (default 1.0s) of interleaved
        **signed 8-bit** I/Q to stdout.
     b. Parses the raw bytes with Python's `array.array("b")`,
        computes RMS over I²+Q², converts to dBFS relative to the
        8-bit full scale (127).
     c. Compares against the per-device calibrated threshold
        (**-14.0 dBFS at LNA 40/VGA 48** — chosen because
        `hackrf_transfer`'s own power readout clamps near -30 dBFS
        below LNA ~40, so discrimination only appears at high gain;
        full derivation in `docs/occupancy-guide.md`).
     d. If active, calls `db.record_sighting(frequency_hz=freq_hz, source_type="hackrf", source_device="hackrf-one", mode=mode, metadata_json=...)`.
   - Loops forever (`Restart=on-failure`, `RestartSec=15`) until
     stopped via `sdr-mode.sh hackrf interactive`.

3. **Result:** sightings tagged `source_type='hackrf'`,
   `source_device='hackrf-one'`. Marked "primary" for VHF/UHF because
   it's the calibrated, resonant-antenna path.

**Programs/processes in this path:** `hackrf_transfer` (HackRF host
tools, invoked as a subprocess per frequency per sweep) →
`vhf_uhf_key_freq_producer.py --device hackrf` → `occupancy_db.py` →
`occupancy.db`.

---

## RTL-SDR (VHF/UHF, backup) — via `rtl_sdr`

**Status:** WORKING — wired as a templated systemd service, backup
role, operator opt-in per device.

### Ownership precondition

Same single-owner model as HackRF, tracked independently:
`scripts/sdr-mode.sh rtlsdr ai` / `rtlsdr interactive`.

### Step by step

1. **Broadband antenna → RTL-SDR dongle (R820T tuner).**

2. **`decode/vhf_uhf_key_freq_producer.py --device rtlsdr`, unit
   `vhf-uhf-occupancy@rtlsdr.service`** — the **same script** as the
   HackRF path (`decode/vhf_uhf_key_freq_producer.py`), just launched
   with a different `--device` argument by the same templated unit
   (`%i` = `rtlsdr`). One codebase, two independently
   enable/disable-able systemd instances.
   - Same `KEY_FREQUENCIES` list, same retune-and-dwell loop
     structure as HackRF.
   - Every `--interval` seconds (default 60s), for each frequency:
     a. Shells out to **`rtl_sdr -f <freq_hz> -s 2000000 -n <samples>
        -g 0 -`**, capturing `--dwell` seconds (default 1.0s) of
        interleaved **unsigned 8-bit** I/Q (centered at 127) to
        stdout. Gain `0` (minimum) is deliberate and
        counterintuitive: the R820T compresses at high gain, so this
        device discriminates *best* at minimum gain — the opposite of
        the HackRF.
     b. Parses with `array.array("B")` (unsigned), subtracts the
        127 offset from each I/Q sample before computing RMS, converts
        to dBFS relative to full scale (127).
     c. Compares against the per-device calibrated threshold
        (**-18.0 dBFS at gain 0** — validated over multiple sweeps: a
        consistent ~-25 dBFS floor across 2m/70cm, real transmissions
        standing ~20 dB above it. A *single* early sweep looked
        alarmingly busy; repeated sweeps revealed the true floor — see
        `docs/occupancy-guide.md`).
     d. If active, calls `db.record_sighting(frequency_hz=freq_hz, source_type="rtlsdr", source_device="rtl-sdr", mode=mode, metadata_json=...)`.
   - Loops forever (`Restart=on-failure`, `RestartSec=15`) until
     stopped via `sdr-mode.sh rtlsdr interactive`.

3. **Result:** sightings tagged `source_type='rtlsdr'`,
   `source_device='rtl-sdr'` — distinguished from the HackRF's rows by
   `source_device` even though both write through the identical
   producer script and the identical `signals`/`sightings` schema.

**Programs/processes in this path:** `rtl_sdr` (rtl-sdr host tools,
invoked as a subprocess per frequency per sweep) →
`vhf_uhf_key_freq_producer.py --device rtlsdr` → `occupancy_db.py` →
`occupancy.db`.

---

## Side-by-side summary

| Stage | RX-888 | HackRF | RTL-SDR |
|---|---|---|---|
| Front-end driver | `radiod` (ka9q-radio) | none (direct capture) | none (direct capture) |
| Config | `ingest/ka9q-radio/radiod@rx888-hf.conf` | `KEY_FREQUENCIES` list in producer script | same list, same script |
| Capture tool (subprocess) | `pcmrecord --catmode <stream>` | `hackrf_transfer` | `rtl_sdr` |
| Coverage per sweep | ~17 fixed HF channels, all at once (radiod demodulates in parallel) | 8 fixed VHF/UHF freqs, retuned serially | same 8 freqs, retuned serially |
| Sample format read | 16-bit signed PCM (post-demod audio) | 8-bit **signed** I/Q | 8-bit **unsigned** I/Q (offset 127) |
| Power metric | RMS → dBFS vs. 16-bit full scale (32768) | RMS(I²+Q²) → dBFS vs. 127 | RMS(I²+Q²) → dBFS vs. 127 |
| Calibrated threshold | -30.0 dBFS | -14.0 dBFS (LNA 40/VGA 48) | -18.0 dBFS (gain 0) |
| Producer script | `decode/radiod_occupancy_producer.py` | `decode/vhf_uhf_key_freq_producer.py --device hackrf` | `decode/vhf_uhf_key_freq_producer.py --device rtlsdr` |
| systemd unit | `radiod-occupancy.service` (fixed) | `vhf-uhf-occupancy@hackrf.service` (templated instance) | `vhf-uhf-occupancy@rtlsdr.service` (templated instance) |
| Default enablement | Auto-enabled at install, always on with the RX-888 in AI mode | Operator opt-in via `sdr-mode.sh hackrf ai` | Operator opt-in via `sdr-mode.sh rtlsdr ai` |
| Ownership switch | `scripts/rx888-mode.sh` (delegated from `sdr-mode.sh rx888`) | `scripts/sdr-mode.sh hackrf {ai\|interactive}` | `scripts/sdr-mode.sh rtlsdr {ai\|interactive}` |
| `source_type` recorded | `radiod` | `hackrf` | `rtlsdr` |
| `source_device` recorded | `rx888-hf` | `hackrf-one` | `rtl-sdr` |
| Write path | `occupancy_db.py` → `record_sighting()` → `signals`/`sightings` in `db/occupancy.db` (identical for all three) | same | same |

## Superseded / not-in-this-path

- `decode/gnuradio-flowgraphs/hackrf_occupancy_monitor.py` and
  `rtlsdr_occupancy_monitor.py` — older single-frequency GNU Radio
  monitors for these same two devices. Superseded by
  `vhf_uhf_key_freq_producer.py` above; never hardware-validated, not
  part of any currently running path.
- OpenWebRX+ → MQTT: discussed as a fourth possible producer (any SDR,
  while OpenWebRX+ holds it) but not built — would need a Mosquitto
  broker as an intermediate hop. Not part of any device's current path.

## See also

- `docs/occupancy-guide.md` — the concept, the schema design
  rationale, and the full calibration methodology (why these specific
  threshold numbers, and how to re-derive them at a different site).
- `docs/build-order.md` Phase 6.6 — the build-log record of these
  decisions in the order they were made.
- `docs/db-to-ai-query-path.md` — what happens *after* the DB is
  populated (how the AI layer queries it).
- `db/occupancy_schema.sql`, `db/occupancy_db.py` — the shared schema
  and access layer referenced throughout this document.
