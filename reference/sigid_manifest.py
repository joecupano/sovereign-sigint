"""
reference/sigid_manifest.py

State tracking for the SigID mirror (sigid_mirror.py). Two things get
tracked, both needed for a re-run to only fetch what's actually new or
changed rather than re-pulling the whole wiki every time:

  - per-page: the last MediaWiki revision ID successfully synced
  - per-file (image/audio): a content hash of what's already downloaded

Manifest lives inside the mirror's own output tree
(/data/reference/sigid/manifest.db) deliberately, same reasoning as
ai-ingest/manifest.py — it moves with the data if /data ever migrates.
"""

import hashlib
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS page_sync (
    page_title      TEXT PRIMARY KEY,
    last_revision_id INTEGER NOT NULL,
    synced_at       TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS file_sync (
    file_url        TEXT PRIMARY KEY,
    content_hash    TEXT NOT NULL,
    local_path      TEXT NOT NULL,
    synced_at       TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sync_runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at      TEXT NOT NULL,
    finished_at     TEXT,
    mode            TEXT NOT NULL,  -- 'api' or 'archive_bootstrap'
    pages_synced    INTEGER DEFAULT 0,
    files_synced    INTEGER DEFAULT 0,
    status          TEXT,           -- 'success' | 'error'
    error_message   TEXT
);
"""


def sha256_of_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class SigidManifest:
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

    def last_page_revision(self, page_title: str) -> int | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT last_revision_id FROM page_sync WHERE page_title = ?",
                (page_title,),
            ).fetchone()
        return row[0] if row else None

    def record_page_synced(self, page_title: str, revision_id: int) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO page_sync (page_title, last_revision_id, synced_at)
                VALUES (?, ?, ?)
                ON CONFLICT(page_title) DO UPDATE SET
                    last_revision_id=excluded.last_revision_id,
                    synced_at=excluded.synced_at
                """,
                (page_title, revision_id, datetime.now(timezone.utc).isoformat()),
            )

    def file_needs_download(self, file_url: str, content_hash: str) -> bool:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT content_hash FROM file_sync WHERE file_url = ?",
                (file_url,),
            ).fetchone()
        return row is None or row[0] != content_hash

    def record_file_synced(self, file_url: str, content_hash: str, local_path: Path) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO file_sync (file_url, content_hash, local_path, synced_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(file_url) DO UPDATE SET
                    content_hash=excluded.content_hash,
                    local_path=excluded.local_path,
                    synced_at=excluded.synced_at
                """,
                (file_url, content_hash, str(local_path), datetime.now(timezone.utc).isoformat()),
            )

    def start_run(self, mode: str) -> int:
        with self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO sync_runs (started_at, mode, status) VALUES (?, ?, 'running')",
                (datetime.now(timezone.utc).isoformat(), mode),
            )
            return cur.lastrowid

    def finish_run(self, run_id: int, pages_synced: int, files_synced: int, status: str, error_message: str = None) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE sync_runs
                SET finished_at = ?, pages_synced = ?, files_synced = ?,
                    status = ?, error_message = ?
                WHERE id = ?
                """,
                (
                    datetime.now(timezone.utc).isoformat(),
                    pages_synced,
                    files_synced,
                    status,
                    error_message,
                    run_id,
                ),
            )

    def last_successful_run_time(self) -> str | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT started_at FROM sync_runs WHERE status = 'success' ORDER BY id DESC LIMIT 1"
            ).fetchone()
        return row[0] if row else None
