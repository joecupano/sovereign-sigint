"""
title: Sovereign SIGINT Kismet
author: sovereign-sigint
description: Query Kismet WiFi capture data (devices, access points, clients)
    from a kismetdb log file. Native in-process Open WebUI tool — the reliable
    path for local Ollama models — mirroring the occupancy tool. This is the
    Kismet->AI bridge: it lets the local LLM reason over captured WiFi
    devices/networks in natural language.
version: 1.0.0
license: AGPL-3.0
"""
#
# WHY kismetdb DIRECT (not the REST API):
#   Kismet logs to a .kismet SQLite file and also exposes a REST API on :2501.
#   We query the kismetdb FILE directly rather than the REST API because:
#     - Kismet is not always running (the API is only up when it is); the
#       kismetdb file is queryable anytime.
#     - The REST API requires HTTP basic auth (credentials in
#       ~/.kismet/kismet_httpd.conf); the file needs none.
#     - Reading a SQLite file read-only is the SAME proven pattern as the
#       occupancy native tool, which works reliably with local models.
#   This keeps Kismet's DEVICE-centric shape (APs, clients, MACs, signal) —
#   it is deliberately NOT flattened into the frequency-based occupancy DB.
#
# DEPLOYMENT NOTE (same as the occupancy tool):
#   Open WebUI tools run INSIDE the Open WebUI container, so the kismetdb file
#   must be visible there. Mount the directory holding the .kismet file into
#   the container (plain read-write bind mount — SQLite WAL/temp needs the dir
#   writable even for reads; the tool enforces read-only via PRAGMA
#   query_only=ON) and set the KISMETDB_PATH valve to the in-container path.
#   Example quadlet line:
#     Volume=/home/<user>:/data/kismet:ro   (see note — use rw if WAL errors)
#   then KISMETDB_PATH=/data/kismet/Kismet-<...>.kismet
#
# kismetdb schema (devices table): first_time, last_time, devkey, phyname,
#   devmac, strongest_signal, lat/lon, bytes_data, type, device (JSON BLOB).
#   The BLOB is plain JSON (kismet.device.base.*); SSID for APs lives under
#   the dot11 sub-structure.

import gzip
import json
import os
import sqlite3
import time
from typing import Optional

from pydantic import BaseModel, Field

MAX_ROWS = 200


