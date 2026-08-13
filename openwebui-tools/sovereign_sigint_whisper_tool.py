"""
title: Sovereign SIGINT Whisper Transcription
author: sovereign-sigint
description: Transcribe or translate speech-bearing audio via faster-whisper,
    running locally on GPU. Native in-process Open WebUI tool — closes the
    "voice translation" cell of the SIGINT workflow map (Analysis stage).
version: 1.0.0
license: AGPL-3.0
requirements: faster-whisper>=1.0.0
"""
#
# WHY THIS EXISTS (SIGINT workflow context):
#   The Analysis stage of a SIGINT workflow includes "voice translation and
#   pattern-of-life mapping." The sovereign-sigint platform already runs
#   faster-whisper on GPU in Phase 5 (ai-ingest, for /data/audio processed
#   into /data/corpus/processed/audio/); this tool exposes the same capability
#   to the local LLM at chat time, for ad-hoc transcription of a single audio
#   file the operator specifies. Typical inputs:
#     - Ham radio QSO recordings dumped from OpenWebRX+ or SDR clients
#     - Demodulated voice audio captured via radiod's pcmrecord
#     - Broadcast/utility station recordings for transcription + translation
#
# HOW THIS IS DIFFERENT FROM ai-ingest's whisper pass:
#   ai-ingest is a scheduled background service — drop a file in /data/audio,
#   wait up to 4 hours, find the transcript in /data/corpus/processed/audio/.
#   That's the right tool for bulk / archival transcription.
#
#   This native tool is chat-time and on-demand — the operator asks the LLM
#   "transcribe /data/audio/qso.wav" and the LLM calls this tool, which runs
#   faster-whisper right then and returns the segments. Same model, same GPU,
#   same fallback logic, different latency profile.
#
# DEPLOYMENT NOTES:
#   1. Container mount: the audio files must be visible inside the Open WebUI
#      container. Add to containers/open-webui.container (which the shipped
#      template already does):
#         Volume=%h/data/audio:/data/audio    (or wherever host audio lives)
#      Then set AUDIO_ROOT valve to /data/audio (default).
#
#   2. Model cache: faster-whisper downloads the model to ~/.cache/huggingface
#      on first use (a few hundred MB for the "medium" default). To reuse
#      the phase5-downloaded cache and avoid a re-download, add to the
#      Quadlet:
#         Volume=%h/.cache/huggingface:/root/.cache/huggingface
#      Optional: not required. First-run in-container download works fine
#      but takes minutes and consumes ~1.5GB in the container's writable
#      layer.
#
#   3. GPU: faster-whisper uses CUDA when device="auto" and torch/cuda
#      libraries are available in the container. Falls back to CPU cleanly.
#      Same load-and-retry pattern as ai-ingest/extractors/audio.py so this
#      tool matches that service's behavior (verified end-to-end on the
#      RTX 5060 Ti during phase5 spot-check).
#
#   4. requirements: faster-whisper — Open WebUI reads the `requirements:`
#      line in this file's docstring and pip-installs the package into the
#      container's Python env on tool load. If that installation fails,
#      pip install faster-whisper manually inside the container:
#         podman exec -u root open-webui pip install "faster-whisper>=1.0.0"

import logging
import os
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, Field

log = logging.getLogger(__name__)

# Same set the ai-ingest audio extractor accepts (docs/data-layout.md).
SUPPORTED_EXTENSIONS = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".opus"}

# Sanity limit: a 200MB audio file at typical speech bitrates is ~3-4 hours.
# Anything larger is almost certainly the operator pointing at the wrong path
# (a bulk archive, a video file, an IQ dump). Fail loud rather than pin GPU
# for an hour transcribing something unintended.
MAX_AUDIO_MB = 200

# Module-level model cache: loading the medium model takes ~10 seconds and
# ~1.5GB VRAM. Reuse across calls in the same Open WebUI process. Reload only
# if the valve model size changed.
_model = None
_model_size_loaded: Optional[str] = None


def _load_model(size: str, device_pref: str):
    """Load a WhisperModel, matching ai-ingest/extractors/audio.py's fallback:
    prefer GPU/auto, but fall back to CPU/int8 cleanly if CUDA isn't available
    inside the container (device='auto' does NOT reliably fall back on a
    CUDA-less box — has to be explicit)."""
    from faster_whisper import WhisperModel
    try:
        return WhisperModel(size, device=device_pref, compute_type="auto")
    except Exception as e:
        log.warning(
            "GPU/auto WhisperModel load failed (%s) — falling back to CPU explicitly.",
            e.__class__.__name__,
        )
        return WhisperModel(size, device="cpu", compute_type="int8")


