#!/usr/bin/env python3
"""
decode/gnuradio-flowgraphs/rtlsdr_occupancy_monitor.py

Single-frequency/mode occupancy monitor for RTL-SDR via GNU Radio +
gr-osmosdr. Same design as hackrf_occupancy_monitor.py — see that
file's docstring for the shared architecture notes (venv boundary,
fixed-threshold caveat, wall-clock timestamp precision). This file
only documents what's actually different for RTL-SDR.

RTL-SDR-specific: gain defaults to MANUAL, not auto — confirmed during
this build's OpenWebRX+ work that auto gain produced a faint,
indistinguishable signal on this exact hardware, while a manual value
worked. Same real-world finding applies here, not a generic guess.
Default sample rate 2.048 MS/s matches this project's established
RTL-SDR convention (Phase 1 validation, capture-to-sigmf.sh).

HF via --direct-sampling: RTL-SDR Blog v3/v4 boards support direct
sampling mode (confirmed via gr-osmosdr's rtl source, direct_samp=0|1|2
device argument — 0 off, 1 I-ADC, 2 Q-ADC) with NO hardware
modification, using the same antenna connector. v3/v4 boards route
through the Q-branch, so direct_samp=2 is correct for this hardware —
this corrects an earlier wrong claim in this project's chat history
that RTL-SDR couldn't reach HF at all; it can, on exactly this
hardware, via this flag. Real tradeoff worth knowing: direct sampling
bypasses the tuner chip's amplification entirely, so sensitivity is
markedly lower than normal VHF/UHF reception — expect to need strong
local signals or a decent antenna, not a mode that matches tuner-path
sensitivity.

UNCONFIRMED — flagged rather than guessed, not yet run against real
hardware: syntax-checked only, same as the HackRF version.

Usage:
    python3 rtlsdr_occupancy_monitor.py --freq 162475000 --mode NOAA \\
        --threshold-db -40 --sample-rate 2048000 --gain 20

    python3 rtlsdr_occupancy_monitor.py --freq 10000000 --mode AM \\
        --direct-sampling --threshold-db -40 --sample-rate 2048000
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import osmosdr
from gnuradio import gr, blocks

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "db"))
from occupancy_db import OccupancyDB  # noqa: E402

DEFAULT_DB_PATH = REPO_ROOT / "db" / "occupancy.db"


class OccupancyDetector(gr.sync_block):
    """See hackrf_occupancy_monitor.py's OccupancyDetector docstring —
    identical logic, duplicated here rather than shared via import so
    each flowgraph file stays a single, standalone, readable script
    (matches this repo's general preference for explicit over clever
    where a script is meant to be read and modified directly)."""

    def __init__(self, db_path, frequency_hz, source_device, mode,
                 threshold_db, hang_time_sec):
        gr.sync_block.__init__(
            self, name="occupancy_detector",
            in_sig=[np.float32], out_sig=None,
        )
        self.db = OccupancyDB(Path(db_path))
        self.frequency_hz = frequency_hz
        self.source_device = source_device
        self.mode = mode
        self.threshold_linear = 10 ** (threshold_db / 10.0)
        self.hang_time_sec = hang_time_sec
        self.active = False
        self.first_seen = None
        self.last_above = None

    def work(self, input_items, output_items):
        power = input_items[0]
        now = time.time()
        for sample in power:
            if sample > self.threshold_linear:
                if not self.active:
                    self.active = True
                    self.first_seen = now
                self.last_above = now
            elif self.active and (now - self.last_above) > self.hang_time_sec:
                self._record_sighting()
                self.active = False
        return len(power)

    def _record_sighting(self):
        key = self.db.record_sighting(
            frequency_hz=self.frequency_hz,
            source_type="gnuradio_feature_extraction",
            source_device=self.source_device,
            mode=self.mode,
            first_seen_sec=int(self.first_seen),
            first_seen_ms=int((self.first_seen % 1) * 1000),
            last_seen_sec=int(self.last_above),
            last_seen_ms=int((self.last_above % 1) * 1000),
        )
        duration = self.last_above - self.first_seen
        print(f"Sighting recorded: {key} ({duration:.2f}s)")

    def stop(self):
        if self.active:
            self._record_sighting()
        return True


class NoiseFloorCalibrator(gr.sync_block):
    """See hackrf_occupancy_monitor.py's NoiseFloorCalibrator — same
    logic, duplicated here for the same standalone-script reason as
    OccupancyDetector above."""

    def __init__(self):
        gr.sync_block.__init__(
            self, name="noise_floor_calibrator",
            in_sig=[np.float32], out_sig=None,
        )
        self.samples = []

    def work(self, input_items, output_items):
        self.samples.extend(input_items[0].tolist())
        return len(input_items[0])

    def report(self, margin_db):
        if not self.samples:
            print("No samples collected — check device/antenna/frequency.")
            return
        arr_db = 10 * np.log10(np.maximum(np.array(self.samples), 1e-20))
        mean_db, std_db, max_db = arr_db.mean(), arr_db.std(), arr_db.max()
        suggested = mean_db + margin_db
        print(f"Samples collected: {len(self.samples)}")
        print(f"Noise floor — mean: {mean_db:.1f} dB, std: {std_db:.1f} dB, max: {max_db:.1f} dB")
        print(f"Suggested --threshold-db {suggested:.1f} (mean + {margin_db:.1f} dB margin)")
        print("Re-run without --calibrate using that threshold to start monitoring.")
        print("NOTE: calibrate on a QUIET moment/frequency — a signal present")
        print("during calibration will inflate the measured floor and threshold.")


class RTLSDROccupancyMonitor(gr.top_block):
    def __init__(self, freq, sample_rate, gain, mode, threshold_db,
                 hang_time_sec, db_path, avg_window, direct_sampling,
                 calibrate=False):
        gr.top_block.__init__(self, "RTL-SDR Occupancy Monitor")

        # direct_samp=2 (Q-branch) — correct for RTL-SDR Blog v3/v4
        # boards specifically, confirmed via gr-osmosdr's rtl source
        # device argument. No hardware mod needed, same antenna
        # connector — see module docstring for the sensitivity tradeoff.
        args = "rtl=0,direct_samp=2" if direct_sampling else "rtl=0"
        self.source = osmosdr.source(args=args)
        self.source.set_sample_rate(sample_rate)
        self.source.set_center_freq(freq)
        # Manual gain, deliberately — see module docstring for why
        # auto gain is not the default here.
        self.source.set_gain_mode(False)
        self.source.set_gain(gain)

        self.mag_sq = blocks.complex_to_mag_squared()
        self.moving_avg = blocks.moving_average_ff(avg_window, 1.0 / avg_window)
        self.decimator = blocks.keep_one_in_n(gr.sizeof_float, avg_window)

        if calibrate:
            self.calibrator = NoiseFloorCalibrator()
            self.connect(self.source, self.mag_sq, self.moving_avg,
                         self.decimator, self.calibrator)
        else:
            self.detector = OccupancyDetector(
                db_path=db_path, frequency_hz=freq,
                source_device="gnuradio/rtlsdr", mode=mode,
                threshold_db=threshold_db, hang_time_sec=hang_time_sec,
            )
            self.connect(self.source, self.mag_sq, self.moving_avg,
                         self.decimator, self.detector)


def main():
    parser = argparse.ArgumentParser(description="RTL-SDR single-frequency occupancy monitor")
    parser.add_argument("--freq", type=float, required=True, help="Center frequency, Hz")
    parser.add_argument("--sample-rate", type=float, default=2048000)
    parser.add_argument("--gain", type=float, default=20,
                         help="Manual gain — auto gain confirmed unreliable on this hardware")
    parser.add_argument("--mode", default=None, help="Mode label recorded with each sighting")
    parser.add_argument("--threshold-db", type=float, default=-40.0,
                         help="FIXED threshold — run --calibrate first rather than trust this default")
    parser.add_argument("--hang-time", type=float, default=1.0,
                         help="Seconds below threshold before a sighting is considered ended")
    parser.add_argument("--avg-window", type=int, default=1000,
                         help="Samples averaged per power estimate (also the decimation factor)")
    parser.add_argument("--direct-sampling", action="store_true",
                         help="Enable HF direct sampling (Q-branch, direct_samp=2) — "
                              "supported on RTL-SDR Blog v3/v4 boards, no hardware mod. "
                              "Bypasses the tuner's amplification — expect lower sensitivity.")
    parser.add_argument("--db-path", default=str(DEFAULT_DB_PATH))
    parser.add_argument("--calibrate", type=float, default=None, metavar="SECONDS",
                         help="Measure noise floor for SECONDS and suggest a threshold, "
                              "instead of monitoring. Run this on a quiet moment first.")
    parser.add_argument("--margin-db", type=float, default=10.0,
                         help="dB above measured mean noise floor for the suggested threshold (--calibrate mode)")
    args = parser.parse_args()

    tb = RTLSDROccupancyMonitor(
        freq=args.freq, sample_rate=args.sample_rate, gain=args.gain,
        mode=args.mode, threshold_db=args.threshold_db,
        hang_time_sec=args.hang_time, db_path=args.db_path,
        avg_window=args.avg_window, direct_sampling=args.direct_sampling,
        calibrate=(args.calibrate is not None),
    )

    if args.calibrate is not None:
        print(f"Calibrating at {args.freq / 1e6:.4f} MHz on RTL-SDR for {args.calibrate:.0f}s "
              f"— ensure this is a quiet moment/frequency...")
        tb.start()
        time.sleep(args.calibrate)
        tb.stop()
        tb.wait()
        tb.calibrator.report(args.margin_db)
        return

    print(f"Monitoring {args.freq / 1e6:.4f} MHz on RTL-SDR "
          f"(threshold {args.threshold_db} dB) — Ctrl-C to stop")
    tb.start()
    try:
        input()
    except KeyboardInterrupt:
        pass
    tb.stop()
    tb.wait()


if __name__ == "__main__":
    main()
