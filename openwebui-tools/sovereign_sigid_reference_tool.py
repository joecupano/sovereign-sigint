"""
title: Sovereign SIGINT SigID Reference
author: sovereign-sigint
description: Look up signals in the local SigID (sigidwiki) reference mirror —
    by name, frequency, or characteristics. Native in-process Open WebUI tool,
    the third AI data source, giving the local LLM an authoritative signal
    reference catalog to pair with live occupancy and Kismet data.
version: 1.0.0
license: AGPL-3.0
"""
#
# THE THIRD AI SOURCE — reference, not observation:
#   occupancy = what frequencies are active (our own capture)
#   kismet    = what WiFi devices are present (our own capture)
#   sigid     = what signals ARE — the reference catalog to identify them
#
#   This mirrors the occupancy/kismet native-tool pattern, but the SigID data
#   is NOT a single SQLite file. The Phase 6.3 mirror stores one JSON per wiki
#   page under /data/reference/sigid/metadata/<title>.json, each containing the
#   page's MediaWiki `wikitext`. Real signal pages carry a structured infobox:
#     {{Unidentified Signal |Frequencies=6115 kHz |Mode=AM |Modulation=8PSK
#      |Bandwidth=7 kHz |Location=... |Signal description=...}}
#   Many pages (~150 of ~500) are #REDIRECT stubs — skipped. This tool parses
#   the infobox into fields so the model can do name lookup, keyword search,
#   and (best-effort) frequency-range search.
#
# DEPLOYMENT (like the occupancy/kismet tools):
#   The tool runs inside the Open WebUI container, so the SigID metadata dir
#   must be mounted in. Add to the quadlet, e.g.:
#     Volume=/data/reference/sigid:/data/sigid-ref:ro
#   (:ro is fine — the tool only reads; the mirror timer writes on the host.)
#   Then set the SIGID_METADATA_DIR valve to /data/sigid-ref/metadata.
#
# PERFORMANCE: ~350 small JSON files. The tool builds a light in-memory index
#   once per call (parse infoboxes), which is fast enough at this scale. If the
#   catalog grows large, this is the point to switch to a prebuilt SQLite index.

import glob
import json
import os
import re
from typing import Optional

from pydantic import BaseModel, Field

MAX_RESULTS = 50

# Infobox fields we lift out of the wikitext.
_FIELD_KEYS = ["Title", "Frequencies", "Mode", "Modulation", "Bandwidth",
               "Location", "Signal description", "Additional categories"]


def _parse_infobox(wikitext: str) -> dict:
    """Pull |Key=Value pairs out of the {{...Signal...}} infobox. Best-effort:
    the wiki markup is human-entered and irregular, so missing fields are fine."""
    fields = {}
    for key in _FIELD_KEYS:
        # Match |Key = value  up to the next | that begins a field or the }} end.
        m = re.search(r"\|\s*" + re.escape(key) + r"\s*=\s*(.*?)(?=\n\s*\||\}\})",
                      wikitext, re.IGNORECASE | re.DOTALL)
        if m:
            val = m.group(1).strip()
            # Strip simple wiki markup noise.
            val = re.sub(r"\[\[([^\]|]+)\|?[^\]]*\]\]", r"\1", val)  # [[link|txt]]
            val = re.sub(r"'''?", "", val)                            # bold/italic
            if val:
                fields[key] = val
    return fields


def _extract_freqs_hz(freq_str: str) -> list:
    """Best-effort parse of the Frequencies field into Hz values for range
    search. Handles kHz/MHz/GHz; returns [] if nothing parseable."""
    out = []
    if not freq_str:
        return out
    for m in re.finditer(r"([\d.,]+)\s*(k|M|G)?Hz", freq_str, re.IGNORECASE):
        num = m.group(1).replace(",", "")
        try:
            v = float(num)
        except ValueError:
            continue
        unit = (m.group(2) or "").lower()
        mult = {"k": 1e3, "m": 1e6, "g": 1e9, "": 1.0}[unit]
        out.append(v * mult)
    return out


