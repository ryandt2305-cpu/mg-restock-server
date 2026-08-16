// Shared helpers for the official Magic Garden platform API.
// Reference: Feeder-Extension/docs/superpowers/specs/2026-08-16-mg-platform-api-reference.md
//
//   GET https://magicgarden.gg/platform/v1/shops   -> { shops: { [shopType]: ShopEntry } }
//   GET https://magicgarden.gg/platform/v1/weather -> null | <weather payload>
//
// Pure functions only (no I/O) except the two fetch helpers at the bottom.

export const DEFAULT_PLATFORM_API_BASE = "https://magicgarden.gg/platform/v1";

/** Canonical weather ids used in weather_events / restock_events.weather_id. */
export const WEATHER_ALIASES = new Map([
  ["sunny", "Sunny"],
  ["clear", "Sunny"],
  ["clearskies", "Sunny"],
  ["none", "Sunny"],
  ["rain", "Rain"],
  ["snow", "Frost"], // display name for the Frost event
  ["frost", "Frost"],
  ["dawn", "Dawn"],
  ["amber", "AmberMoon"],
  ["ambermoon", "AmberMoon"],
  ["ambermoonweather", "AmberMoon"],
  ["thunder", "Thunderstorm"],
  ["storm", "Thunderstorm"],
  ["thunderstorm", "Thunderstorm"],
]);