class Tools:
    class Valves(BaseModel):
        KISMETDB_PATH: str = Field(
            default="/data/kismet/latest.kismet",
            description="Path to the .kismet SQLite log AS SEEN FROM INSIDE the "
            "Open WebUI container. Mount the directory holding it into the "
            "container and point this at it.",
        )

    def __init__(self):
        self.valves = self.Valves()
        self.citation = True

    def _ro_connect(self) -> sqlite3.Connection:
        # Live/large kismetdb: open normally + enforce read-only via pragma
        # (same approach as the occupancy tool, so a read-write mount works
        # without letting the tool modify the capture).
        #
        # Guard first: a plain sqlite3.connect() to a NONEXISTENT path silently
        # CREATES an empty DB there, which then fails later with a confusing
        # "no such table: devices". Before Phase 6 / any capture, the path
        # legitimately doesn't exist yet — detect that and raise a clear,
        # friendly message instead of littering an empty file and confusing
        # the user/model.
        path = self.valves.KISMETDB_PATH
        if not os.path.exists(path):
            raise FileNotFoundError(
                f"no Kismet capture at '{path}' yet. Start a Kismet capture "
                f"(Phase 7) and point the KISMETDB_PATH valve at the resulting "
                f".kismet file. Until then there's nothing to query."
            )
        if os.path.getsize(path) == 0:
            raise ValueError(
                f"the Kismet capture at '{path}' is empty (0 bytes) — no "
                f"devices have been recorded yet. Run a capture, then retry."
            )
        conn = sqlite3.connect(path, timeout=10.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA query_only=ON")
        conn.execute("PRAGMA busy_timeout=5000")
        # Verify this is actually a kismetdb, not some other/empty SQLite file.
        has_devices = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='devices'"
        ).fetchone()
        if not has_devices:
            conn.close()
            raise ValueError(
                f"the file at '{path}' has no 'devices' table — it doesn't look "
                f"like a Kismet capture (or the capture is empty). Confirm "
                f"KISMETDB_PATH points at a real .kismet log."
            )
        return conn

    @staticmethod
    def _blob_to_json(blob) -> dict:
        """Kismet device BLOB is JSON, occasionally gzip-compressed. Return {}
        on any failure — the flat columns are the primary data, JSON is bonus."""
        if blob is None:
            return {}
        raw = bytes(blob) if not isinstance(blob, (bytes, bytearray)) else blob
        try:
            if raw[:2] == b"\x1f\x8b":  # gzip magic
                raw = gzip.decompress(raw)
            return json.loads(raw.decode("utf-8", "ignore"))
        except Exception:
            return {}

    @staticmethod
    def _extract_ssid(dev: dict) -> Optional[str]:
        """Pull an advertised SSID from an AP's device JSON, if present."""
        try:
            d11 = dev.get("dot11.device", {})
            # Advertised SSID map — take the first non-empty SSID string.
            adv = d11.get("dot11.device.advertised_ssid_map")
            if isinstance(adv, list):
                for entry in adv:
                    s = entry.get("dot11.advertisedssid.ssid")
                    if s:
                        return s
            elif isinstance(adv, dict):
                for entry in adv.values():
                    s = entry.get("dot11.advertisedssid.ssid")
                    if s:
                        return s
            last = d11.get("dot11.device.last_beaconed_ssid_record", {})
            if isinstance(last, dict):
                s = last.get("dot11.advertisedssid.ssid")
                if s:
                    return s
        except Exception:
            pass
        return None

    @staticmethod
    def _manufacturer(dev: dict) -> Optional[str]:
        try:
            m = dev.get("kismet.device.base.manuf")
            return m or None
        except Exception:
            return None

    # -- tool 1: query WiFi devices ---------------------------------------
    def query_wifi_devices(
        self,
        device_type: Optional[str] = None,
        min_signal_dbm: Optional[int] = None,
        limit: Optional[int] = None,
    ) -> str:
        """
        List WiFi devices Kismet captured, optionally filtered by type and
        signal strength. Use for questions like "what access points were
        seen", "list the wifi clients", or "what were the strongest devices".
        Returns MAC, type, signal (dBm), SSID (for APs), manufacturer, and
        first/last-seen times.

        :param device_type: Filter by type substring — e.g. "AP", "Client", "Bridged". Omit for all.
        :param min_signal_dbm: Only devices whose strongest signal is >= this (dBm, e.g. -60). Signals are negative; higher (closer to 0) is stronger. Omit for all.
        :param limit: Max devices to return (default/max 200).
        :return: A JSON string of matching devices, or an error/empty message.
        """
        n = MAX_ROWS if limit is None else max(1, min(int(limit), MAX_ROWS))
        sql = ("SELECT first_time, last_time, devmac, phyname, type, "
               "strongest_signal, bytes_data, device FROM devices WHERE 1=1 ")
        params: list = []
        if device_type:
            sql += "AND type LIKE ? "
            params.append(f"%{device_type}%")
        if min_signal_dbm is not None:
            # strongest_signal 0 usually means 'unknown' — exclude when filtering.
            sql += "AND strongest_signal >= ? AND strongest_signal != 0 "
            params.append(int(min_signal_dbm))
        sql += "ORDER BY strongest_signal DESC LIMIT ?"
        params.append(n)

        try:
            with self._ro_connect() as conn:
                rows = conn.execute(sql, params).fetchall()
        except Exception as e:
            return (f"Error opening kismetdb at '{self.valves.KISMETDB_PATH}': "
                    f"{e.__class__.__name__}: {e}. Check the KISMETDB_PATH valve "
                    f"and that the file's directory is mounted into the container.")

        if not rows:
            return "No devices matched the filter in the kismetdb."

        out = []
        for r in rows:
            dev = self._blob_to_json(r["device"])
            out.append({
                "mac": r["devmac"],
                "type": r["type"],
                "phy": r["phyname"],
                "strongest_signal_dbm": r["strongest_signal"],
                "ssid": self._extract_ssid(dev),
                "manufacturer": self._manufacturer(dev),
                "bytes_data": r["bytes_data"],
                "first_seen_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r["first_time"])),
                "last_seen_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r["last_time"])),
            })
        return json.dumps({"count": len(out), "devices": out}, indent=2)

    # -- tool 2: kismet capture summary -----------------------------------
    def kismet_summary(self) -> str:
        """
        Summarize the Kismet WiFi capture: how many devices by type, the
        capture time range, and the strongest devices. Use for "how much did
        Kismet capture", "what's in the wifi capture", or "summarize the
        kismet data".

        :return: A JSON string summary, or an error.
        """
        try:
            with self._ro_connect() as conn:
                total = conn.execute("SELECT COUNT(*) AS c FROM devices").fetchone()["c"]
                by_type = conn.execute(
                    "SELECT type, COUNT(*) AS c FROM devices GROUP BY type "
                    "ORDER BY c DESC").fetchall()
                span = conn.execute(
                    "SELECT MIN(first_time) AS mn, MAX(last_time) AS mx "
                    "FROM devices").fetchone()
                phys = conn.execute(
                    "SELECT phyname, COUNT(*) AS c FROM devices GROUP BY phyname"
                ).fetchall()
        except Exception as e:
            return (f"Error opening kismetdb at '{self.valves.KISMETDB_PATH}': "
                    f"{e.__class__.__name__}: {e}.")

        def utc(t):
            return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if t else "n/a"

        return json.dumps({
            "total_devices": total,
            "by_type": {r["type"]: r["c"] for r in by_type},
            "by_phy": {r["phyname"]: r["c"] for r in phys},
            "capture_start_utc": utc(span["mn"]),
            "capture_end_utc": utc(span["mx"]),
        }, indent=2)
