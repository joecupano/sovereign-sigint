# Classroom — Sovereign SIGINT course materials

Teaching materials derived from this build: a narrative article, a companion
slide deck, and a 13-lab college course with an instructor guide. Every
lesson documents real problems encountered on real hardware during the
actual build — including the bugs, the wrong turns, and the fixes — rather
than an idealized happy path.

> **Status:** all materials are current. The **article + deck** (`article/`)
> are the maintained overview; the **labs** (`labs/`) have been revalidated
> lab-by-lab against the working build (labs 00–10 were already accurate;
> lab11/lab12 were updated for the two real producers (radiod continuous HF;
> a device-flexible HackRF/RTL-SDR producer for VHF/UHF), the closed
> DB→AI loop, the three AI sources, and the calibration lessons). See
> `labs/README.md` for what was checked.

## Layout

```
classroom/
├── article/
│   ├── Building-Sovereign-SIGINT.docx        # the narrative article (built)
│   ├── Building-Sovereign-SIGINT-deck.pptx   # companion slide deck (built)
│   ├── build-article.js                      # article generator
│   └── build-deck.js                         # deck generator
└── labs/
    ├── decks/                                # built .pptx labs + instructor guide
    │   ├── lab00 … lab12 (.pptx)
    │   └── Sovereign-SIGINT-Instructor-Guide.docx
    └── src/                                  # generators + lesson content
        ├── deck-builder.js                   # shared slide-rendering library
        ├── build-all.js                      # builds all 13 lab decks
        ├── build-docx.js                     # builds the instructor guide
        ├── sessions-1..4.js                  # per-lab content (the source of truth)
        └── narrative-1..4.js                 # instructor-guide narrative content
```

## The 13 labs

| Lab | Phase | Topic |
|-----|-------|-------|
| lab00 | — | Introduction to Sovereign SIGINT (architecture, philosophy) |
| lab01 | 1 | Hardware & drivers (incl. the RX-888 DFU-mode "USB2 trap") |
| lab02 | 2 | OS packages: rootless Podman, FFTW, venv strategy |
| lab03 | 3 | Ollama & AI models (native install, GPU, a real networking bug) |
| lab04 | 4 | Open WebUI + Caddy (Quadlet units, the TLS `:80`-bind bugs) |
| lab05 | 5 | AI ingest pipeline (docs/OCR/speech, a CUDA mismatch) |
| lab06 | 6.1 | ka9q-radio / radiod (wideband HF, the `fobos.h` pin fix) |
| lab07 | 6.2 | Decode layer (direwolf, multimon-ng; GNU Radio removed/deferred) |
| lab08 | 6.3 | SigID mirror |
| lab09 | 6.4 | OpenWebRX+ (incl. RX-888 via SoapySDDC, `driver=SDDC`) |
| lab10 | 6.5 | SigMF writer |
| lab11 | 6.6 | Occupancy database |
| lab12 | — | Final lab: use cases of Sovereign SIGINT |

## Regenerating

The built `.pptx`/`.docx` files are committed for convenience, but they are
generated from the `.js` sources — edit the content there, not the binaries.

Lab decks + instructor guide:

```
cd classroom/labs/src
npm install          # first time only (pptxgenjs, docx)
node build-all.js    # → writes the 13 lab decks
node build-docx.js   # → writes the instructor guide
```

Article + companion deck:

```
cd classroom/article
npm install          # first time only
node build-article.js
node build-deck.js
```

(Build output paths in the scripts point at the original working
directories used during authoring; adjust the `outDir` / output paths in
the scripts if regenerating in place.)

## Note on accuracy

These materials have been reconciled against the full working build: three
calibrated occupancy producers (radiod continuous HF + the device-flexible
HackRF/RTL-SDR key-frequency producer), the closed capture→DB→AI loop via
native Open WebUI tools, three AI data sources (occupancy, Kismet, SigID),
and the vision-assisted identification workflow. GNU Radio has been removed.
If the build moves on materially, update the `sessions-*.js` / `build-*.js`
sources and regenerate rather than editing the binaries.
