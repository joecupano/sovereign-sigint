# OpenWebRX+ SDR Device Quickstart

Default profile sets for the three SDR device types in this build:
HackRF (VHF/UHF/well-known services to 6GHz), RTL-SDR (its native tuner
range), and RX-888 (HF). See `docs/build-order.md` Phase 6.4 for the
install itself — this doc is device/profile configuration only.

## Before you start

> **IMPORTANT — using an SDR in OpenWebRX+ takes it AWAY from AI/occupancy
> capture.** Every SDR is a single-owner USB device: exactly one process
> can hold it at a time. Any SDR you enable in OpenWebRX+ is, for as long
> as OpenWebRX+ holds it, **unavailable** to the AI/occupancy pipeline —
> and vice versa. If OpenWebRX+ is configured to use ALL of your SDRs,
> then the occupancy pipeline has **no devices left** and captures
> nothing. Different SDRs can do different jobs at the same time (e.g.
> RX-888 → radiod for HF occupancy *while* HackRF → OpenWebRX+ for a VHF
> waterfall), but no single SDR can serve both at once. Use
> `scripts/sdr-mode.sh status` to see which owner currently holds each
> SDR, and `scripts/rx888-mode.sh` to switch the RX-888 between the two
> roles. See `docs/occupancy-guide.md` for the occupancy side of this.

- OpenWebRX+ installed and running (`scripts/phase6-openwebrx.sh`)
- Admin account created (`sudo openwebrx admin adduser <username>`)
- **Check the Feature Report first:** `http://<host>:8073/features` —
  confirms what's actually enabled on your install before you configure
  a profile that depends on a decoder that isn't there. RX-888 support
  via `soapy_sddc` is now built and enabled (see the RX-888 section
  below for the build step and confirmed working config); `sddc` and
  `sddc_connector` remain NO — those are a different, GPU-capable path
  not built in this project (see below).

## Adding a device

1. Web UI → **Settings → SDR devices → Add new device**
2. Pick the device type (HackRF, RTL-SDR, or SDDC for RX-888)
3. Add one or more **profiles** under that device — each profile is a
   center frequency + demodulator mode + sample rate combination you
   can switch to live from the receiver panel
4. **Gain lives in the profile, not the live receiver panel** —
   confirmed the hard way during this build. The live "Gain" control in
   the sidebar didn't hold; the actual setting that stuck was under
   **Settings → SDR devices → [device] → [profile] → RF gain**. If
   signals look present but indistinguishable/muddy on the waterfall,
   check here before assuming an antenna or hardware problem.

## HackRF — VHF, UHF, and well-known services to 6GHz

Confirmed via Feature Report: `hackrf` → YES, `soapy_hackrf` → YES.
HackRF covers roughly 1 MHz–6 GHz, so it's the device for everything
outside RX-888's HF territory. Default sample rate **10 MS/s**, gain
**auto** as a starting point — override per-profile if a signal is
weak/clipped.

| Profile | Center freq | Mode | Notes |
|---|---|---|---|
| 6m Amateur | 52.000 MHz | USB | 50–54 MHz |
| 2m Amateur | 146.000 MHz | NFM | 144–148 MHz |
| 2m APRS/Packet | 144.390 MHz | NFM + **Packet** digital mode | Needs `direwolf` + `aprs_symbols` both enabled — see Troubleshooting |
| NOAA Weather Radio | 162.475 MHz | NFM | 162.400–162.550 MHz, 7 channels |
| Airband (VHF AM) | 127.500 MHz | AM | 118–137 MHz, civil aviation |
| 70cm Amateur | 435.000 MHz | NFM | 420–450 MHz |
| GMRS/FRS | 465.000 MHz | NFM | 462.550–467.725 MHz |
| ADS-B | 1090.000 MHz | Raw/ADS-B mode if available | Airplane transponders |
| ISM 433 | 433.920 MHz | Raw (waterfall/manual analysis) | See RTL-SDR section for the `rtl_433` decoder path — not confirmed working via a Soapy/HackRF source |
| ISM 915 / LoRa | 915.000 MHz | **LoRa**, bandwidth `125000` | Confirmed working config from this build — see `docs/build-order.md` LoRa notes. Sample rate ≥2 MS/s |
| GPS L1 (awareness) | 1575.420 MHz | Raw | Spectrum reference only — decoding needs an active LNA antenna, not practical off a whip |
| 2.4GHz ISM/WiFi (awareness) | 2440.000 MHz | Raw, wide sample rate | Spectrum view only, no demod target |

