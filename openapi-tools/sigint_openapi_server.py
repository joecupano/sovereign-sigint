#!/usr/bin/env python3
"""
sigint_openapi_server.py — read-only SIGINT tools exposed to Open WebUI as
an OpenAPI tool server.

WHY THIS EXISTS (and its relationship to the MCP server):
  The functionally-identical MCP version of these tools lives on the
  `broken-mcp` branch. It is correct and works, but Open WebUI's NATIVE MCP
  client cannot reach it: during tool validation Open WebUI sends
  `Accept: application/json` on its GET /mcp request, omitting the
  spec-required `text/event-stream`, so any spec-compliant MCP server
  (including our fastmcp one) correctly returns HTTP 406 Not Acceptable and
  the tools never load. This is a documented, client-side Open WebUI bug:
    - open-webui/open-webui Discussion #19568 ("MCP Tool Validation Fails
      Due to Missing 'text/event-stream' Accept Header")
    - open-webui/open-webui Issue #19525 / Discussion #19530
  The same MCP server works fine with other clients (Claude, Goose), which
  confirms the fault is Open WebUI's MCP client, not the server.

  Open WebUI's OPENAPI tool path is unaffected by that bug. So rather than
  run our MCP server plus an MCPO proxy in front of it (two processes, purely
  to dodge the broken MCP client), we expose the same tools directly as a
  single OpenAPI server. One process, no proxy, uses the path that works.

  If/when Open WebUI fixes its MCP client, migrating back to the MCP server
  is straightforward — see docs/openapi-to-mcp-migration.md. The tool logic
  here is deliberately kept identical to the MCP version so the switch is a
  transport change, not a rewrite.

SECURITY (same posture as the MCP server — see
docs/mcp-server-security-requirements.md, which governs these tools too):
  - Read-only: opens SQLite mode=ro; no endpoint writes anything.
  - Validated params: modes allowlisted, frequencies/lookback range-checked,
    results capped; all SQL parameterized.
  - Loopback bind by default (SIGINT_OPENAPI_HOST); cover with ufw. On a box
    where Open WebUI's container reaches the host at its LAN IP, bind
    0.0.0.0 and rely on ufw default-deny (the Ollama posture).
  - No side effects: these are queries. The blast radius if reached is
    "read occupancy data."

USAGE:
  uvicorn sigint_openapi_server:app --host 127.0.0.1 --port 8130
  # or run this file directly (reads SIGINT_OPENAPI_HOST / _PORT):
  python3 sigint_openapi_server.py
"""
from __future__ import annotations

import math
import os
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# --- configuration (identical to the MCP version) ------------------------
_REPO_ROOT = Path(__file__).resolve().parents[1]
_DEFAULT_DB = _REPO_ROOT / "db" / "occupancy.db"
OCCUPANCY_DB = Path(os.environ.get("SIGINT_OCCUPANCY_DB", str(_DEFAULT_DB)))
RADIOD_INSTANCE = "rx888-hf"
RADIOD_CONF_REPO = _REPO_ROOT / "ingest" / "ka9q-radio" / f"radiod@{RADIOD_INSTANCE}.conf"

ALLOWED_MODES = {"am", "usb", "lsb", "cw", "ft8", "aprs", "iq", "wfm", "nfm", "fm"}
FREQ_MIN_HZ = 1_000
FREQ_MAX_HZ = 6_000_000_000
MAX_LOOKBACK_SEC = 90 * 24 * 3600
MAX_ROWS = 200

app = FastAPI(
    title="Sovereign SIGINT Tools",
    description="Read-only occupancy and radiod-status tools for local AI. "
    "Same tools as the MCP server on the broken-mcp branch, exposed as "
    "OpenAPI because Open WebUI's native MCP client is currently broken "
    "(see module docstring).",
    version="1.0.0",
)

