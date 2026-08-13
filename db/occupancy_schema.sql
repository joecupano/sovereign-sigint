-- db/occupancy_schema.sql
--
-- Phase 6.6 — Occupancy DB. Adapted from kismetdb's DEVICES/PACKETS
-- split (see docs/build-order.md Phase 6.6 for the full design
-- discussion): `sightings` mirrors PACKETS (per-detection event,
-- lean columns for fast queries), `signals` mirrors DEVICES (a
-- long-lived aggregate identity layer).
--
-- Real adaptation from the reference: WiFi/BT devices have a durable
-- MAC address; most RF signals don't have an equivalent persistent
-- identifier. Substitute: aggregate on (frequency_hz, mode) instead
-- of a hardware address — see occupancy_db.py's FREQUENCY_BIN_HZ
-- for why this needs a binning strategy, not an exact-match key.
--
-- Timestamp convention: paired epoch-seconds + milliseconds fields,
-- matching kismetdb's actual design (mirrors C's tv_sec/tv_usec
-- struct timeval split) — NOT OpenWebRX+'s single combined
-- millisecond-epoch integer. Deliberate choice per discussion: keeps
-- the coarse field a clean, index-friendly integer for most queries,
-- sub-second precision available separately when needed.

CREATE TABLE IF NOT EXISTS schema_version (
    version         INTEGER NOT NULL,
    applied_at_sec  INTEGER NOT NULL
);

-- signals: aggregate per (frequency_hz bin, mode) — the DEVICES analog.
CREATE TABLE IF NOT EXISTS signals (
    signal_key      TEXT PRIMARY KEY,   -- see occupancy_db.py: make_signal_key()
    frequency_hz    REAL NOT NULL,      -- representative frequency for this bin
    mode            TEXT,               -- nullable — raw energy-only detections have no mode
    first_seen_sec  INTEGER NOT NULL,
    first_seen_ms   INTEGER NOT NULL DEFAULT 0,
    last_seen_sec   INTEGER NOT NULL,
    last_seen_ms    INTEGER NOT NULL DEFAULT 0,
    total_sightings INTEGER NOT NULL DEFAULT 0,
    candidate_sigid TEXT,               -- optional link into 6.3's SigID mirror (page title/slug)
    detail_json     TEXT                -- aggregate rollup detail, nullable
);
CREATE INDEX IF NOT EXISTS idx_signals_frequency ON signals(frequency_hz);
CREATE INDEX IF NOT EXISTS idx_signals_last_seen ON signals(last_seen_sec);

-- sightings: per-detection event — the PACKETS analog.
CREATE TABLE IF NOT EXISTS sightings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    signal_key      TEXT NOT NULL REFERENCES signals(signal_key),
    frequency_hz    REAL NOT NULL,      -- exact measured frequency, not the bin
    bandwidth_hz    REAL,               -- nullable — often unknown from MQTT-only sources
    first_seen_sec  INTEGER NOT NULL,
    first_seen_ms   INTEGER NOT NULL DEFAULT 0,
    last_seen_sec   INTEGER NOT NULL,
    last_seen_ms    INTEGER NOT NULL DEFAULT 0,
    source_type     TEXT NOT NULL,      -- 'openwebrx_mqtt' | 'gnuradio_feature_extraction' | 'radiod_capture'
    source_device   TEXT NOT NULL,      -- e.g. 'radiod/rx888-hf', 'openwebrx/hackrf'
    mode            TEXT,               -- nullable
    raw_capture_ref TEXT,               -- optional pointer into /data/signals/generated (6.5 link)
    metadata_json   TEXT                -- decoded_content / features, source-dependent, nullable
);
CREATE INDEX IF NOT EXISTS idx_sightings_signal_key ON sightings(signal_key);
CREATE INDEX IF NOT EXISTS idx_sightings_frequency ON sightings(frequency_hz);
CREATE INDEX IF NOT EXISTS idx_sightings_first_seen ON sightings(first_seen_sec);
