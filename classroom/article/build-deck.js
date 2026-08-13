const pptxgen = require("pptxgenjs");

const NAVY = "0B1929";
const NAVY_LIGHT = "13273D";
const CYAN = "00A8CC";
const AMBER = "F4A300";
const WHITE = "FFFFFF";
const OFFWHITE = "F7F9FA";
const INK = "1A2733";
const MUTED = "5C7080";
const FONT_HEAD = "Cambria";
const FONT_BODY = "Calibri";

let pres = new pptxgen();
pres.layout = "LAYOUT_16x9";
pres.author = "Sovereign SIGINT";
pres.title = "Building Sovereign SIGINT";

function waterfallBands(slide, bandY, opac) {
  bandY.forEach((y, i) => {
    slide.addShape(pres.shapes.RECTANGLE, {
      x: 0, y: y, w: 10, h: 0.5,
      fill: { color: CYAN, transparency: 100 - opac[i] },
      line: { type: "none" },
    });
  });
}

function titleSlide(kicker, title, subtitle) {
  let slide = pres.addSlide();
  slide.background = { color: NAVY };
  waterfallBands(slide, [0.0, 0.55, 1.1, 1.65, 2.2], [85, 65, 45, 28, 14]);
  slide.addText(kicker.toUpperCase(), {
    x: 0.6, y: 2.6, w: 8.8, h: 0.5, fontFace: FONT_BODY, fontSize: 16,
    color: AMBER, bold: true, charSpacing: 3, margin: 0,
  });
  slide.addText(title, {
    x: 0.6, y: 3.05, w: 8.8, h: 1.3, fontFace: FONT_HEAD, fontSize: 38,
    color: WHITE, bold: true, margin: 0,
  });
  slide.addText(subtitle, {
    x: 0.6, y: 4.2, w: 8.8, h: 0.8, fontFace: FONT_BODY, fontSize: 17,
    color: CYAN, italic: true, margin: 0,
  });
  return slide;
}

function header(slide, kicker, heading) {
  slide.background = { color: OFFWHITE };
  slide.addText(kicker.toUpperCase(), {
    x: 0.6, y: 0.35, w: 8.8, h: 0.35, fontFace: FONT_BODY, fontSize: 13,
    color: CYAN, bold: true, charSpacing: 2, margin: 0,
  });
  slide.addText(heading, {
    x: 0.6, y: 0.68, w: 8.8, h: 0.75, fontFace: FONT_HEAD, fontSize: 27,
    color: NAVY, bold: true, margin: 0,
  });
}

function bulletSlide(kicker, heading, points) {
  let slide = pres.addSlide();
  header(slide, kicker, heading);
  const items = points.map((pt, i) => ({
    text: pt, options: { bullet: { code: "25AA" }, breakLine: i < points.length - 1, paraSpaceAfter: 14 },
  }));
  slide.addText(items, {
    x: 0.7, y: 1.75, w: 8.6, h: 3.6, fontFace: FONT_BODY, fontSize: 16,
    color: INK, valign: "top", lineSpacingMultiple: 1.18,
  });
  slide.addShape(pres.shapes.RECTANGLE, {
    x: 0, y: 5.35, w: 10, h: 0.275, fill: { color: NAVY }, line: { type: "none" },
  });
  return slide;
}

