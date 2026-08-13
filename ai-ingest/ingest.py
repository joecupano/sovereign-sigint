#!/usr/bin/env python3
"""
ai-ingest/ingest.py

Phase 5 ingest orchestrator. Scans:
  - /data/corpus/source  (documents: DOCX, PDF, TXT, MD)
  - /data/imagery         (images: PNG, JPG, HEIC, etc.)
  - /data/audio            (audio: WAV, MP3, etc.)

...and writes extracted/normalized text to /data/corpus/processed,
namespaced by source type (documents/, images/, audio/) to avoid path
collisions between source roots, but still unified in one processed/
tree as a single place to read from (docs/data-layout.md). Idempotent —
see manifest.py — safe to run repeatedly via the systemd timer
(systemd/ai-ingest.timer) or by hand.

Deliberately filesystem-only, not wired to Open WebUI/Ollama — see
docs/build-order.md Phase 5 for why.

Usage:
    python3 ingest.py                  # normal run
    python3 ingest.py --dry-run        # report what WOULD be processed
    python3 ingest.py --once           # same as default; explicit for
                                        # clarity in the systemd unit
"""

import argparse
import json
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path

from extractors import audio, documents, images
from manifest import Manifest, sha256_of_file

DEFAULT_CORPUS_SOURCE = Path("/data/corpus/source")
DEFAULT_IMAGERY_DIR = Path("/data/imagery")
DEFAULT_AUDIO_DIR = Path("/data/audio")
DEFAULT_CORPUS_PROCESSED = Path("/data/corpus/processed")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("ingest")


def iter_candidates(root: Path, can_handle):
    if not root.exists():
        log.warning("Source directory does not exist, skipping: %s", root)
        return
    for path in sorted(root.rglob("*")):
        if path.is_file() and can_handle(path):
            yield path


def output_paths(source_root: Path, source_path: Path, processed_root: Path, source_type: str):
    """Mirror the source file's relative path under
    processed_root/<source_type>/, so files from different source
    directories don't collide even if they happen to share the same
    relative subpath (e.g. a document and an image both at
    ".../reports/q1.*") — namespacing by type, not just mirroring the
    bare relative path, is what actually prevents that collision. The
    origin of any processed file is still obvious from its path alone."""
    rel = source_path.relative_to(source_root)
    stem = rel.with_suffix("")
    base = processed_root / source_type
    text_path = base / stem.with_suffix(".txt")
    json_path = base / stem.with_suffix(".json")
    return text_path, json_path


def process_one(
    source_root: Path,
    source_path: Path,
    processed_root: Path,
    source_type: str,
    extractor_module,
    manifest: Manifest,
    dry_run: bool,
) -> bool:
    current_hash = sha256_of_file(source_path)
    text_path, json_path = output_paths(source_root, source_path, processed_root, source_type)

    # Skip only if the manifest says unchanged AND the claimed output
    # file actually still exists — confirmed via a real run that these
    # two can desync (something deleted the output outside this
    # pipeline, e.g. a validation script's cleanup step, while the
    # manifest still says "already done"). Trusting the DB alone caused
    # a silent skip-forever on a file whose output no longer existed.
    if not manifest.needs_processing(source_path, current_hash) and text_path.exists():
        return False  # genuinely unchanged, output still present — skip

    if dry_run:
        log.info("[dry-run] would process (%s): %s", source_type, source_path)
        return True

    try:
        result = extractor_module.extract(source_path)
    except Exception as exc:
        log.error("FAILED (%s): %s — %s", source_type, source_path, exc)
        manifest.record_failure(
            source_path=source_path,
            source_hash=current_hash,
            source_type=source_type,
            extractor=extractor_module.__name__,
            error_message=str(exc),
        )
        return True

    text_path.parent.mkdir(parents=True, exist_ok=True)
    text_path.write_text(result["text"], encoding="utf-8")

    record = {
        "source_path": str(source_path),
        "source_type": source_type,
        "processed_at": datetime.now(timezone.utc).isoformat(),
        "metadata": result["metadata"],
    }
    json_path.write_text(json.dumps(record, indent=2), encoding="utf-8")

    manifest.record_success(
        source_path=source_path,
        source_hash=current_hash,
        source_type=source_type,
        extractor=extractor_module.__name__,
        output_text_path=text_path,
        output_json_path=json_path,
    )
    log.info("OK (%s): %s -> %s", source_type, source_path, text_path)
    return True


def run(
    corpus_source: Path,
    imagery_dir: Path,
    audio_dir: Path,
    corpus_processed: Path,
    dry_run: bool = False,
) -> dict:
    manifest = Manifest(corpus_processed / "manifest.db")

    counts = {"document": 0, "image": 0, "audio": 0, "skipped": 0}

    for path in iter_candidates(corpus_source, documents.can_handle):
        touched = process_one(
            corpus_source, path, corpus_processed, "document", documents, manifest, dry_run
        )
        counts["document" if touched else "skipped"] += 1

    for path in iter_candidates(imagery_dir, images.can_handle):
        touched = process_one(
            imagery_dir, path, corpus_processed, "image", images, manifest, dry_run
        )
        counts["image" if touched else "skipped"] += 1

    for path in iter_candidates(audio_dir, audio.can_handle):
        touched = process_one(
            audio_dir, path, corpus_processed, "audio", audio, manifest, dry_run
        )
        counts["audio" if touched else "skipped"] += 1

    return counts


def main():
    parser = argparse.ArgumentParser(description="sovereign-sigint AI ingest pipeline")
    parser.add_argument("--dry-run", action="store_true", help="report only, don't process")
    parser.add_argument("--once", action="store_true", help="no-op flag for clarity in systemd unit")
    parser.add_argument("--corpus-source", type=Path, default=DEFAULT_CORPUS_SOURCE)
    parser.add_argument("--imagery-dir", type=Path, default=DEFAULT_IMAGERY_DIR)
    parser.add_argument("--audio-dir", type=Path, default=DEFAULT_AUDIO_DIR)
    parser.add_argument("--corpus-processed", type=Path, default=DEFAULT_CORPUS_PROCESSED)
    args = parser.parse_args()

    log.info("Starting ingest run (dry_run=%s)", args.dry_run)
    counts = run(
        corpus_source=args.corpus_source,
        imagery_dir=args.imagery_dir,
        audio_dir=args.audio_dir,
        corpus_processed=args.corpus_processed,
        dry_run=args.dry_run,
    )
    log.info(
        "Done. documents=%d images=%d audio=%d skipped(unchanged)=%d",
        counts["document"],
        counts["image"],
        counts["audio"],
        counts["skipped"],
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
