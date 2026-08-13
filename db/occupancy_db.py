"""
db/occupancy_db.py

Phase 6.6 — Occupancy DB access layer. Applies db/occupancy_schema.sql
on init (same pattern as ai-ingest/manifest.py and
reference/sigid_manifest.py), and provides record_sighting() as the
single write path every ingestion source (OpenWebRX+ MQTT subscriber,
GNU Radio feature extraction, radiod capture pipeline — none built yet)
would call into.

Not wired to any producer yet — this is the schema + access layer only,
per the current build-order.md Phase 6.6 status.
"""

import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_PATH = Path(__file__).parent / "occupancy_schema.sql"
CURRENT_SCHEMA_VERSION = 1

# UNRESOLVED, flagged rather than guessed: what frequency bin size
# correctly aggregates "the same signal" into one `signals` row across
# repeated sightings, given real oscillator drift, measurement
# rounding, and simply not being bit-exact between sources. A fixed
# 1 kHz bin is a reasonable placeholder for narrowband HF/VHF/UHF
# (ham, APRS, pagers) but is almost certainly wrong at the extremes —
# too coarse for tightly-packed HF CW/digital channels, too fine for
# something like a 20 MHz WiFi channel or a LoRa 125 kHz channel, where
# "same signal, slightly different reported center" should still
# collapse to one row. Revisit once real sighting data shows how much
# this actually matters — don't tune blind.
FREQUENCY_BIN_HZ = 1000


def make_signal_key(frequency_hz: float, mode: str | None) -> str:
    """The signals-table aggregation key — frequency (binned) + mode,
    substituting for the durable per-emitter identity Kismet gets for
    free from a MAC address, which RF signals don't generally have.
    """
    binned = round(frequency_hz / FREQUENCY_BIN_HZ) * FREQUENCY_BIN_HZ
    mode_part = mode if mode else "unknown"
    return f"{int(binned)}:{mode_part}"


def _now_sec_ms() -> tuple[int, int]:
    """Paired epoch-seconds + milliseconds, matching kismetdb's actual
    timestamp convention (tv_sec/tv_usec split) rather than a single
    combined millisecond-epoch integer."""
    now = datetime.now(timezone.utc)
    sec = int(now.timestamp())
    ms = now.microsecond // 1000
    return sec, ms


class OccupancyDB:
    def __init__(self, db_path: Path):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.db_path = db_path
        with self._connect() as conn:
            conn.executescript(SCHEMA_PATH.read_text())
            row = conn.execute("SELECT MAX(version) FROM schema_version").fetchone()
            if row[0] is None:
                sec, _ = _now_sec_ms()
                conn.execute(
                    "INSERT INTO schema_version (version, applied_at_sec) VALUES (?, ?)",
                    (CURRENT_SCHEMA_VERSION, sec),
                )

    @contextmanager
    def _connect(self):
        # timeout= makes a blocked writer wait up to N seconds for the
        # lock instead of raising SQLITE_BUSY immediately — needed because
        # multiple occupancy producers (RTL-SDR, HackRF, RX-888/radiod)
        # may write concurrently.
        conn = sqlite3.connect(self.db_path, timeout=30.0)
        try:
            # WAL: readers and a single writer proceed concurrently, and
            # write lock windows are short. This is what makes several
            # producers writing to one DB robust rather than contended.
            # Set once per connection; harmless if already in WAL.
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")  # safe with WAL, faster
            conn.execute("PRAGMA busy_timeout=30000")  # 30s, matches timeout=
            yield conn
            conn.commit()
        finally:
            conn.close()

    def record_sighting(
        self,
        frequency_hz: float,
        source_type: str,
        source_device: str,
        bandwidth_hz: float = None,
        mode: str = None,
        raw_capture_ref: str = None,
        metadata_json: str = None,
        first_seen_sec: int = None,
        first_seen_ms: int = None,
        last_seen_sec: int = None,
        last_seen_ms: int = None,
    ) -> str:
        """Record one detection event and upsert the aggregate signals
        row. Returns the signal_key. Timestamps default to now if not
        supplied — callers with their own event timestamps (e.g. from
        an MQTT payload) should pass them explicitly rather than rely
        on ingestion-time defaults.
        """
        now_sec, now_ms = _now_sec_ms()
        first_seen_sec = first_seen_sec if first_seen_sec is not None else now_sec
        first_seen_ms = first_seen_ms if first_seen_ms is not None else now_ms
        last_seen_sec = last_seen_sec if last_seen_sec is not None else now_sec
        last_seen_ms = last_seen_ms if last_seen_ms is not None else now_ms

        signal_key = make_signal_key(frequency_hz, mode)

        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO sightings
                    (signal_key, frequency_hz, bandwidth_hz,
                     first_seen_sec, first_seen_ms, last_seen_sec, last_seen_ms,
                     source_type, source_device, mode, raw_capture_ref, metadata_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    signal_key, frequency_hz, bandwidth_hz,
                    first_seen_sec, first_seen_ms, last_seen_sec, last_seen_ms,
                    source_type, source_device, mode, raw_capture_ref, metadata_json,
                ),
            )

            existing = conn.execute(
                "SELECT first_seen_sec, total_sightings FROM signals WHERE signal_key = ?",
                (signal_key,),
            ).fetchone()

            if existing is None:
                conn.execute(
                    """
                    INSERT INTO signals
                        (signal_key, frequency_hz, mode,
                         first_seen_sec, first_seen_ms, last_seen_sec, last_seen_ms,
                         total_sightings)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                    (signal_key, frequency_hz, mode,
                     first_seen_sec, first_seen_ms, last_seen_sec, last_seen_ms),
                )
            else:
                conn.execute(
                    """
                    UPDATE signals
                    SET last_seen_sec = ?, last_seen_ms = ?,
                        total_sightings = total_sightings + 1
                    WHERE signal_key = ?
                    """,
                    (last_seen_sec, last_seen_ms, signal_key),
                )

        return signal_key

    def get_signal(self, signal_key: str) -> dict | None:
        with self._connect() as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT * FROM signals WHERE signal_key = ?", (signal_key,)
            ).fetchone()
        return dict(row) if row else None

    def get_sightings(self, signal_key: str) -> list[dict]:
        with self._connect() as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT * FROM sightings WHERE signal_key = ? ORDER BY first_seen_sec",
                (signal_key,),
            ).fetchall()
        return [dict(r) for r in rows]