function pullQuoteSlide(kicker, heading, quote, attribution) {
  let slide = pres.addSlide();
  slide.background = { color: NAVY };
  slide.addText(kicker.toUpperCase(), {
    x: 0.6, y: 0.5, w: 8.8, h: 0.4, fontFace: FONT_BODY, fontSize: 14,
    color: AMBER, bold: true, charSpacing: 2, margin: 0,
  });
  slide.addShape(pres.shapes.RECTANGLE, {
    x: 0.7, y: 1.5, w: 0.08, h: 2.6, fill: { color: CYAN }, line: { type: "none" },
  });
  slide.addText(quote, {
    x: 1.1, y: 1.4, w: 8.0, h: 2.8, fontFace: FONT_HEAD, fontSize: 26,
    color: WHITE, italic: true, valign: "middle", margin: 0, lineSpacingMultiple: 1.25,
  });
  if (attribution) {
    slide.addText(attribution, {
      x: 1.1, y: 4.3, w: 8.0, h: 0.4, fontFace: FONT_BODY, fontSize: 14,
      color: CYAN, margin: 0,
    });
  }
  return slide;
}
function modelCardsSlide(kicker, heading, cards) {
  let slide = pres.addSlide();
  header(slide, kicker, heading);
  const cardW = 2.8, gap = 0.15, startX = 0.6, y = 1.7, h = 3.5;
  cards.forEach((c, i) => {
    const x = startX + i * (cardW + gap);
    slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
      x, y, w: cardW, h, rectRadius: 0.08,
      fill: { color: WHITE }, line: { type: "none" },
      shadow: { type: "outer", color: "000000", blur: 6, offset: 2, angle: 90, opacity: 0.1 },
    });
    slide.addShape(pres.shapes.RECTANGLE, {
      x, y, w: cardW, h: 0.5, fill: { color: NAVY }, line: { type: "none" },
    });
    slide.addText(c.name, {
      x: x + 0.1, y, w: cardW - 0.2, h: 0.5, fontFace: "Courier New", fontSize: 14,
      color: AMBER, bold: true, align: "center", valign: "middle", margin: 0,
    });
    slide.addText(c.role, {
      x: x + 0.15, y: y + 0.65, w: cardW - 0.3, h: 0.5, fontFace: FONT_HEAD, fontSize: 15,
      color: NAVY, bold: true, margin: 0,
    });
    slide.addText(c.size, {
      x: x + 0.15, y: y + 1.15, w: cardW - 0.3, h: 0.3, fontFace: FONT_BODY, fontSize: 12,
      color: CYAN, italic: true, margin: 0,
    });
    slide.addText(c.desc, {
      x: x + 0.15, y: y + 1.5, w: cardW - 0.3, h: h - 1.65, fontFace: FONT_BODY, fontSize: 11.5,
      color: INK, margin: 0, valign: "top", lineSpacingMultiple: 1.1,
    });
  });
  return slide;
}

function twoColumnSlide(kicker, heading, leftTitle, leftPoints, rightTitle, rightPoints) {
  let slide = pres.addSlide();
  header(slide, kicker, heading);
  const colW = 4.15, y = 1.65, h = 3.6;
  [[0.6, leftTitle, leftPoints, CYAN], [5.25, rightTitle, rightPoints, AMBER]].forEach(([x, t, points, accent]) => {
    slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
      x, y, w: colW, h, rectRadius: 0.07,
      fill: { color: WHITE }, line: { type: "none" },
      shadow: { type: "outer", color: "000000", blur: 5, offset: 2, angle: 90, opacity: 0.08 },
    });
    slide.addShape(pres.shapes.RECTANGLE, { x, y, w: colW, h: 0.06, fill: { color: accent }, line: { type: "none" } });
    slide.addText(t, {
      x: x + 0.25, y: y + 0.2, w: colW - 0.5, h: 0.5, fontFace: FONT_HEAD, fontSize: 18,
      color: NAVY, bold: true, margin: 0,
    });
    const items = points.map((pt, i) => ({
      text: pt, options: { bullet: { code: "25AA" }, breakLine: i < points.length - 1, paraSpaceAfter: 10 },
    }));
    slide.addText(items, {
      x: x + 0.25, y: y + 0.8, w: colW - 0.5, h: h - 1.0, fontFace: FONT_BODY, fontSize: 12.5,
      color: INK, valign: "top", lineSpacingMultiple: 1.1,
    });
  });
  return slide;
}

