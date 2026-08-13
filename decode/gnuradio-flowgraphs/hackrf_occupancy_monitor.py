#!/usr/bin/env python3
"""
decode/gnuradio-flowgraphs/hackrf_occupancy_monitor.py

Single-frequency/mode occupancy monitor for HackRF via GNU Radio +
gr-osmosdr. Deliberately NOT wideband-simultaneous like radiod (see
docs/build-order.md Phase 6.1) — watches ONE frequency at a time,
confirmed acceptable for this build's scope.

Runs under SYSTEM Python (GNU Radio's dist-packages, not the
sigint-processing venv — see docs/venvs.md's GNU Radio/venv boundary
note). db/occupancy_db.py has zero dependencies beyond the standard
library, so it's imported directly here with no cross-venv bridging.

UNCONFIRMED — flagged rather than guessed, not yet run against real
hardware: this has been syntax-checked only. GNU Radio/gr-osmosdr
aren't available in the environment this was written in, so the
flowgraph's actual behavior (block connections, gr-osmosdr's exact
osmosdr.source() API surface for this version) needs a real run to
confirm.

Usage:
    python3 hackrf_occupancy_monitor.py --freq 144390000 --mode APRS \\
        --threshold-db -40 --sample-rate 2000000
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
    """Custom sink block: watches a smoothed/decimated power-estimate
    stream, applies a fixed threshold with hang time (hysteresis, so
    noise crossing the threshold repeatedly doesn't create dozens of
    spurious short sightings), and calls OccupancyDB.record_sighting()
    once per detected sighting.

    UNRESOLVED, flagged rather than guessed: `threshold_db` is a FIXED
    value you supply, not an adaptive/calibrated noise floor. A real
    deployment should calibrate this against the actual measured noise
    floor at the target frequency (varies by band, antenna, time of
    day) rather than trust a default guess — same "don't tune blind"
    caution as occupancy_db.py's FREQUENCY_BIN_HZ.

    Timestamps are wall-clock (time.time() when a buffer is
    processed), not derived from GNU Radio stream tags — accurate to
    roughly this block's processing granularity (set by the upstream
    decimation factor), not sample-precise. Fine for occupancy
    tracking at second-level granularity; not a general timing
    reference.
    """

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
        # Flush a still-in-progress sighting on shutdown instead of
        # silently losing it.
        if self.active:
            self._record_sighting()
        return True


class NoiseFloorCalibrator(gr.sync_block):
    """Accumulates power-estimate samples for a fixed duration — no
    detection logic, no DB writes. Used via --calibrate to measure the
    actual noise floor at a target frequency before trusting a
    --threshold-db value, per this project's "don't tune blind"
    principle (see occupancy_db.py's FREQUENCY_BIN_HZ and
    OccupancyDetector's threshold_db docstring note above).
    """

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


class HackRFOccupancyMonitor(gr.top_block):
    def __init__(self, freq, sample_rate, gain, mode, threshold_db,
                 hang_time_sec, db_path, avg_window, calibrate=False):
        gr.top_block.__init__(self, "HackRF Occupancy Monitor")

        self.source = osmosdr.source(args="hackrf=0")
        self.source.set_sample_rate(sample_rate)
        self.source.set_center_freq(freq)
        self.source.set_gain(gain)

        # Power estimate pipeline: magnitude-squared at full rate, a
        # true N-sample boxcar average to smooth it (not a fixed-alpha
        # IIR approximation — moving_average_ff's semantics are a
        # direct, interpretable "average power over N samples"), then
        # decimate — a Python block processing at multi-MS/s would be
        # far too slow; only feed it the already-averaged, decimated
        # stream.
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
                source_device="gnuradio/hackrf", mode=mode,
                threshold_db=threshold_db, hang_time_sec=hang_time_sec,
            )
            self.connect(self.source, self.mag_sq, self.moving_avg,
                         self.decimator, self.detector)


def main():
    parser = argparse.ArgumentParser(description="HackRF single-frequency occupancy monitor")
    parser.add_argument("--freq", type=float, required=True, help="Center frequency, Hz")
    parser.add_argument("--sample-rate", type=float, default=2000000)
    parser.add_argument("--gain", type=float, default=30)
    parser.add_argument("--mode", default=None, help="Mode label recorded with each sighting, e.g. APRS")
    parser.add_argument("--threshold-db", type=float, default=-40.0,
                         help="FIXED threshold — run --calibrate first rather than trust this default")
    parser.add_argument("--hang-time", type=float, default=1.0,
                         help="Seconds below threshold before a sighting is considered ended")
    parser.add_argument("--avg-window", type=int, default=1000,
                         help="Samples averaged per power estimate (also the decimation factor)")
    parser.add_argument("--db-path", default=str(DEFAULT_DB_PATH))
    parser.add_argument("--calibrate", type=float, default=None, metavar="SECONDS",
                         help="Measure noise floor for SECONDS and suggest a threshold, "
                              "instead of monitoring. Run this on a quiet moment first.")
    parser.add_argument("--margin-db", type=float, default=10.0,
                         help="dB above measured mean noise floor for the suggested threshold (--calibrate mode)")
    args = parser.parse_args()

    tb = HackRFOccupancyMonitor(
        freq=args.freq, sample_rate=args.sample_rate, gain=args.gain,
        mode=args.mode, threshold_db=args.threshold_db,
        hang_time_sec=args.hang_time, db_path=args.db_path,
        avg_window=args.avg_window, calibrate=(args.calibrate is not None),
    )

    if args.calibrate is not None:
        print(f"Calibrating at {args.freq / 1e6:.4f} MHz on HackRF for {args.calibrate:.0f}s "
              f"— ensure this is a quiet moment/frequency...")
        tb.start()
        time.sleep(args.calibrate)
        tb.stop()
        tb.wait()
        tb.calibrator.report(args.margin_db)
        return

    print(f"Monitoring {args.freq / 1e6:.4f} MHz on HackRF "
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
