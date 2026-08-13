#!/usr/bin/env python3
"""
radiod_occupancy_producer.py — RX-888 / radiod occupancy producer.

This is the first producer to actually complete the capture -> occupancy DB
loop for the RX-888. radiod continuously demodulates a fixed set of HF
channels defined in the radiod config (e.g. WWV time standard, ham bands in
several modes, FT8, APRS) and publishes each as a PCM audio multicast stream.
This producer measures how much signal is present on each channel and records
an occupancy sighting when a channel is active. (The exact channel list is
site-configurable; pick beacons/bands receivable at YOUR location. Note:
Canada's CHU shortwave time station shut down 22 Jun 2026 — don't configure it
as a channel expecting signal.)

WHY THIS DESIGN (honest):
  radiod does NOT (in this build's config) publish a resolvable wideband IQ
  stream, and its status-metadata tools (powers/metadump) did not yield
  parseable per-channel levels in testing. The interface that IS proven to
  work is `pcmrecord`, which streams a channel's demodulated audio as WAV.
  So this producer measures per-channel audio power via pcmrecord rather
  than reading a wideband spectrum. That means it reports occupancy for the
  ~18 KNOWN channels radiod demodulates, each with a correct frequency and
  mode — not a full-HF spectral sweep. That is still far more than the
  single-frequency manual RTL-SDR/HackRF monitors, and it is real, running,
  continuous occupancy feeding the AI's database.

  If a wideband spectral producer is wanted later, radiod must first be
  reconfigured to publish its IQ stream (uncomment the [rx888] data= line),
  and a `powers`-based producer built against that SSRC. That is a separate
  effort; this producer uses only interfaces confirmed working.

HOW IT WORKS:
  For each channel parsed from radiod's config:
    1. Run `pcmrecord --catmode <data-stream>` for a short window, capturing
       WAV audio to memory.
    2. Compute RMS power of the samples, expressed in dBFS.
    3. If power >= threshold, the channel is "occupied" -> record a sighting
       at that channel's known frequency/mode via OccupancyDB.record_sighting.
  Repeat every --interval seconds.

USAGE:
  python3 radiod_occupancy_producer.py [--once] [--interval SEC]
      [--window SEC] [--threshold-dbfs DBFS] [--config PATH] [--verbose]

SINGLE-OWNER NOTE:
  The RX-888 must be owned by radiod (AI mode) for this to work. If
  OpenWebRX+ holds the RX-888, radiod is not running and this producer has
  nothing to read. See scripts/sdr-mode.sh / scripts/rx888-mode.sh.
"""
from __future__ import annotations

import argparse
import io
import math
import os
import re
import select
import struct
import subprocess
import sys
import time
import wave
from pathlib import Path

# Import the shared occupancy DB layer (same one every producer uses).
# This file lives at decode/radiod_occupancy_producer.py, so the repo root
# is parents[1] (decode/ -> repo root).
_REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_REPO_ROOT / "db"))
from occupancy_db import OccupancyDB  # noqa: E402

DEFAULT_CONFIG = _REPO_ROOT / "ingest" / "ka9q-radio" / "radiod@rx888-hf.conf"
DEFAULT_DB = _REPO_ROOT / "db" / "occupancy.db"

# Source identity recorded with each sighting.
SOURCE_TYPE = "radiod"
SOURCE_DEVICE = "rx888-hf"

# Defaults chosen conservatively; calibrate --threshold-dbfs against a known
# quiet channel vs. a known active one (e.g. WWV is a strong reliable AM
# carrier -> should read well above threshold; a dead CW slot at night ->
# below). See docs/occupancy-guide.md on calibration.
DEFAULT_INTERVAL_SEC = 60.0
DEFAULT_WINDOW_SEC = 2.0
# Calibrated 2026-07 against a live sweep: the RX-888/radiod demodulators
# sit at a ~-33 dBFS residual floor when a channel carries no strong signal
# (a cluster of unrelated bands all read -32..-36 simultaneously = the floor,
# not real occupancy). Genuinely active channels stood clearly above it: WWV
# carriers -18..-24, FT8 slots ~-21, an active CW channel -27. -30 dBFS sits
# in the gap, marking real signals ACTIVE while treating the demod floor as
# quiet. Recalibrate if the front-end gain or antenna changes; HF activity is
# also time/propagation dependent, but the demod floor is the stable anchor.
DEFAULT_THRESHOLD_DBFS = -30.0


