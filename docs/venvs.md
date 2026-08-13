# Python virtual environments

Host-level Python services on this box are isolated by **capability
domain**, not by build phase. Phase numbers in `docs/build-order.md`
are about install *sequence* and have already been renumbered once
(Phase 2 was inserted after the fact) — a venv named after a phase
number would go stale the next time the sequence changes. Domain names
describe what the code *does* and don't move.

## Registry

| Domain | Path | Purpose | Requirements file | Build phase |
|---|---|---|---|---|
| `ai-ingest` | `/opt/sovereign-sigint/venvs/ai-ingest` | OCR, document/imagery ingest, baseline audio transcription | `ai-ingest/requirements.txt` | Phase 5 |
| `sigint-processing` | `/opt/sovereign-sigint/venvs/sigint-processing` | Signal feature extraction, occupancy DB writes, callsign-over-time tracking | `decode/requirements.txt` | Phase 6 |

**GNU Radio is not installed in this build.** It was originally excluded
from this venv (its apt bindings land in system dist-packages, not pip) and
has since been removed entirely — nothing here uses it (occupancy capture goes
through `hackrf_transfer`/`rtl_sdr`/`pcmrecord` directly, and OpenWebRX+ has
its own DSP). Flowgraph work is deferred to a desktop; see
`docs/build-order.md` Phase 6.2 and `decode/gnuradio-flowgraphs/README.md`. If
you later install GNU Radio for flowgraph experiments, its bindings run under
system Python; only code consuming its *output* (files, sockets) would belong
in this venv.

Add a row here for every new domain — this table is the single place
to answer "what venv does X use and where does it live," instead of
that answer depending on remembering or `find`-ing across the host.

## Conventions

- **Root:** all venvs live under `/opt/sovereign-sigint/venvs/`, kept
  separate from `/data` (which is for growable artifacts — models,
  documents, signal captures — not code or environments; see
  `docs/data-layout.md`).
- **Naming:** by capability domain (`ai-ingest`, `sigint-processing`,
  future domains), never by phase number.
- **Requirements files live next to the code that uses them** — e.g.
  `ai-ingest/requirements.txt`, `decode/requirements.txt` — so a
  domain's dependencies are reproducible straight from git, not from
  whatever got `pip install`ed by hand over time.
- **systemd units point directly at the venv's interpreter**
  (`ExecStart=/opt/sovereign-sigint/venvs/ai-ingest/bin/python3 ...`),
  not at an "activated" shell — services shouldn't depend on shell
  activation state.
- **No dependency sharing across domains at the venv level.** If two
  domains both need `faster-whisper` (as `ai-ingest` and
  `sigint-processing` currently do), each domain's requirements file
  lists it independently rather than one domain importing from the
  other's venv. Costs a bit of disk (a second copy of the model-loading
  library, not the model weights themselves — those live once in
  `/data/models`), buys full independence: either domain's dependency
  bump can't break the other.

## Adding a new domain

1. Add a row to the registry table above.
2. Create `<domain>/requirements.txt` next to that domain's scripts.
3. Add the domain to `scripts/setup-venvs.sh`.
4. Point any new systemd unit's `ExecStart` at
   `/opt/sovereign-sigint/venvs/<domain>/bin/python3`.
