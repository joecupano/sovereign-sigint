# Vision-Assisted Signal Identification

A hands-on guide to using `gemma3:12b` (this build's vision model) to
visually compare a captured waterfall or spectrogram against known
signal shapes — a first-pass triage before deeper analysis, not a
final identification.

## Why Vision, and Why This Model Specifically

Of the three models in this build's lineup, only `gemma3:12b` can look
at an image — `qwen3:14b` (general reasoning) and `nomic-embed-text`
(embeddings) can't. This guide is deliberately scoped to what a vision
model is actually good at: comparing shape, structure, and visual
pattern against known references. It is **not** a substitute for actual
signal identification, which depends on more than appearance
(bandwidth, timing, protocol behavior) — treat its answers as narrowing
the search, not a certified result.

## Step 1: Get a Real Waterfall to Test With

**Simplest path — a screenshot from OpenWebRX+:** tune to an active
signal (2m APRS at 144.390 MHz, LoRa at 915 MHz, or any active
frequency per `docs/openwebrx-sdr-quickstart.md`), let the waterfall
fill with real signal history, and take a screenshot cropped to just
the waterfall/spectrum display — no browser chrome.

**Optional — render a spectrogram from a real SigMF capture**, if you
want to test against an offline recording instead of a live session.
This needs `matplotlib`, now included in `decode/requirements.txt` as
part of the standard `sigint-processing` venv build (Phase 6.5) — if
you set that up before this guide was updated, re-run
`./scripts/phase6-sigmf-writer.sh` once to pick it up; no separate
install step otherwise.

Given a capture from `capture-to-sigmf.sh` or `sigmf_writer.py`:

```python
#!/usr/bin/env python3
"""Render a PNG spectrogram from a SigMF recording for vision-model
comparison. Reads the .sigmf-meta for sample rate, .sigmf-data for
samples — same complex64 format sigmf_writer.py always produces."""

import json
import sys
import numpy as np
from scipy import signal
import matplotlib.pyplot as plt

def render(meta_path, data_path, out_path):
    with open(meta_path) as f:
        meta = json.load(f)
    sample_rate = meta["global"]["core:sample_rate"]

    iq = np.fromfile(data_path, dtype=np.complex64)
    f, t, Sxx = signal.spectrogram(iq, fs=sample_rate, return_onesided=False)

    plt.figure(figsize=(10, 6))
    plt.pcolormesh(t, np.fft.fftshift(f), 10 * np.log10(np.fft.fftshift(Sxx, axes=0) + 1e-12))
    plt.ylabel("Frequency (Hz)")
    plt.xlabel("Time (s)")
    plt.colorbar(label="Power (dB)")
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    print(f"Wrote {out_path}")

if __name__ == "__main__":
    render(sys.argv[1], sys.argv[2], sys.argv[3])
```

```
/opt/sovereign-sigint/venvs/sigint-processing/bin/python3 render_spectrogram.py \
    /data/signals/generated/my_capture.sigmf-meta \
    /data/signals/generated/my_capture.sigmf-data \
    ~/waterfall_test.png
```

**Syntax-checked only, not run against a real capture** — verify the
output actually looks like a sensible spectrogram before trusting it
for comparison; `scipy.signal.spectrogram`'s exact parameters (window
size, overlap) may need tuning for a specific signal's characteristics.

## Step 2: Locate Reference Images from the SigID Mirror

Phase 6.3's synced catalog already has real waterfall/reference images
for known signal types:

```
ls /data/reference/sigid/images/ | head -20
```

Pick one that visually resembles what you captured — this is where
your own RF pattern-recognition experience does the initial narrowing;
the vision model compares against a candidate you choose, it doesn't
search hundreds of images for you.

## Step 3: Try It Out — A Vision Chat Session

In Open WebUI:

1. Start a new chat, select **gemma3:12b** as the model
2. Upload your waterfall screenshot (or rendered spectrogram)
3. Ask something concrete: *"Describe the visual pattern in this
   waterfall — bandwidth, whether it's continuous or bursty, any
   repeating structure."*
4. Upload a second image — a candidate SigID reference — and ask:
   *"Does the signal in the first image resemble this reference
   image? What's similar, what's different?"*

**A good sanity check:** try this with a signal you already know the
identity of — APRS at 144.390 MHz is a good universal one; or a
time/standard station you can receive (WWV in the US; note Canada's CHU
closed 22 Jun 2026), or a strong local FM broadcast — confirm the
model's description is at least plausible before trusting it on something
genuinely unknown.

## Step 4: Confirm Against the SigID Reference Tool (live lookup)