def _ts(seconds: float) -> str:
    """Format a float second offset as HH:MM:SS.mmm — same format whisper's
    own CLI uses for VTT/SRT output, so LLM-summarized responses can quote
    timings the operator can find in a media player."""
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{int(h):02d}:{int(m):02d}:{s:06.3f}"


class Tools:
    class Valves(BaseModel):
        AUDIO_ROOT: str = Field(
            default="/data/audio",
            description="Container-side directory for audio files. Mount host "
            "audio into the container at this path via the Open WebUI Quadlet. "
            "Relative file_path arguments are resolved under this root.",
        )
        MODEL_SIZE: str = Field(
            default="medium",
            description="faster-whisper model size. Options: tiny, base, small, "
            "medium (default, ~1.5GB VRAM), large-v3. Must match a model in "
            "the HuggingFace cache OR downloadable at first use. Matches the "
            "phase5 ai-ingest default for cache reuse.",
        )
        DEVICE: str = Field(
            default="auto",
            description="Compute device: 'auto' (prefer GPU, fall back to CPU), "
            "'cuda', or 'cpu'. Auto is recommended — on the 5060 Ti, ~5-10x "
            "faster than CPU.",
        )
        BEAM_SIZE: int = Field(
            default=5,
            description="Beam search width; higher = more accurate + slower. "
            "5 matches whisper's own default. Set to 1 for ~2x faster with "
            "modest accuracy loss.",
        )

    def __init__(self):
        self.valves = self.Valves()

    def _resolve_path(self, path: str) -> Path:
        """Absolute paths pass through; relative paths join under AUDIO_ROOT.
        Doesn't validate existence — that's the caller's error to surface."""
        p = Path(path)
        if not p.is_absolute():
            p = Path(self.valves.AUDIO_ROOT) / p
        return p

    def _get_model(self):
        global _model, _model_size_loaded
        if _model is not None and _model_size_loaded == self.valves.MODEL_SIZE:
            return _model
        _model = _load_model(self.valves.MODEL_SIZE, self.valves.DEVICE)
        _model_size_loaded = self.valves.MODEL_SIZE
        return _model

    def transcribe_audio(
        self,
        file_path: str,
        language: Optional[str] = None,
        translate_to_english: bool = False,
    ) -> str:
        """Transcribe (or translate) an audio file to text via faster-whisper.

        Use when the operator has speech-bearing audio (a ham radio QSO, a
        demodulated voice signal, a broadcast/utility recording) and wants
        the words as text. Fully local — the audio never leaves this box.

        :param file_path: Path to the audio file. Absolute path within the
            container (e.g. /data/audio/qso-20260728.wav) or relative to the
            AUDIO_ROOT valve (e.g. 'qso-20260728.wav'). Supported extensions:
            .wav .mp3 .m4a .flac .ogg .opus.
        :param language: ISO-639-1 code of the source language (e.g. 'en',
            'es', 'ja', 'ru'). If omitted, whisper auto-detects — accurate
            for clean speech, unreliable for very short or noisy clips.
            Providing the correct code is faster and more accurate.
        :param translate_to_english: If True, translate the audio to English
            using whisper's built-in translation (works for many source
            languages, not all). If False (default), transcribe in the
            source language.
        :return: Per-segment transcript with timestamps [HH:MM:SS.mmm]
            followed by summary metadata (duration, detected language,
            model, task). If no speech is detected, returns a note saying so.
        """
        try:
            p = self._resolve_path(file_path)
            if not p.exists():
                return (f"Error: audio file not found at '{p}'. "
                        f"Check the file_path and AUDIO_ROOT valve "
                        f"(currently '{self.valves.AUDIO_ROOT}'). Use "
                        f"list_audio_files() to see what's available.")
            if not p.is_file():
                return f"Error: '{p}' exists but is not a regular file."
            if p.suffix.lower() not in SUPPORTED_EXTENSIONS:
                return (f"Error: unsupported extension '{p.suffix}'. "
                        f"Supported: {sorted(SUPPORTED_EXTENSIONS)}. If the "
                        f"file really is audio, rename it or convert first.")
            size_mb = p.stat().st_size / (1024 * 1024)
            if size_mb > MAX_AUDIO_MB:
                return (f"Error: audio file too large ({size_mb:.1f}MB > "
                        f"{MAX_AUDIO_MB}MB limit). Split it with ffmpeg or "
                        f"raise the MAX_AUDIO_MB constant if this is intended.")

            model = self._get_model()
            task = "translate" if translate_to_english else "transcribe"

            # faster-whisper returns a lazy segment iterator + info; consume
            # the iterator to force actual work.
            segments_iter, info = model.transcribe(
                str(p),
                language=language,
                task=task,
                beam_size=self.valves.BEAM_SIZE,
                vad_filter=True,   # skip long silences — huge speedup for
                                   # amateur-radio recordings with squelched gaps
            )

            lines = []
            for seg in segments_iter:
                lines.append(f"[{_ts(seg.start)} --> {_ts(seg.end)}] {seg.text.strip()}")

            summary_parts = [
                "",
                "--- transcription complete ---",
                f"file: {p}",
                f"duration: {info.duration:.1f}s",
                f"language: {info.language} (detected confidence "
                f"{info.language_probability:.2f})",
                f"task: {task}",
                f"model: {self.valves.MODEL_SIZE}",
                f"beam_size: {self.valves.BEAM_SIZE}",
                f"segments: {len(lines)}",
            ]

            if not lines:
                return (f"No speech detected in '{p.name}' "
                        f"(duration {info.duration:.1f}s). The VAD may have "
                        f"filtered everything out as silence or noise, or the "
                        f"clip may contain only tones/data/music.\n"
                        + "\n".join(summary_parts))

            return "\n".join(lines) + "\n" + "\n".join(summary_parts)

        except Exception as e:
            return (f"Error transcribing '{file_path}': "
                    f"{e.__class__.__name__}: {e}. If this is the first run, "
                    f"faster-whisper may still be downloading the '"
                    f"{self.valves.MODEL_SIZE}' model — check container logs "
                    f"and retry in a minute. If persistent, verify "
                    f"faster-whisper installed cleanly in the Open WebUI "
                    f"container: podman exec open-webui python -c 'import "
                    f"faster_whisper; print(faster_whisper.__version__)'")

    def list_audio_files(self, subdirectory: str = "") -> str:
        """List audio files available for transcription under AUDIO_ROOT.

        Use when the operator asks 'what audio files are available' before
        calling transcribe_audio. Reports files, sizes, and modification
        times so the LLM can help identify which recording to transcribe.

        :param subdirectory: Optional subdirectory relative to AUDIO_ROOT
            (e.g. 'ham-radio/2m'). If empty, lists everything under AUDIO_ROOT.
        :return: Newline-separated list of relative paths with size in MB
            and human-readable modification time. Or a note if nothing found.
        """
        try:
            import time
            root = Path(self.valves.AUDIO_ROOT)
            search_dir = root / subdirectory if subdirectory else root
            if not search_dir.exists():
                return (f"Directory not found: '{search_dir}'. Check "
                        f"AUDIO_ROOT valve (currently '{self.valves.AUDIO_ROOT}') "
                        f"and the subdirectory argument.")
            if not search_dir.is_dir():
                return f"Path '{search_dir}' exists but is not a directory."

            files = []
            for p in sorted(search_dir.rglob("*")):
                if p.is_file() and p.suffix.lower() in SUPPORTED_EXTENSIONS:
                    rel = p.relative_to(root)
                    size_mb = p.stat().st_size / (1024 * 1024)
                    mtime = time.strftime(
                        "%Y-%m-%d %H:%M UTC",
                        time.gmtime(p.stat().st_mtime),
                    )
                    files.append(f"  {rel}  ({size_mb:.1f}MB, modified {mtime})")

            if not files:
                return (f"No audio files found under '{search_dir}' "
                        f"(supported extensions: {sorted(SUPPORTED_EXTENSIONS)}). "
                        f"Drop audio files there via a share, or record "
                        f"directly to '{root}' from radiod (pcmrecord) or "
                        f"OpenWebRX+.")

            return (f"Audio files under '{search_dir}':\n"
                    + "\n".join(files)
                    + f"\n\n{len(files)} file(s). Call transcribe_audio() "
                    f"with the relative path (or absolute path) to transcribe.")

        except Exception as e:
            return (f"Error listing audio in '{self.valves.AUDIO_ROOT}': "
                    f"{e.__class__.__name__}: {e}")
