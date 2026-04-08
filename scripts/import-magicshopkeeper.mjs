import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import fetch from "node-fetch";

const ROOT = process.cwd();
const DATA_DIR = path.join(ROOT, "data");
const DEFAULT_INPUT = path.join(ROOT, "restock examples", "MagicShopkeeper");

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY =
  process.env.SUPABASE_SERVICE_ROLE_KEY ?? process.env.SERVICE_ROLE_KEY ?? "";
const SUPABASE_REST_ENDPOINT = SUPABASE_URL ? `${SUPABASE_URL}/rest/v1` : "";

const MG_API_BASE = process.env.MG_API_BASE ?? "https://mg-api.ariedam.fr";
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS ?? 15000);

const EVENT_SOURCE = "magicshopkeeper";
const SNAPSHOT_SOURCE = "magicshopkeeper";

const DEFAULT_TZ = "UTC";

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    input: DEFAULT_INPUT,
    timezone: DEFAULT_TZ,
    dryRun: false,
    snapshotsOnly: false,
    eventsOnly: false,
    noSupabase: false,
    maxFiles: 0,
  };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--input") out.input = args[++i];
    else if (arg === "--timezone") out.timezone = args[++i];
    else if (arg === "--dry-run") out.dryRun = true;
    else if (arg === "--snapshots-only") out.snapshotsOnly = true;
    else if (arg === "--events-only") out.eventsOnly = true;
    else if (arg === "--no-supabase") out.noSupabase = true;
    else if (arg === "--max-files") out.maxFiles = Number(args[++i] ?? 0);
  }
  if (out.snapshotsOnly && out.eventsOnly) {
    console.error("Cannot use --snapshots-only with --events-only.");
    process.exit(1);
  }
  return out;
}

function ensureDir(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function isValidEnv() {
  if (process.env.NO_SUPABASE === "1") return false;
  return Boolean(SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY);
}

function writeJson(file, value) {
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n", "utf8");
}

function normalizeKey(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[\u2019']/g, "")
    .replace(/[^a-z0-9]/g, "");
}

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
  ["thunderstorm", "Thunderstorm"],
  ["storm", "Thunderstorm"],
  ["", "Sunny"],
]);

function normalizeWeather(value) {
  const key = normalizeKey(value ?? "");
  return WEATHER_ALIASES.get(key) ?? "Sunny";
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
  ["tulip", "OrangeTulip"],
  ["pine", "PineTree"],
]);

function applyLegacyAlias(value) {
  const key = normalizeKey(value);
  return LEGACY_ALIASES.get(key) ?? value;
}

