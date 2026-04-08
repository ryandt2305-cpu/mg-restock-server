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

async function query(endpoint) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/${endpoint}`, { headers: { ...H, Prefer: "count=exact" } });
  return { data: await r.json(), count: r.headers.get("content-range") };
}

// Total events
const { count: restockCount } = await query("restock_events?select=count");
console.log("Total restock events:", restockCount);

// By shop type
for (const shop of ["seed", "egg", "decor"]) {
  const { count } = await query(`restock_events?shop_type=eq.${shop}&select=count`);
  console.log(`  ${shop}: ${count}`);
}

// By source
const { count: discordCount } = await query("restock_events?source_ip=eq.discord-import&select=count");
console.log(`  discord-import: ${discordCount}`);

// Restock history (predictions)
const { data: predictions } = await query("restock_predictions?select=item_id,total_occurrences,median_interval_ms,base_rate,last_seen,current_probability,estimated_next_timestamp&order=shop_type,base_rate.desc");
console.log("\n=== RESTOCK PREDICTIONS ===");
for (const p of predictions) {
  const medianDays = p.median_interval_ms ? (p.median_interval_ms / 86400000).toFixed(1) : "N/A";
  const lastSeenDate = new Date(p.last_seen).toISOString().slice(0, 16);
  const predictDate = new Date(p.estimated_next_timestamp).toISOString().slice(0, 16);
  console.log(`${p.item_id.padEnd(20)} occ=${String(p.total_occurrences).padStart(5)} rate=${p.base_rate?.toFixed(4).padStart(7)} median=${medianDays.padStart(6)}d last=${lastSeenDate} predict=${predictDate} prob=${p.current_probability?.toFixed(6)}`);
}

// Weather history
const { data: weather } = await query("weather_predictions?select=weather_id,total_occurrences,last_seen,average_interval_ms,estimated_next_timestamp,appearance_rate&order=total_occurrences.desc");
console.log("\n=== WEATHER PREDICTIONS ===");
for (const w of weather) {
  const avgDays = w.average_interval_ms ? (w.average_interval_ms / 86400000).toFixed(2) : "N/A";
  const lastDate = new Date(w.last_seen).toISOString().slice(0, 16);
  const predictDate = new Date(w.estimated_next_timestamp).toISOString().slice(0, 16);
  console.log(`${w.weather_id.padEnd(15)} occ=${String(w.total_occurrences).padStart(5)} avgInterval=${avgDays.padStart(6)}d rate=${w.appearance_rate?.toFixed(2)}/day last=${lastDate} predict=${predictDate}`);
}

// Date range
const { data: dateRange } = await query("restock_events?select=timestamp&order=timestamp.asc&limit=1");
const { data: dateRangeEnd } = await query("restock_events?select=timestamp&order=timestamp.desc&limit=1");
if (dateRange.length && dateRangeEnd.length) {
  const start = new Date(dateRange[0].timestamp).toISOString().slice(0, 10);
  const end = new Date(dateRangeEnd[0].timestamp).toISOString().slice(0, 10);
  const days = ((dateRangeEnd[0].timestamp - dateRange[0].timestamp) / 86400000).toFixed(1);
  console.log(`\nDate range: ${start} to ${end} (${days} days)`);
}