export function normalizeKey(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[’']/g, "")
    .replace(/[^a-z0-9]/g, "");
}

/**
 * Map any weather string (id or display name) to a canonical id.
 * Returns null when the string is unrecognised — callers decide whether
 * to skip or default. (Never silently coerce unknown values to Sunny.)
 */
export function normalizeWeather(value) {
  const key = normalizeKey(value);
  if (!key) return null;
  return WEATHER_ALIASES.get(key) ?? null;
}

const WEATHER_FIELD_CANDIDATES = ["weather", "weatherId", "weather_id", "id", "type", "name", "kind", "event"];
const WEATHER_NESTED_CANDIDATES = ["current", "data", "state", "event", "weather"];

/**
 * Extract a canonical weather id from the /weather payload.
 *   null / undefined            -> "Sunny"   (documented: no active event)
 *   "Rain" / "Amber Moon" ...   -> canonical id, or null if unrecognised
 *   { weather: "Rain", ... }    -> canonical id from the first recognised field, else null
 */
export function extractWeatherId(payload) {
  if (payload === null || payload === undefined) return "Sunny";
  if (typeof payload === "string") return normalizeWeather(payload);
  if (typeof payload !== "object") return null;
  for (const field of WEATHER_FIELD_CANDIDATES) {
    const v = payload[field];
    if (typeof v === "string") {
      const id = normalizeWeather(v);
      if (id) return id;
    }
  }
  for (const field of WEATHER_NESTED_CANDIDATES) {
    const nested = payload[field];
    if (nested && typeof nested === "object") {
      for (const inner of WEATHER_FIELD_CANDIDATES) {
        const v = nested[inner];
        if (typeof v === "string") {
          const id = normalizeWeather(v);
          if (id) return id;
        }
      }
    }
  }
  return null;
}

function toMs(iso) {
  if (typeof iso !== "string" || !iso) return null;
  const ms = Date.parse(iso);
  return Number.isFinite(ms) ? ms : null;
}

function normalizeItem(raw) {
  if (!raw || typeof raw !== "object") return null;
  const itemId = typeof raw.itemId === "string" ? raw.itemId.trim() : "";
  if (!itemId) return null;
  const stock = typeof raw.stock === "number" && Number.isFinite(raw.stock) ? raw.stock : 0;
  return {
    itemId,
    name: typeof raw.name === "string" ? raw.name : itemId,
    itemType: typeof raw.itemType === "string" ? raw.itemType : null,
    coinPrice: typeof raw.coinPrice === "number" ? raw.coinPrice : null,
    stock,
  };
}

/**
 * Normalise the /shops payload into a stable internal shape.
 *
 * Returns { [shopType]: {
 *   open: boolean,
 *   nextRestockAt: number|null,        // epoch ms
 *   nextRestockAtIso: string|null,
 *   secondsUntilRestock: number,       // >= 0, computed against nowMs
 *   items:   [{ itemId, name, itemType, coinPrice, stock }]  // stock > 0 only
 *   catalog: [{ itemId, name, itemType, coinPrice, stock }]  // everything, incl. stock 0
 * } }
 *
 * Accepts either the raw payload ({ shops: {...} }) or the inner shops object.
 */
export function normalizePlatformShops(payload, nowMs = Date.now()) {
  const shops =
    payload && typeof payload === "object" && payload.shops && typeof payload.shops === "object"
      ? payload.shops
      : payload;
  const out = {};
  if (!shops || typeof shops !== "object") return out;
  for (const [shopType, raw] of Object.entries(shops)) {
    if (!raw || typeof raw !== "object") continue;
    const nextRestockAt = toMs(raw.nextRestockAt);
    const rawItems = Array.isArray(raw.items) ? raw.items : [];
    const rawCatalog = Array.isArray(raw.catalog) ? raw.catalog : [];
    const catalog = rawCatalog.map(normalizeItem).filter(Boolean);
    const items = rawItems.map(normalizeItem).filter((i) => i && i.stock > 0);
    out[shopType] = {
      open: raw.open === true,
      nextRestockAt,
      nextRestockAtIso: nextRestockAt !== null ? raw.nextRestockAt : null,
      secondsUntilRestock: nextRestockAt !== null ? Math.max(0, Math.round((nextRestockAt - nowMs) / 1000)) : 0,
      items,
      catalog,
    };
  }
  return out;
}

/**
 * True when any OPEN shop reports nextRestockAt <= now, i.e. the server has
 * not yet rolled the restock we are standing on. Callers should wait ~2s and refetch.
 */
export function isPreRestockStale(normalizedShops, nowMs = Date.now()) {
  for (const shop of Object.values(normalizedShops ?? {})) {
    if (!shop?.open) continue;
    if (shop.nextRestockAt !== null && shop.nextRestockAt <= nowMs) return true;
  }
  return false;
}

/**
 * Restock detection between two observations of the same shop.
 * A restock happened iff nextRestockAt moved. Returns null when either side lacks
 * nextRestockAt (closed shop, or a snapshot written by the legacy mg-api poller)
 * so callers can fall back to their own heuristics.
 */
export function didRestock(prevNextRestockAt, nextNextRestockAt) {
  if (prevNextRestockAt === null || prevNextRestockAt === undefined) return null;
  if (nextNextRestockAt === null || nextNextRestockAt === undefined) return null;
  return nextNextRestockAt !== prevNextRestockAt;
}

// ---------------------------------------------------------------------------
// I/O helpers
// ---------------------------------------------------------------------------

export async function fetchPlatformJson(url, { fetchImpl = globalThis.fetch, timeoutMs = 15000, userAgent = "Gemini-Server" } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, {
      headers: { "User-Agent": userAgent, Accept: "application/json" },
      signal: controller.signal,
    });
    if (!res.ok) throw new Error(`Platform API ${url} failed: ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Fetch + normalise /shops, refetching (bounded) while the snapshot is pre-restock stale.
 * Returns { shops, raw, staleRetries }.
 */
export async function fetchPlatformShops(base = DEFAULT_PLATFORM_API_BASE, opts = {}) {
  const { staleRetries = 3, staleDelayMs = 2000, sleep = (ms) => new Promise((r) => setTimeout(r, ms)), now = () => Date.now() } = opts;
  const url = `${base}/shops`;
  let raw = await fetchPlatformJson(url, opts);
  let shops = normalizePlatformShops(raw, now());
  let retries = 0;
  while (retries < staleRetries && isPreRestockStale(shops, now())) {
    retries += 1;
    await sleep(staleDelayMs);
    raw = await fetchPlatformJson(url, opts);
    shops = normalizePlatformShops(raw, now());
  }
  return { shops, raw, staleRetries: retries };
}

/** Fetch /weather. Returns { raw, weatherId } where weatherId is canonical or null (unrecognised). */
export async function fetchPlatformWeather(base = DEFAULT_PLATFORM_API_BASE, opts = {}) {
  const raw = await fetchPlatformJson(`${base}/weather`, opts);
  return { raw, weatherId: extractWeatherId(raw) };
}
