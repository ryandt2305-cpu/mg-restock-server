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
};

// Check a few imported rows
const r = await fetch(`${env.SUPABASE_URL}/rest/v1/restock_events?source_ip=eq.discord-import&select=items,shop_type,timestamp&limit=3`, { headers: H });
const rows = await r.json();
console.log("Sample imported rows:");
for (const row of rows) {
  console.log(`  shop=${row.shop_type} ts=${row.timestamp} items=${row.items}`);
  console.log(`  typeof items: ${typeof row.items}`);
}

// The issue: items was JSON.stringify'd in the script, so it's a string in the DB
// But rebuild expects jsonb. Check if it's double-stringified
if (rows.length > 0) {
  const items = rows[0].items;
  if (typeof items === "string") {
    console.log("\nItems is a STRING - likely double-encoded JSON");
    try {
      const parsed = JSON.parse(items);
      console.log("Parsed:", JSON.stringify(parsed));
    } catch {
      console.log("Cannot parse as JSON");
    }
  } else {
    console.log("\nItems is already an object/array - proper jsonb");
  }
}
