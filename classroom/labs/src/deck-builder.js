const pptxgen = require("pptxgenjs");

// SIGINT/waterfall-display inspired palette — deliberately not generic blue.
const NAVY = "0B1929";      // dominant — deep night-ops/waterfall background
const NAVY_LIGHT = "13273D"; // secondary panel tone on dark slides
const CYAN = "00A8CC";       // signal/waterfall cyan — the secondary color
const AMBER = "F4A300";      // VU-meter/dial-glow accent — sharp accent, used sparingly
const WHITE = "FFFFFF";
const OFFWHITE = "F7F9FA";
const INK = "1A2733";         // body text on light backgrounds
const MUTED = "5C7080";       // secondary/muted text

const FONT_HEAD = "Cambria";
const FONT_BODY = "Calibri";

function newDeck(title) {
  let pres = new pptxgen();
  pres.layout = "LAYOUT_16x9";
  pres.author = "Sovereign SIGINT Course";
  pres.title = title;
  return pres;
}

function labNum(id) {
  if (id === "lab00") return "Lab 0";
  if (id === "lab12") return "Final Lab";
  return "Lab " + parseInt(id.replace("lab", ""), 10);
}

function addTitleSlide(pres, s) {
  let slide = pres.addSlide();
  slide.background = { color: NAVY };

  // Waterfall-motif: a row of horizontal bands fading in opacity, evoking
  // a spectrum waterfall display — the one visual motif repeated all deck.
  const bandY = [0.0, 0.55, 1.1, 1.65, 2.2];
  const opac = [85, 65, 45, 28, 14];
  bandY.forEach((y, i) => {
    slide.addShape(pres.shapes.RECTANGLE, {
      x: 0, y: y, w: 10, h: 0.5,
      fill: { color: CYAN, transparency: 100 - opac[i] },
      line: { type: "none" },
    });
  });

  slide.addText(labNum(s.id).toUpperCase(), {
    x: 0.6, y: 2.55, w: 8.8, h: 0.5, fontFace: FONT_BODY, fontSize: 16,
    color: AMBER, bold: true, charSpacing: 3, margin: 0,
  });
  slide.addText(s.title, {
    x: 0.6, y: 3.0, w: 8.8, h: 1.3, fontFace: FONT_HEAD, fontSize: 40,
    color: WHITE, bold: true, margin: 0,
  });
  slide.addText(s.subtitle, {
    x: 0.6, y: 4.2, w: 8.8, h: 0.7, fontFace: FONT_BODY, fontSize: 18,
    color: CYAN, italic: true, margin: 0,
  });
  slide.addText("Sovereign SIGINT — College Lab Series", {
    x: 0.6, y: 5.15, w: 8.8, h: 0.35, fontFace: FONT_BODY, fontSize: 11,
    color: MUTED, margin: 0,
  });
  return slide;
}

function lightSlideHeader(pres, slide, kicker, heading) {
  slide.addText(kicker.toUpperCase(), {
    x: 0.6, y: 0.35, w: 8.8, h: 0.35, fontFace: FONT_BODY, fontSize: 13,
    color: CYAN, bold: true, charSpacing: 2, margin: 0,
  });
  slide.addText(heading, {
    x: 0.6, y: 0.68, w: 8.8, h: 0.7, fontFace: FONT_HEAD, fontSize: 28,
    color: NAVY, bold: true, margin: 0,
  });
}

function addObjectivesSlide(pres, s) {
  let slide = pres.addSlide();
  slide.background = { color: OFFWHITE };
  lightSlideHeader(pres, slide, "Session Overview", "Learning Objectives");

  const boxY = 1.7, gap = 0.15;
  const rowH = (5.625 - boxY - 0.4 - gap * (s.objectives.length - 1)) / s.objectives.length;
  s.objectives.forEach((obj, i) => {
    const y = boxY + i * (rowH + gap);
    slide.addShape(pres.shapes.OVAL, {
      x: 0.6, y: y + rowH / 2 - 0.22, w: 0.44, h: 0.44,
      fill: { color: NAVY }, line: { type: "none" },
    });
    slide.addText(String(i + 1), {
      x: 0.6, y: y + rowH / 2 - 0.22, w: 0.44, h: 0.44, fontFace: FONT_BODY,
      fontSize: 16, color: AMBER, bold: true, align: "center", valign: "middle", margin: 0,
    });
    slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
      x: 1.25, y: y, w: 8.15, h: rowH, rectRadius: 0.06,
      fill: { color: WHITE }, line: { type: "none" },
      shadow: { type: "outer", color: "000000", blur: 5, offset: 2, angle: 90, opacity: 0.08 },
    });
    slide.addText(obj, {
      x: 1.5, y: y, w: 7.6, h: rowH, fontFace: FONT_BODY, fontSize: 15,
      color: INK, valign: "middle", margin: 0,
    });
  });
  return slide;
}