# CORS: Open WebUI validates the tool-server URL from the BROWSER, which
# issues a cross-origin OPTIONS preflight before the real request. Without
# this middleware FastAPI returns 405 to OPTIONS and the browser blocks the
# request, surfacing as "connection failed" in Open WebUI. Allowing origins
# lets the preflight succeed. These tools are read-only and the port is
# ufw-scoped to the LAN, so permissive CORS here does not widen the real
# attack surface (worst case remains: read occupancy data). Narrow
# allow_origins to the Open WebUI origin if you prefer.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


# --- helpers (ported verbatim from the MCP server) -----------------------
def _ro_connect() -> sqlite3.Connection:
    if not OCCUPANCY_DB.exists():
        raise HTTPException(status_code=503,
                            detail=f"occupancy DB not found at {OCCUPANCY_DB}")
    conn = sqlite3.connect(f"file:{OCCUPANCY_DB}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def _validate_mode(mode: Optional[str]) -> Optional[str]:
    if mode is None or mode == "":
        return None
    m = mode.strip().lower()
    if m not in ALLOWED_MODES:
        raise HTTPException(status_code=422,
                            detail=f"unknown mode '{mode}'. Allowed: {sorted(ALLOWED_MODES)}")
    return m


def _validate_freq_range(low_hz: Optional[float], high_hz: Optional[float]) -> tuple[float, float]:
    lo = FREQ_MIN_HZ if low_hz is None else float(low_hz)
    hi = FREQ_MAX_HZ if high_hz is None else float(high_hz)
    if not (FREQ_MIN_HZ <= lo <= FREQ_MAX_HZ) or not (FREQ_MIN_HZ <= hi <= FREQ_MAX_HZ):
        raise HTTPException(status_code=422,
                            detail=f"frequency out of bounds [{FREQ_MIN_HZ}, {FREQ_MAX_HZ}] Hz")
    if lo > hi:
        raise HTTPException(status_code=422, detail="low_hz must be <= high_hz")
    return lo, hi


def _validate_lookback(seconds: Optional[int]) -> int:
    if seconds is None:
        return 24 * 3600
    s = int(seconds)
    if s <= 0:
        raise HTTPException(status_code=422, detail="lookback_seconds must be positive")
    if s > MAX_LOOKBACK_SEC:
        raise HTTPException(status_code=422,
                            detail=f"lookback_seconds exceeds cap ({MAX_LOOKBACK_SEC})")
    return s


# --- response models (give Open WebUI a clean OpenAPI schema) ------------
class SignalRow(BaseModel):
    frequency_hz: float
    frequency_mhz: float
    mode: Optional[str]
    first_seen_utc: str
    last_seen_utc: str
    total_sightings: int
    candidate_sigid: Optional[str]


class OccupancyResponse(BaseModel):
    count: int
    signals: list[SignalRow]


# --- tool 1: query_occupancy ---------------------------------------------
@app.get("/query_occupancy", operation_id="query_occupancy", response_model=OccupancyResponse,
         summary="Query logged RF occupancy",
         description="Query the local occupancy database for signals observed on the air, "
                     "filtered by frequency window, mode, and recency. Read-only.")
def query_occupancy(
    low_hz: Optional[float] = Query(None, description="Low frequency bound in Hz (e.g. 7000000 for 40m)"),
    high_hz: Optional[float] = Query(None, description="High frequency bound in Hz (e.g. 7300000 for 40m)"),
    mode: Optional[str] = Query(None, description="Demod mode filter: am, usb, lsb, cw, ft8, aprs, etc."),
    lookback_seconds: Optional[int] = Query(None, description="Only signals last seen within this many seconds (default 86400, max 90 days)"),
    limit: Optional[int] = Query(None, description="Max rows (default/max 200)"),
) -> OccupancyResponse:
    lo, hi = _validate_freq_range(low_hz, high_hz)
    m = _validate_mode(mode)
    lookback = _validate_lookback(lookback_seconds)
    n = MAX_ROWS if limit is None else max(1, min(int(limit), MAX_ROWS))
    cutoff = int(time.time()) - lookback

    sql = ("SELECT frequency_hz, mode, first_seen_sec, last_seen_sec, "
           "total_sightings, candidate_sigid FROM signals "
           "WHERE frequency_hz >= ? AND frequency_hz <= ? AND last_seen_sec >= ? ")
    params: list = [lo, hi, cutoff]
    if m is not None:
        sql += "AND mode = ? "
        params.append(m)
    sql += "ORDER BY last_seen_sec DESC LIMIT ?"
    params.append(n)

    with _ro_connect() as conn:
        rows = conn.execute(sql, params).fetchall()

    signals = [
        SignalRow(
            frequency_hz=r["frequency_hz"],
            frequency_mhz=round(r["frequency_hz"] / 1e6, 6),
            mode=r["mode"],
            first_seen_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r["first_seen_sec"])),
            last_seen_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r["last_seen_sec"])),
            total_sightings=r["total_sightings"],
            candidate_sigid=r["candidate_sigid"],
        )
        for r in rows
    ]
    return OccupancyResponse(count=len(signals), signals=signals)


