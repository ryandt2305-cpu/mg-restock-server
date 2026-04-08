import fs from "node:fs";
import path from "node:path";
import fetch from "node-fetch";
import pg from "pg";

const ROOT = process.cwd();
const DATA_DIR = path.join(ROOT, "data");
const MGDATA_CACHE_FILE = path.join(DATA_DIR, "mgdata-cache.json");
const MG_API_BASE = process.env.MG_API_BASE || "https://mg-api.ariedam.fr";
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS || 15000);
const MGDATA_CACHE_MS = Number(process.env.MGDATA_CACHE_MS || 3600000);

const connectionString = "postgresql://gemini_audit_reader.xjuvryjgrjchbhjixwzh:137920@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres";

function readJson(file, fallback) {
  try {
    if (!fs.existsSync(file)) return fallback;
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJson(file, value) {
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n", "utf8");
}

async function fetchWithTimeout(url) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    return await fetch(url, { signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

async function loadMgData() {
  const cached = readJson(MGDATA_CACHE_FILE, null);
  if (cached?.savedAt && cached?.data && Date.now() - cached.savedAt < MGDATA_CACHE_MS) {
    return cached.data;
  }
  const [plantsRes, eggsRes, decorsRes] = await Promise.all([
    fetchWithTimeout(`${MG_API_BASE}/data/plants`),
    fetchWithTimeout(`${MG_API_BASE}/data/eggs`),
    fetchWithTimeout(`${MG_API_BASE}/data/decors`),
  ]);
  if (!plantsRes.ok || !eggsRes.ok || !decorsRes.ok) {
    throw new Error("MG API data fetch failed");
  }
  const [plants, eggs, decors] = await Promise.all([
    plantsRes.json(),
    eggsRes.json(),
    decorsRes.json(),
  ]);
  const data = { plants, eggs, decor: decors };
  writeJson(MGDATA_CACHE_FILE, { savedAt: Date.now(), data });
  return data;
}

function normalizeKey(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[\u2019']/g, "")
    .replace(/[^a-z0-9]/g, "");
}

function buildIndex(list, field) {
  const map = new Map();
  for (const [id, obj] of Object.entries(list || {})) {
    const name = field ? obj?.[field]?.name : obj?.name;
    if (!name) continue;
    const key = normalizeKey(name);
    if (!map.has(key)) map.set(key, id);
  }
  return map;
}

function resolveId(shopType, itemId, mg) {
  if (shopType === "seed") {
    if (mg.plants?.[itemId]) return itemId;
    return null;
  }
  if (shopType === "egg") {
    if (mg.eggs?.[itemId]) return itemId;
    return null;
  }
  if (shopType === "decor") {
    if (mg.decor?.[itemId]) return itemId;
    return null;
  }
  return null;
}

async function main() {
  const mg = await loadMgData();
  const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false }, family: 4 });
  await client.connect();
  const res = await client.query("select item_id, shop_type from public.restock_history");
  await client.end();

  const missing = [];
  for (const row of res.rows) {
    const itemId = row.item_id;
    const shopType = row.shop_type;
    const resolved = resolveId(shopType, itemId, mg);
    if (!resolved) {
      missing.push({ itemId, shopType });
    }
  }

  console.log("Missing count:", missing.length);
  if (missing.length) {
    console.log(JSON.stringify(missing, null, 2));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
