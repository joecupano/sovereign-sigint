"""
ai-ingest/extractors/audio.py

Baseline spoken-word transcription via faster-whisper. This handles
GENERAL audio in /data/audio — not SIGINT-specific demodulated signal
audio, which is a Phase 6 concern that reuses this same model rather
than duplicating it (see docs/build-order.md Phase 6 and
decode/requirements.txt).
"""

import logging
import os
from pathlib import Path

from faster_whisper import WhisperModel

log = logging.getLogger(__name__)

SUPPORTED_EXTENSIONS = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".opus"}

# "medium" — ~1.5GB VRAM, confirmed fit on the 16GB RTX 5060 Ti alongside
# the Phase 3 Ollama models (see docs/build-order.md Phase 3). Override
# via WHISPER_MODEL if a different size/accuracy tradeoff is wanted.
DEFAULT_MODEL_SIZE = os.environ.get("WHISPER_MODEL", "medium")

_model = None


def _get_model() -> WhisperModel:
    global _model
    if _model is None:
        # device="auto" does NOT reliably fall back to CPU on a CUDA
        # library load failure — confirmed via a real install where a
        # missing libcublas.so.12 (see requirements.txt) hard-failed
        # instead of falling back, contradicting what this comment used
        # to claim. Catching the failure explicitly and retrying on CPU
        # is the actual robust behavior, not something to assume
        # faster-whisper/ctranslate2 does for us.
        try:
            _model = WhisperModel(DEFAULT_MODEL_SIZE, device="auto", compute_type="auto")
        except Exception as exc:
            log.warning(
                "GPU/auto WhisperModel load failed (%s) — falling back to CPU explicitly.",
                exc,
            )
            _model = WhisperModel(DEFAULT_MODEL_SIZE, device="cpu", compute_type="int8")
    return _model


def can_handle(path: Path) -> bool:
    return path.suffix.lower() in SUPPORTED_EXTENSIONS


def extract(path: Path) -> dict:
    """Returns {"text": str, "metadata": dict}. Raises on failure —
    caller (ingest.py) is responsible for catching and recording the
    failure in the manifest."""
    model = _get_model()
    segments, info = model.transcribe(str(path), beam_size=5)

    segment_list = []
    text_parts = []
    for seg in segments:
        segment_list.append(
            {"start": seg.start, "end": seg.end, "text": seg.text.strip()}
        )
        text_parts.append(seg.text.strip())

    full_text = " ".join(text_parts).strip()

    metadata = {
        "extractor": "faster-whisper",
        "model_size": DEFAULT_MODEL_SIZE,
        "detected_language": info.language,
        "language_probability": info.language_probability,
        "duration_seconds": info.duration,
        "segment_count": len(segment_list),
        "segments": segment_list,
    }

    return {"text": full_text, "metadata": metadata}
