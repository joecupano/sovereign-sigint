const { buildSessionDeck } = require("./deck-builder.js");
const fs = require("fs");

const sessions = [
  ...require("./sessions-1.js"),
  ...require("./sessions-2.js"),
  ...require("./sessions-3.js"),
  ...require("./sessions-4.js"),
];

console.log(`Building ${sessions.length} decks...`);

const outDir = "./output";
if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });

(async () => {
  for (const s of sessions) {
    const filename = await buildSessionDeck(s, outDir);
    console.log(`  built: ${filename}`);
  }
  console.log("All decks built.");
})();
