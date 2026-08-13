"""
title: Sovereign SIGINT Occupancy
author: sovereign-sigint
description: Query the local RF occupancy database (populated by the radiod
    producer) for signals observed on the air. Native in-process Open WebUI
    tool — the reliable path for local Ollama models, versus an external
    OpenAPI tool server.
version: 1.0.0
license: AGPL-3.0
"""
#
# WHY THIS EXISTS (native tool vs. the OpenAPI server):
#   We first exposed these tools via an external OpenAPI server
#   (openapi-tools/) and an MCP server (broken-mcp branch). Both are correct
#   and reachable, but local Ollama models in Open WebUI would not reliably
#   INVOKE external OpenAPI tools — the models described calls, denied
#   capability, or asked clarifying questions without ever executing (no
#   request reached the server). This matches Open WebUI's own guidance:
#   native in-process Python tools are the most reliable option; external
#   OpenAPI tool calling with local models is the least reliable
#   (open-webui Discussion #25737). This file is the native equivalent —
#   same read-only occupancy queries, but running inside Open WebUI so the
#   tool schema is injected the way local models reliably act on.
#
# DEPLOYMENT NOTE (important):
#   Open WebUI tools run INSIDE the Open WebUI container. This tool reads the
#   occupancy SQLite file directly, so that file must be readable from within
#   the container. Two options:
#     (a) Mount the host DB into the container (recommended), e.g. add
#         -v /home/<user>/sovereign-sigint/db:/data/sigint:ro to the
#         container run/quadlet, then set the Valve DB_PATH to
#         /data/sigint/occupancy.db
#     (b) Point DB_PATH at wherever the DB is visible inside the container.
#   The default below assumes option (a). Set it via the tool's Valves in the
#   Open WebUI UI (Workspace -> Tools -> this tool -> Valves) if different.
#   SQLite is opened with PRAGMA query_only=ON (read-only at the query level)
#   rather than mode=ro, because the DB is a LIVE WAL database and mode=ro on
#   a read-only mount cannot touch the required -wal/-shm sidecars. Use a
#   PLAIN read-write bind mount (not :ro, not :U).

import json
import sqlite3
import time
from typing import Optional

from pydantic import BaseModel, Field

ALLOWED_MODES = {"am", "usb", "lsb", "cw", "ft8", "aprs", "iq", "wfm", "nfm", "fm"}
FREQ_MIN_HZ = 1_000
FREQ_MAX_HZ = 6_000_000_000
MAX_LOOKBACK_SEC = 90 * 24 * 3600
MAX_ROWS = 200


