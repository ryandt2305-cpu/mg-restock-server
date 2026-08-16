import fs from "node:fs";
import path from "node:path";

function loadEnvFile() {
  const envPath = path.join(process.cwd(), ".env");
  if (!fs.existsSync(envPath)) return;
  for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    if (!key) continue;
    if (process.env[key] === undefined) process.env[key] = value;
  }
}

loadEnvFile();

const SUPABASE_URL = process.env.SUPABASE_URL || "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || "";

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
}

const headers = {
  apikey: SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
};

async function query(pathQ) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathQ}`, { headers });
  if (!res.ok) {
    throw new Error(`${res.status} ${await res.text()}`);
  }
  return res.json();
}

async function tryQuery(pathQ) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathQ}`, { headers });
  const text = await res.text();
  if (!res.ok) {
    return { ok: false, status: res.status, error: text };
  }
  return { ok: true, status: res.status, data: JSON.parse(text) };
}

const extended = await tryQuery(
  "restock_predictions?select=shop_type,item_id,current_weather,weather_baseline_ms,weather_samples,weather_used,weather_rejected_reason,selected_model_name,selected_model_test_events,selected_model_within_one_cycle_pct,expected_interval_ms,median_interval_ms,last_seen&limit=5000"
);

let predictions;
let usedExtended = false;
if (extended.ok) {
  predictions = extended.data;
  usedExtended = true;
} else {
  const base = await query(
    "restock_predictions?select=shop_type,item_id,current_weather,weather_baseline_ms,weather_samples,expected_interval_ms,median_interval_ms,last_seen&limit=5000"
  );
  predictions = base.map((row) => ({
    ...row,
    weather_used: null,
    weather_rejected_reason: "unknown (view lacks field)",
    selected_model_name: "unknown (view lacks field)",
    selected_model_test_events: null,
    selected_model_within_one_cycle_pct: null,
  }));
}

const weatherByReason = new Map();
const weatherByShop = new Map();
const selectedModels = new Map();

let weatherUsed = 0;
let weatherRejected = 0;

for (const row of predictions) {
  const reason = row.weather_rejected_reason ?? "unknown";
  weatherByReason.set(reason, (weatherByReason.get(reason) ?? 0) + 1);

  const shop = row.shop_type ?? "unknown";
  if (!weatherByShop.has(shop)) weatherByShop.set(shop, { total: 0, used: 0, rejected: 0 });
  const entry = weatherByShop.get(shop);
  entry.total += 1;

  if (row.weather_used) {
    weatherUsed += 1;
    entry.used += 1;
  } else {
    weatherRejected += 1;
    entry.rejected += 1;
  }

  const model = row.selected_model_name ?? "no_selected_model";
  selectedModels.set(model, (selectedModels.get(model) ?? 0) + 1);
}

const topRejected = predictions
  .filter((r) => !r.weather_used)
  .sort((a, b) => (b.weather_samples ?? 0) - (a.weather_samples ?? 0))
  .slice(0, 50)
  .map((r) => ({
    shop_type: r.shop_type,
    item_id: r.item_id,
    reason: r.weather_rejected_reason,
    weather_samples: r.weather_samples,
    weather_baseline_ms: r.weather_baseline_ms,
    median_interval_ms: r.median_interval_ms,
    expected_interval_ms: r.expected_interval_ms,
    selected_model_name: r.selected_model_name,
  }));

const summary = {
  generated_at: new Date().toISOString(),
  used_extended_columns: usedExtended,
  item_rows: predictions.length,
  weather_used_count: weatherUsed,
  weather_rejected_count: weatherRejected,
  weather_rejection_reasons: Object.fromEntries([...weatherByReason.entries()].sort((a, b) => b[1] - a[1])),
  weather_usage_by_shop: Object.fromEntries([...weatherByShop.entries()]),
  selected_model_distribution: Object.fromEntries([...selectedModels.entries()].sort((a, b) => b[1] - a[1])),
  top_rejected_items: topRejected,
};

console.log(JSON.stringify(summary, null, 2));
