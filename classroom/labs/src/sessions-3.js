// Sessions: Phase 6.2, 6.3, 6.4, 6.5
module.exports = [
{
  id: "lab07",
  title: "Phase 6.2 — Decode Layer",
  subtitle: "GNU Radio, direwolf, multimon-ng, and the venv boundary",
  objectives: [
    "Install GNU Radio and its SDR abstraction layer (gr-osmosdr)",
    "Understand why GNU Radio runs under system Python, not either project venv",
    "Confirm this layer with a real flowgraph, not just a package-install check"
  ],
  background: {
    heading: "What This Layer Provides",
    points: [
      "GNU Radio: the general-purpose DSP framework used later for occupancy-detection flowgraphs",
      "gr-osmosdr: the abstraction layer letting GNU Radio talk to HackRF, RTL-SDR, and many other SDRs through one consistent interface",
      "direwolf: packet radio / AX.25 / APRS software modem, also used for maritime AIS decode",
      "multimon-ng: FLEX, POCSAG, and other digital-mode decoders"
    ]
  },
  architecture: {
    heading: "The System-Python Boundary",
    points: [
      "GNU Radio's Python bindings are wired into system dist-packages by its apt package — not installable via pip into either project venv",
      "Neither the ai-ingest nor sigint-processing venv was created with --system-site-packages, so GNU Radio's bindings are invisible to them by design",
      "The practical split: GNU Radio flowgraphs run under system Python; anything that just CONSUMES GNU Radio's output (files, multicast streams) stays in the venv-isolated world",
      "This decision, made all the way back in Phase 2, is exactly what makes the occupancy-detection flowgraphs in Phase 6.6 straightforward to write later"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "Installed BEFORE OpenWebRX+ (Phase 6.4) deliberately — OpenWebRX+ auto-detects direwolf and multimon-ng as optional decoders at its own startup, so order matters",
      "Validation must build and run an ACTUAL flowgraph (a real source-to-sink data path), not just confirm the packages installed",
      "ffmpeg included here for format conversion needs elsewhere in the pipeline"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "sudo ./scripts/phase6-decode-tools.sh",
      "./scripts/phase6-decode-tools-validate.sh — builds and runs a real GNU Radio flowgraph, checks direwolf/multimon-ng/ffmpeg",
      "Confirm GNU Radio's Python import works from system Python: python3 -c 'import gnuradio'",
      "Confirm it does NOT import from either project venv (this is expected and correct)"
    ]
  },
  gotcha: {
    heading: "Why Validate With a Real Flowgraph",
    text: "It would be easy to consider this phase 'done' once apt reports gnuradio installed successfully. But a package installing cleanly says nothing about whether its Python bindings are actually reachable, whether gr-osmosdr correctly finds the SDR hardware, or whether the whole dependency chain (Qt, VOLK, Boost) resolved without conflict. This build's validation script instead constructs and runs an actual signal source connected to an actual signal sink — a minimal but real, working flowgraph. If that runs, the entire chain is proven end to end. This is the same 'prove it with a real capture, not an enumeration' principle from Phase 1, applied to software instead of hardware."
  },
  validation: {
    heading: "Exit Criteria",
    points: [
      "A real GNU Radio flowgraph builds and runs successfully",
      "direwolf and multimon-ng both report their version correctly",
      "ffmpeg completes a real encode test"
    ]
  },
  discussion: [
    "Why might 'the package installed' and 'the software actually works' be two very different claims, especially for a large DSP framework?",
    "What are the tradeoffs of the venv-isolation decision made in Phase 2, now that we see its consequence here?",
    "Could you restructure this build to avoid the system-Python/venv split entirely? What would you give up?"
  ],
  nextSession: "Phase 6.3 — SigID Mirror: a local reference catalog, and a rate-limiting bug that killed an entire sync run."
},
{
  id: "lab08",
  title: "Phase 6.3 — SigID Mirror",
  subtitle: "A local signal-identification reference catalog",
  objectives: [
    "Build an incremental local mirror of an external signal-identification wiki",
    "Understand why this uses live incremental sync rather than a one-time static import",
    "Diagnose and fix a real rate-limiting failure"
  ],
  background: {
    heading: "What Gets Mirrored, and Why Locally",
    points: [
      "sigidwiki.com catalogs several hundred known RF signal types — frequency ranges, modulation notes, waterfall images, audio samples",
      "Mirrored locally so this reference material is available for AI-assisted signal identification WITHOUT a live internet dependency at query time — consistent with this course's sovereign-AI philosophy",
      "A live MediaWiki API sync, not a one-time archive dump — designed to be re-run periodically and pick up only what's changed"
    ]
  },
  architecture: {
    heading: "Incremental Sync Design",
    points: [
      "Bootstrap run: enumerate the entire wiki (namespace 0)",
      "Subsequent runs: query only pages changed since the last successful sync",
      "Per-page revision ID and per-file content hash both tracked in a local manifest — the same idempotency pattern as Phase 5's ingest pipeline",
      "Rate-limited deliberately (a fixed delay between requests) and uses an honest, identifiable User-Agent — respectful use of someone else's public infrastructure"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "Runs as a weekly systemd timer, not continuously — this reference data doesn't change fast enough to justify more frequent syncing",
      "~589 signals mirrored, including images and audio samples, not just text metadata",
      "The API endpoint location is auto-discovered rather than hardcoded, since not every wiki install exposes api.php at the same path"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "./scripts/phase6-sigid-mirror.sh (no sudo — this is a long-running first sync, expect 30-50+ minutes)",
      "Monitor progress in the terminal or run it detached (nohup ... &) and check back",
      "./scripts/phase6-sigid-mirror-validate.sh — confirms real content landed in /data/reference/sigid",
      "Browse a few synced entries and confirm images/audio downloaded correctly alongside the text"
    ]
  },
  gotcha: {
    heading: "Real Bug: One Rate-Limit Response Killed the Entire Run",
    text: "On the real, live bootstrap sync (hundreds of pages, each potentially with several image downloads), the external wiki's server returned an HTTP 429 (Too Many Requests) partway through — and the original code treated any non-success HTTP response as fatal, aborting the entire multi-hour sync and losing all remaining progress. But a rate-limit response across a run making hundreds of API calls is an EXPECTED, recoverable condition, not an exceptional one. The fix added retry-with-backoff, honoring the server's own Retry-After header when it provided one, applied consistently across both the metadata API calls and the separate file-download code path (which had originally been on its own unprotected route, a second bug found by inspecting the fix's own blast radius). The re-run after the fix completed cleanly: 497 pages, 834 files, dozens of 429s all handled gracefully instead of fatally."
  },
  validation: {
    heading: "Exit Criteria",
    points: [
      "A full or incremental sync completes without a fatal error",
      "/data/reference/sigid contains real metadata, images, and audio",
      "Re-running the sync correctly performs an incremental update, not a full re-download"
    ]
  },
  discussion: [
    "Why should a rate-limit response be treated differently from most other HTTP error codes?",
    "What's the ethical dimension of scraping/mirroring a public wiki's content — what did this build do to be a 'good citizen' of that infrastructure?",
    "If this sync needed to run against ten different wikis with ten different rate-limit policies, how would you generalize the retry logic?"
  ],
  nextSession: "Phase 6.4 — OpenWebRX+: a browser-based SDR receiver, and a feature dependency that wasn't obvious from its error message."
},
{
  id: "lab09",
  title: "Phase 6.4 — OpenWebRX+",
  subtitle: "A browser-based SDR receiver, with two real, non-obvious feature bugs",
  objectives: [
    "Deploy OpenWebRX+ as the browser-facing SDR receiver for HackRF and RTL-SDR",
    "Use OpenWebRX+'s own Feature Report as a self-diagnosing tool",
    "Diagnose two real, genuinely non-obvious configuration issues"
  ],
  background: {
    heading: "What OpenWebRX+ Provides",
    points: [
      "A live, multi-user, browser-based waterfall and audio receiver for HackRF and RTL-SDR — and, via an added SoapySDDC driver, the RX-888 for a full 0-30 MHz HF panorama (the RX-888's original purchase rationale; time-shared with radiod, see Phase 6.1)",
      "Built-in digital-mode decoders: Packet/APRS (via direwolf, Phase 6.2), LoRa, FLEX/POCSAG (via multimon-ng), FT8/FT4/JS8, and more",
      "SDR device profiles configure center frequency, mode, and gain per use case — deliberately left as a manual web-UI step in this build, not scripted, given how fragile getting these settings wrong can be"
    ]
  },
  architecture: {
    heading: "The Feature Report",
    points: [
      "http://<host>:8073/features lists every optional capability and states explicitly why it's unavailable if it is — a genuinely well-designed self-diagnosis tool",
      "Worth checking BEFORE configuring a profile that depends on a decoder that isn't actually present, rather than debugging blind from the live UI",
      "A feature can depend on MULTIPLE underlying requirements — as this build discovered directly"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "Installed AFTER Phase 6.2's decode tools deliberately, so direwolf/multimon-ng auto-detection happens correctly at OpenWebRX+'s own first startup",
      "Gain lives in the per-profile settings, not the live receiver panel's gain control — confirmed the hard way",
      "RTL-SDR v3/v4 boards support HF reception via direct sampling mode, no hardware modification needed — a fact worth knowing given RTL-SDR's native tuner range starts around 24MHz"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "sudo ./scripts/phase6-openwebrx.sh",
      "sudo openwebrx admin adduser <username> — create your own admin account",
      "Check http://<host>:8073/features BEFORE configuring any profile",
      "Add HackRF and/or RTL-SDR device profiles via Settings -> SDR devices",
      "Confirm a live waterfall and audio, then try Packet/APRS on 144.390 MHz"
    ]
  },
  gotcha: {
    heading: "Real Bugs: A Silent Waterfall, a Two-Part Feature, and a Case-Sensitive Driver",
    text: "Bug 1 — a real waterfall showed faint signals despite a live antenna: RF gain lives in per-profile Settings, not the live panel's Gain control (which doesn't persist). Bug 2 — Packet/APRS was missing though direwolf showed YES in the Feature Report; the real gate was a SECOND requirement, aprs_symbols (NO), not even in the package repo — needing a git clone. Bug 3 (adding the RX-888 later) — a three-part snag: (a) the SoapySDDC driver's source build failed on 'make all' because its unittest target doesn't compile on Ubuntu 24.04 — but the actual driver module built fine, so building the specific targets and installing the .so directly into SoapySDR's module dir worked; (b) the OpenWebRX+ device showed 'State: unknown' and SoapySDRUtil --probe gave 'no match' — because the driver key is CASE-SENSITIVE: the factory registers as 'SDDC' (capital), so 'driver=sddc' fails and 'driver=SDDC' works; (c) 'SoapySDRUtil --find' was the tool that revealed the exact device string. Shared lesson across all three: when something 'isn't there,' the authoritative move is to ask the tool what it actually sees (Feature Report, --find), not to guess from the symptom."
  },
  validation: {
    heading: "Exit Criteria",
    points: [
      "OpenWebRX+ service is active and reachable via browser",
      "A configured SDR device shows a live waterfall with a real, distinguishable signal",
      "Packet/APRS decode produces real decoded packets on 144.390 MHz"
    ]
  },
  discussion: [
    "Why is checking a documented Feature Report more reliable than guessing from a live UI's symptoms?",
    "What's the difference between a device not having enough gain versus a device not being properly connected — how would you tell them apart faster next time?",
    "Should a feature-flag system report ALL of a feature's unmet dependencies at once, or just the first one it finds? What are the tradeoffs?"
  ],
  nextSession: "Phase 6.5 — SigMF Writer: exporting raw IQ captures to an open, interoperable standard."
},
{
  id: "lab10",
  title: "Phase 6.5 — SigMF Writer",
  subtitle: "Exporting raw IQ captures to an open, interoperable format",
  objectives: [
    "Understand the SigMF standard for signal metadata and IQ recordings",
    "Write raw IQ captures from RX-888, RTL-SDR, and HackRF into SigMF format correctly",
    "Confirm correctness via real hardware captures, not just synthetic test data"
  ],
  background: {
    heading: "What SigMF Is, and Why It Matters",
    points: [
      "An open, community standard for describing recorded RF signal data — a metadata JSON file paired with a raw binary IQ data file",
      "Interoperable with external tools (IQEngine, GNU Radio's own SigMF blocks) — signal captures made in this project can be analyzed elsewhere without a custom format",
      "This is the layer that closes a real gap identified earlier: NEITHER radiod NOR OpenWebRX+ can export raw IQ — only decoded/demodulated output. This writer is the only path to a raw, reprocessable capture in this whole build"
    ]
  },
  architecture: {
    heading: "Three Different Native Hardware Formats",
    points: [
      "RX-888 (rx888_stream): 16-bit signed IQ (ci16_le)",
      "RTL-SDR (rtl_sdr): unsigned 8-bit IQ (cu8), offset-binary, centered at 127.5 not 128",
      "HackRF (hackrf_transfer): signed 8-bit IQ (ci8)",
      "Each format needs DIFFERENT normalization math before it's a valid SigMF recording — getting the offset wrong introduces a DC-offset artifact, not an obvious crash"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "A single capture-to-sigmf.sh utility wraps the device-specific capture tool AND the SigMF writer into one command, auto-selecting the correct input format per device",
      "All three formats convert to complex64 internally — a real, acknowledged tradeoff (up to 8x file-size increase for the 8-bit formats) versus preserving native bit depth",
      "An extra_capture_metadata hook exists in the writer specifically so a future SigID match or occupancy-DB record can be embedded directly in a capture's metadata"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "./scripts/phase6-sigmf-writer.sh (venv setup, no sudo)",
      "./scripts/phase6-sigmf-writer-validate.sh — round-trips synthetic data through all three formats",
      "./scripts/capture-to-sigmf.sh --device rtlsdr --freq <a known frequency> --sample-rate 2048000 --duration 5 --output-name my_test",
      "Inspect the resulting .sigmf-meta file: confirm frequency, sample rate, and SHA512 hash are all correct"
    ]
  },
  gotcha: {
    heading: "Catching an Overconfident Claim Before It Shipped",
    text: "Early in writing this module, the code asserted a specific library method name for setting author/description metadata as if it were confirmed, when it had only been guessed by pattern-matching against similar libraries. That guess was caught and flagged honestly in the code BEFORE ever running against real hardware — a documented 'this is unconfirmed, here's a graceful fallback if it's wrong' comment, rather than a confident but untested claim. When a real hardware capture was finally run, the guess turned out correct — but the discipline of flagging it as unconfirmed until actually tested, rather than presenting confidence that hadn't been earned yet, is the transferable lesson, independent of whether that particular guess happened to be right."
  },
  validation: {
    heading: "Exit Criteria",
    points: [
      "Synthetic round-trip tests pass for all three formats (ci16_le, cu8, ci8)",
      "A real hardware capture from at least one device produces a valid SigMF recording",
      "The written metadata's SHA512 hash matches an independent verification"
    ]
  },
  discussion: [
    "Why does an open standard like SigMF matter more for a SIGINT tool than a proprietary internal format would?",
    "What's the practical cost of the 8-bit-to-complex64 conversion, and when would preserving native bit depth actually matter?",
    "How do you decide when a claim in your own code is 'confirmed' versus 'a reasonable guess that hasn't been tested yet'?"
  ],
  nextSession: "Phase 6.6 — Occupancy Database: a Kismet-inspired schema, and turning raw signal energy into structured data an LLM can query."
}
];