class Tools:
    class Valves(BaseModel):
        SIGID_METADATA_DIR: str = Field(
            default="/data/sigid-ref/metadata",
            description="Directory of SigID mirror metadata JSON files AS SEEN "
            "FROM INSIDE the Open WebUI container. Mount the mirror's metadata "
            "dir in and point this at it.",
        )

    def __init__(self):
        self.valves = self.Valves()
        self.citation = True

    def _load_signals(self) -> list:
        """Load + parse all non-redirect signal pages into dicts. Returns a
        list of {title, fields, freqs_hz, wikitext}."""
        signals = []
        pattern = os.path.join(self.valves.SIGID_METADATA_DIR, "*.json")
        for path in glob.glob(pattern):
            try:
                d = json.load(open(path, encoding="utf-8"))
            except Exception:
                continue
            wt = d.get("wikitext", "") or ""
            if wt.strip().upper().startswith("#REDIRECT"):
                continue
            if "Signal" not in wt and "|Frequencies" not in wt:
                # Not a signal infobox page (talk/category/etc.)
                continue
            fields = _parse_infobox(wt)
            title = fields.get("Title") or d.get("title", os.path.basename(path))
            signals.append({
                "title": title,
                "fields": fields,
                "freqs_hz": _extract_freqs_hz(fields.get("Frequencies", "")),
                "wikitext": wt,
            })
        return signals

    @staticmethod
    def _format(sig: dict) -> dict:
        f = sig["fields"]
        return {
            "title": sig["title"],
            "frequencies": f.get("Frequencies"),
            "mode": f.get("Mode"),
            "modulation": f.get("Modulation"),
            "bandwidth": f.get("Bandwidth"),
            "location": f.get("Location"),
            "description": f.get("Signal description"),
        }

    # -- tool 1: look up a signal by name ---------------------------------
    def lookup_signal(self, name: str) -> str:
        """
        Look up a signal in the SigID reference catalog by name or title (e.g.
        "OTH Radar", "LoRa", "STANAG 4285", "10-tone signal"). Returns the
        signal's known characteristics — frequencies, mode, modulation,
        bandwidth, location, and description — from the local sigidwiki mirror.
        Use when the user asks "what is <signal>" or "tell me about <signal>".

        :param name: The signal name or a distinctive part of it (case-insensitive substring match).
        :return: A JSON string with the matching signal(s)' details, or a not-found message.
        """
        if not name or not name.strip():
            return "Error: provide a signal name to look up."
        q = name.strip().lower()
        try:
            signals = self._load_signals()
        except Exception as e:
            return (f"Error reading SigID mirror at "
                    f"'{self.valves.SIGID_METADATA_DIR}': {e.__class__.__name__}: {e}. "
                    f"Check the valve and that the mirror dir is mounted in.")
        exact = [s for s in signals if q == s["title"].lower()]
        partial = [s for s in signals if q in s["title"].lower() and s not in exact]
        hits = (exact + partial)[:MAX_RESULTS]
        if not hits:
            return (f"No signal named like '{name}' found in the SigID mirror "
                    f"({len(signals)} catalog entries searched).")
        return json.dumps({"count": len(hits),
                           "signals": [self._format(s) for s in hits]}, indent=2)

    # -- tool 2: search signals by characteristic -------------------------
    def search_signals(
        self,
        keyword: Optional[str] = None,
        near_frequency_hz: Optional[float] = None,
        tolerance_hz: Optional[float] = None,
    ) -> str:
        """
        Search the SigID reference catalog by keyword and/or frequency. Use for
        "what signals use 8PSK", "what's known around 6 MHz", or "find military
        HF signals". Keyword matches the description/mode/modulation text;
        frequency matches signals documented near that frequency.

        :param keyword: Text to match in mode, modulation, location, or description (case-insensitive). Omit to match all.
        :param near_frequency_hz: Center frequency in Hz to search near (e.g. 6115000 for 6115 kHz). Omit to skip frequency filtering.
        :param tolerance_hz: How far from near_frequency_hz counts as a match (default 100000 = 100 kHz).
        :return: A JSON string of matching signals, or a not-found message.
        """
        try:
            signals = self._load_signals()
        except Exception as e:
            return (f"Error reading SigID mirror at "
                    f"'{self.valves.SIGID_METADATA_DIR}': {e.__class__.__name__}: {e}.")

        kw = keyword.strip().lower() if keyword else None
        tol = 100_000.0 if tolerance_hz is None else float(tolerance_hz)
        hits = []
        for s in signals:
            if kw:
                hay = " ".join([
                    s["fields"].get("Mode", ""), s["fields"].get("Modulation", ""),
                    s["fields"].get("Location", ""), s["fields"].get("Signal description", ""),
                    s["fields"].get("Additional categories", ""),
                ]).lower()
                if kw not in hay:
                    continue
            if near_frequency_hz is not None:
                if not any(abs(f - float(near_frequency_hz)) <= tol for f in s["freqs_hz"]):
                    continue
            hits.append(s)
            if len(hits) >= MAX_RESULTS:
                break
        if not hits:
            return "No signals matched those criteria in the SigID mirror."
        return json.dumps({"count": len(hits),
                           "signals": [self._format(s) for s in hits]}, indent=2)