async function fetchJson(url) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(url, { signal: controller.signal });
    if (!res.ok) return null;
    return res.json();
  } catch {
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

function buildIndex(names) {
  const index = new Map();
  for (const id of names) {
    const key = normalizeKey(id);
    if (!index.has(key)) index.set(key, id);
  }
  return index;
}

async function loadMgData() {
  const [plants, eggs, decors] = await Promise.all([
    fetchJson(`${MG_API_BASE}/data/plants`),
    fetchJson(`${MG_API_BASE}/data/eggs`),
    fetchJson(`${MG_API_BASE}/data/decors`),
  ]);
  const seedNames = plants && typeof plants === "object" ? Object.keys(plants) : [];
  const eggNames = eggs && typeof eggs === "object" ? Object.keys(eggs) : [];
  const decorNames = decors && typeof decors === "object" ? Object.keys(decors) : [];
  return {
    seed: new Set(seedNames),
    egg: new Set(eggNames),
    decor: new Set(decorNames),
    index: {
      seed: buildIndex(seedNames),
      egg: buildIndex(eggNames),
      decor: buildIndex(decorNames),
    },
  };
}

function resolveItemId(shopType, raw, mg) {
  if (!mg) return raw;
  const set = shopType === "seed" ? mg.seed : shopType === "egg" ? mg.egg : mg.decor;
  const idx = shopType === "seed" ? mg.index.seed : shopType === "egg" ? mg.index.egg : mg.index.decor;
  const normalized = applyLegacyAlias(String(raw ?? ""));
  if (set.has(normalized)) return normalized;
  const key = normalizeKey(normalized);
  if (!key) return null;
  const direct = idx.get(key);
  if (direct) return direct;
  if (key.endsWith("s")) {
    const singular = key.slice(0, -1);
    const hit = idx.get(singular);
    if (hit) return hit;
  }
  if (key.endsWith("es")) {
    const singular = key.slice(0, -2);
    const hit = idx.get(singular);
    if (hit) return hit;
  }
  return null;
}

function parseDateFromFilename(name) {
  const match = name.match(/(\d{4}-\d{2}-\d{2})/);
  if (!match) return null;
  return match[1];
}

function parseTimeString(value) {
  const raw = String(value ?? "").trim();
  if (!raw) return null;
  const match = raw.match(/^(\d{1,2}):(\d{2})$/);
  if (!match) return null;
  const h = Number(match[1]);
  const m = Number(match[2]);
  if (!Number.isFinite(h) || !Number.isFinite(m)) return null;
  if (h < 0 || h > 23 || m < 0 || m > 59) return null;
  return { h, m };
}

function getTimeZoneOffsetMinutes(timeZone, date) {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });
  const parts = dtf.formatToParts(date);
  const get = (type) => parts.find((p) => p.type === type)?.value ?? "00";
  const y = Number(get("year"));
  const mo = Number(get("month"));
  const d = Number(get("day"));
  const h = Number(get("hour"));
  const m = Number(get("minute"));
  const s = Number(get("second"));
  const asUTC = Date.UTC(y, mo - 1, d, h, m, s);
  return (asUTC - date.getTime()) / 60000;
}

function toTimestampMs(dateStr, timeStr, tz) {
  const t = parseTimeString(timeStr);
  if (!t || !dateStr) return null;
  const [y, mo, d] = dateStr.split("-").map(Number);
  if (!Number.isFinite(y) || !Number.isFinite(mo) || !Number.isFinite(d)) return null;
  const baseUtc = Date.UTC(y, mo - 1, d, t.h, t.m, 0, 0);
  if (tz === "UTC") return baseUtc;
  try {
    const date = new Date(baseUtc);
    const offsetMin = getTimeZoneOffsetMinutes(tz, date);
    return baseUtc - offsetMin * 60000;
  } catch {
    return null;
  }
}

function makeRestockFingerprint(shopType, timestamp, items) {
  const parts = items
    .map((item) => `${item.itemId}:${item.stock ?? ""}`)
    .sort()
    .join("|");
  return `${shopType}:${timestamp}:${parts}`;
}

function makeSnapshotFingerprint(timestamp, payload) {
  const parts = Object.keys(payload)
    .sort()
    .map((key) => `${key}:${payload[key] ?? ""}`)
    .join("|");
  return `snapshot:${timestamp}:${parts}`;
}

function makeWeatherFingerprint(timestamp, weatherId, source) {
  return `weather:${source}:${timestamp}:${weatherId}`;
}

function hasAnyStock(items) {
  return items.some((i) => (i.stock ?? 0) > 0);
}

function getShopIntervalMs(shopType) {
  if (shopType === "seed") return 300000;
  if (shopType === "egg") return 900000;
  return 3600000;
}

function snapTimestamp(shopType, ts) {
  const interval = getShopIntervalMs(shopType);
  return Math.floor(ts / interval) * interval;
}

function deriveRestockEvents(rows, shopType) {
  const events = [];
  let currentSnap = null;
  for (const row of rows) {
    const items = row.itemsByShop[shopType] ?? [];
    if (!items.length || !hasAnyStock(items)) continue;
    const snappedTs = snapTimestamp(shopType, row.timestamp);
    if (currentSnap === snappedTs) continue;
    currentSnap = snappedTs;
    events.push({
      shopType,
      timestamp: snappedTs,
      items,
      weatherId: row.weatherId,
    });
  }
  return events;
}

