/**
 * MagicShopkeeper Seed Script
 *
 * Reads 167 xlsx files from MagicShopkeeper data, parses items,
 * maps display names to PascalCase game IDs, snaps timestamps,
 * generates fingerprints, batch inserts into restock_events,
 * then calls rebuild_restock_history().
 *
 * Usage:
 *   npx tsx scripts/seed-magicshopkeeper.ts [--dry-run] [--max-files N] [--timezone UTC]
 *
 * Requires:
 *   - Python 3 with pandas + openpyxl installed (for xlsx reading)
 *   - SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY env vars (or --dry-run)
 */

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const ROOT = process.cwd();
const DATA_DIR = path.join(ROOT, "data");
const DEFAULT_INPUT = path.join(ROOT, "restock examples", "MagicShopkeeper");

const SUPABASE_URL = (process.env.SUPABASE_URL ?? "").replace(/\s+/g, "");
const SUPABASE_SERVICE_ROLE_KEY =
  (process.env.SUPABASE_SERVICE_ROLE_KEY ?? process.env.SERVICE_ROLE_KEY ?? "").replace(/\s+/g, "");
const SUPABASE_REST_ENDPOINT = SUPABASE_URL ? `${SUPABASE_URL}/rest/v1` : "";

const MG_API_BASE = process.env.MG_API_BASE ?? "https://mg-api.ariedam.fr";
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS ?? 15000);
const BATCH_SIZE = 500;

const EVENT_SOURCE = "magicshopkeeper";

type ShopType = "seed" | "egg" | "decor";
type MgData = {
  seed: Set<string>;
  egg: Set<string>;
  decor: Set<string>;
  index: { seed: Map<string, string>; egg: Map<string, string>; decor: Map<string, string> };
};

