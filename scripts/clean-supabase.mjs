import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import fetch from "node-fetch";

const ROOT = process.cwd();
const DATA_DIR = path.join(ROOT, "data");
const EVENTS_FILE = path.join(DATA_DIR, "events.json");
const MG_API_BASE = process.env.MG_API_BASE || "https://mg-api.ariedam.fr";
const MGDATA_CACHE_FILE = path.join(DATA_DIR, "mgdata-cache.json");
const MGDATA_CACHE_MS = Number(process.env.MGDATA_CACHE_MS || 3600000);
const INSERT_BATCH_SIZE = Number(process.env.CLEAN_INSERT_BATCH_SIZE || 500);
const DELETE_BATCH_SIZE = Number(process.env.CLEAN_DELETE_BATCH_SIZE || 500);
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS || 15000);

function loadEnvFile() {
  const envPath = path.join(process.cwd(), ".env");
  if (!fs.existsSync(envPath)) return;
  const raw = fs.readFileSync(envPath, "utf8");
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    if (!key) continue;
    if (process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}

loadEnvFile();

const SUPABASE_URL = process.env.SUPABASE_URL || "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
const SUPABASE_REST_ENDPOINT = SUPABASE_URL ? `${SUPABASE_URL}/rest/v1` : "";
const SUPABASE_HEADERS = SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
  ? {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
      Prefer: "resolution=ignore-duplicates,return=representation",
    }
  : null;

const SHOP_TYPES = ["seed", "egg", "decor"];

function readJson(file, fallback) {
  try {
    if (!fs.existsSync(file)) return fallback;
    const raw = fs.readFileSync(file, "utf8");
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

function writeJson(file, value) {
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n", "utf8");
}

function toNameSet(value) {
  if (!value || typeof value !== "object") return null;
  if (Array.isArray(value)) return new Set(value.map((v) => String(v)));
  return new Set(Object.keys(value));
}

async function fetchWithTimeout(url, options = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

async function supabaseFetch(url, options = {}) {
  return fetchWithTimeout(url, options);
}

function normalizeKey(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[\u2019']/g, "")
    .replace(/[^a-z0-9]/g, "");
}

function normalizeItemName(value) {
  return String(value || "").trim();
}

const LEGACY_ALIASES = new Map([
  ["uncommoneggs", "UncommonEgg"],
  ["rareeggs", "RareEgg"],
  ["legendaryeggs", "LegendaryEgg"],
  ["mythicaleggs", "MythicalEgg"],
  ["snoweggs", "SnowEgg"],
  ["wintereggs", "WinterEgg"],
  ["commoneggs", "CommonEgg"],
  ["moonbinder", "MoonCelestial"],
  ["moonbinderpod", "MoonCelestial"],
  ["dawnbinder", "DawnCelestial"],
  ["dawnbinderpod", "DawnCelestial"],
  ["burrostail", "BurrosTail"],
  ["stringlights", "StringLights"],
  ["coloredstringlights", "ColoredStringLights"],
  ["haybale", "HayBale"],
  ["woodowl", "WoodOwl"],
  ["woodbirdhouse", "WoodBirdhouse"],
  ["stonebirdbath", "StoneBirdbath"],
  ["stonegnome", "StoneGnome"],
  ["marbleblobling", "MarbleBlobling"],
  ["pet hutch", "PetHutch"],
  ["decor shed", "DecorShed"],
  ["seed silo", "SeedSilo"],
  ["moonbinder", "Moonbinder"],
  ["dawnbinder", "Dawnbinder"],
]);

const WEATHER_ALIASES = new Map([
  ["rain", "Rain"],
  ["snow", "Frost"],
  ["frost", "Frost"],
  ["dawn", "Dawn"],
  ["ambermoon", "AmberMoon"],
  ["amber", "AmberMoon"],
  ["ambermoonweather", "AmberMoon"],
  ["clear", "Sunny"],
  ["sunny", "Sunny"],
]);

function normalizeWeather(value) {
  if (!value) return "Sunny";
  const key = normalizeKey(String(value));
  if (!key) return "Sunny";
  return WEATHER_ALIASES.get(key) ?? "Sunny";
}

function buildItemIndex(mgSets, nameIndex) {
  const index = { seed: new Map(), egg: new Map(), decor: new Map() };
  for (const shopType of SHOP_TYPES) {
    const set = mgSets[shopType];
    if (!set) continue;
    for (const id of set) {
      const key = normalizeKey(id);
      if (!index[shopType].has(key)) index[shopType].set(key, id);
    }
    const names = nameIndex?.[shopType];
    if (names) {
      for (const [key, id] of names.entries()) {
        if (!index[shopType].has(key)) index[shopType].set(key, id);
      }
    }
  }
  return index;
}

function toNameIndexMap(value) {
  if (!value || typeof value !== "object") return null;
  const seedObj = value.seed && typeof value.seed === "object" ? value.seed : null;
  const eggObj = value.egg && typeof value.egg === "object" ? value.egg : null;
  const decorObj = value.decor && typeof value.decor === "object" ? value.decor : null;
  const seed = seedObj ? new Map(Object.entries(seedObj)) : new Map();
  const egg = eggObj ? new Map(Object.entries(eggObj)) : new Map();
  const decor = decorObj ? new Map(Object.entries(decorObj)) : new Map();
  return { seed, egg, decor };
}

function buildMgData(mg, nameIndex) {
  if (!mg || typeof mg !== "object") return null;
  const seed = mg.seed && typeof mg.seed === "object" ? mg.seed : {};
  const egg = mg.egg && typeof mg.egg === "object" ? mg.egg : {};
  const decor = mg.decor && typeof mg.decor === "object" ? mg.decor : {};
  const seedSet = toNameSet(seed);
  const eggSet = toNameSet(egg);
  const decorSet = toNameSet(decor);
  const nameIndexMap = nameIndex ? toNameIndexMap(nameIndex) : null;
  return {
    seed: seedSet,
    egg: eggSet,
    decor: decorSet,
    index: buildItemIndex({ seed: seedSet, egg: eggSet, decor: decorSet }, nameIndexMap),
    nameIndex: nameIndexMap,
  };
}

async function loadMgData() {
  const cached = readJson(MGDATA_CACHE_FILE, null);
  if (cached?.savedAt && cached?.data && Date.now() - cached.savedAt < MGDATA_CACHE_MS) {
    if (cached?.nameIndex) {
      return buildMgData(cached.data, cached.nameIndex);
    }
  }

  const [plantsRes, eggsRes, decorsRes] = await Promise.all([
    fetchWithTimeout(`${MG_API_BASE}/data/plants`, { headers: { "User-Agent": "Gemini-Server" } }),
    fetchWithTimeout(`${MG_API_BASE}/data/eggs`, { headers: { "User-Agent": "Gemini-Server" } }),
    fetchWithTimeout(`${MG_API_BASE}/data/decors`, { headers: { "User-Agent": "Gemini-Server" } }),
  ]);
  if (!plantsRes.ok || !eggsRes.ok || !decorsRes.ok) {
    throw new Error("MG API data fetch failed");
  }
  const [plants, eggs, decors] = await Promise.all([
    plantsRes.json(),
    eggsRes.json(),
    decorsRes.json(),
  ]);
  const seedNames = new Map();
  const eggNames = new Map();
  const decorNames = new Map();
  for (const [id, value] of Object.entries(plants ?? {})) {
    const seedName = value?.seed?.name;
    if (seedName) seedNames.set(normalizeKey(seedName), id);
  }
  for (const [id, value] of Object.entries(eggs ?? {})) {
    const eggName = value?.name;
    if (eggName) eggNames.set(normalizeKey(eggName), id);
  }
  for (const [id, value] of Object.entries(decors ?? {})) {
    const decorName = value?.name;
    if (decorName) decorNames.set(normalizeKey(decorName), id);
  }
  const nameIndex = { seed: Object.fromEntries(seedNames), egg: Object.fromEntries(eggNames), decor: Object.fromEntries(decorNames) };
  const data = {
    seed: plants && typeof plants === "object" ? Object.keys(plants) : [],
    egg: eggs && typeof eggs === "object" ? Object.keys(eggs) : [],
    decor: decors && typeof decors === "object" ? Object.keys(decors) : [],
  };
  writeJson(MGDATA_CACHE_FILE, { savedAt: Date.now(), data, nameIndex });
  return buildMgData(data, nameIndex);
}

function resolveItemId(shopType, rawName, mgSets) {
  if (!mgSets) return rawName;
  const set = shopType === "seed" ? mgSets.seed : shopType === "egg" ? mgSets.egg : mgSets.decor;
  if (set && set.has(rawName)) return rawName;
  const idx = mgSets.index?.[shopType];
  if (!idx) return null;
  const raw = normalizeItemName(rawName);
  const key = normalizeKey(raw);
  if (!key) return null;
  if (LEGACY_ALIASES.has(key)) return LEGACY_ALIASES.get(key);
  if (LEGACY_ALIASES.has(raw.toLowerCase())) return LEGACY_ALIASES.get(raw.toLowerCase());
  if (idx.has(key)) return idx.get(key);
  if (key.endsWith("seed")) {
    const trimmed = key.replace(/seed(s)?$/, "");
    if (idx.has(trimmed)) return idx.get(trimmed);
  }
  if (key.endsWith("egg")) {
    const trimmed = key.replace(/egg(s)?$/, "");
    if (idx.has(trimmed)) return idx.get(trimmed);
  }
  if (key.endsWith("s")) {
    const singular = key.slice(0, -1);
    if (idx.has(singular)) return idx.get(singular);
  }
  if (key.endsWith("es")) {
    const singular = key.slice(0, -2);
    if (idx.has(singular)) return idx.get(singular);
  }
  return null;
}

function inferShopType(rawName, mgSets) {
  if (!mgSets) return null;
  const raw = normalizeItemName(rawName);
  const key = normalizeKey(raw);
  if (key.includes("egg")) return "egg";
  if (key.includes("seed")) return "seed";
  const seed = resolveItemId("seed", rawName, mgSets);
  if (seed) return "seed";
  const egg = resolveItemId("egg", rawName, mgSets);
  if (egg) return "egg";
  const decor = resolveItemId("decor", rawName, mgSets);
  if (decor) return "decor";
  return null;
}

function normalizeEvent(ev, mgSets, rejects) {
  const items = Array.isArray(ev.items) ? ev.items : [];
  const timestamp = typeof ev.timestamp === "number" ? ev.timestamp : Date.now();
  const previousWeatherId = ev.previousWeatherId ?? ev.previous_weather_id ?? null;
  if (ev.shopType && SHOP_TYPES.includes(String(ev.shopType).toLowerCase())) {
    const shopType = String(ev.shopType).toLowerCase();
    const weatherId = normalizeWeather(ev.weatherId ?? ev.weather ?? ev.weather_id);
    const normalizedItems = items
      .map((item) => {
        const raw = String(item.itemId ?? item.name ?? "");
        const resolved = resolveItemId(shopType, raw, mgSets);
        if (!resolved) {
          if (rejects) {
            const key = `${shopType}:${raw}`;
            rejects.set(key, (rejects.get(key) ?? 0) + 1);
          }
          return null;
        }
        return {
          itemId: resolved,
          stock: typeof item.stock === "number" ? item.stock : typeof item.quantity === "number" ? item.quantity : null,
        };
      })
      .filter((item) => item && item.itemId);
    if (!normalizedItems.length) return [];
    return [
      {
        timestamp,
        shopType,
        weatherId,
        previousWeatherId,
        items: normalizedItems,
        source: ev.source ?? "clean",
      },
    ];
  }
  const buckets = new Map();
  for (const item of items) {
    const rawType = String(item.type ?? item.shopType ?? ev.shopType ?? "").toLowerCase();
    const shopType = SHOP_TYPES.includes(rawType) ? rawType : inferShopType(item.itemId ?? item.name ?? "", mgSets);
    if (!shopType) continue;
    if (!buckets.has(shopType)) buckets.set(shopType, []);
    buckets.get(shopType).push(item);
  }

  const out = [];
  for (const [shopType, group] of buckets.entries()) {
    const normalizedItems = group
      .map((item) => {
        const raw = String(item.itemId ?? item.name ?? "");
        const resolved = resolveItemId(shopType, raw, mgSets);
        if (!resolved) {
          if (rejects) {
            const key = `${shopType}:${raw}`;
            rejects.set(key, (rejects.get(key) ?? 0) + 1);
          }
          return null;
        }
        return {
          itemId: resolved,
          stock: typeof item.stock === "number" ? item.stock : typeof item.quantity === "number" ? item.quantity : null,
        };
      })
      .filter((item) => item && item.itemId);
    if (normalizedItems.length === 0) continue;
    out.push({
      timestamp,
      shopType,
      weatherId: normalizeWeather(ev.weatherId ?? ev.weather ?? ev.weather_id),
      previousWeatherId,
      items: normalizedItems,
      source: ev.source ?? "clean",
    });
  }
  return out;
}

function updateHistory(history, event) {
  for (const item of event.items) {
    const key = `${event.shopType}:${item.itemId}`;
    const existing = history[key];
    const qty = typeof item.stock === "number" ? item.stock : null;
    if (!existing) {
      history[key] = {
        itemId: item.itemId,
        shopType: event.shopType,
        totalOccurrences: 1,
        firstSeen: event.timestamp,
        lastSeen: event.timestamp,
        averageIntervalMs: null,
        estimatedNextTimestamp: null,
        averageQuantity: qty,
        lastQuantity: qty,
        ratePerDay: null,
      };
      continue;
    }
    existing.totalOccurrences += 1;
    existing.lastSeen = event.timestamp;
    if (!existing.firstSeen || event.timestamp < existing.firstSeen) {
      existing.firstSeen = event.timestamp;
    }
    if (typeof qty === "number") {
      if (typeof existing.averageQuantity === "number") {
        existing.averageQuantity = Math.round((existing.averageQuantity + qty) / 2);
      } else {
        existing.averageQuantity = qty;
      }
      existing.lastQuantity = qty;
    }
  }
}

function computeStats(history) {
  const now = Date.now();
  for (const item of Object.values(history)) {
    const interval = item.totalOccurrences > 1 && item.firstSeen && item.lastSeen
      ? Math.max(1, Math.round((item.lastSeen - item.firstSeen) / (item.totalOccurrences - 1)))
      : null;
    item.averageIntervalMs = interval;
    if (interval && item.lastSeen) {
      let next = item.lastSeen + interval;
      while (next <= now) next += interval;
      item.estimatedNextTimestamp = next;
    } else {
      item.estimatedNextTimestamp = null;
    }
    if (item.firstSeen && item.lastSeen && item.lastSeen > item.firstSeen) {
      const days = (item.lastSeen - item.firstSeen) / 86400000;
      item.ratePerDay = days > 0 ? Number((item.totalOccurrences / days).toFixed(2)) : null;
    } else {
      item.ratePerDay = null;
    }
  }
}

async function deleteAll(table, keyColumn) {
  if (!SUPABASE_HEADERS || !SUPABASE_REST_ENDPOINT) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  }
  const key = keyColumn ?? "id";
  let total = 0;
  let batch = 0;
  while (true) {
    const selectRes = await supabaseFetch(
      `${SUPABASE_REST_ENDPOINT}/${table}?select=${key}&limit=${DELETE_BATCH_SIZE}`,
      { headers: SUPABASE_HEADERS }
    );
    if (!selectRes.ok) {
      const text = await selectRes.text();
      throw new Error(`Supabase select ${table} failed: ${selectRes.status} ${text}`);
    }
    const rows = await selectRes.json();
    if (!Array.isArray(rows) || rows.length === 0) break;
    const ids = rows.map((row) => row[key]).filter(Boolean);
    if (ids.length === 0) break;
    batch += 1;
    total += ids.length;
    console.log(`Deleting ${table}: batch ${batch} (${ids.length} rows, total ${total})`);
    const list = ids.map((v) => `"${String(v).replace(/"/g, '\\"')}"`).join(",");
    const res = await supabaseFetch(`${SUPABASE_REST_ENDPOINT}/${table}?${key}=in.(${list})`, {
      method: "DELETE",
      headers: SUPABASE_HEADERS,
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Supabase delete ${table} failed: ${res.status} ${text}`);
    }
  }
}

async function rebuildRestockHistory() {
  if (!SUPABASE_HEADERS || !SUPABASE_REST_ENDPOINT) return;
  const res = await supabaseFetch(`${SUPABASE_REST_ENDPOINT}/rpc/rebuild_restock_history`, {
    method: "POST",
    headers: SUPABASE_HEADERS,
    body: JSON.stringify({}),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Supabase rebuild_restock_history failed: ${res.status} ${text}`);
  }
}

async function insertRestockEvents(events) {
  if (!SUPABASE_HEADERS || !SUPABASE_REST_ENDPOINT) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  }
  if (!events || events.length === 0) return;
  const payload = events.map((ev) => ({
    timestamp: ev.timestamp,
    shop_type: ev.shopType,
    weather_id: ev.weatherId ?? null,
    items: ev.items.map((item) => ({ itemId: item.itemId, stock: item.stock ?? item.quantity ?? null })),
    source: ev.source ?? "clean",
    fingerprint: makeFingerprint(ev),
  }));
  const res = await supabaseFetch(`${SUPABASE_REST_ENDPOINT}/restock_events?on_conflict=fingerprint`, {
    method: "POST",
    headers: SUPABASE_HEADERS,
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const text = await res.text();
    if (res.status === 409) {
      return;
    }
    throw new Error(`Supabase insert restock_events failed: ${res.status} ${text}`);
  }
}

function makeFingerprint(ev) {
  const items = Array.isArray(ev.items) ? ev.items : [];
  const parts = items
    .map((item) => `${item.itemId}:${item.stock ?? item.quantity ?? ""}`)
    .sort()
    .join("|");
  return `${ev.shopType}:${ev.timestamp}:${parts}`;
}

function makeWeatherFingerprint(timestamp, weatherId, source) {
  return `weather:${source ?? "discord-json"}:${timestamp}:${weatherId ?? "Sunny"}`;
}

async function insertWeatherEvents(events) {
  if (!SUPABASE_HEADERS || !SUPABASE_REST_ENDPOINT) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  }
  if (!events || events.length === 0) return;
  const rows = events.map((ev) => ({
    timestamp: ev.timestamp,
    weather_id: ev.weatherId ?? "Sunny",
    previous_weather_id: ev.previousWeatherId ?? null,
    source: ev.source ?? "discord-json",
    fingerprint: makeWeatherFingerprint(ev.timestamp, ev.weatherId ?? "Sunny", ev.source ?? "discord-json"),
  }));
  const res = await supabaseFetch(`${SUPABASE_REST_ENDPOINT}/weather_events?on_conflict=fingerprint`, {
    method: "POST",
    headers: SUPABASE_HEADERS,
    body: JSON.stringify(rows),
  });
  if (!res.ok) {
    const text = await res.text();
    if (res.status === 409) return;
    throw new Error(`Supabase insert weather_events failed: ${res.status} ${text}`);
  }
}

async function upsertRestockHistory(items) {
  if (!SUPABASE_HEADERS || !SUPABASE_REST_ENDPOINT) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  }
  const body = Object.values(items).map((row) => ({
    item_id: row.itemId,
    shop_type: row.shopType,
    total_occurrences: row.totalOccurrences,
    first_seen: row.firstSeen,
    last_seen: row.lastSeen,
    average_interval_ms: row.averageIntervalMs,
    estimated_next_timestamp: row.estimatedNextTimestamp,
    average_quantity: row.averageQuantity,
    last_quantity: row.lastQuantity,
    rate_per_day: row.ratePerDay,
  }));
  if (body.length === 0) return;
  const res = await fetch(
    `${SUPABASE_REST_ENDPOINT}/restock_history?on_conflict=item_id,shop_type`,
    {
      method: "POST",
      headers: SUPABASE_HEADERS,
      body: JSON.stringify(body),
    }
  );
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Supabase upsert restock_history failed: ${res.status} ${text}`);
  }
}

async function main() {
  console.log("Clean start...");
  if (fs.existsSync(MGDATA_CACHE_FILE)) {
    console.log("MGDATA cache reset to include name index");
    try { fs.unlinkSync(MGDATA_CACHE_FILE); } catch {}
  }
  const mgSets = await loadMgData();
  console.log("MGData loaded");
  const rawEvents = readJson(EVENTS_FILE, []);
  console.log(`Loaded events.json: ${Array.isArray(rawEvents) ? rawEvents.length : 0}`);
  const rejects = new Map();
  const normalized = rawEvents.flatMap((ev) => normalizeEvent(ev, mgSets, rejects)).filter(Boolean);
  console.log(`Normalized events: ${normalized.length}`);
  if (!normalized.length) {
    console.log("No events to clean.");
    return;
  }
  const seen = new Set();
  let dedupedCount = 0;
  const deduped = [];
  for (const ev of normalized) {
    const fingerprint = makeFingerprint(ev);
    if (seen.has(fingerprint)) {
      dedupedCount += 1;
      continue;
    }
    seen.add(fingerprint);
    deduped.push(ev);
  }
  if (dedupedCount > 0) {
    console.log(`Deduped ${dedupedCount} duplicate events (fingerprint)`);
  }
  if (rejects.size > 0) {
    const top = Array.from(rejects.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, 25)
      .map(([key, count]) => ({ key, count }));
    writeJson(path.join(DATA_DIR, "clean-rejects.json"), {
      totalRejected: Array.from(rejects.values()).reduce((a, b) => a + b, 0),
      top,
    });
    console.log(`Wrote clean-rejects.json with top ${top.length} rejects`);
  }

  const history = {};
  for (const ev of normalized) {
    updateHistory(history, ev);
  }
  computeStats(history);

  console.log("Deleting existing restock_events and restock_history...");
  await deleteAll("restock_events", "id");
  await deleteAll("restock_history", "item_id");

  for (let i = 0; i < deduped.length; i += INSERT_BATCH_SIZE) {
    const batch = deduped.slice(i, i + INSERT_BATCH_SIZE);
    await insertRestockEvents(batch);
    console.log(`Inserted ${Math.min(i + INSERT_BATCH_SIZE, deduped.length)}/${deduped.length} events`);
  }

  console.log("Writing weather_events from source data...");
  await insertWeatherEvents(deduped);

  console.log("Rebuilding restock_history in SQL...");
  try {
    await rebuildRestockHistory();
  } catch (err) {
    const msg = String(err);
    if (msg.includes("statement timeout") || msg.includes("57014")) {
      console.warn("RPC rebuild timed out; falling back to local history upsert...");
      await upsertRestockHistory(history);
    } else {
      throw err;
    }
  }
  console.log("Clean rebuild complete.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