function darkHighlightSlide(kicker, heading, text) {
  let slide = pres.addSlide();
  slide.background = { color: NAVY };
  slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
    x: 0.6, y: 0.4, w: 2.3, h: 0.5, rectRadius: 0.25,
    fill: { color: AMBER }, line: { type: "none" },
  });
  slide.addText(kicker.toUpperCase(), {
    x: 0.6, y: 0.4, w: 2.3, h: 0.5, fontFace: FONT_BODY, fontSize: 12,
    color: NAVY, bold: true, align: "center", valign: "middle", charSpacing: 1, margin: 0,
  });
  slide.addText(heading, {
    x: 0.6, y: 1.05, w: 8.8, h: 0.8, fontFace: FONT_HEAD, fontSize: 23,
    color: WHITE, bold: true, margin: 0,
  });
  slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
    x: 0.6, y: 1.95, w: 8.8, h: 3.4, rectRadius: 0.08,
    fill: { color: NAVY_LIGHT }, line: { type: "none" },
  });
  slide.addText(text, {
    x: 0.95, y: 2.2, w: 8.1, h: 2.95, fontFace: FONT_BODY, fontSize: 14,
    color: OFFWHITE, valign: "top", lineSpacingMultiple: 1.25, margin: 0,
  });
  return slide;
}

function closingSlide(heading, subtext) {
  let slide = pres.addSlide();
  slide.background = { color: NAVY };
  waterfallBands(slide, [3.6, 4.15, 4.7, 5.25], [14, 28, 45, 65]);
  slide.addText(heading, {
    x: 0.6, y: 1.6, w: 8.8, h: 1.3, fontFace: FONT_HEAD, fontSize: 32,
    color: WHITE, bold: true, margin: 0,
  });
  slide.addText(subtext, {
    x: 0.6, y: 2.75, w: 8.8, h: 0.7, fontFace: FONT_BODY, fontSize: 16,
    color: CYAN, italic: true, margin: 0,
  });
  return slide;
}
// 1. Title
titleSlide("Field Report", "Building Sovereign SIGINT",
  "Signals intelligence, AI, and infrastructure you actually own");

// 2. Agenda
bulletSlide("Overview", "What We'll Cover", [
  "What \u201csovereign AI\u201d actually means, and why it matters for SIGINT specifically",
  "Choosing the models: a task-driven lineup, not one model doing everything",
  "Understanding the hardware: HackRF and RTL-SDR in real depth",
  "Two workflows: browser-based (OpenWebRX+) and manual (GNU Radio)",
  "The Occupancy concept \u2014 turning raw RF energy into queryable data",
  "Real lessons learned, pulled directly from an actual build",
]);

// 3. Sovereign AI concept
bulletSlide("Concept", "Local by Default, Cloud by Exception", [
  "Every model, reference dataset, and signal capture lives on hardware the operator physically controls",
  "A local LLM (via Ollama) handles the overwhelming majority of queries \u2014 summarization, cross-referencing, natural-language lookups",
  "Cloud AI is not forbidden \u2014 it remains a deliberate, opt-in escalation path for sanitized, non-sensitive queries only",
  "Matters most in exactly the environments this tool is built for: financial, defense, and critical-infrastructure contexts",
]);

// 4. Pull quote
pullQuoteSlide("The Core Principle", "",
  "\u201cThe point isn't to reject cloud AI. It's to make sending data outward a conscious choice, not a silent default.\u201d");

// 5. Why SIGINT benefits from AI
bulletSlide("Why AI + SIGINT", "Three Capabilities the Pairing Is Built to Enable", [
  "Natural-language spectrum queries \u2014 \u201cwhat's been active on 20 meters\u201d, answered live from logged activity (working: the radiod producer feeds the occupancy DB continuously from live HF, and a native tool lets the local LLM query it and answer with real signals; a companion VHF/UHF producer exists in code but isn't wired as a service yet)",
  "A second AI source, different in kind: Kismet WiFi capture (APs, clients, MACs, SSIDs, signal) via its own native tool over kismetdb \u2014 kept in device-centric shape, not flattened into occupancy; semi-live via a 15-min refresh",
  "A third AI source \u2014 reference, not observation: a mirrored signal-ID catalog (hundreds of signals with frequency, mode, modulation, bandwidth, description) via a native tool (lookup by name, search by characteristic). Occupancy + Kismet say what is present; SigID says what it is \u2014 and paired with the vision model, triage an unknown by shape, cross-check the catalog, confirm by measured frequency",
  "Vision-assisted signal identification \u2014 comparing a captured waterfall against a reference catalog of known signal types",
  "Summarization of long capture sessions \u2014 turning a shift's worth of detections into a short, readable brief",
  "None of this requires the AI to understand RF physics \u2014 it requires retrieval, comparison, and language, which is exactly what current local models do well",
]);