function addBulletSlide(pres, kicker, heading, points, opts) {
  opts = opts || {};
  let slide = pres.addSlide();
  slide.background = { color: OFFWHITE };
  lightSlideHeader(pres, slide, kicker, heading);

  const items = points.map((p, i) => ({
    text: p, options: { bullet: { code: "25AA" }, breakLine: i < points.length - 1, paraSpaceAfter: 14 },
  }));
  slide.addText(items, {
    x: 0.7, y: 1.75, w: 8.6, h: 3.6, fontFace: FONT_BODY, fontSize: 15,
    color: INK, valign: "top", lineSpacingMultiple: 1.15,
  });

  slide.addShape(pres.shapes.RECTANGLE, {
    x: 0, y: 5.35, w: 10, h: 0.275, fill: { color: NAVY }, line: { type: "none" },
  });
  return slide;
}

function addLabStepsSlide(pres, s) {
  let slide = pres.addSlide();
  slide.background = { color: OFFWHITE };
  lightSlideHeader(pres, slide, "Hands-On", s.labSteps.heading);

  const boxY = 1.65, gap = 0.12;
  const n = s.labSteps.steps.length;
  const rowH = (5.3 - boxY - gap * (n - 1)) / n;
  s.labSteps.steps.forEach((step, i) => {
    const y = boxY + i * (rowH + gap);
    slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
      x: 0.6, y: y, w: 0.5, h: rowH, rectRadius: 0.06,
      fill: { color: CYAN }, line: { type: "none" },
    });
    slide.addText(String(i + 1), {
      x: 0.6, y: y, w: 0.5, h: rowH, fontFace: FONT_BODY, fontSize: 15,
      color: NAVY, bold: true, align: "center", valign: "middle", margin: 0,
    });
    slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
      x: 1.25, y: y, w: 8.15, h: rowH, rectRadius: 0.05,
      fill: { color: WHITE }, line: { color: "DCE3E8", width: 1 },
    });
    slide.addText(step, {
      x: 1.5, y: y, w: 7.6, h: rowH, fontFace: "Courier New", fontSize: 12.5,
      color: INK, valign: "middle", margin: 0,
    });
  });
  return slide;
}

function addGotchaSlide(pres, s) {
  let slide = pres.addSlide();
  slide.background = { color: NAVY };

  slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
    x: 0.6, y: 0.4, w: 2.6, h: 0.5, rectRadius: 0.25,
    fill: { color: AMBER }, line: { type: "none" },
  });
  slide.addText("REAL-WORLD BUG", {
    x: 0.6, y: 0.4, w: 2.6, h: 0.5, fontFace: FONT_BODY, fontSize: 13,
    color: NAVY, bold: true, align: "center", valign: "middle", charSpacing: 1, margin: 0,
  });

  slide.addText(s.gotcha.heading, {
    x: 0.6, y: 1.05, w: 8.8, h: 0.85, fontFace: FONT_HEAD, fontSize: 24,
    color: WHITE, bold: true, margin: 0,
  });

  slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
    x: 0.6, y: 2.0, w: 8.8, h: 3.35, rectRadius: 0.08,
    fill: { color: NAVY_LIGHT }, line: { type: "none" },
  });
  slide.addText(s.gotcha.text, {
    x: 0.95, y: 2.25, w: 8.1, h: 2.9, fontFace: FONT_BODY, fontSize: 13.5,
    color: OFFWHITE, valign: "top", lineSpacingMultiple: 1.25, margin: 0,
  });
  return slide;
}

