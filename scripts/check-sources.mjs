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

// Check distinct source_ip values
const r1 = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/`, { method: "POST", headers: H });

// Get recent events to see source_ip distribution
const r2 = await fetch(`${env.SUPABASE_URL}/rest/v1/restock_events?select=source_ip,timestamp&order=timestamp.desc&limit=50`, { headers: H });
const recent = await r2.json();

console.log("=== Last 50 events by source ===");
const sources = {};
for (const e of recent) {
  const src = e.source_ip || "(null)";
  if (!sources[src]) sources[src] = { count: 0, latest: 0, earliest: Infinity };
  sources[src].count++;
  sources[src].latest = Math.max(sources[src].latest, e.timestamp);
  sources[src].earliest = Math.min(sources[src].earliest, e.timestamp);
}
for (const [src, info] of Object.entries(sources)) {
  console.log(`  ${src}: ${info.count} events, ${new Date(info.earliest).toISOString().slice(0,16)} to ${new Date(info.latest).toISOString().slice(0,16)}`);
}

// Check if there's a server/edge function that polls
// Look at events from the last 24h grouped by source
const oneDayAgo = Date.now() - 86400000;
const r3 = await fetch(`${env.SUPABASE_URL}/rest/v1/restock_events?select=source_ip,timestamp&timestamp=gte.${oneDayAgo}&order=timestamp.desc&limit=1000`, { headers: H });
const last24h = await r3.json();

console.log(`\n=== Last 24h: ${last24h.length} events ===`);
const sources24 = {};
for (const e of last24h) {
  const src = e.source_ip || "(null)";
  if (!sources24[src]) sources24[src] = 0;
  sources24[src]++;
}
for (const [src, count] of Object.entries(sources24)) {
  console.log(`  ${src}: ${count}`);
}

// Check for gaps in the last 24h
if (last24h.length > 1) {
  let maxGap = 0;
  for (let i = 0; i < last24h.length - 1; i++) {
    const gap = last24h[i].timestamp - last24h[i+1].timestamp;
    if (gap > maxGap) maxGap = gap;
  }
  console.log(`  Max gap between events: ${(maxGap / 60000).toFixed(0)} minutes`);
}

// What time was your computer likely off? Check for consistent coverage
console.log("\n=== Event coverage by hour (last 24h) ===");
const hourCounts = new Array(24).fill(0);
for (const e of last24h) {
  const h = new Date(e.timestamp).getUTCHours();
  hourCounts[h]++;
}
for (let h = 0; h < 24; h++) {
  const bar = "#".repeat(Math.min(hourCounts[h], 50));
  console.log(`  ${String(h).padStart(2)}:00 UTC  ${bar} (${hourCounts[h]})`);
}
