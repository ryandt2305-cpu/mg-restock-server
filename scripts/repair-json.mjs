import fs from "node:fs";
import path from "node:path";

const base = "C:/Users/ryand/Feeder-Extension/Gemini-folder/Gemini-server/restock examples";
const entries = fs.readdirSync(base, { withFileTypes: true });
const target = entries.find((e) => e.isFile() && e.name.includes("Magic Circle"));
if (!target) {
  console.error("Target file not found");
  process.exit(1);
}
const full = path.join(base, target.name);
console.log(full);

let raw = fs.readFileSync(full, "utf8");
// Remove BOM, fix trailing commas
raw = raw.replace(/^\uFEFF/, "");
raw = raw.replace(/,\s*([}\]])/g, "$1");

const temp = path.join(base, "__repair__magic_circle.json");
fs.writeFileSync(temp, raw, "utf8");
console.log(temp);