function deriveWeatherEvents(rows) {
  const events = [];
  let prev = null;
  for (const row of rows) {
    if (!row.weatherId) continue;
    if (!prev || prev.weatherId !== row.weatherId) {
      events.push({
        timestamp: row.timestamp,
        weatherId: row.weatherId,
        previousWeatherId: prev?.weatherId ?? null,
      });
    }
    prev = row;
  }
  return events;
}

async function readExcelFileWithPython(filePath) {
  const tempPath = path.join(
    DATA_DIR,
    `__magicshopkeeper_${Date.now()}_${Math.floor(Math.random() * 100000)}.json`
  );
  const escaped = filePath.replace(/\\/g, "\\\\");
  const tempEscaped = tempPath.replace(/\\/g, "\\\\");
  const code =
    `import pandas as pd\n` +
    `df = pd.read_excel(r"${escaped}")\n` +
    `df.to_json(r"${tempEscaped}", orient="records")\n`;
  const res = spawnSync("python", ["-c", code], { encoding: "utf8", maxBuffer: 50 * 1024 * 1024 });
  if (res.status !== 0) {
    const err = res.stderr || res.stdout || "";
    throw new Error(`Failed to read excel: ${filePath}: ${err}`);
  }
  if (!fs.existsSync(tempPath)) return [];
  const raw = fs.readFileSync(tempPath, "utf8");
  fs.unlinkSync(tempPath);
  if (!raw.trim()) return [];
  return JSON.parse(raw);
}

async function loadRowsFromFiles(inputDir) {
  const entries = fs.readdirSync(inputDir, { withFileTypes: true });
  const files = entries
    .filter((e) => e.isFile() && e.name.endsWith(".xlsx"))
    .map((e) => path.join(inputDir, e.name))
    .sort();
  return { files };
}

async function buildRows(inputDir, timezone, mg, maxFiles = 0) {
  const { files } = await loadRowsFromFiles(inputDir);
  const out = [];
  const limit = maxFiles > 0 ? Math.min(maxFiles, files.length) : files.length;

  for (let i = 0; i < limit; i++) {
    const filePath = files[i];
    const dateStr = parseDateFromFilename(path.basename(filePath));
    if (!dateStr) continue;
    const rows = await readExcelFileWithPython(filePath);
    for (const row of rows) {
      const time = row.time ?? row.Time ?? row.TIME;
      const timestamp = toTimestampMs(dateStr, time, timezone);
      if (!timestamp) continue;

      const weatherRaw = row.weather ?? row.Weather ?? row.WEATHER;
      const weatherId = normalizeWeather(weatherRaw);

      const itemsByShop = { seed: [], egg: [], decor: [] };
      for (const [key, value] of Object.entries(row)) {
        if (key === "time" || key === "Time" || key === "TIME") continue;
        if (key === "weather" || key === "Weather" || key === "WEATHER") continue;
        if (key === "version" || key === "Version" || key === "VERSION") continue;

        const qty = Number(value ?? 0);
        if (!Number.isFinite(qty) || qty <= 0) continue;
        const resolvedSeed = resolveItemId("seed", key, mg);
        const resolvedEgg = resolveItemId("egg", key, mg);
        const resolvedDecor = resolveItemId("decor", key, mg);
        if (resolvedSeed) itemsByShop.seed.push({ itemId: resolvedSeed, stock: qty });
        else if (resolvedEgg) itemsByShop.egg.push({ itemId: resolvedEgg, stock: qty });
        else if (resolvedDecor) itemsByShop.decor.push({ itemId: resolvedDecor, stock: qty });
      }

      out.push({
        timestamp,
        weatherId,
        itemsByShop,
      });
    }
  }

  out.sort((a, b) => a.timestamp - b.timestamp);
  return out;
}

