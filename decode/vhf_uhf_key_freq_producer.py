#!/usr/bin/env python3
"""
vhf_uhf_key_freq_producer.py — VHF/UHF fixed-frequency occupancy producer.

Supports two devices via --device: the HackRF (primary, Comet GP-1 antenna)
and the RTL-SDR (backup, broadband antenna). Same key-frequency occupancy
design for both; the capture tool and 8-bit sample format differ (hackrf_
transfer = signed int8; rtl_sdr = unsigned uint8 centered at 127).

Monitors a fixed LIST of key VHF/UHF frequencies (APRS, simplex calling
channels, local repeaters, a couple of 70cm/ISM spots) and records occupancy
when a channel is active. This is the VHF/UHF complement to the RX-888/radiod
HF producer: radiod covers HF wideband; the HackRF (with a resonant 2m/70cm
antenna, e.g. a Comet GP-1) covers specific VHF/UHF channels radiod can't
reach.

DESIGN (mirrors the proven radiod producer, single-tuner style):
  radiod publishes many pre-demodulated channels at once; the HackRF is a
  single tuner, so instead we RETUNE to each frequency in the list, capture a
  short IQ window, compute power, and record a sighting if it's above a
  calibrated threshold. Same OccupancyDB.record_sighting() path as every other
  producer. "Key frequencies only" (not a wideband sweep) was a deliberate
  choice: it's robust, simple, and matches what the antenna is cut for.

  Interface: shells out to `hackrf_transfer` (like radiod's producer shells
  out to pcmrecord), capturing N samples of interleaved signed 8-bit I/Q to
  stdout, then computes RMS power -> dBFS-relative. No Python SoapySDR binding
  is required (none installed on the reference box).

MEASUREMENT NOTE (honest):
  hackrf_transfer int8 I/Q gives a power figure relative to the HackRF's own
  8-bit full scale, NOT an absolute calibrated dBm. That is fine for
  OCCUPANCY (is this channel active vs. the noise floor?) — exactly like the
  radiod producer's dBFS. It is NOT a calibrated field-strength measurement.
  The threshold must be calibrated per antenna/gain against the observed
  noise floor (see radiod's calibration lesson in docs/occupancy-guide.md).

SINGLE-OWNER NOTE:
  The HackRF is a single-owner USB device. If OpenWebRX+ (or anything else)
  holds it, hackrf_transfer will fail to open it and the sweep records
  nothing for that cycle (reported, not fatal). See scripts/sdr-mode.sh.

USAGE:
  python3 hackrf_key_freq_producer.py [--once] [--interval SEC]
      [--dwell SEC] [--threshold-dbfs DBFS] [--lna-gain N] [--vga-gain N]
      [--verbose]
"""
from __future__ import annotations

import argparse
import math
import subprocess
import sys
import time
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_REPO_ROOT / "db"))
from occupancy_db import OccupancyDB  # noqa: E402

DEFAULT_DB = _REPO_ROOT / "db" / "occupancy.db"

# The key frequencies to monitor. (freq_hz, label, mode). Edit this list to
# add/remove channels — e.g. your actual local repeater outputs. Modes are
# labels for the occupancy record, not demodulation (we measure power only).
KEY_FREQUENCIES = [
    (144_390_000, "2m-aprs", "fm"),
    (144_900_000, "2m-144900", "fm"),
    (145_100_000, "2m-145100", "fm"),
    (145_500_000, "2m-simplex-145500", "fm"),
    (146_520_000, "2m-calling-146520", "fm"),
    (433_450_000, "70cm-433450", "fm"),
    (438_500_000, "70cm-438500", "fm"),
    (446_000_000, "70cm-calling-446000", "fm"),
]

SAMPLE_RATE = 2_000_000        # 2 Msps is plenty for a power reading
DEFAULT_DWELL_SEC = 1.0        # seconds of IQ per frequency
DEFAULT_INTERVAL_SEC = 60.0
FULL_SCALE = 127.0             # 8-bit full scale (both devices are 8-bit)