// 6. Model lineup cards
modelCardsSlide("Deepest Technical Section", "Choosing the Models: Three Jobs, Three Models", [
  { name: "qwen3:14b", role: "General Reasoning", size: "~9.3 GB", desc: "Talks to the operator: answers questions, summarizes activity, reasons across multiple observations." },
  { name: "nomic-embed-text", role: "Retrieval Backbone", size: "~274 MB", desc: "Embeds every reference document and corpus entry for RAG \u2014 the smallest model, doing the least glamorous but most essential job." },
  { name: "gemma3:12b", role: "Vision", size: "~8.1 GB", desc: "The only model that can look at an image \u2014 comparing a captured spectrogram against known signal shapes, as triage, not final ID." },
]);

// 7. Why not one model
bulletSlide("Design Rationale", "Why Not One Larger Model", [
  "VRAM: a single model excellent at reasoning, embeddings, AND vision at once likely won't fit in 16GB alongside everything else the box runs",
  "Embeddings specifically benefit from a model trained and evaluated for that exact task \u2014 a repurposed chat model rarely matches a purpose-built embedder at the same size",
  "Ollama loads one model at a time \u2014 three right-sized models that swap in and out beats one oversized generalist sitting in VRAM regardless of whether the current task needs it",
  "Transferable lesson: choose models by the job, not by leaderboard ranking",
]);
// 8. Hardware: RTL-SDR vs HackRF comparison
twoColumnSlide("Deepest Technical Section", "Understanding the Hardware",
  "RTL-SDR", [
    "Originally a $5 DVB-T TV tuner dongle, repurposed by the community into a general-purpose receiver",
    "R820T tuner covers ~24MHz\u20131.7GHz natively (with a gap ~1.1\u20131.25GHz)",
    "RTL-SDR Blog v3/v4: HF reception via direct sampling mode \u2014 no hardware mod, but bypasses tuner amplification",
    "Gain must live in the correct config location \u2014 confirmed the hard way",
  ],
  "HackRF One", [
    "Wide range: ~1MHz\u20136GHz, at coarser 8-bit resolution",
    "Half-duplex \u2014 transmit or receive, not both at once",
    "The generalist: one device reasonably capable across VHF, UHF, and well beyond",
    "A stock antenna can silently invalidate a calibration \u2014 suspiciously identical readings across two different bands was the clue; the fix was a proper resonant antenna, not code",
  ]
);

// 9. RX-888 — the diagnosis-the-wrong-layer story
bulletSlide("The Most Instructive Bug", "RX-888 MkII \u2014 Diagnosing the Wrong Layer", [
  "Symptom: brand-new RX-888 stuck at USB2 (480M), never USB3 (5000M) \u2014 needs USB3 to work at all",
  "Chased: every port, two cables, a full BIOS audit, and a USB3 PCIe card purchase \u2014 all reasonable, all wrong",
  "Actual cause: the Cypress FX3 powers up in DFU/bootloader mode and enumerates at USB2 BY DESIGN \u2014 it only jumps to USB3 AFTER firmware is uploaded. Every test ran against a device that couldn't yet show the behavior being tested",
  "Proof it worked all along: once firmware loaded, 486 MB captured in ~8s (~60 MB/s \u2014 impossible over USB2)",
  "Lesson: a symptom that looks like hardware can be device-state; ask whether the thing is even in a state where the wanted behavior is possible BEFORE replacing hardware",
]);

// 9b. RX-888 working — the payoff
bulletSlide("The Payoff", "RX-888 + radiod \u2014 Why It Matters for AI", [
  "radiod brings up 18 simultaneous demodulated channels from ONE wideband HF capture \u2014 WWV, FT8, APRS, CW, voice \u2014 each a network multicast stream",
  "For a single narrow channel, the three SDRs are peers to the AI; only the RX-888 feeds it EVERY HF band at once, continuously, with no sweeping blind spots",
  "So it matters MORE for the AI/occupancy mission than for the interactive waterfall it was originally bought for",
  "Single-owner device: time-shares between radiod (always-watching AI) and OpenWebRX+ (interactive human waterfall) via an explicit mode switch",
]);

