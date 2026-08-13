const {
  Document, Paragraph, TextRun, HeadingLevel, AlignmentType, PageBreak,
  Packer, LevelFormat, convertInchesToTwip,
} = require("docx");
const fs = require("fs");

const NAVY = "0B1929";
const CYAN = "0A7EA4";
const INK = "1A2733";
const MUTED = "5C7080";

function h1(text) {
  return new Paragraph({ text, heading: HeadingLevel.HEADING_1, spacing: { before: 360, after: 180 } });
}
function h2(text) {
  return new Paragraph({ text, heading: HeadingLevel.HEADING_2, spacing: { before: 280, after: 140 } });
}
function p(text, opts) {
  opts = opts || {};
  return new Paragraph({
    children: [new TextRun({ text, size: 22, italics: !!opts.italic, bold: !!opts.bold, color: opts.color || INK })],
    spacing: { after: 200 },
    alignment: AlignmentType.LEFT,
  });
}
function rich(parts, opts) {
  opts = opts || {};
  return new Paragraph({
    children: parts.map(part => new TextRun({
      text: part.text, bold: !!part.bold, italics: !!part.italic,
      font: part.mono ? "Courier New" : undefined,
      size: part.mono ? 20 : 22, color: part.color || INK,
    })),
    spacing: { after: 200 },
  });
}
function bullet(text) {
  return new Paragraph({
    text, numbering: { reference: "article-bullets", level: 0 },
    spacing: { after: 100 },
  });
}
function pull(text) {
  return new Paragraph({
    children: [new TextRun({ text, italics: true, size: 24, color: CYAN })],
    spacing: { before: 200, after: 300 },
    indent: { left: convertInchesToTwip(0.4), right: convertInchesToTwip(0.4) },
  });
}
function caption(text) {
  return new Paragraph({
    children: [new TextRun({ text, size: 18, italics: true, color: MUTED })],
    spacing: { after: 260 },
  });
}

const numbering = {
  config: [{
    reference: "article-bullets",
    levels: [{ level: 0, format: LevelFormat.BULLET, text: "\u25AA", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 720, hanging: 260 } } } }],
  }],
};

const sections = [];

// ---------- TITLE ----------
sections.push(
  new Paragraph({ text: "", spacing: { before: 600 } }),
  new Paragraph({
    children: [new TextRun({ text: "BUILDING SOVEREIGN SIGINT", bold: true, size: 56, color: NAVY })],
    spacing: { after: 160 },
  }),
  new Paragraph({
    children: [new TextRun({ text: "Signals Intelligence on Infrastructure You Actually Own", size: 28, italics: true, color: CYAN })],
    spacing: { after: 100 },
  }),
  new Paragraph({
    children: [new TextRun({ text: "A field account of designing and building a local, AI-assisted RF monitoring system \u2014 what worked, what broke, and what it teaches about combining sovereign AI with signals intelligence.", size: 22, color: MUTED })],
    spacing: { after: 500 },
  }),
);
// ---------- INTRODUCTION ----------
sections.push(
  h1("Introduction"),
  p("Most people who work in radio have, at some point, wanted a system that could listen everywhere at once, remember everything it heard, and tell them what was actually happening on the airwaves \u2014 without asking a cloud provider for permission or sending sensitive spectrum data to a third party to get an answer. That system is what this article describes: a real, working build of a sovereign SIGINT platform, assembled piece by piece, with every real failure left in rather than smoothed over."),
  p("\u201cSovereign\u201d here has a specific, narrow meaning, not a marketing one: every model, every reference dataset, and every signal capture lives on hardware the operator physically controls. Cloud AI is not forbidden \u2014 it remains available as a deliberate, opt-in escalation path for sanitized, non-sensitive queries \u2014 but nothing in the system depends on it by default. That distinction matters enormously in exactly the environments this kind of tool is built for: financial, defense, and critical-infrastructure contexts where sending RF telemetry to someone else's API is not a convenience decision, it's a compliance and trust decision."),
  p("This account draws on an actual build: a Dell Precision T5820 workstation, an RTX 5060 Ti GPU, and a real shelf of SDR hardware \u2014 HackRF, RTL-SDR, and an RX-888 MkII, all now working. Every bug described here is a real bug, diagnosed from a real error message, on real hardware. The goal isn't to present an idealized architecture; it's to show what building sovereign AI/SIGINT infrastructure actually looks like, including the parts that don't work on the first try \u2014 of which the RX-888, as it turned out, provided the single most instructive example in the entire build."),
);