# Per-device configuration. Each device differs in: the capture command, the
# 8-bit sample encoding (hackrf = signed, rtl_sdr = unsigned/offset-127), the
# source_device label recorded in the DB, and — importantly — the calibrated
# gain and threshold, since each device+antenna has its own noise floor.
#
# HackRF (primary): calibrated 2026-07 at LNA 40/VGA 48 with the Comet GP-1.
#   The hackrf_transfer power readout CLAMPS ~-30 dBFS below ~LNA 40; at 40/48
#   signals separate — quiet 70cm/dead-ref floor ~-20.5, 2m ambient ~-18,
#   genuine activity well above (146.52 mid-Tx -5.6, strong FM -11.8). -14 dBFS
#   sits in the gap (only ~4dB above 2m ambient — only CLEARLY active channels
#   register, correct for occupancy).
#
# RTL-SDR (backup): NOT yet field-calibrated. Uses rtl_sdr with auto gain (0)
#   and a placeholder threshold; the broadband backup antenna and the RTL-SDR's
#   own floor differ from the HackRF, so a --verbose calibration run is needed
#   before its readings are trustworthy (same procedure as the HackRF: find the
#   gap between a dead-reference floor and real activity). Marked clearly so its
#   data isn't mistaken for calibrated.
DEVICE_CONFIG = {
    "hackrf": {
        "source_type": "hackrf",
        "source_device": "hackrf-one",
        "encoding": "signed",       # hackrf_transfer int8
        "gain_args": ["-l", "40", "-g", "48"],
        "threshold_dbfs": -14.0,
        "calibrated": True,
    },
    "rtlsdr": {
        "source_type": "rtlsdr",
        "source_device": "rtl-sdr",
        "encoding": "unsigned",     # rtl_sdr uint8, centered 127
        # Calibrated 2026-07 with the broadband backup antenna. COUNTERINTUITIVE
        # but measured: the RTL-SDR discriminates BEST at MINIMUM gain (-g 0).
        # At g0: strong FM -4.2, quiet 146.52 -25.6 -> ~21 dB gap. At high gain
        # (g40) the R820T compresses everything down (FM -22.8, floor ~-39) with
        # a smaller usable spread. So g0 is the operating point.
        "gain_args": ["-g", "0"],
        # -18 dBFS sits in the g0 gap: ~7 dB above the quiet floor and well
        # below real activity. Validated over multiple sweeps: the floor is a
        # consistent ~-25 dBFS across both 2m and 70cm; real transmissions stand
        # ~20 dB above it (an isolated 145.100 key-up read -4.7 while all other
        # channels stayed at the -25 floor). Quiet reads quiet, real signals
        # register.
        "threshold_dbfs": -18.0,
        "calibrated": True,
    },
}