## RTL-SDR — native tuner range

Confirmed via Feature Report: `rtl_sdr` → YES, `rtl_connector` → YES,
`soapy_rtl_sdr` → YES (adds direct-sampling support if ever needed).
R820T/R828D tuners cover roughly **24 MHz–1766 MHz**, with a known gap
around 1100–1250 MHz — don't expect coverage there. Default sample
rate **2.4 MS/s** (stock RTL-SDR ceiling for clean capture).

| Profile | Center freq | Mode | Notes |
|---|---|---|---|
| FM Broadcast | 98.000 MHz | WFM | 88–108 MHz |
| Airband (VHF AM) | 127.500 MHz | AM | 118–137 MHz |
| 2m Amateur | 146.000 MHz | NFM | 144–148 MHz |
| NOAA Weather Radio | 162.475 MHz | NFM | 162.400–162.550 MHz |
| 70cm Amateur | 435.000 MHz | NFM | 420–450 MHz |
| ADS-B | 1090.000 MHz | Raw/ADS-B (`dump1090`, confirmed YES) | Classic RTL-SDR use case |
| ISM 433 | 433.920 MHz | Raw + **ISM** digital mode (`rtl_433`, confirmed YES) | Sensors, remotes, weather stations |
| Pagers (FLEX/POCSAG) | 929.000–932.000 MHz | Raw + **Page** digital mode (`multimon-ng`, confirmed YES) | Set profile range wide enough to sweep the paging band |

**Gain — same gotcha as HackRF, confirmed directly during this build:**
`auto` gain in the live receiver panel produced a faint, indistinguishable
waterfall at 438.8 MHz — fix was setting RF gain explicitly under
**Settings → SDR devices → [RTL-SDR] → [profile] → RF gain**, not
anything in the live UI. Try a lower manual value (start ~15–20) if
auto isn't cutting it.

**`[R82XX] PLL not locked!` in the logs — often benign.** Seen
repeatedly on this hardware across sessions and frequencies; Phase 1
validation captured clean data despite the warning, and live reception
worked once gain was corrected. Worth monitoring if it's *constant*
across every frequency (possible marginal USB power/cable), but a
one-off log line isn't itself a failure signal.

## RX-888 — HF spectrum

**Built and confirmed working via a from-source SoapySDDC module** (the
CPU-only path — no NVIDIA GPU needed, since the RTX is reserved for
Ollama/vision):

```
sudo ./scripts/phase6-openwebrx-rx888.sh
```

This builds libsddc + SoapySDDC from source, installs the module into
SoapySDR's active module directory, installs a udev rule, and prints the
exact UI steps. See that script's header/NEXT STEPS for the fullest
detail — confirmed accurate against a real setup, including all of the
following gotchas:

**Device-type label (confirmed exact wording) — it is NOT a generic
"SoapySDR device" entry.** In Settings → SDR devices → Add device, pick:
```
BBRF103 / RX666 / RX888 / RX888 mkII (SDDC) device (via SoapySDR)
```

