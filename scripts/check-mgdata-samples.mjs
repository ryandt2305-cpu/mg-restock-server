import fs from "node:fs";
import path from "node:path";
import fetch from "node-fetch";

const ROOT = process.cwd();
const DATA_DIR = path.join(ROOT, "data");
const MGDATA_CACHE_FILE = path.join(DATA_DIR, "mgdata-cache.json");
const MG_API_BASE = process.env.MG_API_BASE || "https://mg-api.ariedam.fr";
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS || 15000);
const MGDATA_CACHE_MS = Number(process.env.MGDATA_CACHE_MS || 3600000);

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
  return String(value || "").toLowerCase().replace(/[\u2019']/g, "").replace(/[^a-z0-9]/g, "");
}

function buildIndex(list, field) {
  const map = new Map();
  for (const [id, obj] of Object.entries(list || {})) {
    const name = obj?.[field]?.name ?? obj?.name ?? null;
    if (!name) continue;
    const key = normalizeKey(name);
    if (!map.has(key)) map.set(key, id);
  }
  return map;
}

function itemLabel(list, id, field) {
  const obj = list?.[id];
  if (!obj) return id;
  const item = field ? obj?.[field] : obj;
  return item?.name ?? id;
}

function price(list, id, field) {
  const obj = list?.[id];
  if (!obj) return null;
  const item = field ? obj?.[field] : obj;
  return item?.coinPrice ?? null;
}

function rarity(list, id, field) {
  const obj = list?.[id];
  if (!obj) return null;
  const item = field ? obj?.[field] : obj;
  return item?.rarity ?? null;
}

async function main() {
  const mg = await loadMgData();
  const seeds = buildIndex(mg.plants, "seed");
  const eggs = buildIndex(mg.eggs, null);
  const decor = buildIndex(mg.decor, null);

  const samples = [
    { shop: "seed", name: "Moonbinder Pod" },
    { shop: "seed", name: "Dawnbinder Pod" },
    { shop: "seed", name: "Starweaver Pod" },
    { shop: "seed", name: "Blueberry" },
    { shop: "seed", name: "Fava Bean" },
    { shop: "decor", name: "Small Gravestone" },
  ];

  const out = samples.map((s) => {
    const key = normalizeKey(s.name);
    if (s.shop === "seed") {
      const id = seeds.get(key) ?? s.name;
      return {
        shop: s.shop,
        name: s.name,
        id,
        label: itemLabel(mg.plants, id, "seed"),
        price: price(mg.plants, id, "seed"),
        rarity: rarity(mg.plants, id, "seed"),
      };
    }
    if (s.shop === "egg") {
      const id = eggs.get(key) ?? s.name;
      return {
        shop: s.shop,
        name: s.name,
        id,
        label: itemLabel(mg.eggs, id, null),
        price: price(mg.eggs, id, null),
        rarity: rarity(mg.eggs, id, null),
      };
    }
    const id = decor.get(key) ?? s.name;
    return {
      shop: s.shop,
      name: s.name,
      id,
      label: itemLabel(mg.decor, id, null),
      price: price(mg.decor, id, null),
      rarity: rarity(mg.decor, id, null),
    };
  });

  console.log(out);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