The vision model gives you a *shape* description; the **SigID reference
native tool** (`openwebui-tools/sovereign_sigid_reference_tool.py`) gives you
the authoritative *catalog detail* to match it against — a live lookup over
the mirrored signal catalog (`lookup_signal` by name, `search_signals` by
keyword or near a frequency). (Install it once via the procedure in
`docs/openwebui-setup-guide.md` if you haven't already.)

Because the vision model (`gemma3:12b`) can't call tools and the tool-capable
model (`qwen3:14b`) can't see images, this lookup happens in a **separate chat
with `qwen3:14b`**, carrying over the vision model's shape description and your
measured frequency. The full procedure — capture/measure, describe, look up,
and confirm by triangulation — is laid out step-by-step in *The Complete
Workflow* below; this section just introduces the reference tool as the piece
that turns a shape description into named candidates.

## The Complete Workflow: Triaging an Unknown Signal

This is the full end-to-end procedure that ties the three data sources
together to make a first identification of an unknown signal, entirely on
local hardware. It combines the vision model (shape), the SigID reference tool
(catalog), and your own receiver's measurement (frequency/bandwidth).

**Important model constraint — read first.** This workflow uses **two
different models**, because no single local model does both halves:
- `gemma3:12b` can *see images* but **cannot call tools**.
- `qwen3:14b` can *call tools* (occupancy, Kismet, SigID) but **cannot see
  images**.

So you switch models between the visual step and the lookup step. That is
expected, not a misconfiguration. Keep the waterfall image and the vision
model's description handy to carry from the first chat to the second.

### Step-by-step

1. **Capture and measure (your receiver).** With the signal live in
   OpenWebRX+ (or from a SigMF recording), note the two things only your
   receiver can tell you: the **center frequency** and the approximate
   **bandwidth**. These are your ground-truth anchors — the vision model and
   the catalog can only narrow; the measured frequency confirms. Take a
   tightly-cropped waterfall screenshot of just this signal.

2. **Describe the shape (`gemma3:12b`, vision).** New chat, select
   `gemma3:12b`, upload the crop, and ask for a structural description:
   *"Describe this waterfall — bandwidth, continuous vs bursty, any repeating
   or tonal structure, number of tones/carriers."* You want characteristics
   (e.g. "narrowband, bursty, looks like multi-tone PSK"), not a guess at the
   name. Note the description.

3. **Cross-check the catalog (`qwen3:14b`, SigID tool).** New chat, select
   `qwen3:14b` (with the SigID reference tool enabled). Turn the vision
   description and your measured frequency into a lookup:
   - by characteristic: *"Call search_signals with keyword 'PSK'"* (or 8psk,
     FSK, tones, etc. from the shape description), and/or
   - by frequency: *"Call search_signals near <your measured frequency in Hz>"*
     — this uses the anchor from Step 1 to filter the catalog to signals
     documented around that frequency.
   You get back candidate signals with their documented mode, modulation,
   bandwidth, and location.

4. **Confirm by triangulation.** A candidate is credible only when the three
   independent sources agree:
   - **Shape** (Step 2) matches the candidate's documented modulation/structure,
   - **Frequency** (Step 1) is consistent with where the candidate is documented
     to appear,
   - **Bandwidth** (Step 1) matches the candidate's documented bandwidth.
   If all three line up, you have a defensible first identification. If they
   conflict (right shape, wrong frequency band; or right frequency, wrong
   bandwidth), treat it as unconfirmed and keep the candidate list open.

5. **Optionally, check what's actually on air (occupancy tool).** Still in the
   `qwen3:14b` chat, *"Call query_occupancy near <frequency>"* to see whether
   your own receivers have logged activity there and how often — corroborating
   that this is a real, recurring signal rather than a one-off.

### What this workflow is, and is not

It is a **triage that narrows an unknown to a small, evidence-backed candidate
set** — appearance, plus catalog reference, plus your own measurement, all
agreeing. It is **not** a certified identification: final confirmation of many
signals needs decoding or protocol analysis the vision model can't do. The
discipline that makes it trustworthy is requiring *agreement across
independent sources* rather than trusting any one — especially not the vision
model's confidence alone (see Troubleshooting).

## Tips & Troubleshooting

- **Vague or generic descriptions:** crop tightly to just the signal of
  interest — a full-band waterfall with many signals gives the model
  too much to describe at once. One signal, one crop, one question.
- **Model seems confident about something clearly wrong:** this is
  expected and worth internalizing, not a bug to fix — vision models
  can describe a plausible-sounding but incorrect match with the same
  confidence as a correct one. Cross-check against your own RF
  knowledge, not just the model's confidence level.
- **`gemma3:12b` doesn't respond, or errors about tools:** confirm no
  Tools/function-calling feature is active for this chat — `gemma3:12b`
  doesn't support tool calling at all (a real, confirmed Ollama
  limitation, unrelated to vision). Switch to `qwen3:14b` for anything
  needing tools; use `gemma3:12b` for image-only turns.
- **Want a second opinion on the same image:** ask the same question
  fresh in a new chat rather than continuing a long thread — a model's
  own prior answer in context can anchor a second question toward
  agreeing with itself rather than re-evaluating independently.
