"""
ai-ingest/manifest.py

Idempotency tracking for the ingest pipeline. Each source file's content
hash is recorded once it's successfully processed; re-runs skip files
whose hash hasn't changed since the last successful run, and
re-process files whose content changed (edited/replaced) or that
previously failed.

Manifest lives at /data/corpus/processed/manifest.db — inside the
output tree deliberately, so it moves with the corpus if /data ever
migrates to a new drive (see docs/data-layout.md), rather than sitting
in a separate location that could get left behind.
"""

import hashlib
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS ingest_manifest (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source_path     TEXT UNIQUE NOT NULL,
    source_hash     TEXT NOT NULL,
    source_type     TEXT NOT NULL,   -- 'document' | 'image' | 'audio'
    extractor       TEXT NOT NULL,   -- which extractor handled it
    output_text_path TEXT,
    output_json_path TEXT,
    status          TEXT NOT NULL,   -- 'success' | 'error'
    error_message   TEXT,
    processed_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_manifest_source_path
    ON ingest_manifest(source_path);
"""


def sha256_of_file(path: Path, chunk_size: int = 1 << 20) -> str:
    """Content hash used to detect whether a source file changed since
    the last successful ingest run."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()


class Manifest:
    def __init__(self, db_path: Path):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.db_path = db_path
        with self._connect() as conn:
            conn.executescript(SCHEMA)

    @contextmanager
    def _connect(self):
        conn = sqlite3.connect(self.db_path)
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def needs_processing(self, source_path: Path, current_hash: str) -> bool:
        """True if this file hasn't been processed, its content changed
        since last time, or its last attempt failed."""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT source_hash, status FROM ingest_manifest WHERE source_path = ?",
                (str(source_path),),
            ).fetchone()
        if row is None:
            return True
        stored_hash, status = row
        return stored_hash != current_hash or status != "success"

    def record_success(
        self,
        source_path: Path,
        source_hash: str,
        source_type: str,
        extractor: str,
        output_text_path: Path,
        output_json_path: Path,
    ) -> None:
        self._upsert(
            source_path=source_path,
            source_hash=source_hash,
            source_type=source_type,
            extractor=extractor,
            output_text_path=str(output_text_path),
            output_json_path=str(output_json_path),
            status="success",
            error_message=None,
        )

    def record_failure(
        self,
        source_path: Path,
        source_hash: str,
        source_type: str,
        extractor: str,
        error_message: str,
    ) -> None:
        self._upsert(
            source_path=source_path,
            source_hash=source_hash,
            source_type=source_type,
            extractor=extractor,
            output_text_path=None,
            output_json_path=None,
            status="error",
            error_message=error_message,
        )

    def _upsert(
        self,
        source_path: Path,
        source_hash: str,
        source_type: str,
        extractor: str,
        output_text_path,
        output_json_path,
        status: str,
        error_message,
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO ingest_manifest
                    (source_path, source_hash, source_type, extractor,
                     output_text_path, output_json_path, status,
                     error_message, processed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_path) DO UPDATE SET
                    source_hash=excluded.source_hash,
                    source_type=excluded.source_type,
                    extractor=excluded.extractor,
                    output_text_path=excluded.output_text_path,
                    output_json_path=excluded.output_json_path,
                    status=excluded.status,
                    error_message=excluded.error_message,
                    processed_at=excluded.processed_at
                """,
                (
                    str(source_path),
                    source_hash,
                    source_type,
                    extractor,
                    str(output_text_path) if output_text_path else None,
                    str(output_json_path) if output_json_path else None,
                    status,
                    error_message,
                    datetime.now(timezone.utc).isoformat(),
                ),
            )

    def summary(self) -> dict:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT status, COUNT(*) FROM ingest_manifest GROUP BY status"
            ).fetchall()
        return dict(rows)
