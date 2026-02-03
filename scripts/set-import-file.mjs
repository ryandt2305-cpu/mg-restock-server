import fs from "node:fs";
import path from "node:path";

const META_FILE = path.join(process.cwd(), "data", "meta.json");
const meta = JSON.parse(fs.readFileSync(META_FILE, "utf8"));
const args = process.argv.slice(2);
const fileArg = args[0];
if (fileArg) {
  meta.importFile = fileArg;
}
fs.writeFileSync(META_FILE, JSON.stringify(meta, null, 2) + "\n", "utf8");