def parse_channels(config_path: Path) -> list[dict]:
    """Parse radiod's config into a list of channels the producer can read.

    Each channel needs a freq, a data (multicast) name, and a mode. IQ-mode
    channels are skipped — RMS-on-audio is meaningless for raw IQ.
    """
    text = config_path.read_text()
    channels: list[dict] = []
    # Split on section headers; first element is pre-first-section preamble.
    for block in re.split(r"\n\[", text):
        name = block.split("]", 1)[0].strip()
        if name in ("global", "rx888") or name.startswith("#"):
            continue
        freq_m = re.search(r"^\s*freq\s*=\s*(\d+)", block, re.M)
        data_m = re.search(r"^\s*data\s*=\s*(\S+)", block, re.M)
        mode_m = re.search(r"^\s*mode\s*=\s*(\S+)", block, re.M)
        if not (freq_m and data_m):
            continue
        mode = (mode_m.group(1) if mode_m else "usb").lower()
        if mode == "iq":
            # Raw IQ channel — not an audio stream; skip for power measurement.
            continue
        channels.append(
            {
                "name": name,
                "freq_hz": float(freq_m.group(1)),
                "mode": mode,
                "stream": data_m.group(1),
            }
        )
    return channels


def measure_channel_dbfs(stream: str, window_sec: float, verbose: bool) -> float | None:
    """Capture a short WAV window from a radiod PCM channel via pcmrecord and
    return its RMS power in dBFS, or None if capture failed / no audio.

    Uses the proven interface: `pcmrecord --catmode <stream>` writes WAV to
    stdout. We read for window_sec then stop, parse the WAV, compute RMS.
    """
    # -c/--catmode streams WAV to stdout. We time-bound it ourselves and take
    # whatever audio arrived in the window.
    try:
        proc = subprocess.Popen(
            ["pcmrecord", "--catmode", stream],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        print("ERROR: pcmrecord not found on PATH.", file=sys.stderr)
        return None

    raw = b""
    deadline = time.time() + window_sec
    fd = proc.stdout.fileno()
    try:
        # select()-based read so a SILENT stream (a channel radiod defines
        # but that isn't actually flowing, e.g. 2m-aprs when no APRS traffic)
        # cannot block forever. A plain blocking read() would hang the whole
        # sweep on the first dead channel. We wait at most until the deadline
        # for data to appear on each iteration.
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                # No data within the remaining window -> silent stream; stop.
                break
            chunk = os.read(fd, 4096)
            if not chunk:
                break  # EOF
            raw += chunk
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()

    if len(raw) < 64:
        if verbose:
            print(f"    {stream:14} (no data — stream silent/absent)")
        return None

    # Parse WAV. pcmrecord emits a RIFF header with a streaming-unknown size
    # (ffffffff), which Python's wave can choke on; parse PCM frames robustly.
    try:
        samples = _extract_pcm_s16(raw)
    except Exception as e:  # noqa: BLE001 - defensive; any parse failure -> skip
        if verbose:
            print(f"    {stream}: WAV parse failed ({e.__class__.__name__})")
        return None

    if not samples:
        return None

    # RMS -> dBFS relative to full-scale 16-bit (32768).
    sumsq = 0.0
    for s in samples:
        sumsq += float(s) * float(s)
    rms = math.sqrt(sumsq / len(samples))
    if rms <= 0:
        return -math.inf
    dbfs = 20.0 * math.log10(rms / 32768.0)
    return dbfs


def _extract_pcm_s16(raw: bytes) -> list[int]:
    """Extract 16-bit signed mono PCM samples from a RIFF/WAVE byte blob,
    tolerating the streaming header pcmrecord emits (unknown RIFF/data size).
    """
    # Find 'data' chunk; samples follow its 8-byte header.
    idx = raw.find(b"data")
    if idx == -1:
        # No data chunk marker — treat everything after a 44-byte header as PCM.
        pcm = raw[44:]
    else:
        pcm = raw[idx + 8:]
    # Trim to whole 2-byte frames.
    n = (len(pcm) // 2) * 2
    if n == 0:
        return []
    return list(struct.unpack("<%dh" % (n // 2), pcm[:n]))


def run_once(db: OccupancyDB, channels: list[dict], window_sec: float,
             threshold_dbfs: float, verbose: bool) -> int:
    """One sweep across all channels. Returns count of channels recorded active."""
    active = 0
    for ch in channels:
        dbfs = measure_channel_dbfs(ch["stream"], window_sec, verbose)
        if dbfs is None:
            continue
        state = "ACTIVE" if dbfs >= threshold_dbfs else "quiet"
        if verbose:
            fs = f"{dbfs:6.1f}" if dbfs != -math.inf else "  -inf"
            print(f"    {ch['name']:14} {ch['freq_hz']/1e6:8.4f} MHz "
                  f"{ch['mode']:4} {fs} dBFS  {state}")
        if dbfs >= threshold_dbfs:
            active += 1
            db.record_sighting(
                frequency_hz=ch["freq_hz"],
                source_type=SOURCE_TYPE,
                source_device=SOURCE_DEVICE,
                mode=ch["mode"],
                metadata_json=(
                    '{"channel":"%s","power_dbfs":%.1f,"threshold_dbfs":%.1f}'
                    % (ch["name"], dbfs, threshold_dbfs)
                ),
            )
    return active


def main() -> int:
    ap = argparse.ArgumentParser(description="RX-888/radiod occupancy producer")
    ap.add_argument("--once", action="store_true",
                    help="run a single sweep and exit (default: loop)")
    ap.add_argument("--interval", type=float, default=DEFAULT_INTERVAL_SEC,
                    help=f"seconds between sweeps (default {DEFAULT_INTERVAL_SEC})")
    ap.add_argument("--window", type=float, default=DEFAULT_WINDOW_SEC,
                    help=f"audio window per channel (default {DEFAULT_WINDOW_SEC}s)")
    ap.add_argument("--threshold-dbfs", type=float, default=DEFAULT_THRESHOLD_DBFS,
                    help=f"occupancy threshold dBFS (default {DEFAULT_THRESHOLD_DBFS})")
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG,
                    help="radiod config to parse channels from")
    ap.add_argument("--db", type=Path, default=DEFAULT_DB,
                    help="occupancy DB path")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    if not args.config.exists():
        print(f"ERROR: radiod config not found: {args.config}", file=sys.stderr)
        return 1

    channels = parse_channels(args.config)
    if not channels:
        print("ERROR: no audio channels parsed from config.", file=sys.stderr)
        return 1

    db = OccupancyDB(args.db)
    print(f"radiod occupancy producer: {len(channels)} channels, "
          f"threshold {args.threshold_dbfs} dBFS, window {args.window}s"
          + ("" if args.once else f", every {args.interval}s"))

    try:
        while True:
            t0 = time.time()
            if args.verbose:
                print(f"-- sweep @ {time.strftime('%H:%M:%S')} --")
            active = run_once(db, channels, args.window, args.threshold_dbfs,
                              args.verbose)
            print(f"sweep complete: {active}/{len(channels)} channels active")
            if args.once:
                break
            # Sleep the remainder of the interval (sweeps take real time).
            elapsed = time.time() - t0
            sleep_for = max(0.0, args.interval - elapsed)
            time.sleep(sleep_for)
    except KeyboardInterrupt:
        print("\nstopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
