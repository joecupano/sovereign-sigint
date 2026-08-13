// Sessions 1-4
module.exports = [
{
  id: "lab00",
  title: "Introduction to Sovereign SIGINT",
  subtitle: "Course Overview & Architecture",
  objectives: [
    "Define Sovereign AI and SIGINT, and why this course combines them",
    "Tour the full system architecture at a high level",
    "Understand the local-by-default, cloud-by-exception design philosophy",
    "Preview the lab sequence and final project"
  ],
  background: {
    heading: "What is Sovereign AI?",
    points: [
      "AI infrastructure you own and control end-to-end: models, data, and compute stay on your hardware",
      "No dependency on a cloud vendor's API, uptime, or data policies",
      "\"Local by default, cloud by exception\" — Claude/cloud LLMs used only for deliberate, sanitized, non-sensitive escalation",
      "Directly relevant to defense, financial, and critical-infrastructure contexts where data sovereignty is not optional"
    ]
  },
  architecture: {
    heading: "System Architecture",
    points: [
      "Hardware layer: RX-888 MkII (HF), HackRF (1MHz-6GHz), RTL-SDR (VHF/UHF), Ubertooth One (Bluetooth), Evil Crow RF v2 (sub-GHz)",
      "AI stack (Phases 3-5): Ollama for local LLM inference, Open WebUI as the interface, an ingest pipeline for documents/images/audio",
      "SIGINT stack (Phase 6): radiod for wideband HF capture, GNU Radio + decoders, a signal-ID reference mirror, a web SDR, a SigMF export layer, and an occupancy database",
      "Every phase is independently validated before the next one builds on it — a real, working exit criteria at each step, not just \"install succeeded\""
    ]
  },
  decisions: {
    heading: "Why This Course Structure",
    points: [
      "One lab session per build phase — students build the actual system, not a simulation of it",
      "Every technical decision in this course came from a real build, including the bugs — you'll see actual failures and actual fixes, not idealized happy-path instructions",
      "Hardware-first: nothing is assumed to work until it's proven with a real capture or a real query",
      "Final lab applies the whole stack to real SIGINT use cases; a final project (to be assigned) builds on that foundation"
    ]
  },
  labSteps: {
    heading: "Today's Lab",
    steps: [
      "Review the repository structure: github.com/joecupano/sovereign-sigint",
      "Read docs/build-order.md — the Quickstart section and Phase overviews",
      "Identify which hardware you have access to for your own build",
      "Sketch the six-phase build order from memory, then check it against the repo"
    ]
  },
  gotcha: {
    heading: "A Note on How This Course Works",
    text: "Every subsequent lab documents a real problem encountered on real hardware — package renames between Ubuntu versions, permission gaps between system users, rate limits on external APIs, sensitivity/gain settings that only reveal themselves with an antenna connected. This is intentional. Production systems fail in exactly these ways, and learning to diagnose them is the actual skill this course teaches — not memorizing a command sequence that only works once."
  },
  validation: {
    heading: "Exit Criteria for This Session",
    points: [
      "Can explain, in one sentence each, what Sovereign AI and SIGINT mean in this context",
      "Can name the six build phases in order",
      "Has cloned or has access to the sovereign-sigint repository"
    ]
  },
  discussion: [
    "What are the tradeoffs of sovereign/local AI versus a cloud API, for a security-sensitive organization?",
    "Why might a course combine AI infrastructure with amateur radio/SIGINT skills specifically?",
    "What hardware constraints do you expect to hit first, given your own available equipment?"
  ],
  nextSession: "Phase 1 — Hardware and Drivers: standalone validation of every SDR device before any application touches it."
},
{
  id: "lab01",
  title: "Phase 1 — Hardware & Drivers",
  subtitle: "Standalone validation before any application layer",
  objectives: [
    "Install and validate SDR hardware drivers independently of any consuming application",
    "Understand why RX-888 requires a fundamentally different install path than HackRF/RTL-SDR",
    "Run real capture tests, not just device enumeration",
    "Use the device-selection menu to install only the hardware you have"
  ],
  background: {
    heading: "Why Standalone Validation?",
    points: [
      "Every SDR application (GNU Radio, OpenWebRX+) links against the same shared driver library — HackRF via libhackrf, RTL-SDR via librtlsdr",
      "Proving the driver/USB layer works BEFORE any application touches it means a later failure is known to be a software/config issue, not a hardware one hiding underneath",
      "Enumeration (lsusb) is not proof of a working device — this course requires a real, sustained data capture at each phase"
    ]
  },
  architecture: {
    heading: "The RX-888 Exception",
    points: [
      "HackRF and RTL-SDR: one shared driver library, every application links against it",
      "RX-888 MkII has NO shared driver library — two entirely separate codebases (rx888_stream for validation, radiod for actual SIGINT ingest) each talk to raw USB directly, each loading firmware onto the device's Cypress FX3 chip",
      "CRITICAL and counterintuitive: an RX-888 with no firmware loaded sits in FX3 DFU/bootloader mode and enumerates at USB2 (480M) BY DESIGN — it only re-enumerates to USB3 (5000M) AFTER firmware is uploaded. A '480M' reading on a fresh device is NOT a USB3 fault, it's firmware-not-loaded-yet",
      "This means Phase 1's RX-888 validation MUST upload firmware (rx888_stream -f SDDC_FX3.img) before it can prove anything — and it proves the rx888_stream code path, not radiod's, which gets proven separately in Phase 6.1",
      "A recognized industry pattern, not unique to this project: USRP, bladeRF, and LimeSDR share this same firmware/FPGA-loading gap"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "Interactive device-selection menu — install only hardware you actually have connected, re-run any time to add more later",
      "git/build-essential/cmake/pkg-config live in Phase 1, not Phase 2 — they exist specifically to build RX-888's from-source driver",
      "usbfs_memory_mb raised for sustained USB3 streaming — required for the RX-888's high sample rates"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "sudo ./scripts/phase1-hardware-drivers.sh — select the devices you have connected",
      "Reboot (NVIDIA driver, usbfs_memory_mb persistence, initramfs blacklist all require it)",
      "./scripts/phase1-validate-sdrs.sh — confirm a real sustained capture for each SDR",
      "./scripts/phase1-validate-protocol-tools.sh — confirm Ubertooth/Evil Crow RF if selected",
      "Verify: cat /sys/module/usbcore/parameters/usbfs_memory_mb reads 1000, not 16"
    ]
  },
  gotcha: {
    heading: "Real Bug: The RX-888 'Stuck at USB2' Trap (a multi-day red herring)",
    text: "The most instructive failure in this entire build. A brand-new RX-888 showed only USB2 (480M) in lsusb, never USB3 (5000M) — across every port on a Dell T5820, two cables, a BIOS audit (all settings already correct), and ultimately the purchase of a dedicated USB3 PCIe card. NONE of that was the cause. The RX-888 sits in Cypress FX3 DFU/bootloader mode (04b4:00f3, 'DFU mode') until firmware is loaded, and in that state it enumerates at USB2 BY DESIGN. The Phase 1 validation script was ALSO buggy — it never passed the -f firmware flag, so it couldn't trigger the re-enumeration. Once firmware was uploaded, the device jumped to USB3 and streamed 486 MB in ~8 seconds (~60 MB/s, physically impossible over USB2 — proof positive). The lesson: a symptom that looks like a hardware/host problem can be a device-state problem entirely, and confident wrong diagnoses ('it must be the port') can burn days. Also note: the device returns to DFU mode only on a real power cycle, so back-to-back validation runs fail with LIBUSB_ERROR_NO_DEVICE unless you reboot/replug first. (Bonus real bug from the same phase: 'apt install librtlsdr0' failed — renamed to librtlsdr2 in 24.04 — and usbfs_memory_mb via modprobe.d was silently ignored because usbcore is built statically into this kernel; fixed with a GRUB boot parameter.)"
  },
  validation: {
    heading: "Exit Criteria",
    points: [
      "Each selected SDR produces a real, sustained data capture, not just device enumeration",
      "usbfs_memory_mb persists across a reboot",
      "Ubertooth (if selected) shows firmware version and a live capture window"
    ]
  },
  discussion: [
    "The RX-888 'USB2 problem' was really a device-state problem. How do you build a diagnostic discipline that catches a wrong assumption before it costs you days of chasing the wrong layer?",
    "Why does a device that enumerates at USB2 in DFU mode, then USB3 after firmware, defeat every port/cable/BIOS test you could run beforehand?",
    "Why does a shared driver library (HackRF/RTL-SDR) create a different risk profile than a device-specific firmware-loading codebase like RX-888's?"
  ],
  nextSession: "Phase 2 — OS Packages: rootless Podman, FFTW background wisdom generation, and the Python venv strategy for the rest of the build."
},
{
  id: "lab02",
  title: "Phase 2 — OS Packages",
  subtitle: "Rootless containers, FFTW, and the venv strategy",
  objectives: [
    "Configure rootless Podman correctly (subuid/subgid, lingering, cgroups v2)",
    "Understand why FFTW wisdom generation is kicked off early despite taking hours",
    "Learn the Python venv boundary strategy this build uses throughout",
  ],
  background: {
    heading: "Why Rootless Podman?",
    points: [
      "Every container in this build (Open WebUI, Caddy) runs without root privileges — a meaningfully smaller attack surface than Docker's traditional root daemon model",
      "Rootless containers need explicit subuid/subgid ranges and systemd lingering (so containers keep running after logout) — not defaults on a fresh Ubuntu install",
      "cgroups v2 unified hierarchy is a prerequisite most modern distros have by default, but it's still worth confirming rather than assuming"
    ]
  },
  architecture: {
    heading: "The Venv Strategy",
    points: [
      "Two isolated Python domains: ai-ingest (Docling, faster-whisper, OCR) and sigint-processing (numpy, scipy, sigmf)",
      "Neither venv uses --system-site-packages — deliberate isolation, so GNU Radio's system-Python bindings and this build's pinned Python dependencies never collide",
      "This boundary decision shows up again in Phase 6.2, where GNU Radio flowgraphs must run under system Python, not either venv"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "FFTW3 baseline wisdom generation kicked off in the BACKGROUND at Phase 2, immediately — it can take hours, so starting it early means it's likely done by the time Phase 6 actually needs it",
      "curl and sqlite3 both live here as general-purpose utilities other phases assume are present",
      "setup-venvs.sh is idempotent — safe to re-run any time a requirements.txt changes, not just once"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "sudo ./scripts/phase2-os-packages.sh",
      "./scripts/phase2-validate.sh — confirms 'podman run --rm hello-world' and venv creation both work",
      "Check on FFTW: tail -f /tmp/fftw-wisdom-phase2.log (this will still be running — that's expected)",
      "ps aux | grep fftwf-wisdom — confirm it's alive and burning CPU, not silently dead"
    ]
  },
  gotcha: {
    heading: "Real Lesson: Long-Running Background Jobs Are Not Bugs",
    text: "On the real build, a student (or instructor) checking on the FFTW wisdom file an hour in and seeing no output file yet might reasonably assume something failed. It hadn't — fftwf-wisdom only writes its output once, at the very end, and multi-million-point transform planning at default effort can genuinely take many hours. The correct diagnostic isn't 'is the file there,' it's 'is the process alive and using CPU.' This is a broader lesson: not every quiet process is a dead one."
  },
  validation: {
    heading: "Exit Criteria",
    points: [
      "podman run --rm hello-world succeeds",
      "A test venv creates and resolves a package from PyPI",
      "FFTW wisdom generation is confirmed running (not necessarily finished)"
    ]
  },
  discussion: [
    "What are the security tradeoffs of rootless versus rootful containers in a production environment?",
    "Why deliberately avoid --system-site-packages even though it would make some later steps simpler?",
    "When should a long-running background job worry you, versus when is 'it's just slow' the right diagnosis?"
  ],
  nextSession: "Phase 3 — Ollama: local LLM inference, and the first real cross-service networking bug of this build."
},
{
  id: "lab03",
  title: "Phase 3 — Ollama & AI Models",
  subtitle: "Local inference, GPU passthrough, and a real networking bug",
  objectives: [
    "Install Ollama natively for simpler GPU passthrough than a containerized alternative",
    "Understand the OLLAMA_HOST binding requirement for container-to-host communication",
    "Diagnose a real, multi-layered permission and networking failure"
  ],
  background: {
    heading: "Why Native, Not Containerized?",
    points: [
      "Routing Ollama through the NVIDIA Container Toolkit for a single service adds real complexity for no benefit here",
      "Native install means GPU passthrough is automatic — no container runtime GPU configuration to get wrong",
      "Models: qwen3:14b (general reasoning), nomic-embed-text (RAG embeddings), gemma3:12b (vision) — all fit comfortably on a 16GB GPU since Ollama loads one at a time"
    ]
  },
  architecture: {
    heading: "Where Ollama Sits",
    points: [
      "Ollama serves the model inference API that Open WebUI (Phase 4) and any future SIGINT AI features consume",
      "Runs as its own systemd service, under its own 'ollama' system user — not your interactive user, not root",
      "/data/models is where model weights physically live — a deliberate, narrow exception to this build's general /data ownership convention"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "OLLAMA_MODELS=/data/models keeps model weights on the shared data volume, not scattered under a user's home directory",
      "OLLAMA_HOST=0.0.0.0 required — Ollama's default (127.0.0.1-only) is unreachable from Open WebUI's container in Phase 4",
      "This is a real security tradeoff, not free: 0.0.0.0 exposes an unauthenticated API on the LAN, not just to the local container"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "sudo ./scripts/phase3-ollama.sh",
      "./scripts/phase3-validate.sh — confirms GPU inference is active and models physically live on /data/models",
      "Check GPU usage during inference: nvidia-smi should show an active compute process",
      "Confirm the embedding endpoint returns a proper vector (768 dimensions for nomic-embed-text)"
    ]
  },
  gotcha: {
    heading: "Real Bug: A Two-Layer Permission and Networking Failure",
    text: "On the real build, Open WebUI could not reach Ollama even after chowning /data/models to the ollama user. The actual chain of failures: (1) Ollama defaulted to binding 127.0.0.1 only, unreachable from a separate container network namespace — fixed with OLLAMA_HOST=0.0.0.0; (2) even after that fix, Ollama still failed to start with 'mkdir /data/models: permission denied' — because /data itself (the PARENT directory) was locked to the human operator's group, and the 'ollama' system user wasn't a member of that group. Chowning the child directory wasn't enough; the ollama user couldn't even traverse into the parent to reach it. The real fix was adding 'ollama' to the group that owns /data. Two independent bugs, discovered one at a time, each only visible by actually running the service and reading the exact error."
  },
  validation: {
    heading: "Exit Criteria",
    points: [
      "17GB+ present on /data/models",
      "A real inference request shows GPU compute activity via nvidia-smi",
      "The embedding endpoint returns a 768-dimension vector"
    ]
  },
  discussion: [
    "Why does chowning a subdirectory not guarantee a service can reach it?",
    "Given the LAN-exposure tradeoff of OLLAMA_HOST=0.0.0.0, what firewall rule would you add in a real deployment?",
    "What's the difference between a 'the service won't start' bug and a 'the service starts but can't be reached' bug, and how does your diagnostic approach differ?"
  ],
  nextSession: "Phase 4 — Open WebUI + Caddy: rootless Podman Quadlet units, and three more real bugs in a single install."
}
];