// ─── CLI Args ────────────────────────────────────────────────────────────────

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    input: DEFAULT_INPUT,
    timezone: "UTC",
    dryRun: false,
    maxFiles: 0,
  };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--input") out.input = args[++i];
    else if (arg === "--timezone") out.timezone = args[++i];
    else if (arg === "--dry-run") out.dryRun = true;
    else if (arg === "--max-files") out.maxFiles = Number(args[++i] ?? 0);
  }
  return out;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function normalizeKey(value: string): string {
  return String(value || "")
    .toLowerCase()
    .replace(/[\u2019']/g, "")
    .replace(/[^a-z0-9]/g, "");
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

function applyLegacyAlias(value: string): string {
  const key = normalizeKey(value);
  return LEGACY_ALIASES.get(key) ?? value;
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
  ["", "Sunny"],
]);

function normalizeWeather(value: unknown): string {
  const key = normalizeKey(String(value ?? ""));
  return WEATHER_ALIASES.get(key) ?? "Sunny";
}

function makeWeatherFingerprint(timestamp: number, weatherId: string, source: string): string {
  return `weather:${source}:${timestamp}:${weatherId}`;
}

// ─── MG Data Loading ─────────────────────────────────────────────────────────

async function fetchJson(url: string): Promise<any> {
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

function buildIndex(names: string[]): Map<string, string> {
  const index = new Map<string, string>();
  for (const id of names) {
    const key = normalizeKey(id);
    if (!index.has(key)) index.set(key, id);
  }
  return index;
}

async function loadMgData(): Promise<MgData | null> {
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

function resolveItemId(shopType: ShopType, raw: string, mg: MgData): string | null {
  const set = shopType === "seed" ? mg.seed : shopType === "egg" ? mg.egg : mg.decor;
  const idx = shopType === "seed" ? mg.index.seed : shopType === "egg" ? mg.index.egg : mg.index.decor;
  const normalized = applyLegacyAlias(String(raw ?? ""));
  if (set.has(normalized)) return normalized;
  const key = normalizeKey(normalized);
  if (!key) return null;
  const direct = idx.get(key);
  if (direct) return direct;
  if (key.endsWith("s")) {
    const hit = idx.get(key.slice(0, -1));
    if (hit) return hit;
  }
  if (key.endsWith("es")) {
    const hit = idx.get(key.slice(0, -2));
    if (hit) return hit;
  }
  return null;
}

// ─── Timestamp Logic ─────────────────────────────────────────────────────────

function parseDateFromFilename(name: string): string | null {
  const match = name.match(/(\d{4}-\d{2}-\d{2})/);
  return match ? match[1] : null;
}

function parseTimeString(value: unknown): { h: number; m: number } | null {
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

function toTimestampMs(dateStr: string, timeStr: unknown, tz: string): number | null {
  const t = parseTimeString(timeStr);
  if (!t || !dateStr) return null;
  const [y, mo, d] = dateStr.split("-").map(Number);
  if (!Number.isFinite(y) || !Number.isFinite(mo) || !Number.isFinite(d)) return null;
  const baseUtc = Date.UTC(y, mo - 1, d, t.h, t.m, 0, 0);
  if (tz === "UTC") return baseUtc;
  try {
    const dtf = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
      hour12: false,
    });
    const parts = dtf.formatToParts(new Date(baseUtc));
    const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "00";
    const asUtcMs = Date.UTC(
      Number(get("year")), Number(get("month")) - 1, Number(get("day")),
      Number(get("hour")), Number(get("minute")), Number(get("second"))
    );
    const offsetMin = (asUtcMs - baseUtc) / 60000;
    return baseUtc - offsetMin * 60000;
  } catch {
    return null;
  }
}

// ─── Snap + Fingerprint (matching new DB function) ───────────────────────────

const SHOP_INTERVALS: Record<ShopType, number> = {
  seed: 300000,    // 5 minutes
  egg: 900000,     // 15 minutes
  decor: 3600000,  // 60 minutes
};

function snapTimestamp(shopType: ShopType, ts: number): number {
  const interval = SHOP_INTERVALS[shopType];
  return Math.floor(ts / interval) * interval;
}

function makeFingerprint(shopType: string, snappedTs: number, items: { itemId: string; stock: number }[]): string {
  const parts = items
    .map((item) => `${item.itemId}:${item.stock}`)
    .sort()
    .join("|");
  return `${shopType}:${snappedTs}:${parts}`;
}

// ─── Excel Reading ───────────────────────────────────────────────────────────

function readExcelFileWithPython(filePath: string): Record<string, unknown>[] {
  if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
  const tempPath = path.join(DATA_DIR, `__seed_${Date.now()}_${Math.floor(Math.random() * 100000)}.json`);
  const escaped = filePath.replace(/\\/g, "\\\\");
  const tempEscaped = tempPath.replace(/\\/g, "\\\\");
  const code =
    `import pandas as pd\n` +
    `df = pd.read_excel(r"${escaped}")\n` +
    `df.to_json(r"${tempEscaped}", orient="records")\n`;
  const res = spawnSync("python", ["-c", code], { encoding: "utf8", maxBuffer: 50 * 1024 * 1024 });
  if (res.status !== 0) {
    throw new Error(`Failed to read excel: ${filePath}: ${res.stderr || res.stdout || ""}`);
  }
  if (!fs.existsSync(tempPath)) return [];
  const raw = fs.readFileSync(tempPath, "utf8");
  fs.unlinkSync(tempPath);
  if (!raw.trim()) return [];
  return JSON.parse(raw);
}

// ─── Event Derivation ────────────────────────────────────────────────────────

type ParsedRow = {
  timestamp: number;
  weatherId: string;
  itemsByShop: Record<ShopType, { itemId: string; stock: number }[]>;
};

function buildRows(inputDir: string, timezone: string, mg: MgData, maxFiles: number): ParsedRow[] {
  const entries = fs.readdirSync(inputDir, { withFileTypes: true });
  const files = entries
    .filter((e) => e.isFile() && e.name.endsWith(".xlsx"))
    .map((e) => path.join(inputDir, e.name))
    .sort();

  const limit = maxFiles > 0 ? Math.min(maxFiles, files.length) : files.length;
  const out: ParsedRow[] = [];

  for (let i = 0; i < limit; i++) {
    const filePath = files[i];
    const dateStr = parseDateFromFilename(path.basename(filePath));
    if (!dateStr) continue;

    console.log(`  [${i + 1}/${limit}] ${path.basename(filePath)}`);
    const rows = readExcelFileWithPython(filePath);

    for (const row of rows) {
      const time = (row as any).time ?? (row as any).Time ?? (row as any).TIME;
      const timestamp = toTimestampMs(dateStr, time, timezone);
      if (!timestamp) continue;

      const weatherRaw = (row as any).weather ?? (row as any).Weather ?? (row as any).WEATHER;
      const weatherId = normalizeWeather(weatherRaw);

      const itemsByShop: Record<ShopType, { itemId: string; stock: number }[]> = { seed: [], egg: [], decor: [] };
      for (const [key, value] of Object.entries(row)) {
        const lk = key.toLowerCase();
        if (lk === "time" || lk === "weather" || lk === "version") continue;

        const qty = Number(value ?? 0);
        if (!Number.isFinite(qty) || qty <= 0) continue;

        // Try to resolve to each shop type
        const resolvedSeed = resolveItemId("seed", key, mg);
        const resolvedEgg = resolveItemId("egg", key, mg);
        const resolvedDecor = resolveItemId("decor", key, mg);

        if (resolvedSeed) itemsByShop.seed.push({ itemId: resolvedSeed, stock: qty });
        else if (resolvedEgg) itemsByShop.egg.push({ itemId: resolvedEgg, stock: qty });
        else if (resolvedDecor) itemsByShop.decor.push({ itemId: resolvedDecor, stock: qty });
        // Tools (Watering Can, Planter Pot, Crop Cleanser) won't resolve — excluded
      }

      out.push({ timestamp, weatherId, itemsByShop });
    }
  }

  out.sort((a, b) => a.timestamp - b.timestamp);
  return out;
}

type RestockEventRow = {
  timestamp: number;
  shop_type: string;
  items: { itemId: string; stock: number }[];
  source: string;
  fingerprint: string;
};

function deriveRestockEvents(rows: ParsedRow[], shopType: ShopType): RestockEventRow[] {
  const events: RestockEventRow[] = [];
  let currentSnap: number | null = null;

  for (const row of rows) {
    const items = row.itemsByShop[shopType];
    if (!items.length || !items.some((i) => i.stock > 0)) continue;

    const snappedTs = snapTimestamp(shopType, row.timestamp);
    if (currentSnap === snappedTs) continue;
    currentSnap = snappedTs;

    events.push({
      timestamp: snappedTs,
      shop_type: shopType,
      items,
      source: EVENT_SOURCE,
      fingerprint: makeFingerprint(shopType, snappedTs, items),
    });
  }

  return events;
}

type WeatherEventRow = {
  timestamp: number;
  weather_id: string;
  previous_weather_id: string | null;
  source: string;
  fingerprint: string;
};

function deriveWeatherEvents(rows: ParsedRow[]): WeatherEventRow[] {
  const events: WeatherEventRow[] = [];
  let prev: ParsedRow | null = null;
  for (const row of rows) {
    if (!row.weatherId) continue;
    if (!prev || prev.weatherId !== row.weatherId) {
      events.push({
        timestamp: row.timestamp,
        weather_id: row.weatherId,
        previous_weather_id: prev?.weatherId ?? null,
        source: EVENT_SOURCE,
        fingerprint: makeWeatherFingerprint(row.timestamp, row.weatherId, EVENT_SOURCE),
      });
    }
    prev = row;
  }
  return events;
}

// ─── Supabase ────────────────────────────────────────────────────────────────

async function supabaseInsertBatch(table: string, rows: Record<string, unknown>[]): Promise<void> {
  for (let i = 0; i < rows.length; i += BATCH_SIZE) {
    const batch = rows.slice(i, i + BATCH_SIZE);
    const res = await fetch(`${SUPABASE_REST_ENDPOINT}/${table}?on_conflict=fingerprint`, {
      method: "POST",
      headers: {
        apikey: SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        "content-type": "application/json",
        Prefer: "resolution=ignore-duplicates",
      },
      body: JSON.stringify(batch),
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Insert ${table} batch ${i}..${i + batch.length} failed: ${res.status} ${text}`);
    }
    console.log(`  Inserted batch ${i + 1}..${i + batch.length} / ${rows.length}`);
  }
}

async function callRpc(name: string): Promise<void> {
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
    throw new Error(`RPC ${name} failed: ${res.status} ${text}`);
  }
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const args = parseArgs();
  const inputDir = path.resolve(args.input);

  if (!fs.existsSync(inputDir)) {
    console.error(`Input directory not found: ${inputDir}`);
    process.exit(1);
  }

  console.log("Loading MG data from API...");
  const mg = await loadMgData();
  if (!mg) {
    console.error("Failed to load MG data.");
    process.exit(1);
  }
  console.log(`  Seeds: ${mg.seed.size}, Eggs: ${mg.egg.size}, Decor: ${mg.decor.size}`);

  console.log("Parsing xlsx files...");
  const rows = buildRows(inputDir, args.timezone, mg, args.maxFiles);
  console.log(`Parsed ${rows.length} snapshot rows.`);

  // Derive restock events per shop type
  const allEvents: RestockEventRow[] = [];
  for (const shopType of ["seed", "egg", "decor"] as ShopType[]) {
    const events = deriveRestockEvents(rows, shopType);
    allEvents.push(...events);
    console.log(`  ${shopType}: ${events.length} events`);
  }
  console.log(`Total restock events: ${allEvents.length}`);

  // Derive weather events
  const weatherEvents = deriveWeatherEvents(rows);
  console.log(`Weather events: ${weatherEvents.length}`);

  if (args.dryRun || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    console.log("Dry run — writing JSON output.");
    if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(
      path.join(DATA_DIR, "seed_restock_events.json"),
      JSON.stringify(allEvents, null, 2) + "\n",
      "utf8"
    );
    fs.writeFileSync(
      path.join(DATA_DIR, "seed_weather_events.json"),
      JSON.stringify(weatherEvents, null, 2) + "\n",
      "utf8"
    );
    console.log(`Wrote ${allEvents.length} restock events and ${weatherEvents.length} weather events`);
    return;
  }

  console.log("Inserting into Supabase restock_events...");
  await supabaseInsertBatch("restock_events", allEvents);

  console.log("Inserting into Supabase weather_events...");
  await supabaseInsertBatch("weather_events", weatherEvents);

  console.log("Calling rebuild_restock_history()...");
  await callRpc("rebuild_restock_history");

  console.log("Calling rebuild_weather_summary()...");
  await callRpc("rebuild_weather_summary");

  console.log("Seed complete.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