async function supabaseInsert(table, rows) {
  if (!rows.length) return { ok: true };

  const BATCH_SIZE = 2000;
  const totalBatches = Math.ceil(rows.length / BATCH_SIZE);

  for (let i = 0; i < rows.length; i += BATCH_SIZE) {
    const chunk = rows.slice(i, i + BATCH_SIZE);
    const batchNum = Math.floor(i / BATCH_SIZE) + 1;
    console.log(`Inserting ${table} batch ${batchNum}/${totalBatches} (${chunk.length} rows)...`);

    const res = await fetch(`${SUPABASE_REST_ENDPOINT}/${table}?on_conflict=fingerprint`, {
      method: "POST",
      headers: {
        apikey: SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        "content-type": "application/json",
        "Prefer": "resolution=ignore-duplicates"
      },
      body: JSON.stringify(chunk),
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Supabase insert ${table} batch ${batchNum} failed: ${res.status} ${text}`);
    }
  }
  return { ok: true };
}

async function callRpc(name) {
  const res = await fetch(`${SUPABASE_REST_ENDPOINT}/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({}),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Supabase rpc ${name} failed: ${res.status} ${text}`);
  }
  return { ok: true };
}

async function main() {
  const args = parseArgs();
  const inputDir = path.resolve(args.input);
  ensureDir(DATA_DIR);

  if (!fs.existsSync(inputDir)) {
    console.error(`Input directory not found: ${inputDir}`);
    process.exit(1);
  }

  const mg = await loadMgData();
  if (!mg) {
    console.error("Failed to load MG data from mg-api.");
    process.exit(1);
  }

  const rows = await buildRows(inputDir, args.timezone, mg, args.maxFiles);
  console.log(`Loaded ${rows.length} snapshot rows.`);

  const weatherEvents = deriveWeatherEvents(rows).map((ev) => ({
    timestamp: ev.timestamp,
    weather_id: ev.weatherId,
    previous_weather_id: ev.previousWeatherId,
    source: EVENT_SOURCE,
    fingerprint: makeWeatherFingerprint(ev.timestamp, ev.weatherId, EVENT_SOURCE),
  }));

  const restockEvents = [];
  for (const shopType of ["seed", "egg", "decor"]) {
    const derived = deriveRestockEvents(rows, shopType).map((ev) => ({
      timestamp: ev.timestamp,
      shop_type: ev.shopType,
      items: ev.items,
      weather_id: ev.weatherId,
      source: EVENT_SOURCE,
      fingerprint: makeRestockFingerprint(ev.shopType, ev.timestamp, ev.items),
    }));
    restockEvents.push(...derived);
  }

  const snapshots = rows.map((row) => {
    const payload = {};
    for (const shop of ["seed", "egg", "decor"]) {
      for (const item of row.itemsByShop[shop]) {
        payload[item.itemId] = item.stock;
      }
    }
    return {
      timestamp: row.timestamp,
      weather_id: row.weatherId,
      source: SNAPSHOT_SOURCE,
      payload,
      fingerprint: makeSnapshotFingerprint(row.timestamp, payload),
    };
  });

  console.log(`Derived restock events: ${restockEvents.length}`);
  console.log(`Derived weather events: ${weatherEvents.length}`);
  console.log(`Snapshots: ${snapshots.length}`);

  if (args.dryRun || args.noSupabase || !isValidEnv()) {
    console.log("Dry run or Supabase disabled - writing JSON outputs only.");
    writeJson(path.join(DATA_DIR, "magicshopkeeper_restock_events.json"), restockEvents);
    writeJson(path.join(DATA_DIR, "magicshopkeeper_weather_events.json"), weatherEvents);
    writeJson(path.join(DATA_DIR, "magicshopkeeper_snapshots.json"), snapshots);
    return;
  }

  if (!args.eventsOnly) {
    // Snapshots table was dropped in overhaul migration
    // await supabaseInsert("restock_snapshots", snapshots);
  }
  if (!args.snapshotsOnly) {
    await supabaseInsert("weather_events", weatherEvents);
    await supabaseInsert("restock_events", restockEvents);
  }

  if (!args.snapshotsOnly) {
    await callRpc("rebuild_restock_history");
    await callRpc("rebuild_weather_history");
  }

  console.log("Import complete.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
