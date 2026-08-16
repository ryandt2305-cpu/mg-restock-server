import { writeFileSync } from "fs";

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY env vars");
  process.exit(1);
}

const headers = {
  apikey: SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
  "Content-Type": "application/json",
  Prefer: "return=representation",
};

const rest = `${SUPABASE_URL}/rest/v1`;

// Fetch all rows with pagination using cursor-based keyset paging on timestamp
async function fetchAll(table, select, order) {
  const rows = [];
  let lastTs = 0;
  const limit = 500;
  while (true) {
    const url = `${rest}/${table}?select=${select}&order=${order}&timestamp=gt.${lastTs}&limit=${limit}`;
    const res = await fetch(url, { headers });
    if (!res.ok) throw new Error(`${table}: ${res.status} ${await res.text()}`);
    const batch = await res.json();
    rows.push(...batch);
    if (batch.length < limit) break;
    lastTs = batch[batch.length - 1].timestamp;
    process.stdout.write(`\r  ${table}: ${rows.length} rows...`);
  }
  if (rows.length > 0) process.stdout.write(`\r  ${table}: ${rows.length} rows - done\n`);
  return rows;
}

function formatTime(ts) {
  return new Date(ts).toISOString().replace("T", " ").replace(".000Z", " UTC");
}

// Cycle durations in ms per shop type
const CYCLE_MS = {
  seed: 5 * 60_000,
  tool: 10 * 60_000,
  egg: 15 * 60_000,
  decor: 60 * 60_000,
  dawn: 60 * 60_000,
};

// Minimum items to consider "full inventory" era
const FULL_INVENTORY_THRESHOLD = {
  seed: 5,
  egg: 3,
  tool: 3,
  decor: 3,
  dawn: 2,
};

// Snap timestamp to nearest cycle boundary
function snapToCycle(ts, shopType) {
  const cycle = CYCLE_MS[shopType] || 5 * 60_000;
  return Math.round(ts / cycle) * cycle;
}

// Round timestamp down to its cycle boundary (for dedup key)
function cycleKey(ts, shopType) {
  const cycle = CYCLE_MS[shopType] || 5 * 60_000;
  return Math.floor(ts / cycle) * cycle;
}

// Find the index where full-inventory era begins (5 consecutive entries above threshold)
function findFullInventoryStart(events, shopType) {
  const threshold = FULL_INVENTORY_THRESHOLD[shopType] || 3;
  const run = 5;
  for (let i = 0; i < events.length - run; i++) {
    if (events.slice(i, i + run).every(e => e.items.length >= threshold)) return i;
  }
  return 0; // all full-inventory
}

// --- Fetch raw data ---
const rawRestocks = await fetchAll("restock_events", "timestamp,shop_type,weather_id,items", "timestamp.asc");
const rawWeather = await fetchAll("weather_events", "timestamp,weather_id,previous_weather_id,source", "timestamp.asc");

// --- Deduplicate restocks: one entry per cycle per shop ---
const allByShop = {};
const seenCycles = {};
for (const row of rawRestocks) {
  const shop = row.shop_type;
  const key = `${shop}:${cycleKey(row.timestamp, shop)}`;
  if (seenCycles[key]) continue;
  seenCycles[key] = true;
  if (!allByShop[shop]) allByShop[shop] = [];
  allByShop[shop].push({
    timestamp: row.timestamp,
    weather: row.weather_id || null,
    items: row.items,
  });
}

// --- Split into early/late eras per shop ---
const earlyByShop = {};
const lateByShop = {};

for (const [shop, events] of Object.entries(allByShop)) {
  const splitIdx = findFullInventoryStart(events, shop);

  const early = events.slice(0, splitIdx).map(e => ({
    time: formatTime(snapToCycle(e.timestamp, shop)),
    timestamp: snapToCycle(e.timestamp, shop),
    weather: e.weather,
    items: e.items.map(i => i.stock > 1 ? `${i.itemId} x${i.stock}` : i.itemId),
  }));

  const late = events.slice(splitIdx).map(e => ({
    time: formatTime(e.timestamp),
    timestamp: e.timestamp,
    weather: e.weather,
    items: e.items.map(i => i.stock > 1 ? `${i.itemId} x${i.stock}` : i.itemId),
  }));

  if (early.length > 0) earlyByShop[shop] = early;
  if (late.length > 0) lateByShop[shop] = late;

  console.log(`  ${shop}: ${early.length} early + ${late.length} full-inventory (split at ${early.length > 0 ? early[early.length - 1].time : 'n/a'})`);
}

// --- Deduplicate weather: only keep actual changes ---
const weatherTimeline = [];
let lastWeather = null;
for (const row of rawWeather) {
  if (row.weather_id === lastWeather) continue;
  lastWeather = row.weather_id;
  weatherTimeline.push({
    time: formatTime(row.timestamp),
    timestamp: row.timestamp,
    weather: row.weather_id,
    previous: row.previous_weather_id || null,
  });
}

// --- Write files ---
if (Object.keys(earlyByShop).length > 0) {
  writeFileSync("data/export-restock-early.json", JSON.stringify(earlyByShop, null, 2));
}
writeFileSync("data/export-restock-full.json", JSON.stringify(lateByShop, null, 2));
writeFileSync("data/export-weather-events.json", JSON.stringify(weatherTimeline, null, 2));

const earlyTotal = Object.values(earlyByShop).reduce((s, a) => s + a.length, 0);
const lateTotal = Object.values(lateByShop).reduce((s, a) => s + a.length, 0);
console.log(`\nRestocks: ${earlyTotal} early (snapped) + ${lateTotal} full-inventory`);
console.log(`Weather: ${rawWeather.length} raw -> ${weatherTimeline.length} transitions`);