// ---------- WHAT IS SOVEREIGN AI ----------
sections.push(
  h1("What \u201cSovereign AI\u201d Actually Means Here"),
  p("The architecture follows a simple governing rule: local by default, cloud by exception. A local large language model, running entirely on-premises through Ollama, handles the overwhelming majority of queries \u2014 summarizing what's been observed on a frequency, cross-referencing a captured waterfall against a reference catalog, answering a natural-language question about the last week of activity on a band. A cloud model like Claude is used only as a deliberate escalation, for sanitized, non-sensitive requests where a broader model's reasoning is genuinely useful and no operationally sensitive data needs to leave the building."),
  pull("The point isn't to reject cloud AI. It's to make sending data outward a conscious choice, not a silent default."),
  p("This posture has a real cost: local models are smaller and, for some tasks, less capable than the largest cloud offerings. The build accepts that cost deliberately. For a security-sensitive operator, a slightly less fluent local answer that never leaves the premises is worth more than a more eloquent one that does."),
);
// ---------- WHY SIGINT BENEFITS FROM AI ----------
sections.push(
  h1("Why SIGINT Benefits From AI Specifically"),
  p("Signals intelligence has always generated more raw material than any human operator can absorb in real time \u2014 a waterfall display full of activity, hours of recorded traffic, a reference catalog of hundreds of known signal types that no one memorizes completely. AI doesn't replace the RF engineering; it replaces the tedious parts of correlating what's been captured against what's known, and it makes that correlation queryable in plain language rather than requiring a manual lookup every time."),
  p("Three concrete capabilities emerge once a local LLM sits alongside a capture pipeline:"),
  bullet("Natural-language spectrum queries \u2014 asking \u201cwhat's been active on 2 meters this week\u201d and getting a real answer synthesized from logged activity, instead of manually scrolling a log."),
  bullet("Vision-assisted signal identification \u2014 handing a captured waterfall image to a vision-capable model and asking it to compare the shape against a reference library of known signal types, as a first-pass triage before deeper analysis."),
  bullet("Summarization of long capture sessions \u2014 turning a shift's worth of raw detections into a short, readable brief, which matters more than it sounds once you've tried to hand-write one after a long monitoring session."),
  p("None of this requires the AI to understand RF physics. It requires the AI to be good at retrieval, comparison, and language \u2014 which is exactly what current local models are good at, and exactly why pairing a modest local LLM with a well-organized reference catalog and a structured activity log outperforms either piece alone."),
);
// ---------- LLM CHOICE (DEEPEST TECHNICAL SECTION) ----------
sections.push(
  h1("Choosing the Models: A Task-Driven Approach, Not a Single Model"),
  p("The single most common mistake in a local-AI build is treating model selection as picking one model to do everything. This build instead runs three models, each doing a genuinely different job, coexisting on a single 16GB GPU because Ollama loads only the model actually in use for a given request rather than holding all three resident simultaneously."),
  h2("qwen3:14b \u2014 General Reasoning and Synthesis"),
  p("This is the model that actually talks to the operator: answering natural-language questions, summarizing activity, reasoning about what a set of observations might mean together. At roughly 9.3GB on disk, a 14-billion-parameter model is a deliberate middle-ground choice \u2014 large enough to reason competently about multi-step questions, small enough to run comfortably alongside the other two models' VRAM needs and leave headroom for whichever GPU-accelerated SIGINT tooling (Whisper transcription, GNU Radio processing) happens to be running at the same time."),
  p("Worth naming directly, because it surprised a real test during this build: qwen3's responses can include a visible chain-of-thought section before the final answer. That's normal behavior for this model family, not a bug \u2014 it's the model showing its reasoning, and most chat interfaces (including Open WebUI) render it as a collapsible block rather than inline noise. It's worth knowing about before it shows up unannounced in a live demo."),
  h2("nomic-embed-text \u2014 The Retrieval Backbone"),
  p("At only 274MB, this is by far the smallest of the three models, and it does the least glamorous job: converting text into numerical embeddings for retrieval-augmented generation (RAG). Every reference document, every synced signal-catalog entry, every piece of the ingested corpus gets embedded through this model so that a later query can find the passages actually relevant to it, rather than the LLM guessing from parametric memory alone."),
  pull("A capable reasoning model with no retrieval layer will confidently make things up. A retrieval layer with a mediocre reasoning model will at least surface the right source material. Both are needed; neither substitutes for the other."),
  h2("gemma3:12b \u2014 Vision"),
  p("The only one of the three models that can look at an image, at roughly 8.1GB. Its role in this build is specifically visual comparison \u2014 given a captured spectrogram or waterfall screenshot, asking whether its shape resembles a known signal type from the reference catalog. This is deliberately framed as triage, not final identification: a vision model's job here is narrowing the search, not delivering a certified answer, since RF signal identification ultimately depends on more than visual shape (timing, bandwidth, protocol behavior)."),
  h2("Why Not One Larger Model"),
  p("A single large multimodal model could technically attempt all three jobs. Three considerations argue against it here. First, VRAM: a single model large enough to be excellent at reasoning, embeddings, and vision simultaneously would likely not fit in 16GB alongside everything else this box needs to run. Second, embeddings specifically benefit from a model trained and evaluated for that exact task \u2014 a general chat model repurposed for embeddings is rarely as good as a purpose-built embedding model at the same size. Third, and most practically: Ollama's own architecture rewards having several right-sized models it can swap in and out, rather than one oversized model sitting in VRAM at all times whether or not the current task needs its full capability."),
  p("The transferable lesson for anyone building a similar system: choose models by the job, not by leaderboard ranking. A 274MB embedding model that's actually good at embeddings will outperform a 70-billion-parameter generalist pressed into the same role."),
);
// ---------- HARDWARE: HACKRF AND RTL-SDR ----------
sections.push(
  h1("Understanding the Hardware: HackRF and RTL-SDR"),
  p("Software-defined radio replaces purpose-built receiver circuitry with a general-purpose analog-to-digital front end and does the actual demodulation, filtering, and decoding in software. Two devices did essentially all of the receive-side work in this build, and they are different enough in character that understanding both is genuinely useful, not just a shopping decision."),
  h2("RTL-SDR: The Accidental Standard"),
  p("The RTL-SDR's origin story is almost folklore in the SDR world: a DVB-T TV tuner dongle, built around the Realtek RTL2832U chip, that a community discovered could be coaxed into streaming raw IQ samples instead of decoded television \u2014 turning a five-dollar TV tuner into a general-purpose receiver. Modern RTL-SDR Blog v3/v4 dongles, the ones used in this build, use a Rafael Micro R820T tuner and cover roughly 24MHz to 1.7GHz natively, with a documented gap in coverage around 1.1\u20131.25GHz."),
  p("Two real, hard-won lessons from actually operating this hardware are worth passing on directly. First: RF gain lives in specific, sometimes non-obvious configuration locations \u2014 in OpenWebRX+, the live receiver panel's own gain control does not reliably persist the way a per-profile gain setting does, and the difference between the two produced, in a real test, the difference between an indistinguishable, muddy waterfall and clean reception. Second: the recurring console warning \u201c[R82XX] PLL not locked!\u201d looks alarming but is frequently benign on this exact tuner chip \u2014 real captures succeeded cleanly despite the warning appearing on nearly every session. The lesson generalizes: don't treat every console warning as a failure signal; correlate it against whether the actual data coming out is good."),
  p("A genuinely underappreciated capability of RTL-SDR v3/v4 boards specifically: HF reception via direct sampling mode, with no physical hardware modification at all. A software flag (direct_samp=2 for these boards, routing through the tuner's Q-branch) reroutes the ADC to sample directly rather than through the tuner chip, extending usable reception down into the HF bands \u2014 at a real cost, since bypassing the tuner also bypasses its amplification, so sensitivity drops meaningfully compared to normal VHF/UHF reception through the tuner path."),
  h2("HackRF: Wide, Simple, and Half-Duplex"),
  p("HackRF One covers an enormously wider range \u2014 roughly 1MHz to 6GHz \u2014 at the cost of coarser resolution (8-bit samples, versus RTL-SDR's 8-bit unsigned format handled slightly differently) and half-duplex operation, meaning it can transmit or receive but not both simultaneously. Where RTL-SDR is the specialist that happens to cover a huge swath of spectrum cheaply, HackRF is the generalist: one device reasonably capable across VHF, UHF, and well beyond, useful for everything from 2-meter amateur packet and ADS-B aircraft transponders to ISM-band devices and LoRa."),
  p("A genuinely instructive real-world lesson from this build involves neither device's electronics at all, but the antenna. Early threshold-calibration attempts on HackRF produced suspiciously identical noise-floor readings across two completely different bands \u2014 down to a tenth of a decibel. A real off-air noise floor should differ meaningfully between such different frequencies; the near-identical readings were themselves the diagnostic clue that something other than actual atmospheric noise was being measured. The cause, given HackRF's small stock antenna, was simply an inadequate antenna for the frequencies in question. The fix was not in code at all: moving the HackRF to a proper resonant antenna (a dual-band 2m/70cm base vertical) and the RTL-SDR to its own antenna made the bands behave as physics says they should \u2014 a quiet noise floor with real signals standing clearly above it. No amount of correct code compensates for an antenna that isn't coupling real energy into the receiver; conversely, once the antenna was right, the same calibration approach worked cleanly."),
  h2("The RX-888 MkII: A Cautionary Tale About Diagnosing the Wrong Layer"),
  p("The RX-888 MkII is a considerably more advanced device \u2014 a high-resolution direct-sampling receiver that captures the entire HF spectrum at once and channelizes many simultaneous demodulated signals from that single wideband capture, via a dedicated daemon (ka9q-radio's radiod) rather than a general SDR application. Getting it working produced the most instructive failure of the whole build, and it is worth telling in full because the lesson is general."),
  p("The symptom: a brand-new RX-888 stubbornly enumerated at USB2 speed (480 Mbps), never the USB3 (5 Gbps) it needs. What followed was a methodical elimination of every plausible cause \u2014 every USB port on the workstation, two different cables including the vendor's own, a full BIOS audit (every USB3 and xHCI setting already correct), and finally the purchase of a dedicated USB3 PCIe expansion card. None of it moved the device to USB3. Each test was thorough, each conclusion reasonable, and every single one was chasing the wrong layer."),
  p("The actual cause: the RX-888's Cypress FX3 controller powers up in DFU (bootloader) mode with no firmware loaded, and in that state it enumerates at USB2 BY DESIGN. It only re-enumerates at USB3 after firmware is uploaded to it. The device was never going to show USB3 while sitting unconfigured \u2014 so every port, cable, and BIOS test had been run against a device that physically could not exhibit the behavior being tested for. Compounding it, the validation script itself had a bug: it never passed the firmware-upload flag, so it couldn't trigger the re-enumeration that would have revealed the truth. Once firmware was uploaded, the device jumped to USB3 and streamed 486 megabytes in about eight seconds \u2014 roughly 60 MB/s, a rate physically impossible over USB2, and therefore proof beyond doubt that USB3 had been available all along."),
  p("The lesson generalizes well beyond this one device: a symptom that presents as a hardware or host-configuration problem can be a device-state problem entirely, and a confident, reasonable-sounding diagnosis (\u201cit must be the port\u201d) can burn days if it is aimed at the wrong layer of the stack. The discipline worth building is to ask, early and often, whether the thing you are testing is even in a state where the behavior you want is possible \u2014 before you start replacing hardware."),
  p("With the device working, radiod brings up eighteen simultaneous demodulated channels from a single wideband HF capture \u2014 WWV time stations, FT8 on multiple bands, APRS, CW, voice \u2014 each published as its own network multicast stream that any downstream tool can subscribe to. That is the architecture that makes the RX-888 uniquely valuable for AI-driven occupancy work: where HackRF and RTL-SDR must stare at one narrow slice or sweep with blind spots, the RX-888 feeds the analysis layer every HF band at once, continuously. It is a single-owner USB device, so it time-shares between radiod (the always-watching AI path) and OpenWebRX+ (an interactive human waterfall) through an explicit mode switch rather than running both at once."),
);
// ---------- WORKFLOWS ----------
sections.push(
  h1("Two Workflows: Browser-Based and Manual"),
  p("The build supports two genuinely different ways of actually receiving and working with signals, and they suit different tasks rather than one simply superseding the other."),
  h2("OpenWebRX+: The Browser-Based Path"),
  p("OpenWebRX+ turns a connected SDR into a live, multi-user, browser-accessible receiver \u2014 a waterfall display, tunable audio, and a set of built-in digital-mode decoders (packet/APRS, LoRa, FLEX and POCSAG paging, FT8 and related digital modes, and more) available to anyone pointed at the right URL, with no client software beyond a browser. Device profiles \u2014 center frequency, mode, gain \u2014 are configured through its own web interface rather than scripted, deliberately, since getting these settings wrong is easy and a live UI makes the mistake immediately visible rather than buried in a config file."),
  p("Its own Feature Report page, which simply lists every optional capability and states plainly why it is or isn't currently available, turned out to be a genuinely well-designed diagnostic tool in practice \u2014 more than once, a feature that appeared broken from its symptoms in the live UI turned out to have an entirely different, non-obvious cause once the Feature Report was actually read line by line rather than assumed from a single indicator."),
  h2("The Manual Path: GNU Radio and Direct Capture"),
  p("The alternative path skips the browser interface entirely: GNU Radio flowgraphs built directly against the hardware (via the gr-osmosdr abstraction layer, which lets the same flowgraph logic address HackRF, RTL-SDR, and other devices through one interface), doing custom signal processing \u2014 energy detection, feature extraction, or triggering a raw capture \u2014 with full control over exactly what happens to the sample stream."),
  p("This path is where genuinely custom SIGINT logic lives: an occupancy-detection flowgraph, for instance, that watches a specific frequency's power level against a calibrated threshold and logs a structured record every time real energy crosses that threshold for a sustained period, rather than relying on any built-in decoder to recognize a specific protocol."),
  p("The two paths are not mutually exclusive within the same build: OpenWebRX+ handles live human-facing monitoring and mode-specific decoding well; direct custom detection logic handles unattended occupancy work that no off-the-shelf receiver application was built to do. In practice the occupancy producers that shipped took the simplest form of that second path \u2014 not full GNU Radio flowgraphs but direct short captures via each device own command-line tool (pcmrecord for radiod, hackrf_transfer for the HackRF, rtl_sdr for the RTL-SDR), computing power from the samples. The lesson there was its own: the most robust integration is often the least elegant one that reliably works, not the most sophisticated abstraction."),
);
// ---------- OCCUPANCY ----------
sections.push(
  h1("The Occupancy Concept"),
  p("\u201cOccupancy\u201d is standard spectrum-management terminology, not something invented for this build \u2014 it describes whether a given frequency is in use, over what time window, and for how long. Regulatory bodies run occupancy surveys for exactly this reason: knowing how much allocated spectrum is actually being used, and when, is foundational spectrum-management information, independent of what any particular signal turns out to be."),
  p("That last distinction matters architecturally. Occupancy tracking deliberately answers a narrower question than \u201cwhat is this signal\u201d \u2014 it answers \u201cwas this frequency in use, from when to when, detected by which device.\u201d Signal identification (comparing a capture against the reference catalog) is a separate, optional layer built on top of an occupancy record, not baked into it."),
  h2("A Kismet-Inspired Design, Not a Kismet Dependency"),
  p("The occupancy database schema deliberately borrowed its shape from Kismet \u2014 the well-established WiFi/Bluetooth monitoring tool \u2014 specifically its split between a long-lived aggregate record per tracked entity and a lean, high-volume table of individual detection events. That pattern transferred cleanly, with one real adaptation required: WiFi devices have a durable identity handed to them for free by their MAC address; most RF signals don't have an equivalent. The practical substitute adopted here aggregates on frequency (grouped into a tunable bin size) plus mode, standing in for the MAC address Kismet gets for free."),
  p("A second, smaller but genuinely instructive design choice: timestamps are stored as a paired seconds-plus-milliseconds value, deliberately mirroring a very old, proven convention from C's struct timeval, rather than a single combined millisecond integer. The paired approach keeps the common case \u2014 querying by whole seconds \u2014 working against a clean integer field, while still preserving sub-second precision on the rare occasion it's actually needed."),
  h2("Turning Energy Into a Queryable Record"),
  p("In principle, occupancy tracking is what turns raw receiver output into something an LLM can reason about: a producer watches a frequency's power level, and when it crosses a calibrated threshold for long enough to be a real signal rather than noise, a structured record is written \u2014 frequency, timestamps, source device, and mode if known. In this build the RX-888/radiod producer feeds the database continuously, sweeping each of radiod's demodulated HF channels and writing a sighting whenever power crosses a calibrated threshold. A second device-flexible producer exists in the codebase to cover VHF/UHF from either the HackRF (primary) or the RTL-SDR (backup) on-demand, watching a fixed list of key 2m/70cm frequencies (APRS, simplex calling channels, local repeaters). It isn't wired as a service in the current build \u2014 a fair statement of the state: HF is verified end-to-end and populates the database continuously; VHF/UHF is designed, coded, and ready to run on a schedule when that becomes worth committing an adapter to. Each producer carries its own hand-calibrated threshold, because each device and antenna has its own noise floor and even its own quirks (the HackRF's power readout only discriminates at high gain; the RTL-SDR, counterintuitively, at its lowest). And the final link \u2014 an LLM answering a natural-language question like \u201cwhat's been active on 20 meters recently\u201d directly against the database \u2014 works: the local model calls a query tool, reads the live database, and answers with real signals and their sighting counts. The whole loop is closed \u2014 energy in the air becomes a calibrated power measurement, becomes a structured database row, becomes an answer the AI gives in plain language, entirely on local hardware."),
  pull("A calibrated threshold, not a guessed one, is what separates a genuinely useful occupancy log from a noisy one. Measuring a real noise floor before choosing a detection threshold is not an optional refinement \u2014 it's the difference between a log worth querying and one full of false detections."),
);
// ---------- LESSONS LEARNED ----------
sections.push(
  h1("Lessons Learned Along the Way"),
  p("Several transferable lessons surfaced repeatedly across this build, in contexts different enough that they're clearly general principles rather than one-off quirks of this particular hardware or software stack."),
  h2("Enumeration Is Not Validation"),
  p("A device showing up in a device list, or a package installing without error, proves far less than it appears to. This build's discipline was to require a real, sustained data capture, or a real end-to-end flowgraph execution, before considering any component actually working \u2014 not because caution is a virtue in itself, but because several real bugs (a USB permission gap, a missing secondary dependency, a rate limit) were invisible to a simple installed-successfully check and only surfaced when something real was actually run."),
  h2("Test as the User Who Will Actually Need It to Work"),
  p("One of the more subtle bugs in this build involved a permission validated correctly for one system user, then silently assumed to also cover a completely different system user created later by a separate service's own install process. The two accounts had no inherent relationship; proving access worked for one proved nothing about the other. Any permission or capability check is only as good as the identity it was actually tested under."),
  h2("A Suspiciously Clean Result Deserves More Suspicion Than an Error"),
  p("An outright failure announces itself. A calibration reading that returns without error but happens to be identical across two physically different situations \u2014 as happened when two very different frequency bands produced near-identical noise-floor readings \u2014 is a quieter, easier-to-miss signal that something is wrong. The habit worth building is sanity-checking a clean result against physical expectation, not just checking whether the tool reported success."),
  h2("Recoverable Failure Should Be Handled as Recoverable"),
  p("A single rate-limit response from an external server, encountered partway through a long synchronization job, once caused an entire multi-hour run to abort and lose all unsaved progress \u2014 because the original code treated any non-success response as fatal. Across a job making hundreds of external requests, a rate limit is an expected condition, not an exceptional one, and the fix (retrying with backoff, honoring the server's own retry guidance) reflects that distinction directly in the code rather than papering over it after the fact."),
  h2("Flag What's Actually Confirmed, Not What's a Reasonable Guess"),
  p("More than once during this build, a piece of code asserted something \u2014 a library's method name, a device's expected behavior \u2014 with more confidence than had actually been earned through testing. The useful practice, applied consistently once noticed, was flagging an unconfirmed assumption explicitly in the code itself, with a safe fallback, rather than presenting a guess as settled fact. Some of those guesses turned out correct once finally tested against real hardware; the discipline of flagging them mattered independently of how any individual guess happened to land."),
  h2("Version Drift Is a Recurring Category of Bug, Not a One-Off"),
  p("A renamed package between Linux distribution versions, a configuration key unsupported by an older installed version of a container tool, a systemd unit type that doesn't support the command a script assumed it would \u2014 these are all the same underlying failure mode wearing different clothes: an assumption about what a specific installed version supports, that happened to be wrong for the actual version present. The general defense is favoring interfaces designed to degrade gracefully across versions (a generic argument pass-through, for instance) over hardcoding to whatever happened to be available at the time the code was written."),
);

