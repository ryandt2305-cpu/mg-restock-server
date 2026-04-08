import fs from "node:fs";
import path from "node:path";

const envPath = path.join(process.cwd(), ".env");
const env = {};
for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
  const eq = line.indexOf("=");
  if (eq > 0 && !line.trim().startsWith("#")) {
    env[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
}

const H = {
  apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
  "Content-Type": "application/json",
};

// Fix: update all discord-import rows to parse double-encoded items
// Use SQL RPC to fix in bulk
const sql = `
UPDATE restock_events
SET items = items::text::jsonb
WHERE source_ip = 'discord-import'
  AND jsonb_typeof(items) = 'string';
`;

console.log("Fixing double-encoded items...");
const r = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/`, {
  method: "POST",
  headers: H,
  body: JSON.stringify({ query: sql }),
});

// Since we can't run raw SQL via REST, let's do it row by row
// Actually, let's just delete and re-import with the fixed script
console.log("Deleting discord-import restock events...");
const del = await fetch(`${env.SUPABASE_URL}/rest/v1/restock_events?source_ip=eq.discord-import`, {
  method: "DELETE",
  headers: H,
});
console.log("Delete status:", del.status, del.statusText);

console.log("\nNow re-run import-discord-gap.mjs to re-import with correct format.");