# --- tool 2: lookup_signal_candidate -------------------------------------
@app.get("/lookup_signal_candidate", operation_id="lookup_signal_candidate",
         summary="Candidate SigID for logged signals",
         description="For signals logged in a frequency window, return any candidate SigID "
                     "identification already recorded. Does NOT classify from scratch; for "
                     "open-ended signal ID use the SigID reference knowledge base. Read-only.")
def lookup_signal_candidate(
    low_hz: float = Query(..., description="Low frequency bound in Hz (required)"),
    high_hz: float = Query(..., description="High frequency bound in Hz (required)"),
) -> dict:
    lo, hi = _validate_freq_range(low_hz, high_hz)
    sql = ("SELECT frequency_hz, mode, candidate_sigid, total_sightings, last_seen_sec "
           "FROM signals WHERE frequency_hz >= ? AND frequency_hz <= ? "
           "AND candidate_sigid IS NOT NULL ORDER BY total_sightings DESC LIMIT ?")
    with _ro_connect() as conn:
        rows = conn.execute(sql, [lo, hi, MAX_ROWS]).fetchall()
    candidates = [
        {
            "frequency_mhz": round(r["frequency_hz"] / 1e6, 6),
            "mode": r["mode"],
            "candidate_sigid": r["candidate_sigid"],
            "total_sightings": r["total_sightings"],
            "last_seen_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r["last_seen_sec"])),
        }
        for r in rows
    ]
    return {
        "count": len(candidates),
        "note": "Candidate IDs recorded for LOGGED signals. For general signal ID, "
                "consult the SigID reference knowledge base.",
        "candidates": candidates,
    }


# --- tool 3: radiod_status -----------------------------------------------
@app.get("/radiod_status", operation_id="radiod_status",
         summary="radiod service status and channels",
         description="Report whether the radiod HF ingest service is active and which "
                     "demodulator channels it is configured to run. Read-only.")
def radiod_status() -> dict:
    try:
        proc = subprocess.run(
            ["systemctl", "is-active", f"radiod@{RADIOD_INSTANCE}"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        active_state = proc.stdout.strip() or "unknown"
    except Exception as e:  # pragma: no cover
        active_state = f"error: {e.__class__.__name__}"

    channels: list[str] = []
    if RADIOD_CONF_REPO.exists():
        for line in RADIOD_CONF_REPO.read_text().splitlines():
            s = line.strip()
            if s.startswith("[") and s.endswith("]"):
                name = s[1:-1].strip()
                if name.lower() not in ("global", "hardware", "rx888"):
                    channels.append(name)

    return {
        "service": f"radiod@{RADIOD_INSTANCE}",
        "active": active_state,
        "configured_channels": channels,
        "channel_count": len(channels),
        "note": "If active is 'inactive', the RX-888 may be handed to OpenWebRX+ "
                "(interactive mode) — see rx888-mode.sh.",
    }


if __name__ == "__main__":
    import uvicorn
    host = os.environ.get("SIGINT_OPENAPI_HOST", "127.0.0.1")
    port = int(os.environ.get("SIGINT_OPENAPI_PORT", "8130"))
    uvicorn.run(app, host=host, port=port)
