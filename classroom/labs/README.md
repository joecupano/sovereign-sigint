# Labs — STATUS: revalidated against the current build

> These 13 lab decks (lab00–lab12) and their source generators
> (`src/sessions-*.js`, `src/narrative-*.js`) have been checked lab-by-lab
> against the current build. Labs **00–10 were already accurate** (they cover
> phases — hardware, OS, Ollama, Open WebUI, ingest, ka9q/RX-888, decode, SigID
> mirror, OpenWebRX+, SigMF — that later work didn't change). Labs **11 and 12
> were updated** to match current ground truth (see below). The scope note has
> also been updated now that the Phase 7 Kismet→AI integration exists.
>
> The maintained, current-state overview material remains the **article +
> deck** in `../article/`. These labs are the session-by-session curriculum
> and are now consistent with it.

## What was revalidated (full pass)

**Labs 00–10 — accurate, unchanged.** Each was checked; none teaches anything
that later work invalidated. (lab08's SigID mirror is if anything *more* true
now — its reference catalog is queryable live via a native tool, covered in
lab12 and the vision guide.)

**lab11 (Occupancy Database) — updated.** Previously taught the GNU Radio
HackRF/RTL-SDR monitors as the producers to "run and confirm sightings." Those
were never hardware-validated. Now reflects the two real producers that
populate the DB: **radiod** (continuous HF, the first to fill it) and the
**device-flexible key-frequency producer** driving the **HackRF** (primary) or
**RTL-SDR** (backup) for VHF/UHF, wired as a per-device templated systemd
service (`vhf-uhf-occupancy@<device>`) that the operator toggles via
`scripts/sdr-mode.sh <device> {ai|interactive}`. Adds the real calibration lessons
(the opposite gain quirks between the two SDRs; multi-sweep diligence; antenna
fixed in hardware not code), the WAL/busy_timeout concurrency that lets
producers write simultaneously, and the final step that closes the loop —
querying the DB from the local LLM via the occupancy native tool.

**lab12 (Use Cases) — updated.** Previously described the DB→AI path as
intended-but-not-wired and listed only occupancy. Now reflects reality: the
**capture→DB→AI loop is closed** via native in-process tools, and there are
**three live AI sources** — occupancy (what's active), Kismet (what WiFi
devices), and the SigID reference catalog (what a signal is). The
signal-identification use case is now the real end-to-end workflow (vision
model for shape + SigID tool + measured frequency, triangulated). Ubertooth /
Evil Crow remain correctly described as future hardware not yet wired into the
AI layer.

**Scope note — updated.** The course still centers on applying AI to SIGINT.
Phase 7 (Kismet/WiFi) was once excluded on the grounds that "a Kismet→AI lab
only becomes appropriate once that integration exists." That integration now
exists (the Kismet native tool), so lab12 references it as a working AI source.
A dedicated Kismet/Ubertooth hands-on lab remains a reasonable future addition.

## Rebuilding the decks

The lab decks are generated from the `src/` sources:

```
cd src
npm install      # first time only
node build-all.js
```

Output PPTX files land in `src/output/`; the committed decks in `decks/` are
the rendered results. After editing any `sessions-*.js` / `narrative-*.js`,
re-run `build-all.js` and copy the regenerated decks over.