function addValidationSlide(pres, s) {
  let slide = pres.addSlide();
  slide.background = { color: OFFWHITE };
  lightSlideHeader(pres, slide, "Before Moving On", s.validation.heading);

  const boxY = 1.7, gap = 0.2;
  const n = s.validation.points.length;
  const rowH = (5.3 - boxY - gap * (n - 1)) / n;
  s.validation.points.forEach((point, i) => {
    const y = boxY + i * (rowH + gap);
    slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
      x: 0.6, y: y, w: 8.8, h: rowH, rectRadius: 0.06,
      fill: { color: WHITE }, line: { type: "none" },
      shadow: { type: "outer", color: "000000", blur: 5, offset: 2, angle: 90, opacity: 0.08 },
    });
    slide.addShape(pres.shapes.OVAL, {
      x: 0.85, y: y + rowH / 2 - 0.14, w: 0.28, h: 0.28,
      fill: { color: CYAN }, line: { type: "none" },
    });
    slide.addText(point, {
      x: 1.35, y: y, w: 7.85, h: rowH, fontFace: FONT_BODY, fontSize: 14.5,
      color: INK, valign: "middle", margin: 0,
    });
  });
  return slide;
}

function addDiscussionSlide(pres, s) {
  let slide = pres.addSlide();
  slide.background = { color: OFFWHITE };
  lightSlideHeader(pres, slide, "Group Discussion", "Discussion Questions");

  const boxY = 1.75, gap = 0.25;
  const n = s.discussion.length;
  const rowH = (5.3 - boxY - gap * (n - 1)) / n;
  s.discussion.forEach((q, i) => {
    const y = boxY + i * (rowH + gap);
    slide.addText("Q" + (i + 1), {
      x: 0.6, y: y, w: 0.7, h: rowH, fontFace: FONT_HEAD, fontSize: 22,
      color: AMBER, bold: true, valign: "middle", margin: 0,
    });
    slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
      x: 1.4, y: y, w: 8.0, h: rowH, rectRadius: 0.06,
      fill: { color: WHITE }, line: { type: "none" },
      shadow: { type: "outer", color: "000000", blur: 5, offset: 2, angle: 90, opacity: 0.08 },
    });
    slide.addText(q, {
      x: 1.65, y: y, w: 7.5, h: rowH, fontFace: FONT_BODY, fontSize: 14,
      italic: true, color: INK, valign: "middle", margin: 0,
    });
  });
  return slide;
}

function addSummarySlide(pres, s) {
  let slide = pres.addSlide();
  slide.background = { color: NAVY };

  const bandY = [3.6, 4.15, 4.7, 5.25];
  const opac = [14, 28, 45, 65];
  bandY.forEach((y, i) => {
    slide.addShape(pres.shapes.RECTANGLE, {
      x: 0, y: y, w: 10, h: 0.5,
      fill: { color: CYAN, transparency: 100 - opac[i] },
      line: { type: "none" },
    });
  });

  slide.addText("NEXT SESSION", {
    x: 0.6, y: 0.7, w: 8.8, h: 0.4, fontFace: FONT_BODY, fontSize: 14,
    color: AMBER, bold: true, charSpacing: 2, margin: 0,
  });
  slide.addText(s.nextSession, {
    x: 0.6, y: 1.15, w: 8.8, h: 2.0, fontFace: FONT_HEAD, fontSize: 22,
    color: WHITE, bold: true, margin: 0, lineSpacingMultiple: 1.2,
  });
  return slide;
}

function buildSessionDeck(s, outDir) {
  let pres = newDeck(s.title);

  addTitleSlide(pres, s);
  addObjectivesSlide(pres, s);
  addBulletSlide(pres, "Concept", s.background.heading, s.background.points);
  addBulletSlide(pres, "System Design", s.architecture.heading, s.architecture.points);
  addBulletSlide(pres, "Design Rationale", s.decisions.heading, s.decisions.points);
  addLabStepsSlide(pres, s);
  addGotchaSlide(pres, s);
  addValidationSlide(pres, s);
  addDiscussionSlide(pres, s);
  addSummarySlide(pres, s);

  const filename = `${outDir}/${s.id}-${s.title.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}.pptx`;
  return pres.writeFile({ fileName: filename }).then(() => filename);
}

module.exports = { buildSessionDeck };
