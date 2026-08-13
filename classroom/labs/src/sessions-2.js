// Sessions 5-8: Phase 4, Phase 5, Phase 6.1, Phase 6.2
module.exports = [
{
  id: "lab04",
  title: "Phase 4 — Open WebUI + Caddy",
  subtitle: "Rootless Podman Quadlet units, and three real bugs in one install",
  objectives: [
    "Deploy Open WebUI and Caddy as rootless Podman Quadlet units",
    "Understand the difference between systemd-enabled units and Quadlet-generated units",
    "Diagnose real version-mismatch and privileged-port bugs"
  ],
  background: {
    heading: "What Are Quadlet Units?",
    points: [
      "Quadlet lets you describe a container as a plain systemd-style .container file — Podman's generator converts it into a real systemd unit at daemon-reload time",
      "This build uses it for Open WebUI (the chat interface) and Caddy (reverse proxy) — both rootless, both auto-restarting",
      "Open WebUI binds to loopback only (127.0.0.1:8080) — Caddy is the actual LAN/public-facing entry point, not Open WebUI directly"
    ]
  },
  architecture: {
    heading: "The Reverse Proxy Chain",
    points: [
      "Browser -> Caddy (port 8000) -> Open WebUI (127.0.0.1:8080, container-internal) -> Ollama (host, native)",
      "App state (chat history, vector DB) lives in a Podman-managed named volume, separate from /data/rag (human-uploaded RAG documents specifically)",
      "This separation matters: script-dropped files in /data/rag have no database record and are NOT part of Open WebUI's RAG — only files uploaded through the UI are"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "Caddy on port 8000 (HTTP) by default, not 80 — rootless containers can't bind privileged ports without a system-wide policy change; moving the port avoided that tradeoff entirely",
      "TLS is opt-in with three modes: plain HTTP (default), self-signed local CA (CADDY_TLS=1, on :8443), and bring-your-own-certificate (CADDY_TLS=cert — for a corporate CA / wildcard / existing PKI, with no per-client trust step if the cert already chains to a trusted CA)",
      "Caddy fronts Open WebUI specifically because Open WebUI structurally refuses to do its own TLS (maintainers' explicit position) — the reverse proxy exists to do the one job the app won't",
      "Quadlet-generated units are started, never 'enabled' — a real distinction that surfaced only when the install script tried the wrong systemctl verb"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "sudo ./scripts/setup-data-dirs.sh (if /data doesn't exist yet)",
      "./scripts/phase4-open-webui.sh (no sudo — rootless)",
      "./scripts/phase4-validate.sh — confirms reachability direct, via Caddy, AND Open WebUI's connection to Ollama",
      "Log into Open WebUI at http://<host>:8000/ and complete first-run admin setup"
    ]
  },
  gotcha: {
    heading: "Real Bugs: Four, Across Two Sessions, on One Service",
    text: "Bug 1: the Quadlet file used AddHost= to reach the host — a key absent in the Podman 4.9.3 that Ubuntu 24.04 ships; fixed with the generic PodmanArgs= pass-through. Bug 2: 'systemctl enable' failed with 'is transient or generated' — Quadlet units are generator-produced and boot via their own [Install] section; the fix was calling 'start', not 'enable --now'. Bug 3: Caddy failed with 'bind: permission denied' on port 80 — rootless Podman can't bind privileged ports; Caddy was moved to 8000. Bug 4 (the subtle one, surfaced later when TLS was enabled): with 'tls internal', Caddy AUTOMATICALLY opens privileged port 80 for the HTTP->HTTPS redirect, EVEN when the site block is on :8443 — so it crash-looped with the same ':80 bind: permission denied', but this time while logging a clean startup first, which made it look like it had worked. The fix: a global 'auto_https disable_redirects' block, which is REQUIRED (not optional) for any tls-internal config under rootless Podman. The lesson: the same root cause (can't bind :80) resurfaced through a completely different trigger, and a clean-looking startup log hid a crash — you have to check that the service STAYS up, not just that it started."
  },
  validation: {
    heading: "Exit Criteria",
    points: [
      "HTTP 200 from Open WebUI directly AND via Caddy",
      "Open WebUI shows 3 models available (proves it reached Ollama)",
      "A file written to /data/rag is visible from inside the container"
    ]
  },
  discussion: [
    "Why does version drift between what a script assumes and what's actually installed cause exactly this class of bug?",
    "What's the real security tradeoff between lowering the unprivileged-port sysctl versus just moving your service to a higher port?",
    "How would you design a Quadlet file to be more version-tolerant from the start?"
  ],
  nextSession: "Phase 5 — AI Ingest Pipeline: documents, images, and audio, with a CUDA version mismatch bug worth knowing about."
},
{
  id: "lab05",
  title: "Phase 5 — AI Ingest Pipeline",
  subtitle: "Documents, OCR, and speech-to-text, with a real CUDA mismatch",
  objectives: [
    "Build a document/image/audio ingest pipeline feeding local RAG",
    "Understand idempotent processing via a content-hash manifest",
    "Diagnose a real CUDA library version mismatch on cutting-edge hardware"
  ],
  background: {
    heading: "What Gets Ingested, and How",
    points: [
      "Documents (DOCX/PDF/TXT/MD) via Docling",
      "Images via Docling OCR first, pytesseract as fallback, HEIC support via pillow-heif",
      "Audio via faster-whisper's 'medium' model — GPU-accelerated speech-to-text",
      "Output lands in /data/corpus/processed, deliberately decoupled from Open WebUI's own chat RAG — a standalone corpus, not wired into the UI's upload API"
    ]
  },
  architecture: {
    heading: "Idempotency via Content-Hash Manifest",
    points: [
      "A SQLite manifest tracks content hash + revision per file — re-running ingest doesn't reprocess unchanged files",
      "This idempotency check has to verify BOTH the database record AND that the claimed output file still physically exists — a real bug, covered below, showed why checking only the database isn't sufficient",
      "Runs as a systemd timer every 4 hours, not continuously — a batch job, not a live stream"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "Isolated ai-ingest venv (Phase 2) keeps this pipeline's dependencies separate from sigint-processing's",
      "GPU acceleration for Whisper is attempted first, with an explicit fallback to CPU rather than trusting the library's own claimed auto-fallback",
      "Two purpose-built CUDA-12 packages installed alongside a CUDA-13 system stack — a deliberate compatibility patch, not an oversight"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "./scripts/phase5-ai-ingest.sh (no sudo)",
      "./scripts/phase5-validate.sh — round-trips a real document, image, and audio file through ingest",
      "Confirm all three land correctly in /data/corpus/processed with the expected extracted content",
      "Inspect the manifest: what happens if you delete a processed output file directly and re-run ingest?"
    ]
  },
  gotcha: {
    heading: "Real Bug: CUDA Version Mismatch on New Hardware",
    text: "On a real build with a cutting-edge GPU (driver reporting CUDA 13.2), faster-whisper's backend, ctranslate2, failed with 'Library libcublas.so.12 is not found or cannot be loaded' — because ctranslate2's published wheels hadn't caught up to CUDA 13 yet and specifically need CUDA 12's cuBLAS library, even on a system otherwise fully on CUDA 13. The fix: install nvidia-cublas-cu12 and nvidia-cudnn-cu12 as ADDITIONAL packages alongside the CUDA 13 stack — they coexist fine as separate files, no conflict. A second, subtler bug: the code's own comment claimed device='auto' would gracefully fall back to CPU if CUDA failed — a real test proved that claim wrong; it hard-failed instead. The fix wrapped the GPU attempt in an explicit try/except with a genuine CPU fallback, rather than trusting the library's internal behavior."
  },
  validation: {
    heading: "Exit Criteria",
    points: [
      "A test DOCX, PNG, and WAV file each produce correct extracted text",
      "GPU is confirmed active during Whisper transcription (or a genuine CPU fallback occurs cleanly)",
      "Re-running ingest against unchanged files correctly skips them"
    ]
  },
  discussion: [
    "Why can very new hardware/drivers actually cause MORE compatibility problems than older, more established combinations?",
    "What's the risk of trusting a library's documented 'graceful fallback' behavior without testing it yourself?",
    "How would you design a manifest system to be resilient against a file disappearing outside the pipeline's own control?"
  ],
  nextSession: "Phase 6.1 — ka9q-radio: wideband HF capture, and why the RX-888 gets its own dedicated ingest daemon."
},
{
  id: "lab06",
  title: "Phase 6.1 — ka9q-radio (RX-888 HF Ingest)",
  subtitle: "Wideband capture, many simultaneous channels, and a cross-phase permission gap",
  objectives: [
    "Understand radiod's wideband-capture-plus-channelization architecture",
    "Explain why this build deliberately does NOT route RX-888 through OpenWebRX+",
    "Diagnose a permission gap between two different system users"
  ],
  background: {
    heading: "What Makes radiod Different",
    points: [
      "radiod captures the ENTIRE HF spectrum at once and simultaneously demodulates many independent channels from that single wideband capture — no other tool in this stack does that",
      "Each configured channel (WWV and other time/beacon signals receivable at your site, ham bands, a wideband IQ tap) publishes as its own IP multicast stream — any downstream tool can subscribe independently (note: Canada's CHU shut down 22 Jun 2026 — pick beacons you can actually receive)",
      "This multicast architecture is exactly what later phases (SigMF export, occupancy tracking) need to consume RX-888 data without re-architecting anything"
    ]
  },
  architecture: {
    heading: "radiod vs OpenWebRX+ — one device, two roles",
    points: [
      "The RX-888 is a single-owner USB device: exactly one process can hold it. radiod (this phase) is the AI/occupancy path — many simultaneous channels published for arbitrary downstream consumption. OpenWebRX+ is the interactive human waterfall — one signal at a time, but a beautiful full-HF panorama",
      "Both are legitimate; they TIME-SHARE the hardware via scripts/rx888-mode.sh (ai | interactive | status), which stops the other owner and waits for USB release before switching. 'ai' (radiod) is the always-watching default; 'interactive' hands it to OpenWebRX+ and pauses AI HF occupancy",
      "Key insight on value: for a SINGLE narrow channel the three SDRs are peers to the AI, but only the RX-888 (via radiod) can feed the AI EVERY HF band at once, continuously, with no sweeping blind spots — so it matters MORE for the AI mission than for the waterfall it was originally bought for",
      "There is no clean native path for OpenWebRX+ to consume radiod's streams (radiod emits demodulated PCM / a raw-IQ format OpenWebRX+ can't ingest) — hence time-sharing, not simultaneous sharing"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "radiod's own system user ('radio') is created by its own install process, separate from any interactive human user",
      "Firmware path handling is explicitly best-effort — verified against radiod's own startup log, not assumed",
      "FFTW wisdom generation started back in Phase 2 pays off here — radiod's own high-effort planning has a head start"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab (requires RX-888 MkII)",
    steps: [
      "sudo ./scripts/phase6-ka9q-radio.sh",
      "./scripts/phase6-ka9q-radio-validate.sh — a real pcmrecord capture from a live channel, not just service-active status",
      "Verify firmware loaded correctly by checking radiod's own startup log",
      "Subscribe to a multicast channel manually and confirm real audio/IQ data is flowing"
    ]
  },
  gotcha: {
    heading: "Real Bug: A Source Build That Broke on a Driver You Don't Use",
    text: "On the first real-hardware run, the ka9q-radio build failed hard: 'fobos.c:16: fatal error: fobos.h: No such file'. A recent ka9q-radio 'main' had pulled the Fobos SDR driver (fobos.c) into the DEFAULT build path — but per ka9q's own notes it should only compile with 'make FOBOS=1', it needs third-party libfobos headers that aren't installed, and no Fobos device is present. The fix that the whole ka9q ecosystem uses: pin to a known-working commit (e1224dcd, the one projecthorus/auto_rx pins) rather than tracking a fast-moving main branch. Once pinned, everything that had been FLAGGED as risky worked on the first proper attempt: radiod uploaded the RX-888 firmware itself, the device re-enumerated to USB3, the dedicated 'radio' system user's USB permissions worked (a cross-user permission gap we'd anticipated but which resolved cleanly), 18 demodulators started, and validation captured 716 KB of real WWV 10 MHz AM audio. The lesson: pinning a source dependency to a tested commit is not paranoia — a fast-moving upstream WILL break your default build path eventually, on a component you don't even use."
  },
  validation: {
    heading: "Exit Criteria (all confirmed on real hardware)",
    points: [
      "radiod active, demodulators started (WWV, 20m/40m FT8, APRS, CW, LSB/USB, wideband-iq — channel list is site-specific), no firmware errors",
      "A real pcmrecord capture succeeds from a live multicast channel (confirmed: 716 KB of WWV 10 MHz AM audio)",
      "The 'radio' system user has confirmed USB access — and the RX-888 re-enumerated to USB3 (5000M) after radiod loaded its firmware"
    ]
  },
  discussion: [
    "Why is pinning a source dependency to a tested commit worth the loss of 'latest' — and what class of failure does tracking a moving 'main' expose you to?",
    "The RX-888 is a single-owner device shared between radiod and OpenWebRX+. How do you design a safe switch that can't leave both fighting for the hardware?",
    "Why is 'many simultaneous channels from one capture' architecturally different from 'many separate captures,' and what does that make possible for AI occupancy that a swept narrowband SDR cannot?"
  ],
  nextSession: "Phase 6.2 — Decode Layer: GNU Radio, direwolf, multimon-ng, and the system-Python venv boundary."
}
];
