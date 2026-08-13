const {
  Document, Paragraph, TextRun, HeadingLevel, AlignmentType, PageBreak,
  Table, TableRow, TableCell, WidthType, ShadingType, TableOfContents,
  BorderStyle, Packer,
} = require("docx");
const fs = require("fs");

const sessionsData = [
  ...require("./sessions-1.js"),
  ...require("./sessions-2.js"),
  ...require("./sessions-3.js"),
  ...require("./sessions-4.js"),
];
const narrativeData = [
  ...require("./narrative-1.js"),
  ...require("./narrative-2.js"),
  ...require("./narrative-3.js"),
  ...require("./narrative-4.js"),
];

const NAVY = "0B1929";
const CYAN = "0A7EA4";
const INK = "1A2733";

function labLabel(id) {
  if (id === "lab00") return "Lab 0";
  if (id === "lab12") return "Final Lab";
  return "Lab " + parseInt(id.replace("lab", ""), 10);
}

function h1(text) {
  return new Paragraph({
    text, heading: HeadingLevel.HEADING_1,
    spacing: { before: 200, after: 200 },
  });
}

function h2(text) {
  return new Paragraph({
    text, heading: HeadingLevel.HEADING_2,
    spacing: { before: 260, after: 120 },
  });
}

function body(text) {
  return new Paragraph({
    children: [new TextRun({ text, size: 22 })],
    spacing: { after: 200 },
    alignment: AlignmentType.LEFT,
  });
}

function infoTable(session, narrative) {
  const row = (label, value) => new TableRow({
    children: [
      new TableCell({
        width: { size: 2200, type: WidthType.DXA },
        shading: { type: ShadingType.CLEAR, fill: "E8EEF2" },
        children: [new Paragraph({ children: [new TextRun({ text: label, bold: true, size: 20 })] })],
      }),
      new TableCell({
        width: { size: 7300, type: WidthType.DXA },
        children: [new Paragraph({ children: [new TextRun({ text: value, size: 20 })] })],
      }),
    ],
  });
  return new Table({
    width: { size: 9500, type: WidthType.DXA },
    columnWidths: [2200, 7300],
    rows: [
      row("Phase Reference", session.subtitle),
      row("Suggested Duration", narrative.duration),
      row("Prerequisites", narrative.prerequisites),
    ],
  });
}

function discussionBlock(discussionNotes) {
  const paras = [];
  discussionNotes.forEach((d, i) => {
    paras.push(new Paragraph({
      children: [new TextRun({ text: `Q${i + 1}. ${d.q}`, bold: true, italics: true, size: 22 })],
      spacing: { before: 160, after: 80 },
    }));
    paras.push(new Paragraph({
      children: [new TextRun({ text: `Facilitation note: ${d.note}`, size: 20, color: "444444" })],
      spacing: { after: 120 },
    }));
  });
  return paras;
}

function sessionSection(session, narrative, isLast) {
  const paras = [];
  paras.push(h1(`${labLabel(session.id)}: ${session.title}`));
  paras.push(new Paragraph({
    children: [new TextRun({ text: session.subtitle, italics: true, size: 22, color: "0A7EA4" })],
    spacing: { after: 200 },
  }));
  paras.push(infoTable(session, narrative));
  paras.push(new Paragraph({ text: "", spacing: { after: 120 } }));

  paras.push(h2("Opening the Session"));
  paras.push(body(narrative.opening));

  paras.push(h2("Presenting the Concept"));
  paras.push(body(narrative.concept));

  paras.push(h2("Key Design Decisions"));
  paras.push(body(narrative.designDecisions));

  paras.push(h2("Running the Hands-On Lab"));
  paras.push(body(narrative.runningTheLab));
  const stepsList = session.labSteps.steps.map((s, i) =>
    new Paragraph({
      children: [new TextRun({ text: `${i + 1}. `, bold: true, size: 20 }), new TextRun({ text: s, font: "Courier New", size: 19 })],
      spacing: { after: 60 },
    })
  );
  paras.push(...stepsList);
  paras.push(new Paragraph({ text: "", spacing: { after: 100 } }));
  paras.push(new Paragraph({
    children: [new TextRun({ text: "Exit criteria before moving on: ", bold: true, size: 20 })],
    spacing: { after: 60 },
  }));
  session.validation.points.forEach(v => {
    paras.push(new Paragraph({
      children: [new TextRun({ text: "• " + v, size: 20 })],
      spacing: { after: 40 },
    }));
  });

  paras.push(h2("Telling the Real-World Story"));
  paras.push(new Paragraph({
    children: [new TextRun({ text: session.gotcha.heading, bold: true, size: 22 })],
    spacing: { after: 100 },
  }));
  paras.push(body(narrative.gotchaStory));

  paras.push(h2("Facilitating Discussion"));
  paras.push(...discussionBlock(narrative.discussion));

  paras.push(h2("Wrapping Up"));
  paras.push(body(narrative.wrapUp));

  if (!isLast) {
    paras.push(new Paragraph({ children: [new PageBreak()] }));
  }
  return paras;
}

function titlePageAndToc() {
  const paras = [];
  paras.push(new Paragraph({ text: "", spacing: { before: 1200 } }));
  paras.push(new Paragraph({
    children: [new TextRun({ text: "SOVEREIGN SIGINT", bold: true, size: 64, color: NAVY })],
    alignment: AlignmentType.CENTER,
    spacing: { after: 200 },
  }));
  paras.push(new Paragraph({
    children: [new TextRun({ text: "Instructor's Presentation Guide", size: 32, color: CYAN, italics: true })],
    alignment: AlignmentType.CENTER,
    spacing: { after: 100 },
  }));
  paras.push(new Paragraph({
    children: [new TextRun({ text: "A Lab-by-Lab Narrative for Presenting Each Session", size: 22, color: "5C7080" })],
    alignment: AlignmentType.CENTER,
    spacing: { after: 800 },
  }));
  paras.push(new Paragraph({
    children: [new TextRun({
      text: "This guide accompanies the Sovereign SIGINT lab slide decks. Each section below corresponds " +
        "to one lab session and provides a presentation narrative — what to say, what to emphasize, and how " +
        "to facilitate discussion — rather than a restatement of the slides themselves. Every \u201cReal-World " +
        "Bug\u201d story referenced in this guide is drawn from an actual build of the system, not a constructed " +
        "teaching example.",
      size: 22, color: INK,
    })],
    alignment: AlignmentType.LEFT,
    spacing: { after: 400 },
  }));
  paras.push(new Paragraph({ children: [new PageBreak()] }));

  paras.push(h1("Table of Contents"));
  paras.push(new TableOfContents("Table of Contents", {
    hyperlink: true,
    headingStyleRange: "1-1",
  }));
  paras.push(new Paragraph({ children: [new PageBreak()] }));
  return paras;
}

const children = [];
children.push(...titlePageAndToc());

sessionsData.forEach((session, i) => {
  const narrative = narrativeData.find(n => n.id === session.id);
  const isLast = i === sessionsData.length - 1;
  children.push(...sessionSection(session, narrative, isLast));
});

const doc = new Document({
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 }, // US Letter
        margin: { top: 1080, bottom: 1080, left: 1080, right: 1080 },
      },
    },
    children,
  }],
});

Packer.toBuffer(doc).then(buffer => {
  fs.writeFileSync("./output/Sovereign-SIGINT-Instructor-Guide.docx", buffer);
  console.log("Word document written.");
});
