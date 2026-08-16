// Shared helpers for the official Magic Garden platform API (Deno / edge functions).
// Mirror of scripts/lib/platformApi.mjs — keep the two in sync.
// Reference: Feeder-Extension/docs/superpowers/specs/2026-08-16-mg-platform-api-reference.md

export const DEFAULT_PLATFORM_API_BASE = "https://magicgarden.gg/platform/v1";

export type PlatformShopItem = {
  itemId: string;
  name: string;
  itemType: string | null;
  coinPrice: number | null;
  stock: number;
};

export type PlatformShop = {
  open: boolean;
  nextRestockAt: number | null; // epoch ms
  nextRestockAtIso: string | null;
  secondsUntilRestock: number;
  items: PlatformShopItem[]; // stock > 0 only
  catalog: PlatformShopItem[]; // everything incl. stock 0
};

export type PlatformShops = Record<string, PlatformShop>;

/** Canonical weather ids used in weather_events / restock_events.weather_id. */
export const WEATHER_ALIASES: ReadonlyMap<string, string> = new Map([
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

export function normalizeKey(value: unknown): string {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[’']/g, "")
    .replace(/[^a-z0-9]/g, "");
}

/** Canonical id for a weather string, or null when unrecognised. */
export function normalizeWeather(value: unknown): string | null {
  const key = normalizeKey(value);
  if (!key) return null;
  return WEATHER_ALIASES.get(key) ?? null;
}

const WEATHER_FIELD_CANDIDATES = ["weather", "weatherId", "weather_id", "id", "type", "name", "kind", "event"];
const WEATHER_NESTED_CANDIDATES = ["current", "data", "state", "event", "weather"];

function pickWeatherField(obj: Record<string, unknown>): string | null {
  for (const field of WEATHER_FIELD_CANDIDATES) {
    const v = obj[field];
    if (typeof v === "string") {
      const id = normalizeWeather(v);
      if (id) return id;
    }
  }
  return null;
}

/**
 * Extract a canonical weather id from the /weather payload.
 *   null / undefined -> "Sunny" (documented: no active event)
 *   string           -> canonical id or null
 *   object           -> first recognised field (top-level, then one level nested) or null
 */
export function extractWeatherId(payload: unknown): string | null {
  if (payload === null || payload === undefined) return "Sunny";
  if (typeof payload === "string") return normalizeWeather(payload);
  if (typeof payload !== "object") return null;
  const obj = payload as Record<string, unknown>;
  const direct = pickWeatherField(obj);
  if (direct) return direct;
  for (const field of WEATHER_NESTED_CANDIDATES) {
    const nested = obj[field];
    if (nested && typeof nested === "object") {
      const id = pickWeatherField(nested as Record<string, unknown>);
      if (id) return id;
    }
  }
  return null;
}

function toMs(iso: unknown): number | null {
  if (typeof iso !== "string" || !iso) return null;
  const ms = Date.parse(iso);
  return Number.isFinite(ms) ? ms : null;
}

function normalizeItem(raw: unknown): PlatformShopItem | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const itemId = typeof r.itemId === "string" ? r.itemId.trim() : "";
  if (!itemId) return null;
  const stock = typeof r.stock === "number" && Number.isFinite(r.stock) ? r.stock : 0;
  return {
    itemId,
    name: typeof r.name === "string" ? r.name : itemId,
    itemType: typeof r.itemType === "string" ? r.itemType : null,
    coinPrice: typeof r.coinPrice === "number" ? r.coinPrice : null,
    stock,
  };
}

/** Normalise the /shops payload (raw `{shops:{...}}` or inner object) into PlatformShops. */
export function normalizePlatformShops(payload: unknown, nowMs: number = Date.now()): PlatformShops {
  const maybe = payload as Record<string, unknown> | null;
  const shops =
    maybe && typeof maybe === "object" && maybe.shops && typeof maybe.shops === "object"
      ? (maybe.shops as Record<string, unknown>)
      : (payload as Record<string, unknown> | null);
  const out: PlatformShops = {};
  if (!shops || typeof shops !== "object") return out;
  for (const [shopType, raw] of Object.entries(shops)) {
    if (!raw || typeof raw !== "object") continue;
    const r = raw as Record<string, unknown>;
    const nextRestockAt = toMs(r.nextRestockAt);
    const rawItems = Array.isArray(r.items) ? r.items : [];
    const rawCatalog = Array.isArray(r.catalog) ? r.catalog : [];
    const catalog = rawCatalog.map(normalizeItem).filter((i): i is PlatformShopItem => i !== null);
    const items = rawItems
      .map(normalizeItem)
      .filter((i): i is PlatformShopItem => i !== null && i.stock > 0);
    out[shopType] = {
      open: r.open === true,
      nextRestockAt,
      nextRestockAtIso: nextRestockAt !== null ? (r.nextRestockAt as string) : null,
      secondsUntilRestock: nextRestockAt !== null ? Math.max(0, Math.round((nextRestockAt - nowMs) / 1000)) : 0,
      items,
      catalog,
    };
  }
  return out;
}

/** True when any OPEN shop reports nextRestockAt <= now (server hasn't rolled the restock yet). */
export function isPreRestockStale(shops: PlatformShops, nowMs: number = Date.now()): boolean {
  for (const shop of Object.values(shops ?? {})) {
    if (!shop?.open) continue;
    if (shop.nextRestockAt !== null && shop.nextRestockAt <= nowMs) return true;
  }
  return false;
}

export async function fetchPlatformJson(
  url: string,
  { fetchImpl = fetch, timeoutMs = 15000, userAgent = "Gemini-Server" }: {
    fetchImpl?: typeof fetch;
    timeoutMs?: number;
    userAgent?: string;
  } = {},
): Promise<unknown> {
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

export type FetchShopsOptions = {
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  userAgent?: string;
  staleRetries?: number;
  staleDelayMs?: number;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
};

/** Fetch + normalise /shops, refetching (bounded) while pre-restock stale. */
export async function fetchPlatformShops(
  base: string = DEFAULT_PLATFORM_API_BASE,
  opts: FetchShopsOptions = {},
): Promise<{ shops: PlatformShops; raw: unknown; staleRetries: number }> {
  const {
    staleRetries = 3,
    staleDelayMs = 2000,
    sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms)),
    now = () => Date.now(),
  } = opts;
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

/** Fetch /weather. weatherId is canonical, or null when the payload is unrecognised. */
export async function fetchPlatformWeather(
  base: string = DEFAULT_PLATFORM_API_BASE,
  opts: { fetchImpl?: typeof fetch; timeoutMs?: number; userAgent?: string } = {},
): Promise<{ raw: unknown; weatherId: string | null }> {
  const raw = await fetchPlatformJson(`${base}/weather`, opts);
  return { raw, weatherId: extractWeatherId(raw) };
}
