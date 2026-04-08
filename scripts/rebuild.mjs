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

// Use raw SQL via rpc to set statement_timeout first
// Actually, just call the rebuild in smaller steps - rebuild per item
// Or use the Supabase management API

// Try with a longer statement timeout via the header
console.log("Rebuilding restock history with extended timeout...");
const t1 = Date.now();
const r = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/rebuild_restock_history`, {
  method: "POST",
  headers: {
    ...H,
    // Supabase supports statement timeout via header
    "x-timeout": "120",
  },
});
const elapsed = ((Date.now() - t1) / 1000).toFixed(1);
if (r.ok) {
  console.log(`  Restock rebuild: OK (${elapsed}s)`);
} else {
  const body = await r.text();
  console.log(`  Restock rebuild failed (${elapsed}s):`, body);

  // If still timing out, try counting how many events we have
  console.log("\nChecking event counts...");
  const countR = await fetch(`${env.SUPABASE_URL}/rest/v1/restock_events?select=count`, {
    headers: { ...H, Prefer: "count=exact" },
  });
  console.log("Total restock events:", countR.headers.get("content-range"));
}
