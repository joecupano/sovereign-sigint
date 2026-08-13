# GNU Radio Flowgraphs — Reference Only (Deferred)

These two flowgraphs (`hackrf_occupancy_monitor.py`,
`rtlsdr_occupancy_monitor.py`) are **reference material, not part of the
working build.** They were an early approach to occupancy detection and were
**never hardware-validated** (their own docstrings say "syntax-checked only").

## Why they're not used

The working occupancy producers took a simpler, more robust path: they capture
short samples directly via each device's own command-line tool
(`hackrf_transfer`, `rtl_sdr`, radiod's `pcmrecord`) and compute power from the
samples — no GNU Radio in the loop. See `decode/vhf_uhf_key_freq_producer.py`
and `docs/occupancy-guide.md`. That approach is calibrated and validated on
real hardware; these flowgraphs are superseded by it.

## Why GNU Radio isn't installed anymore

GNU Radio is a large dependency, and nothing in the working system needs it:
- Occupancy capture uses the direct CLIs above.
- Interactive HackRF/RTL-SDR viewing is handled by OpenWebRX+ (its own DSP).

So GNU Radio was removed from the Phase 6.2 install
(`scripts/phase6-decode-tools.sh`). These files remain only as a record of the
approach that was tried and set aside — a genuine teaching point (the simplest
robust integration often beats the more sophisticated one).

## Running them anyway (if you want to)

Building real demodulation flowgraphs is a legitimate **advanced topic**, but
better suited to a desktop workstation than this headless server. To use these
files or build your own flowgraphs, install GNU Radio first:

```
sudo apt install -y gnuradio gnuradio-dev gr-osmosdr
```

Then treat these two files as starting points to validate against real
hardware — they have not been.
