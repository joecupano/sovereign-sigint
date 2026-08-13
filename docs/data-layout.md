# /data layout

All growable, potentially-large data for sovereign-sigint lives under a
single `/data` mount point rather than scattered across home directories
or container-internal volumes. The goal: moving to a dedicated SSD later
is a drive swap + `rsync` + `/etc/fstab` entry, not a reconfiguration of
every service.

```
/data/models              LLM weights pulled by Ollama
/data/rag                 Documents manually uploaded through Open
                          WebUI's UI ONLY — not the automated pipeline
/data/corpus/source       Phase 5 automated ingest: original documents
                          (DOCX, PDF, TXT, MD) before extraction
/data/corpus/processed    Phase 5 automated ingest: extracted/normalized
                          text — from documents, OCR'd images, and
                          audio transcripts alike, unified in one place
/data/reference/sigid     Phase 6.3: sovereign mirror of sigidwiki.com
                          (metadata/images/audio subdirs) — external
                          reference data, not something this build
                          generates
/data/imagery             Static images — GIF, PNG, JPG, JPEG, HEIC, etc.
/data/signals/raw         Raw SDR captures (IQ, unprocessed SigMF pairs)
/data/signals/generated   SigMF recordings WE generate for external consumption
/data/audio               Audio extracted from SDR streams (voice, decoded modes)
```

Created via `scripts/setup-data-dirs.sh`.

## Why one mount point instead of five

A single `/data` root means one `/etc/fstab` line and one place to check
disk usage (`df -h /data`), while the five subdirectories keep each data
type independently backed-up, pruned, or quota'd without touching the
others. Signal captures and audio grow fast and are the most disposable;
models and RAG documents are comparatively small and worth protecting.

## Per-subsystem wiring

**Ollama (`/data/models`)**
Set `OLLAMA_MODELS=/data/models` in the environment before the first
`ollama pull` — moving weights after the fact works, but means
re-pointing manifests/symlinks rather than just pulling clean.
Ownership exception: `/data` is otherwise owned by the human operator
(see `scripts/setup-data-dirs.sh`), but Ollama's systemd service runs
as its own `ollama` system user, which needs write access here to pull
models. `/data/models` is chowned to `ollama:ollama` specifically —
see `scripts/phase3-ollama.sh` — a narrow exception scoped to this one
subdirectory, not a change to the general convention.

**Open WebUI (`/data/rag`)**
Bind-mounted specifically to `/app/backend/data/uploads` — the
confirmed internal path Open WebUI stores uploaded RAG documents at —
so uploaded source material survives container recreation and is
visible to backup tooling on the host. App state that lives alongside
it internally (`webui.db`, `vector_db/`, `cache/`) is intentionally
NOT under `/data` — it stays in a separate Podman-managed named volume,
since that's app internals rather than the "static documents for RAG"
this directory is meant for. See `containers/open-webui.container`.

**This directory is for manual UI uploads only.** Open WebUI tracks
uploads in its own database — each file gets a DB record and an
embedding, which is what actually makes it searchable in chat. A file
dropped into `/data/rag` by a script, without going through Open
WebUI's API, sits in the directory but has no DB record and isn't
part of RAG. Phase 5's automated ingest pipeline is therefore
deliberately NOT wired to this directory — see `/data/corpus` below.

**Automated ingest (`/data/corpus/source`, `/data/corpus/processed`)**
Phase 5's ingest pipeline (docling, pytesseract, faster-whisper) is a
decoupled corpus, not wired into Open WebUI's chat RAG — see
`docs/build-order.md` Phase 5 for the reasoning. `source/` holds
original documents before extraction; `processed/` is the landing spot
for extracted/normalized text, namespaced by source type
(`processed/document/`, `processed/image/`, `processed/audio/`) to
avoid path collisions between source roots that happen to share a
relative subpath — still one tree to read from, just not flat. A
DOCX's parsed text, an OCR'd image's text, an audio transcript all end
up as plain text + a metadata JSON sibling under their type's
subdirectory. Original images and audio stay in `/data/imagery` and
`/data/audio` respectively; only text *derived from* them lands in
`/data/corpus/processed`, not a copy of the media itself.

**SigID mirror (`/data/reference/sigid`)**
A new top-level category (`/data/reference/`) for external reference
datasets, distinct from `/data/rag` (manual uploads) and `/data/corpus`
(Phase 5's own ingest output) — this is neither; it's a periodically-
synced mirror of external curated data with its own update cadence
(weekly, via `systemd/sigid-mirror.timer`). See `docs/build-order.md`
Phase 6.3 and `reference/sigid_mirror.py`.

**SIGINT ingest (`/data/signals/raw`)**
Capture scripts (`sigint-ingest.py` and friends) and the wideband IQ tap
from `radiod` write here — raw, unprocessed captures only. Consider a
retention/rotation policy early — raw IQ at even modest sample rates
fills a drive fast.

**SigMF generation (`/data/signals/generated`)**
Kept separate from raw captures because generated output is meant for
external consumption (IQEngine, GNU Radio's SigMF blocks, other
third-party tooling per SigMF's interoperability goal) — a consumer of
generated recordings should never have to sort them out from raw,
possibly malformed or partial captures sitting in the same directory.
See `decode/requirements.txt` for the pinned `sigmf` library used on
this write path specifically (reading stays on direct JSON parsing).

**Audio extraction (`/data/audio`)**
Anything demodulated and rendered to audio (voice segments for
Whisper transcription, decoded digital-mode audio kept for review)
lands here, separate from raw signal captures so audio-specific
retention/compression policy can differ from IQ retention policy.

**Imagery (`/data/imagery`)**
Reserved for static image assets feeding OCR/vision pipelines — not
signal-derived spectrograms (those belong under `/data/signals/raw`
alongside the captures they're derived from, unless a clear case
emerges for splitting them out later).

## Moving to a dedicated SSD later

1. Install and mount the new drive at a temp path (e.g. `/mnt/newssd`).
2. Stop dependent services (Ollama, Open WebUI, ingest daemons).
3. `rsync -aHAX /data/ /mnt/newssd/`
4. Update `/etc/fstab` to mount the new drive at `/data`.
5. Reboot or remount, verify contents, restart services.

No container definitions, env vars, or script paths need to change —
they all point at `/data/...`, not at a physical device.
