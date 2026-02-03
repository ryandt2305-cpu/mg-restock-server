import fs from "node:fs";
import path from "node:path";

const META_FILE = path.join(process.cwd(), "data", "meta.json");
const meta = JSON.parse(fs.readFileSync(META_FILE, "utf8"));
meta.importedAt = 1769944415316;
meta.importSource = "discord-html";
meta.importFile = "Magic Circle - 🍄 Magic Garden - ping [1392142706964303933].html";
fs.writeFileSync(META_FILE, JSON.stringify(meta, null, 2) + "\n", "utf8");
