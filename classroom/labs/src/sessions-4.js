// Sessions: Phase 6.6, and the final Use Cases session
module.exports = [
{
  id: "lab11",
  title: "Phase 6.6 — Occupancy Database",
  subtitle: "A Kismet-inspired schema, and turning RF energy into queryable data",
  objectives: [
    "Design an occupancy database schema using Kismet's proven pattern as a reference, not a standard to copy blindly",
    "Understand the real adaptation needed when RF signals lack a durable identity the way MAC addresses give WiFi devices",
    "Run and calibrate the two real occupancy producers — radiod (continuous HF) and the device-flexible HackRF/RTL-SDR key-frequency producer (on-demand VHF/UHF) — that actually populate the database"
  ],
  background: {
    heading: "What 'Occupancy' Means Here",
    points: [
      "Standard RF/spectrum-management terminology: is a given frequency in use, over what time window, at what duration — not signal classification, not raw detection, specifically frequency+time+duration of use",
      "No single existing standard defines a machine-readable RECORD format for this the way SigMF standardizes IQ captures",
      "Kismet's kismetdb schema is the closest real, proven precedent — not because it's a broad interoperability standard (it isn't; other tools consume Kismet's EXPORTS, not its native format directly), but because its DEVICES/PACKETS split is a directly analogous, battle-tested pattern"
    ]
  },
  architecture: {
    heading: "signals + sightings, Adapted From DEVICES + PACKETS",
    points: [
      "sightings (-> Kismet's PACKETS): one row per detection event — lean columns for fast queries",
      "signals (-> Kismet's DEVICES): a long-lived aggregate, keyed by frequency (binned) + mode — substituting for the durable MAC address identity that RF signals generally don't have",
      "Paired epoch-seconds + milliseconds timestamp fields, matching Kismet's actual convention (mirrors C's tv_sec/tv_usec struct split) — deliberately NOT a single combined millisecond integer",
      "Zero dependencies beyond the Python standard library — any future producer, regardless of venv or system-Python context, can call directly into it"
    ]
  },
  decisions: {
    heading: "Key Design Decisions",
    points: [
      "SQLite with WAL journaling + busy_timeout, so multiple producers write concurrently without contention — this is what lets radiod stream continuously while the on-demand VHF/UHF producer writes at the same time",
      "FREQUENCY_BIN_HZ (a placeholder value) determines how close two reported frequencies must be to count as 'the same signal' — explicitly flagged as needing real-world tuning, not asserted as correct",
      "Two producers actually populate the DB, each calling the same record_sighting(): radiod (continuous, ~17 demodulated HF channels, first to populate it) and one device-flexible key-frequency producer that drives either the HackRF (primary, Comet GP-1 antenna) or the RTL-SDR (backup, broadband antenna) on-demand for VHF/UHF. The older GNU Radio single-frequency monitors were never hardware-validated and are superseded by this producer.",
      "Each producer/device carries its OWN calibrated threshold, because each has a different noise floor and even opposite gain behavior — see the calibration lesson below"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "./scripts/phase6-occupancy-db-validate.sh — confirms schema, frequency-binning, and aggregate tracking with real functional tests",
      "Confirm the continuous radiod occupancy producer is running (systemd --user radiod-occupancy.service) and has populated the DB — this is the source that first filled it",
      "Run the VHF/UHF key-frequency producer on-demand against real hardware: python3 decode/vhf_uhf_key_freq_producer.py --device hackrf --once --verbose (or --device rtlsdr) — observe the per-channel dBFS readings and the quiet/ACTIVE split",
      "Query occupancy.db directly and inspect a signals row's aggregate first_seen/last_seen/total_sightings",
      "Install the occupancy native tool in Open WebUI (see docs/openwebui-setup-guide.md) and ask the local LLM a natural-language question — e.g. 'Call query_occupancy near 10 MHz' — closing the capture->DB->AI loop"
    ]
  },
  gotcha: {
    heading: "Real Lessons: Calibration Is Where the Truth Lives",
    text: "Calibrating three different devices taught the same discipline from several angles. First, suspiciously identical readings across two very different bands were the diagnostic clue that something other than real noise was being measured — traced to a continuous carrier being read as if it were background, and separately to an antenna inadequate for the frequency; the fix for the latter was a proper resonant antenna (a 2m/70cm vertical), NOT code. Second, the two SDRs discriminate at OPPOSITE gain extremes: the HackRF's power readout clamps near -30 dBFS below high gain (so it only separates signal from floor at LNA 40+), while the RTL-SDR compresses at high gain and works best at MINIMUM gain — a single 'sensible' gain guess would have been wrong for one of them. Third, a single reference sample misleads: the RTL-SDR's first sweep looked alarmingly busy until three sweeps revealed the true floor and one genuine transmission standing well above it. The through-line: don't trust a calibration number because the tool ran without error — sanity-check against physical expectation, calibrate per device against its own floor, and take multiple samples before believing any of them."
  },
  validation: {
    heading: "Exit Criteria",
    points: [
      "Occupancy DB schema applies cleanly and passes its functional test suite",
      "The radiod producer is confirmed populating the DB continuously; the VHF/UHF key-freq producer runs on-demand and shows a sane quiet/ACTIVE split against its calibrated per-device threshold",
      "The occupancy native tool answers a natural-language question from real DB data in Open WebUI — the capture->DB->AI loop is closed end to end"
    ]
  },
  discussion: [
    "Why doesn't a fixed-size frequency bin work equally well for a 125kHz LoRa channel and a 20MHz WiFi channel?",
    "What real-world antenna or RF-path problem would produce two suspiciously identical noise-floor readings at very different frequencies?",
    "If you had to extend this schema to also track signal BANDWIDTH occupancy, not just center frequency, what would you add?"
  ],
  nextSession: "Final Lab — Use Cases of Sovereign SIGINT: putting the whole stack to work, and previewing the final project."
},
{
  id: "lab12",
  title: "Final Lab — Use Cases of Sovereign SIGINT",
  subtitle: "Putting the whole stack to work",
  objectives: [
    "Synthesize all six build phases into real, applied SIGINT use cases",
    "Understand how the AI stack augments raw capture — via native in-process tools that let the local LLM query THREE live sources (occupancy, Kismet WiFi devices, the SigID reference catalog) in natural language",
    "Walk the end-to-end unknown-signal identification workflow that ties those sources together",
    "Preview the final project"
  ],
  background: {
    heading: "What the Full Stack Actually Enables",
    points: [
      "Raw RF capture (radiod continuous HF, plus on-demand VHF/UHF key-frequency producers) feeding a local occupancy database of what's actually on the air, when, and for how long",
      "SigMF-format archival captures for anything worth deeper offline analysis, interoperable with external tools",
      "A local, sovereign AI layer that reasons over what's been observed WITHOUT any cloud dependency — and reaches the data through NATIVE in-process Open WebUI tools, the reliable path for local models (external HTTP/OpenAPI tools proved unreliable to invoke; that lesson is part of the story)",
      "THREE live AI sources, each in its native shape: RF occupancy (what's active), Kismet WiFi device intelligence (what devices are present), and the SigID reference catalog (what a signal IS) — observation plus reference, all queryable in natural language",
      "Most of this was built and validated independently across the prior sessions; this session combines them and adds the native-tool query layer that turns separate databases into things one local model reasons across"
    ]
  },
  architecture: {
    heading: "Example Use Case Walkthroughs",
    points: [
      "Spectrum situational awareness: the occupancy native tool answering 'what's been active on 20m recently' in natural language — a working live query against the DB, not a summary of a stale export",
      "Unknown-signal identification (the flagship workflow): measure frequency/bandwidth on your receiver, have the vision model (gemma3:12b) describe the waterfall's shape, then — switching to the tool-capable model (qwen3:14b) — search the SigID reference tool by that shape and near that frequency, and confirm by triangulation (shape + frequency + bandwidth must agree). Vision alone is triage; vision + SigID + measured frequency is a defensible first ID. See docs/vision-signal-identification-guide.md.",
      "WiFi device intelligence: the Kismet native tool lets the LLM answer 'what access points were seen, with SSIDs and signal' from real capture — a different KIND of intelligence (device/protocol presence) than frequency occupancy, kept in its own native shape",
      "Physical security / asset discovery: Ubertooth and Evil Crow RF would extend this same sovereign-AI philosophy into Bluetooth/BLE and sub-GHz ISM bands — a genuinely different SIGINT domain (hardware groundwork laid in Phase 1; not yet wired into the AI layer)",
      "Emergency communications awareness: Winlink/APRS traffic monitoring entirely on infrastructure you control, relevant to ARES/RACES-style operations"
    ]
  },
  decisions: {
    heading: "What Makes These 'Sovereign' Rather Than Just 'Local'",
    points: [
      "No use case in this list requires an internet connection to function at query time — the SigID reference, the AI models, and the occupancy history are all already on the box",
      "Cloud LLMs remain available as a deliberate, opt-in escalation path for non-sensitive queries — not a silent default dependency",
      "This distinction matters most exactly where this course's audience works: environments where sending RF/signal data to a third party is not an acceptable default, regardless of how good that third party's model is"
    ]
  },
  labSteps: {
    heading: "Hands-On Lab",
    steps: [
      "Choose one use case from today's walkthrough and reproduce it end-to-end on your own build",
      "Document which phases of the stack you relied on, and which, if any, you found yourself wanting to extend",
      "Identify one genuine limitation you hit that wasn't covered in a prior lab session",
      "Group discussion: compare use cases chosen across the class"
    ]
  },
  gotcha: {
    heading: "A Course-Wide Reflection, Not a Single Bug",
    text: "Every prior lab session in this course documented a REAL failure encountered on real hardware — package renames, cross-user permission gaps, rate limits, gain settings, calibration sanity checks. None of these were manufactured for teaching purposes; they are the literal record of building this system once, honestly, with the mistakes included. The transferable skill this course has been teaching, session by session, isn't any single fix — it's the discipline of validating with a REAL test at every step, treating a suspicious result as a reason to dig deeper rather than move on, and being honest in your own documentation about what's confirmed versus what's still a guess. That discipline is what separates a system that happens to work once from one you can actually trust."
  },
  validation: {
    heading: "Exit Criteria for the Course",
    points: [
      "Can articulate, end-to-end, how a signal goes from antenna to an AI-answerable question in this system — including the native-tool query layer that closes the loop",
      "Has reproduced at least one complete use case on their own build — ideally the unknown-signal identification workflow across the vision and tool-capable models",
      "Is prepared to scope and propose a final project building on this foundation"
    ]
  },
  discussion: [
    "Which single phase of this build do you think has the most direct application to your own professional or research context?",
    "Where would you draw the line between 'local by default' and 'cloud by exception' if you were deploying this in a real organization?",
    "What SIGINT use case would you want to pursue that this course's current architecture does NOT yet support?"
  ],
  nextSession: "Final Project (to be assigned) — building on this foundation."
}
];