def measure_freq_dbfs(freq_hz: int, dwell_sec: float, device: str,
                      gain_args: list, verbose: bool) -> float | None:
    """Capture a short IQ window at freq from the given device and return RMS
    power in dBFS relative to 8-bit full scale, or None if capture failed.

    Handles both capture tools and their different sample encodings:
      - hackrf: `hackrf_transfer -r -` → interleaved SIGNED int8 I/Q
      - rtlsdr: `rtl_sdr -` → interleaved UNSIGNED uint8 I/Q (centered 127)
    """
    n_samples = int(SAMPLE_RATE * dwell_sec)
    if device == "hackrf":
        cmd = (["hackrf_transfer", "-r", "-", "-f", str(freq_hz),
                "-s", str(SAMPLE_RATE), "-n", str(n_samples)] + gain_args)
        tool = "hackrf_transfer"
    elif device == "rtlsdr":
        # rtl_sdr -f freq -s rate -n num_samples - (stdout). Gain via gain_args.
        cmd = (["rtl_sdr", "-f", str(freq_hz), "-s", str(SAMPLE_RATE),
                "-n", str(n_samples)] + gain_args + ["-"])
        tool = "rtl_sdr"
    else:
        print(f"ERROR: unknown device '{device}'", file=sys.stderr)
        return None

    try:
        proc = subprocess.run(cmd, capture_output=True,
                              timeout=dwell_sec + 8, check=False)
    except FileNotFoundError:
        print(f"ERROR: {tool} not found on PATH.", file=sys.stderr)
        return None
    except subprocess.TimeoutExpired:
        if verbose:
            print(f"    {freq_hz/1e6:.4f} MHz: capture timed out")
        return None

    raw = proc.stdout
    if len(raw) < 256:
        if verbose:
            err = (proc.stderr or b"").decode("utf-8", "ignore").strip().split("\n")[-1:]
            msg = err[0] if err else "no data"
            print(f"    {freq_hz/1e6:.4f} MHz: no/short data ({len(raw)}B) — {msg}")
        return None

    import array
    n = (len(raw) // 2) * 2
    if device == "hackrf":
        samples = array.array("b")           # signed int8
        samples.frombytes(raw[:n])
        offset = 0.0
    else:  # rtlsdr — unsigned uint8 centered at 127
        samples = array.array("B")           # unsigned uint8
        samples.frombytes(raw[:n])
        offset = 127.0

    npairs = len(samples) // 2
    if npairs == 0:
        return None
    sumsq = 0.0
    for k in range(npairs):
        i = float(samples[2 * k]) - offset
        q = float(samples[2 * k + 1]) - offset
        sumsq += i * i + q * q
    rms = math.sqrt(sumsq / npairs)
    if rms <= 0:
        return -math.inf
    return 20.0 * math.log10(rms / FULL_SCALE)


def run_once(db: OccupancyDB, dwell: float, threshold: float, device: str,
             gain_args: list, source_type: str, source_device: str,
             verbose: bool) -> int:
    active = 0
    for freq_hz, label, mode in KEY_FREQUENCIES:
        dbfs = measure_freq_dbfs(freq_hz, dwell, device, gain_args, verbose)
        if dbfs is None:
            continue
        state = "ACTIVE" if dbfs >= threshold else "quiet"
        if verbose:
            fs = f"{dbfs:6.1f}" if dbfs != -math.inf else "  -inf"
            print(f"    {label:22} {freq_hz/1e6:8.4f} MHz {mode:3} {fs} dBFS  {state}")
        if dbfs >= threshold:
            active += 1
            db.record_sighting(
                frequency_hz=float(freq_hz),
                source_type=source_type,
                source_device=source_device,
                mode=mode,
                metadata_json=('{"channel":"%s","power_dbfs":%.1f,"threshold_dbfs":%.1f}'
                               % (label, dbfs, threshold)),
            )
    return active


def main() -> int:
    ap = argparse.ArgumentParser(description="VHF/UHF key-frequency occupancy producer")
    ap.add_argument("--device", choices=["hackrf", "rtlsdr"], default="hackrf",
                    help="SDR to use: hackrf (primary, calibrated) or rtlsdr "
                         "(backup, NOT yet calibrated). Default hackrf.")
    ap.add_argument("--once", action="store_true", help="single sweep then exit")
    ap.add_argument("--interval", type=float, default=DEFAULT_INTERVAL_SEC)
    ap.add_argument("--dwell", type=float, default=DEFAULT_DWELL_SEC,
                    help=f"seconds of IQ per frequency (default {DEFAULT_DWELL_SEC})")
    ap.add_argument("--threshold-dbfs", type=float, default=None,
                    help="override the per-device calibrated threshold")
    ap.add_argument("--gain-args", type=str, default=None,
                    help="override device gain args, space-separated "
                         "(e.g. '-l 40 -g 48' for hackrf, '-g 0' for rtlsdr)")
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    cfg = DEVICE_CONFIG[args.device]
    threshold = args.threshold_dbfs if args.threshold_dbfs is not None else cfg["threshold_dbfs"]
    gain_args = args.gain_args.split() if args.gain_args else cfg["gain_args"]
    source_type = cfg["source_type"]
    source_device = cfg["source_device"]

    if not cfg["calibrated"]:
        print(f"WARNING: device '{args.device}' is NOT field-calibrated — its "
              f"threshold ({threshold} dBFS) and gain are placeholders. Do a "
              f"--verbose calibration run and set a real threshold before "
              f"trusting its ACTIVE/quiet calls. (See the HackRF calibration "
              f"basis in DEVICE_CONFIG.)")

    db = OccupancyDB(args.db)
    print(f"VHF/UHF key-freq producer [{args.device}]: {len(KEY_FREQUENCIES)} "
          f"channels, threshold {threshold} dBFS, dwell {args.dwell}s, "
          f"gain {' '.join(gain_args)}"
          + ("" if args.once else f", every {args.interval}s"))

    try:
        while True:
            t0 = time.time()
            if args.verbose:
                print(f"-- sweep @ {time.strftime('%H:%M:%S')} --")
            active = run_once(db, args.dwell, threshold, args.device,
                              gain_args, source_type, source_device, args.verbose)
            print(f"sweep complete: {active}/{len(KEY_FREQUENCIES)} channels active")
            if args.once:
                break
            time.sleep(max(0.0, args.interval - (time.time() - t0)))
    except KeyboardInterrupt:
        print("\nstopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
