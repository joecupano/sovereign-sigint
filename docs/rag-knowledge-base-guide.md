# Building a Local RAG Knowledge Base — Antenna Design Example

A hands-on guide to building a local, sovereign RAG (retrieval-augmented
generation) knowledge base using this build's existing AI stack — no
cloud dependency, no data leaving the box. We'll use a real, substantial
public source (L.B. Cebik W4RNL's antenna design collection) as the
worked example, and end with a live chat session querying it.

## What You're Building

RAG lets a local LLM answer questions grounded in specific source
material it wasn't trained on — instead of relying purely on what
`qwen3:14b` already knows (or doesn't), it retrieves relevant passages
from your own document collection and answers from those, with the
source material never leaving this machine. Same "local by default"
philosophy as the rest of this build.

## About the Source Material

[antenna2/cebik](https://github.com/antenna2/cebik) is a community-preserved
archive of L.B. Cebik's (W4RNL, silent key 2008) antenna design writings —
books, decades of magazine columns, and detailed antenna modeling notes
(NEC-2/NEC-4). Cebik was one of the most respected technical writers in
amateur radio antenna theory; this collection is a genuinely valuable,
substantial technical corpus — hundreds of real pages, not a toy dataset.

**Licensing, stated plainly rather than skipped past:** this is
copyrighted material. The source explicitly states it "may be used for
personal purposes, but may not be reproduced for publication in print or
any other medium without permission," and may not be used commercially.
That fits exactly what this guide does — a private, local knowledge base
for your own use, never redistributed or made public — but it's worth
being direct about: don't repurpose the resulting processed corpus for
any public-facing or commercial system.

## Architecture Note: Two Ingest Paths, and Why We're Using One Specifically

This build already has a document ingest pipeline (Phase 5,
`ai-ingest/`) — but it's deliberately **decoupled from Open WebUI's own
chat RAG**, by design (see `docs/build-order.md` Phase 5). Phase 5's
output lands in `/data/corpus/processed` as a standalone corpus; nothing
currently wires it into a chat-queryable retrieval layer.

For an actual chat session that retrieves from this material, the
correct tool is **Open WebUI's own native Knowledge feature** — its own
embedding (via `nomic-embed-text`, already configured in Phase 3) and
its own retrieval, already wired into chat. That's the path this guide
uses. If you also want this material in Phase 5's separate corpus for
other reasons, that's an independent, optional step — not required for
the chat session below.

## Step 1: Get the Source Material

```
mkdir -p ~/rag-demo
cd ~/rag-demo
git clone --depth 1 https://github.com/antenna2/cebik.git
```

`--depth 1` skips the full commit history — you only need the current
files, and this repo has been maintained for a while.

## Step 2: Convert HTML to Clean Text

Open WebUI's document upload works best with clean text/markdown, not
raw HTML with 1990s-era markup (the source material itself notes much
of it predates modern HTML standards). Rather than introduce a new
dependency, this reuses **Docling — already installed in Phase 5's
`ai-ingest` venv** — the same conversion engine this build already
relies on elsewhere, applied here as a one-off preprocessing pass
rather than through the full `ingest.py` pipeline.

Save this as `~/rag-demo/convert.py`:

```python
#!/usr/bin/env python3
"""One-off HTML -> Markdown conversion for RAG prep, using Docling
directly (not the full Phase 5 ingest.py pipeline — this is a
standalone preprocessing step feeding Open WebUI's Knowledge feature,
not this project's own /data/corpus)."""

import sys
from pathlib import Path
from docling.document_converter import DocumentConverter

SOURCE_DIR = Path.home() / "rag-demo" / "cebik"
OUTPUT_DIR = Path.home() / "rag-demo" / "converted"

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    converter = DocumentConverter()

    html_files = list(SOURCE_DIR.rglob("*.html"))
    print(f"Found {len(html_files)} HTML files.")

    converted, failed = 0, 0
    for html_file in html_files:
        try:
            result = converter.convert(str(html_file))
            markdown = result.document.export_to_markdown()

            # Flatten into one directory, encoding the relative path in
            # the filename so hundreds of similarly-named pages
            # (common across the columns/books directories) don't collide.
            rel_path = html_file.relative_to(SOURCE_DIR)
            safe_name = str(rel_path.with_suffix(".md")).replace("/", "__")
            out_path = OUTPUT_DIR / safe_name
            out_path.write_text(markdown, encoding="utf-8")
            converted += 1
        except Exception as exc:
            print(f"  FAILED: {html_file} — {exc}", file=sys.stderr)
            failed += 1

    print(f"Converted: {converted}, Failed: {failed}")
    print(f"Output: {OUTPUT_DIR}")

if __name__ == "__main__":
    main()
```

Run it with the Phase 5 venv's Python — no separate install needed:

```
/opt/sovereign-sigint/venvs/ai-ingest/bin/python3 ~/rag-demo/convert.py
```

This will take a while — hundreds of pages, each going through
Docling's real document-structure parsing, not a simple strip-tags
regex. A handful of conversion failures on oddly-formatted 1990s pages
is expected and fine; check the `FAILED` lines but don't expect zero.

## Step 3: Create a Knowledge Collection in Open WebUI

Log into Open WebUI and:

*(Default install: `http://<this-box-ip>:8000/` — Caddy serves plain
HTTP on :8000 unless you opted into TLS with `CADDY_TLS=1`, in which
case it's `https://<hostname>.local:8443/`. See docs/security-hardening.md
for the TLS path.)*

1. **Workspace → Knowledge → Create a new collection** — name it
   something like "Antenna Design (Cebik)"
2. **Upload the converted files** — the `.md` files from
   `~/rag-demo/converted`. Open WebUI will chunk and embed each one
   using whatever embedding model is configured in Admin Settings →
   Documents (should already be `nomic-embed-text`, set back in Phase 3/4
   — worth confirming rather than assuming it stuck).
3. Wait for indexing to complete — with hundreds of files, this takes
   real time. Open WebUI shows per-file processing status; let it finish
   before querying.

*(Menu wording may shift slightly across Open WebUI versions — if
"Knowledge" isn't where you expect, check Workspace's other tabs; the
underlying feature has been stable even when labels move.)*

## Step 4: Attach the Knowledge Base to a Chat

Two ways to use it once indexed:

- **Per-message reference:** type `#` in the chat box, select your
  "Antenna Design (Cebik)" collection — scopes retrieval to that one
  message
- **Always-on for a custom model:** Workspace → Models → create a model
  based on `qwen3:14b`, attach the Knowledge collection in its settings
  — every chat with that model retrieves from it automatically

For this first test, the `#` reference per-message is simpler and lets
you compare answers with and without RAG active.

## Try It Out — A Real Chat Session

With the collection indexed and referenced, try questions that only a
system that's actually retrieved from this specific corpus should
answer well — not generic antenna trivia `qwen3:14b` might already
know from training, but Cebik's own specific treatments:

- *"According to this material, what determines the feedpoint
  impedance of a center-fed dipole, and how does height above ground
  affect it?"*
- *"What does this collection say about the Moxon rectangle antenna
  and its bandwidth compared to a Yagi?"*
- *"Summarize the modeling approach described for link-coupled
  antenna tuners."*
- *"What design considerations are described for vertically radiating
  horizontal antennas?"*

**A good sanity check, not just a good demo:** ask the same question
once with the `#` Knowledge reference and once without it. If the
answers are meaningfully different — the RAG-backed one citing or
clearly drawing on specific Cebik terminology/structure the plain
answer doesn't — that's real confirmation retrieval is actually
happening, not just Ollama answering from general training data anyway.

## Tips & Troubleshooting

- **Indexing seems stuck:** check Open WebUI's own logs
  (`podman logs open-webui`) — large batches can take a while;
  distinguish "still working" from "actually stalled" the same way
  this build's FFTW background job taught you to (Phase 2) — check for
  actual activity, not just elapsed time.
- **Answers ignore the knowledge base entirely:** confirm the `#`
  reference actually attached (it should show as a chip/tag in the
  message box before sending) and that indexing genuinely completed,
  not just started.
- **Conversion produced garbled text for some pages:** expected for a
  handful of 1990s-era pages with unusual markup — Docling's own
  structure-aware parsing handles most of it well, but not perfectly;
  spot-check a few converted `.md` files against the original HTML if
  an answer seems off.
- **Want this material in Phase 5's own corpus too:** copy the
  converted `.md` files into `/data/corpus/source` and re-run
  `./scripts/phase5-ai-ingest.sh` — an independent, optional step, not
  required for the chat-session path above.