**Sample rate is a FIXED discrete list, not free-entry MSPS — confirmed
via the UI's own rejection message.** Allowed values: 2, 4, 8, 16, 32, 64
(millions of samples/sec). **64.8 MS/s (radiod's exact native rate) is
REJECTED here** — the earlier assumption in this doc that "64.8 MS/s
covers 0–30 MHz cleanly" for this UI was wrong; use one of the six fixed
values instead.

**Confirmed working config on this hardware (Xeon W-2145, this exact USB
topology) — start here rather than the max 64 MSPS:**
- 64 MSPS pegged `soapy_connector` + `openwebrx` near/above 180% combined
  CPU and caused audible audio stutter (confirmed via `top`).
- **32 MSPS** eliminated the stutter.
- Default FFT size (4096) at 32 MSPS gives ~7.8 kHz/bin — too coarse;
  narrowband signals show as a wide blur rather than a thin trace.
- Raising the **primary "FFT size"** (a GLOBAL setting under general
  Settings, affects all receivers, not per-device) from 4096 to **16384**
  (~1.95 kHz/bin at 32 MSPS) fixed resolution with no stutter returning.
  Leave the secondary/audio FFT size field alone — different, smaller
  display.
- **Net recommended profile: center ~15,000,000 Hz, 32 MSPS, FFT size
  16384.** A low center (e.g. 3.5 MHz) with a wide sample rate pushes
  much of the displayed span below 0 Hz and looks like a broken/confusing
  waterfall — a tuning choice, not a bug. 64 MSPS remains available for
  occasional wide-view sessions if you can tolerate the CPU cost.

**CRITICAL — a newly added/edited profile will NOT appear in the main
receiver page's selector until you restart the service, confirmed via a
real run:**
```
sudo systemctl restart openwebrx
```
The device/profile IS correctly saved to `/var/lib/openwebrx/settings.json`
immediately (verify: `sudo python3 -m json.tool
/var/lib/openwebrx/settings.json | grep -A10 sddc` if in doubt) — it's the
running process's in-memory receiver list that's stale, not a save
failure. Without this restart it looks exactly like the profile silently
vanished or never saved; it didn't — just restart and it appears.

**This is a SECOND RX-888 driver stack** alongside radiod's. They can't
both hold the single-owner device — use `scripts/rx888-mode.sh` to
switch (see "RX-888 dual use" below). Given radiod already demonstrates
the RX-888's real advantage (18 simultaneous channels), this OpenWebRX+
path is for the interactive full-HF *waterfall* specifically — the
"sit and explore" view the RX-888 was originally bought for.

**Hard prerequisite before any of this: the RX-888 must be able to
stream over USB3 (5000M).** Important nuance learned the hard way,
though (see `docs/build-order.md` Phase 6.1 for the full story): a fresh
RX-888 sits in FX3 DFU/bootloader mode and enumerates at USB2 (480M)
**by design** — it only jumps to USB3 *after* firmware is uploaded. So a
480M reading in `lsusb -t` on an unconfigured device is NOT proof of a
USB3 fault; don't chase it as one (this build wasted a long detour doing
exactly that). Confirm the device is present as `04b4:00f3 ... DFU mode`,
let the firmware upload happen (Phase 1 validation does this, or
radiod's own startup — confirmed: `found rx888 ... device 00f1 ...
USB speed: Super (5 Gb/s), selected`), and check the speed *after*. If it
still won't do USB3 post-firmware, only then is it a genuine
host/port/cable issue.

The `sddc`/`sddc_connector` path (a different, GPU/CUDA-capable
alternative) remains **NO** in the Feature Report — not built in this
project; `soapy_sddc` (CPU-only, above) is the one that's live.

These profiles reuse the same frequencies as
`ingest/ka9q-radio/radiod@rx888-hf.conf` for consistency across the
build:

| Profile | Center freq | Mode | Notes |
|---|---|---|---|
| WWV 5 MHz | 5.000 MHz | AM | Propagation/time-standard beacon (US) |
| WWV 10 MHz | 10.000 MHz | AM | Same. (Canada's CHU shut down 22 Jun 2026; use WWV or a regional equivalent.) |
| 80m Amateur | 3.900 MHz | LSB | |
| 40m Amateur | 7.200 MHz | LSB | |
| 40m CW | 7.030 MHz | CW | |
| 20m Amateur | 14.300 MHz | USB | |
| 20m FT8 | 14.074 MHz | USB (digital decode via WSJT-X modes) | |
| 17m Amateur | 18.130 MHz | USB | |
| 15m Amateur | 21.300 MHz | USB | |
| 10m Amateur | 28.400 MHz | USB | |

## RX-888 dual use: OpenWebRX+ vs the AI pipeline (radiod)

The RX-888 is a single USB device — exactly one process can hold it open
at a time. Two very different consumers both want it:

- **radiod** (Phase 6.1) — opens the RX-888 once, does the wideband work
  once, and multicasts wideband + demodulated streams that the
  AI/occupancy consumers subscribe to **continuously**. This is the
  "always watching" default for a sovereign-SIGINT box: complete,
  gapless, all-HF-bands-at-once coverage feeding the AI.
- **OpenWebRX+** — wants the RX-888 directly for its interactive,
  tunable 0-30 MHz HF waterfall (a hands-on, one-human-at-a-time view).

They **cannot both own the device.** There is also no clean native path
for OpenWebRX+ to consume radiod's streams: radiod emits demodulated PCM
(and a raw-IQ stream in a format OpenWebRX+ has no input driver for), so
"OpenWebRX+ reads radiod" would require an awkward ALSA-loopback hack
that only exposes radiod's fixed channels and defeats OpenWebRX+'s
tunable-waterfall purpose. Don't go there.

Instead, **time-share the hardware** with an explicit single-owner
switch, `scripts/rx888-mode.sh`, which enforces the "only one owner"
rule so you never hit a device-busy collision:

```
sudo ./scripts/rx888-mode.sh ai            # radiod owns it (AI default)
sudo ./scripts/rx888-mode.sh interactive   # OpenWebRX+ owns it (hands-on)
./scripts/rx888-mode.sh status             # who currently owns it
```

`ai` mode stops OpenWebRX+ (releasing the device), then starts radiod.
`interactive` mode stops radiod (AI HF occupancy pauses), then starts
OpenWebRX+ so you can drive the waterfall. When done exploring, switch
back to `ai`. OpenWebRX+ can still run for HackRF/RTL-SDR (VHF/UHF) even
in `ai` mode — just keep its RX-888 profile disabled so it doesn't grab
the device out from under radiod.

**Which axis actually needs the RX-888?** For a *single narrow channel*,
RTL-SDR/HackRF/RX-888 are peers to the AI — one 12 kHz PCM stream is the
same regardless of source. The RX-888's non-peer advantage is
*simultaneous breadth*: only it (via radiod) can feed the AI **every HF
band at once, continuously**, with no sweeping blind spots — which is
exactly what pattern-over-time occupancy reasoning wants. So the RX-888
matters *more* for the AI mission than for the OpenWebRX+ waterfall it
was originally bought for.

## Troubleshooting — issues actually hit during this build

**Packet/APRS mode missing from the DIG selector, `direwolf` shows YES
in Feature Report.** Real root cause confirmed via the Feature Report:
`packet` requires **both** `direwolf` and `aprs_symbols`. The latter
isn't in the `luarvique` PPA at all — install it directly:
```
sudo git clone https://github.com/hessu/aprs-symbols /usr/share/aprs-symbols
sudo systemctl restart openwebrx
```

**Waterfall shows faint/muddy signals, nothing distinguishable.**
Check RF gain in the profile settings first (see the Gain notes above)
before assuming an antenna, frequency, or hardware problem — this was
the actual cause both times it came up in this build.

**Admin password reset fails with a `KeyError`.** Almost certainly a
stray character appended to the username by a shell/paste artifact
(`admin~` instead of `admin`) — re-run the exact command, double-check
for trailing characters.

**A feature shows unavailable and you don't know why.** Check
`http://<host>:8073/features` directly — it states the specific
missing dependency per feature, rather than guessing from service logs.

## See also

- `docs/build-order.md` Phase 6.4 — install, native-vs-containerized
  rationale, why SDR device config is deliberately not scripted
- `ingest/ka9q-radio/radiod@rx888-hf.conf` — the canonical HF band
  plan this doc's RX-888 profiles are copied from