class Tools:
    class Valves(BaseModel):
        DB_PATH: str = Field(
            default="/data/sigint/occupancy.db",
            description="Path to the occupancy SQLite DB AS SEEN FROM INSIDE "
            "the Open WebUI container. Mount the host db/ dir into the "
            "container and point this at it (e.g. /data/sigint/occupancy.db).",
        )

    def __init__(self):
        self.valves = self.Valves()
        # Show source citations in the chat for tool results.
        self.citation = True

    # -- internal helpers --------------------------------------------------
    def _ro_connect(self) -> sqlite3.Connection:
        # The occupancy DB is a LIVE WAL database — another process (the
        # radiod producer) writes it continuously. Opening with mode=ro on a
        # read-only bind mount fails, because SQLite in WAL mode must touch the
        # -wal/-shm sidecar files even to read. So we open a normal connection
        # (which needs the db DIRECTORY to be writable in the container — use a
        # plain read-write bind mount, NOT :ro and NOT :U; :U would chown the
        # host dir and break the producer's writes) and enforce read-only at
        # the QUERY level: PRAGMA query_only=ON rejects any write on this
        # connection, so we get safe, current reads of the live WAL DB without
        # modifying anything. busy_timeout lets a read wait briefly if the
        # writer holds a lock rather than erroring.
        conn = sqlite3.connect(self.valves.DB_PATH, timeout=10.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA query_only=ON")
        conn.execute("PRAGMA busy_timeout=5000")
        return conn

    # -- tool 1: query occupancy ------------------------------------------
    def query_occupancy(
        self,
        low_hz: Optional[float] = None,
        high_hz: Optional[float] = None,
        mode: Optional[str] = None,
        lookback_seconds: Optional[int] = None,
    ) -> str:
        """
        Query the local RF occupancy database for signals observed on the air,
        optionally filtered by frequency window, demodulation mode, and how
        recently they were seen. Use this to answer questions like "what has
        been active on 40 meters", "what signals are logged near 10 MHz", or
        "is WWV active". Returns logged signals with frequency, mode, sighting
        counts, and first/last-seen times.

        :param low_hz: Low frequency bound in Hz (e.g. 7000000 for 40m). Omit for no lower bound.
        :param high_hz: High frequency bound in Hz (e.g. 7300000 for 40m). Omit for no upper bound.
        :param mode: Demod mode filter (am, usb, lsb, cw, ft8, aprs, etc.). Omit for all modes.
        :param lookback_seconds: Only signals last seen within this many seconds (default 86400 = 1 day, max 90 days).
        :return: A JSON string of matching signals, or an error/empty message.
        """
        # validate
        lo = FREQ_MIN_HZ if low_hz is None else float(low_hz)
        hi = FREQ_MAX_HZ if high_hz is None else float(high_hz)
        if not (FREQ_MIN_HZ <= lo <= FREQ_MAX_HZ) or not (FREQ_MIN_HZ <= hi <= FREQ_MAX_HZ):
            return f"Error: frequency out of bounds [{FREQ_MIN_HZ}, {FREQ_MAX_HZ}] Hz."
        if lo > hi:
            return "Error: low_hz must be <= high_hz."
        m = None
        if mode:
            m = mode.strip().lower()
            if m not in ALLOWED_MODES:
                return f"Error: unknown mode '{mode}'. Allowed: {sorted(ALLOWED_MODES)}."
        lookback = 24 * 3600 if lookback_seconds is None else int(lookback_seconds)
        if lookback <= 0 or lookback > MAX_LOOKBACK_SEC:
            return f"Error: lookback_seconds must be 1..{MAX_LOOKBACK_SEC}."
        cutoff = int(time.time()) - lookback

        sql = ("SELECT frequency_hz, mode, first_seen_sec, last_seen_sec, "
               "total_sightings, candidate_sigid FROM signals "
               "WHERE frequency_hz >= ? AND frequency_hz <= ? AND last_seen_sec >= ? ")
        params: list = [lo, hi, cutoff]
        if m is not None:
            sql += "AND mode = ? "
            params.append(m)
        sql += "ORDER BY last_seen_sec DESC LIMIT ?"
        params.append(MAX_ROWS)

        try:
            with self._ro_connect() as conn:
                rows = conn.execute(sql, params).fetchall()
        except Exception as e:
            return (f"Error opening occupancy DB at '{self.valves.DB_PATH}': "
                    f"{e.__class__.__name__}: {e}. Check the DB_PATH valve and "
                    f"that the db dir is mounted into the Open WebUI container.")

        if not rows:
            return ("No signals matched. The occupancy DB is reachable but had "
                    "no signals in the requested window/frequency/mode.")

        out = [
            {
                "frequency_mhz": round(r["frequency_hz"] / 1e6, 6),
                "mode": r["mode"],
                "total_sightings": r["total_sightings"],
                "first_seen_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r["first_seen_sec"])),
                "last_seen_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r["last_seen_sec"])),
                "candidate_sigid": r["candidate_sigid"],
            }
            for r in rows
        ]
        return json.dumps({"count": len(out), "signals": out}, indent=2)

    # -- tool 2: radiod status --------------------------------------------
    def radiod_status(self) -> str:
        """
        Summarize the RF occupancy database: how many distinct signals are
        logged and the total sighting count. Use this to answer "how much has
        the system logged" or "is the occupancy database being populated".

        :return: A JSON string with signal and sighting totals, or an error.
        """
        try:
            with self._ro_connect() as conn:
                sig = conn.execute("SELECT COUNT(*) AS c FROM signals").fetchone()["c"]
                sight = conn.execute("SELECT COUNT(*) AS c FROM sightings").fetchone()["c"]
                newest = conn.execute(
                    "SELECT MAX(last_seen_sec) AS t FROM signals").fetchone()["t"]
        except Exception as e:
            return (f"Error opening occupancy DB at '{self.valves.DB_PATH}': "
                    f"{e.__class__.__name__}: {e}.")
        newest_utc = (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(newest))
                      if newest else "n/a")
        return json.dumps({
            "distinct_signals": sig,
            "total_sightings": sight,
            "most_recent_sighting_utc": newest_utc,
        }, indent=2)