// ---------- CONCLUSION ----------
sections.push(
  h1("Where This Goes Next"),
  p("Getting that final link working was the build's most instructive stretch, because it took three attempts and the first two failed in ways worth keeping. The plan was to expose the occupancy data to the local LLM as a set of read-only query tools. The first attempt built them as a small MCP server \u2014 correct on its own, but the chat front end could not reach it, blocked by a genuine upstream bug in that front end's own tool client. The second re-exposed the identical tools as a plain web API, which sidestepped that bug and tested clean \u2014 yet the local models would not reliably pull the trigger on an external tool: they described the call they would make, or claimed they could not, without ever actually invoking it. The third attempt \u2014 the one that worked \u2014 moved the tools in-process, as a native extension the chat app runs itself, which is the path its own documentation recommends for local models. That fired: the model called the tool, read the live database, and answered. The lesson is not that any one piece was broken, but that the seam between a capable local model and a real data source is still finicky, and closing it took matching the integration style to what local models actually do reliably \u2014 not the most elegant abstraction, but the one that works."),
  h2("More Sources, Different Kinds of Intelligence"),
  p("Once that native-tool pattern worked for occupancy, it generalized to something the occupancy database was never meant to hold. Kismet \u2014 the WiFi/Bluetooth monitor whose schema had already inspired the occupancy design \u2014 captures a fundamentally different kind of observation: not what frequencies are busy, but what devices are present. Access points, clients, MAC addresses, advertised network names, signal strength, manufacturer. Rather than force that into the frequency-and-mode shape of the occupancy database, the build kept it in Kismet's own device-centric form and gave the AI a second native tool that reads Kismet's capture file directly. The reasoning that reads a SQLite file read-only \u2014 proven once for occupancy \u2014 transferred without drama; the local model now answers \u201cwhat access points did we see, and what were their signal levels\u201d from the same chat, calling a different tool against a different database. The design choice worth underscoring is the restraint: two sources, two native shapes, not one lowest-common-denominator table. Frequency occupancy and device presence are different questions, and forcing them into one schema would have degraded both. Kismet runs continuously as a system service, and a fifteen-minute timer stages a fresh copy of its capture to a stable path so the AI always sees current-within-fifteen-minutes data \u2014 a deliberate semi-live design that keeps the tool's file path fixed (Kismet names each session's file with a timestamp otherwise) and avoids reading a mid-write SQLite file directly, an easy trap when the underlying format uses WAL sidecars."),
  p("A third source completed the shift from observation to reference. Occupancy and Kismet both answer what was OBSERVED \u2014 what frequencies were busy, what devices appeared. Neither answers the question that actually matters when you see something unfamiliar: what IS this signal? For that the build mirrors a sovereign copy of the community signal-identification wiki \u2014 hundreds of documented signals, each with its frequency, mode, modulation, bandwidth, location, and a description, plus reference waterfall images. A third native tool lets the local model look these up by name or search them by characteristic (\u201cwhat signals use 8PSK,\u201d \u201cwhat is documented near 6 MHz\u201d), reading the mirrored catalog directly. Notably this source is a directory of files rather than a single database, yet the same native-tool pattern absorbed it without fuss \u2014 the shape of the underlying store mattered less than keeping the reasoning in-process where local models reliably invoke it. The three together make a genuine identification workflow: the occupancy and Kismet tools say what is present, the reference tool says what such a thing tends to be, and \u2014 paired with the vision model that can look at a captured waterfall and describe its shape \u2014 the local stack can triage an unknown signal by appearance, cross-check it against the reference catalog, and confirm against the frequency its own receiver measured. Three sources, three native shapes, one local model reasoning across all of them."),
  p("What is finished, and genuinely working, is the whole chain: a local AI stack that never depends on a cloud connection to function, a real signal-capture and export pipeline built on open standards, a growing local reference catalog of known signal types, a structured occupancy database populated continuously from live HF capture (with a companion VHF/UHF producer ready in code for when an adapter is scheduled to it), a device-intelligence source from Kismet in its own native shape, a mirrored signal-identification reference catalog, and a local LLM that queries all three in natural language and answers from them. The last mile is closed: you can ask the machine what has been active on the bands, what WiFi devices were seen, or what a given signal is likely to be, and it tells you from what it actually captured and cataloged, without a single packet leaving the building. That system \u2014 sovereign by design, validated by real hardware at every step, and honest about the false starts it took to get here \u2014 is the actual argument this article has tried to make: that combining AI with SIGINT doesn't require giving up control of your data to get real value from the combination."),
);
// ---------- ASSEMBLE + WRITE ----------
const doc = new Document({
  numbering,
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 }, // US Letter
        margin: { top: 1080, bottom: 1080, left: 1350, right: 1350 },
      },
    },
    children: sections,
  }],
});

Packer.toBuffer(doc).then(buffer => {
  fs.writeFileSync("./Building-Sovereign-SIGINT.docx", buffer);
  console.log("Article written.");
});
