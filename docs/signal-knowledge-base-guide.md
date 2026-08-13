# Building a Signal Reference Knowledge Base

Applies the same RAG pattern from
`docs/rag-knowledge-base-guide.md` to this build's **own** SIGINT
data — the occupancy database (Phase 6.6) and SigID mirror (Phase
6.3) — instead of an external corpus, so `qwen3:14b` can answer
natural-language questions grounded in what your own hardware has
actually observed.

## Honest Scope Note — Read This First

This guide builds a **snapshot RAG export** — the knowledge base is only as
current as the last time you ran the export script below. When it was
written, the live alternative (an Open WebUI Tool querying the data directly
on every question) was future work. **That live bridge now exists**, for both
data sources this guide covers:

- **Occupancy** — `openwebui-tools/sovereign_sigint_occupancy_tool.py` queries
  the occupancy DB live (see `docs/db-to-ai-query-path.md`).
- **SigID reference** — `openwebui-tools/sovereign_sigid_reference_tool.py`
  looks up signals in the SigID mirror live (`lookup_signal`,
  `search_signals`).

So for most uses, prefer the **live native tools** — they answer from current
data with no re-export. This RAG-export guide remains useful when you want the
data in Open WebUI's Knowledge feature specifically (e.g. blended into broader
document RAG, or semantic search over descriptions rather than structured
lookup). Treat it as the snapshot/RAG alternative to the live tools, not the
only path.

## Step 1: Export Occupancy Data to Readable Text

`occupancy_db.py` has zero dependencies beyond the standard library —
this export script needs nothing installed beyond what's already there:

```python
#!/usr/bin/env python3
"""Export occupancy_db.py's signals + sightings into readable markdown
for RAG ingestion — a snapshot, not a live feed. Re-run this whenever
you want the knowledge base refreshed with newer occupancy data."""

import sys
from pathlib import Path
from datetime import datetime, timezone

# Adjust if your clone lives somewhere other than ~/sovereign-sigint
REPO_ROOT = Path.home() / "sovereign-sigint"
sys.path.insert(0, str(REPO_ROOT / "db"))
from occupancy_db import OccupancyDB

DB_PATH = REPO_ROOT / "db" / "occupancy.db"
OUTPUT_DIR = Path.home() / "rag-demo" / "occupancy-export"

def export_all():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    db = OccupancyDB(DB_PATH)

    import sqlite3
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    signal_keys = [row["signal_key"] for row in conn.execute("SELECT signal_key FROM signals")]
    conn.close()

    print(f"Exporting {len(signal_keys)} signals...")
    for key in signal_keys:
        sig = db.get_signal(key)
        sightings = db.get_sightings(key)

        lines = [
            f"# Signal: {key}",
            "",
            f"- Frequency: {sig['frequency_hz']} Hz",
            f"- Mode: {sig['mode'] or 'unknown'}",
            f"- First seen: {sig['first_seen_sec']} (epoch)",
            f"- Last seen: {sig['last_seen_sec']} (epoch)",
            f"- Total sightings: {sig['total_sightings']}",
            "",
            "## Individual Sightings",
            "",
        ]
        for s in sightings:
            lines.append(
                f"- {s['first_seen_sec']} to {s['last_seen_sec']}, "
                f"source: {s['source_type']}/{s['source_device']}"
                + (f", bandwidth: {s['bandwidth_hz']} Hz" if s['bandwidth_hz'] else "")
            )

        safe_name = key.replace(":", "_").replace("/", "_")
        (OUTPUT_DIR / f"signal_{safe_name}.md").write_text("\n".join(lines))

    exported_at = datetime.now(timezone.utc).isoformat()
    (OUTPUT_DIR / "_export_metadata.md").write_text(
        f"# Export Metadata\n\nExported at: {exported_at}\n\n"
        f"This is a snapshot, not live data — re-run this script and "
        f"re-upload to refresh.\n"
    )
    print(f"Done. Output: {OUTPUT_DIR}")

if __name__ == "__main__":
    export_all()
```

Save as `~/rag-demo/export_occupancy.py`, then run with the
`sigint-processing` venv (matches where `occupancy_db.py` actually
runs elsewhere in this build — no new dependency, it's stdlib-only):

```
/opt/sovereign-sigint/venvs/sigint-processing/bin/python3 ~/rag-demo/export_occupancy.py
```

## Step 2: Include SigID Reference Text

Phase 6.3's mirror stores metadata as JSON, one file per signal —
useful for programs, less useful for RAG chunking as raw JSON. Flatten
it to readable markdown:

```python
#!/usr/bin/env python3
"""Flatten SigID mirror JSON metadata into readable markdown for RAG."""

import json
from pathlib import Path

SIGID_DIR = Path("/data/reference/sigid/metadata")
OUTPUT_DIR = Path.home() / "rag-demo" / "sigid-export"

def flatten():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    json_files = list(SIGID_DIR.glob("*.json"))
    print(f"Found {len(json_files)} SigID entries.")

    for jf in json_files:
        try:
            data = json.loads(jf.read_text())
        except json.JSONDecodeError as exc:
            print(f"  SKIP (bad JSON): {jf} — {exc}")
            continue

        title = data.get("title", jf.stem)
        lines = [f"# {title}", ""]
        for key, value in data.items():
            if key == "title":
                continue
            lines.append(f"**{key}**: {value}")
            lines.append("")

        (OUTPUT_DIR / f"{jf.stem}.md").write_text("\n".join(lines))

    print(f"Done. Output: {OUTPUT_DIR}")

if __name__ == "__main__":
    flatten()
```

**Flagged rather than guessed:** the exact JSON field names/schema
depend on what Phase 6.3's actual sync produced — this script assumes
a `title` field and dumps everything else generically, which should
work regardless of exact schema specifics, but spot-check a few output
files against the source JSON before trusting the flattening looks
right.

Save as `~/rag-demo/flatten_sigid.py`, then run:

```
/opt/sovereign-sigint/venvs/sigint-processing/bin/python3 ~/rag-demo/flatten_sigid.py
```

## Step 3: Create the Knowledge Collection

Same steps as `docs/rag-knowledge-base-guide.md` Step 3 — not repeated
here in full. Create a collection named something like "Signal
Reference (Occupancy + SigID)", and upload **both** export directories'
`.md` files (`~/rag-demo/occupancy-export/` and
`~/rag-demo/sigid-export/`) into it.

## Try It Out

- *"What signals have been recorded on or near 144.39 MHz?"*
- *"How many total sightings does the occupancy log show for APRS?"*
- *"What does the SigID reference say about POCSAG paging signals?"*
- *"Based on what's been logged, has anything shown a long-duration,
  continuous sighting versus short bursts?"*

Check the answer against `_export_metadata.md`'s timestamp — if you
suspect the answer is stale, that's your first thing to verify, not a
model problem.

## Tips & Troubleshooting

- **Answers reference old data:** re-run both export scripts and
  re-upload — this is a snapshot by design, covered in the scope note
  above, not a bug.
- **Empty or near-empty export:** confirm `occupancy.db` actually has
  rows (`sqlite3 db/occupancy.db "SELECT COUNT(*) FROM signals;"`, or
  the Python equivalent per `scripts/security-hardening.sh`'s pattern
  if `sqlite3` CLI isn't installed) before assuming the export script
  is broken.
- **Want this live instead of snapshot-based:** that's the Open WebUI
  Tool bridge discussed but not built — a real, separate, buildable
  piece of work, not something this export-based approach evolves into
  automatically.