// 10. Two workflows
twoColumnSlide("Workflows", "Two Ways to Actually Work With Signals",
  "OpenWebRX+ (Browser-Based)", [
    "Live, multi-user, browser-accessible waterfall and audio",
    "Built-in decoders: Packet/APRS, LoRa, FLEX/POCSAG, FT8 and related digital modes",
    "Its own Feature Report page states plainly why any capability is or isn't available \u2014 a genuinely well-designed diagnostic tool",
    "Best for live, human-facing monitoring",
  ],
  "Manual (GNU Radio)", [
    "Flowgraphs built directly against hardware via gr-osmosdr, one interface for multiple device types",
    "Full control: energy detection, feature extraction, triggering a raw capture",
    "Where genuinely custom SIGINT logic lives \u2014 no off-the-shelf decoder required",
    "Best for unattended, custom detection logic",
  ]
);

// 11. Occupancy concept
bulletSlide("The Occupancy Concept", "Turning RF Energy Into Queryable Data", [
  "Standard spectrum-management terminology: is a frequency in use, over what window, for how long \u2014 not what the signal IS",
  "Signal identification is a separate, optional layer built on top of an occupancy record, not baked into it",
  "Design reference: Kismet's proven DEVICES/PACKETS split \u2014 a long-lived aggregate plus a lean, high-volume event log",
  "Real adaptation required: RF signals generally lack the durable identity a MAC address gives a WiFi device \u2014 frequency (binned) + mode substitutes",
]);

// 12. Occupancy pull quote
pullQuoteSlide("Why Calibration Matters", "",
  "\u201cA calibrated threshold, not a guessed one, is what separates a genuinely useful occupancy log from a noisy one.\u201d");
// 13. Lessons learned - highlight 1
darkHighlightSlide("Real-World Lesson", "Enumeration Is Not Validation",
  "A device showing up in a list, or a package installing without error, proves far less than it appears to. This build required a real, sustained data capture or a real end-to-end flowgraph execution before considering any component actually working \u2014 because several real bugs (a USB permission gap, a missing secondary dependency, a rate limit) were invisible to a simple installed-successfully check and only surfaced when something real was actually run.");

// 14. Lessons learned - highlight 2
darkHighlightSlide("Real-World Lesson", "Test as the User Who Will Actually Need It to Work",
  "A permission validated correctly for one system user was silently assumed to also cover a completely different system user created later by a separate service's own install process. The two accounts had no inherent relationship; proving access worked for one proved nothing about the other. Any permission check is only as good as the identity it was actually tested under.");

// 15. Lessons learned - highlight 3
darkHighlightSlide("Real-World Lesson", "A Suspiciously Clean Result Deserves More Suspicion Than an Error",
  "An outright failure announces itself. A calibration reading that returns without error but happens to be identical across two physically different situations is a quieter, easier-to-miss signal that something is wrong. The habit worth building: sanity-check a clean result against physical expectation, not just whether the tool reported success.");

// 16. Remaining lessons, condensed
bulletSlide("More Real Lessons", "Additional Principles From the Build", [
  "Recoverable failure should be handled as recoverable \u2014 a single rate-limit response once aborted an entire multi-hour sync; the fix treated it as the expected condition it actually was",
  "Flag what's actually confirmed, not what's a reasonable guess \u2014 an unconfirmed assumption, stated honestly with a safe fallback, beats false confidence",
  "Version drift is a recurring category of bug \u2014 a renamed package, an unsupported config key, a systemd unit type that behaves differently than assumed, all wearing different clothes for the same underlying failure",
]);

// 17. Closing
closingSlide("Sovereign by Design", 
  "A local AI stack that never depends on a cloud connection to function \u2014 validated by real hardware at every step, honest about what still needs building.");
pres.writeFile({ fileName: "./Building-Sovereign-SIGINT-deck.pptx" }).then(() => {
  console.log("Deck written.");
});
