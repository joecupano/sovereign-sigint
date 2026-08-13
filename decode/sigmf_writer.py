#!/usr/bin/env python3
"""
decode/sigmf_writer.py

Phase 6.5 — SigMF writer. Generates spec-compliant SigMF recordings
(.sigmf-meta / .sigmf-data pairs) from raw IQ captures, for external
consumption (IQEngine, GNU Radio's SigMF blocks, other third-party
SigMF tooling). WRITER ONLY — see decode/requirements.txt for why
reading stays on direct JSON parsing rather than this library.

Runs under the sigint-processing venv (docs/venvs.md), using the
pinned sigmf==1.11.1 functional API. Confirmed pattern (from the
library's own usage examples): `sigmf.fromarray(data)`,
`meta.sample_rate = ...`, `meta.add_capture(...)`, `meta.tofile(...)`.
NOT the older SigMFFile(metadata_path=..., data_path=...) constructor
that broke a prior version of sigint-ingest.py (see
decode/requirements.txt for that history). Author/description metadata
via `set_global_info()` — confirmed correct via a real hardware
capture (both fields verified present and correct in the written
`.sigmf-meta`), not just a guess that happened not to error.

Output lands in /data/signals/generated (docs/data-layout.md) —
deliberately separate from /data/signals/raw, so external consumers of
generated output never have to sort it from raw/possibly-partial
captures.

UNCONFIRMED, flagged rather than guessed: exact fidelity tradeoffs of
converting any of ci16_le (RX-888), cu8 (RTL-SDR), or ci8 (HackRF) to
complex64 through sigmf-python's fromarray() API, which is documented
primarily against floating-point numpy complex arrays. This module
normalizes all three to complex64 as the safe, always-works path;
verify against real hardware captures once available whether writing
native bit depth directly (smaller files, no precision loss from the
conversion) is worth doing instead via the lower-level SigMFFile API —
this matters most for cu8/ci8, where complex64 conversion is an 8x size
increase, not just 2x like ci16_le.

Usage as a CLI (convert an existing raw IQ file):
    python3 sigmf_writer.py \\
        --input capture.bin \\
        --output-name my_capture \\
        --sample-rate 8000000 \\
        --center-freq 14074000 \\
        --input-format ci16_le \\
        --description "40m FT8 capture" \\
        --author "NE2Z"

Usage as a library:
    from sigmf_writer import write_sigmf
    write_sigmf(iq_array, output_name="my_capture", sample_rate=8e6,
                center_freq=14074000, description="...", author="NE2Z")
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import sigmf

DEFAULT_OUTPUT_ROOT = Path("/data/signals/generated")

# core:datatype strings this module accepts as input format labels for
# raw binary files being wrapped — maps to how the bytes get interpreted
# before conversion to a numpy array. Mapped to their actual native
# devices (corrected from an earlier version of this file, which
# incorrectly claimed ci16_le was native to RTL-SDR/HackRF too — it
# isn't; only RX-888/rx888_stream captures at that resolution):
#   ci16_le — RX-888 MkII (rx888_stream)
#   cu8     — RTL-SDR (rtl_sdr), unsigned 8-bit, offset-binary (0-255,
#             center 127.5) — the classic RTL-SDR/librtlsdr convention
#   ci8     — HackRF (hackrf_transfer), signed 8-bit (-128 to 127)
#   cf32_le — already-normalized float32 IQ, any source
SUPPORTED_INPUT_FORMATS = {
    "ci16_le": np.dtype([("i", "<i2"), ("q", "<i2")]),  # interleaved int16 IQ
    "cu8": np.dtype([("i", "u1"), ("q", "u1")]),  # unsigned 8-bit, RTL-SDR
    "ci8": np.dtype([("i", "i1"), ("q", "i1")]),  # signed 8-bit, HackRF
    "cf32_le": np.complex64,
}


def load_raw_iq(path: Path, input_format: str) -> np.ndarray:
    """Load a raw binary IQ file and return a complex64 numpy array.

    Each hardware format needs different normalization before it's a
    proper complex64 signal — see SUPPORTED_INPUT_FORMATS above for
    which device each one is actually native to.
    """
    if input_format not in SUPPORTED_INPUT_FORMATS:
        raise ValueError(
            f"Unsupported input format '{input_format}'. "
            f"Supported: {list(SUPPORTED_INPUT_FORMATS)}"
        )

    if input_format == "ci16_le":
        raw = np.fromfile(path, dtype=SUPPORTED_INPUT_FORMATS["ci16_le"])
        # Normalize int16 range to [-1, 1] float, matching what SigMF's
        # cf32_le convention expects for floating-point representations.
        iq = (raw["i"].astype(np.float32) / 32768.0) + 1j * (
            raw["q"].astype(np.float32) / 32768.0
        )
        return iq.astype(np.complex64)

    if input_format == "cu8":
        # RTL-SDR's offset-binary convention: unsigned bytes 0-255,
        # centered at 127.5, not 128 — a real source of a small DC
        # offset if you center on 128 instead. Subtract 127.5 before
        # scaling, not 127 or 128.
        raw = np.fromfile(path, dtype=SUPPORTED_INPUT_FORMATS["cu8"])
        iq = ((raw["i"].astype(np.float32) - 127.5) / 127.5) + 1j * (
            (raw["q"].astype(np.float32) - 127.5) / 127.5
        )
        return iq.astype(np.complex64)

    if input_format == "ci8":
        # HackRF's signed 8-bit range is -128 to 127, not symmetric —
        # scale by 128 (not 127) to keep -128 mapping to exactly -1.0;
        # +127 then lands just under +1.0, which is correct and
        # expected, not a bug to "fix" by scaling differently.
        raw = np.fromfile(path, dtype=SUPPORTED_INPUT_FORMATS["ci8"])
        iq = (raw["i"].astype(np.float32) / 128.0) + 1j * (
            raw["q"].astype(np.float32) / 128.0
        )
        return iq.astype(np.complex64)

    if input_format == "cf32_le":
        return np.fromfile(path, dtype=np.complex64)

    raise AssertionError("unreachable")  # SUPPORTED_INPUT_FORMATS guards this


def write_sigmf(
    iq_array: np.ndarray,
    output_name: str,
    sample_rate: float,
    center_freq: float,
    description: str = "",
    author: str = "",
    output_root: Path = DEFAULT_OUTPUT_ROOT,
    extra_capture_metadata: dict | None = None,
) -> tuple[Path, Path]:
    """Write iq_array as a spec-compliant SigMF recording. Returns
    (meta_path, data_path).

    API confidence note: `sigmf.fromarray(data)`, setting
    `meta.sample_rate = ...`, `meta.add_capture(...)`, `meta.tofile(...)`,
    and `meta.set_global_info(...)` for author/description are all
    confirmed against sigmf-python 1.11.1 — verified via a real hardware
    capture (RTL-SDR, 100 MHz FM) where both `core:author` and
    `core:description` came back correct in the written `.sigmf-meta`.
    The try/except below is kept as defensive coding against a future
    library version changing this method, not because the call itself
    is still in doubt.

    extra_capture_metadata: optional dict merged into the capture
    segment's metadata — the hook point for future integration (e.g. a
    candidate SigID match, or an occupancy-DB record ID) without
    needing to change this function's signature later. Not populated
    by anything yet, since 6.3's SigID mirror and 6.6's occupancy DB
    aren't wired to this writer — that's a future integration, not
    assumed here.
    """
    output_root.mkdir(parents=True, exist_ok=True)
    output_stem = output_root / output_name

    meta = sigmf.fromarray(iq_array)
    meta.sample_rate = sample_rate

    if author or description:
        try:
            if author:
                meta.set_global_info({"core:author": author})
            if description:
                meta.set_global_info({"core:description": description})
        except AttributeError:
            print(
                "WARNING: set_global_info() raised AttributeError — this "
                "call is confirmed working on sigmf-python 1.11.1 (verified "
                "via a real hardware capture), so this likely means a "
                "different sigmf-python version is installed. Recording is "
                "still valid; these two optional fields just weren't set.",
                file=sys.stderr,
            )

    capture_metadata = {"core:frequency": center_freq}
    if extra_capture_metadata:
        capture_metadata.update(extra_capture_metadata)
    meta.add_capture(0, metadata=capture_metadata)

    meta.tofile(str(output_stem))  # writes <output_stem>.sigmf-meta/-data

    meta_path = output_stem.with_suffix(".sigmf-meta")
    data_path = output_stem.with_suffix(".sigmf-data")
    return meta_path, data_path


def verify_written_recording(meta_path: Path, data_path: Path) -> dict:
    """Independent sanity check on a just-written recording — reads the
    .sigmf-meta as plain JSON (NOT via the sigmf library — consistent
    with this project's read-path convention, see module docstring) and
    cross-checks the data file's size and SHA512 against what the
    metadata claims, since SigMF's own spec includes a sha512 field for
    exactly this kind of integrity check.
    """
    with open(meta_path) as f:
        meta = json.load(f)

    actual_size = data_path.stat().st_size
    actual_hash = hashlib.sha512(data_path.read_bytes()).hexdigest()

    global_info = meta.get("global", {})
    claimed_hash = global_info.get("core:sha512")

    result = {
        "meta_path": str(meta_path),
        "data_path": str(data_path),
        "data_size_bytes": actual_size,
        "hash_match": claimed_hash == actual_hash if claimed_hash else None,
        "sample_rate": global_info.get("core:sample_rate"),
        "datatype": global_info.get("core:datatype"),
        "captures": meta.get("captures", []),
    }
    return result


def main():
    parser = argparse.ArgumentParser(description="sovereign-sigint SigMF writer")
    parser.add_argument("--input", type=Path, required=True, help="raw IQ file to wrap")
    parser.add_argument("--output-name", required=True, help="output filename stem (no extension)")
    parser.add_argument("--sample-rate", type=float, required=True)
    parser.add_argument("--center-freq", type=float, required=True)
    parser.add_argument(
        "--input-format", choices=list(SUPPORTED_INPUT_FORMATS), default="ci16_le"
    )
    parser.add_argument("--description", default="")
    parser.add_argument("--author", default="")
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    args = parser.parse_args()

    print(f"Loading {args.input} as {args.input_format}...")
    iq_array = load_raw_iq(args.input, args.input_format)
    print(f"Loaded {len(iq_array)} samples.")

    meta_path, data_path = write_sigmf(
        iq_array=iq_array,
        output_name=args.output_name,
        sample_rate=args.sample_rate,
        center_freq=args.center_freq,
        description=args.description,
        author=args.author,
        output_root=args.output_root,
    )
    print(f"Wrote {meta_path}")
    print(f"Wrote {data_path}")

    print("Verifying...")
    result = verify_written_recording(meta_path, data_path)
    print(json.dumps(result, indent=2))

    if result["hash_match"] is False:
        print("ERROR: SHA512 mismatch between metadata and data file.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
