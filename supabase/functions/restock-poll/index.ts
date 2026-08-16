import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, preflight } from "../_shared/cors.ts";

const SUPABASE_URL =
  Deno.env.get("SVC_SUPABASE_URL") ??
  Deno.env.get("SUPABASE_URL") ??
  "";
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get("SVC_SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  "";
const POLL_SECRET = Deno.env.get("POLL_SECRET") ?? "";

const MG_API_BASE = Deno.env.get("MG_API_BASE") ?? "https://mg-api.ariedam.fr";
const FETCH_TIMEOUT_MS = Number(Deno.env.get("FETCH_TIMEOUT_MS") ?? 15000);

type ShopItem = { name: string; stock: number };
type ShopData = { secondsUntilRestock: number; items: ShopItem[] };
type LiveShopsResponse = Record<string, ShopData>;

type RegistryEntry = {
  shop_type: string;
  cycle_interval_ms: number;
  config: Record<string, unknown>;
};

// Maps the live API weather display string to the game enum ID stored in weather_events.
// "Clear Skies" is the API's string for no active special weather.
// "Snow" is the display name for what the game internally calls "Frost".
const LIVE_WEATHER_ID_MAP: Record<string, string> = {
  "Clear Skies": "Sunny",
  "":            "Sunny",
  "Rain":        "Rain",
  "Snow":        "Frost",     // API display name → game enum ID
  "Frost":       "Frost",
  "Dawn":        "Dawn",
  "Amber Moon":  "AmberMoon",
  "AmberMoon":   "AmberMoon",
  "Thunderstorm":"Thunderstorm",
};

const VALID_WEATHER_IDS: ReadonlySet<string> = new Set([
  "Sunny", "Rain", "Dawn", "Frost", "Snow", "AmberMoon", "Thunderstorm",
]);

// Weather events are snapped to 5-minute slots (matching Rain's event duration).
const WEATHER_SNAP_INTERVAL = 300_000;

function snapTimestamp(intervalMs: number, ts: number): number {
  return Math.floor(ts / intervalMs) * intervalMs;
}

/** Round cycle estimate up to nearest minute boundary (min 60s). */
function roundToMinuteBoundary(ms: number): number {
  const minute = 60_000;
  return Math.max(minute, Math.ceil(ms / minute) * minute);
}

async function fetchRegistry(client: ReturnType<typeof getClient>): Promise<Map<string, RegistryEntry>> {
  const { data, error } = await client
    .from("shop_type_registry")
    .select("shop_type, cycle_interval_ms, config")
    .eq("is_active", true);

  if (error) {
    console.error("Failed to fetch shop_type_registry:", error.message);
    return new Map();
  }

  const map = new Map<string, RegistryEntry>();
  for (const row of data ?? []) {
    map.set(row.shop_type, row as RegistryEntry);
  }
  return map;
}

function makeFingerprint(shopType: string, snappedTs: number, items: { itemId: string; stock: number }[]): string {
  const parts = items
    .map((item) => `${item.itemId}:${item.stock}`)
    .sort()
    .join("|");
  return `${shopType}:${snappedTs}:${parts}`;
}

function makeWeatherFingerprint(snappedTs: number, weatherId: string): string {
  return `weather:restock:${snappedTs}:${weatherId}`;
}

function getClient() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  }
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
}

async function fetchWithTimeout(url: string): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    return await fetch(url, { signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

function json(data: unknown, status: number, req: Request): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders(req, "POST, OPTIONS") },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return preflight(req, "POST, OPTIONS");
  }

  // Authenticate: require x-poll-secret header (or Authorization Bearer matching POLL_SECRET)
  if (POLL_SECRET) {
    const secret = req.headers.get("x-poll-secret") ?? "";
    const authHeader = req.headers.get("authorization") ?? "";
    const bearerToken = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
    if (secret !== POLL_SECRET && bearerToken !== POLL_SECRET) {
      return json({ ok: false, error: "Unauthorized" }, 403, req);
    }
  }

  try {
    // Fetch the full /live endpoint — includes both current weather and shop inventory.
    // Previously fetched /live/shops which omits the weather field.
    const liveRes = await fetchWithTimeout(`${MG_API_BASE}/live`);
    if (!liveRes.ok) {
      return json({ ok: false, error: `MG API returned ${liveRes.status}` }, 502, req);
    }
    const liveData = await liveRes.json();

    // shops is nested under liveData.shops (vs the old /live/shops which returned the object directly)
    const shops: LiveShopsResponse = liveData.shops ?? {};
    const rawWeatherString: string = typeof liveData.weather === "string" ? liveData.weather : "";

    const client = getClient();
    const now = Date.now();
    const inserted: string[] = [];
    const skipped: string[] = [];
    const registered: string[] = [];

    // Resolve weather ID before the shop loop so it's available for both
    // restock_events inserts and ingest_restock_history RPC calls.
    const weatherId = LIVE_WEATHER_ID_MAP[rawWeatherString] ?? null;

    // ── Registry lookup ─────────────────────────────────────────────────
    const registry = await fetchRegistry(client);

    // ── Shop inventory ────────────────────────────────────────────────────
    // Iterate ALL shop keys from the API, not a hardcoded list.
    for (const shopType of Object.keys(shops)) {
      const shopData = shops[shopType];
      if (!shopData || !Array.isArray(shopData.items) || shopData.items.length === 0) {
        skipped.push(shopType);
        continue;
      }

      // Auto-register unknown shop types using secondsUntilRestock as cycle estimate
      let entry = registry.get(shopType);
      if (!entry) {
        const estimatedMs = shopData.secondsUntilRestock
          ? roundToMinuteBoundary(shopData.secondsUntilRestock * 1000)
          : 300_000;
        const { error: regErr } = await client.rpc("register_shop_type", {
          p_shop_type: shopType,
          p_cycle_interval_ms: estimatedMs,
          p_discovered_from: "restock-poll-auto",
        });
        if (regErr) {
          console.error(`Failed to register shop type "${shopType}":`, regErr.message);
          skipped.push(shopType);
          continue;
        }
        entry = { shop_type: shopType, cycle_interval_ms: estimatedMs, config: {} };
        registry.set(shopType, entry);
        registered.push(shopType);
      }

      const intervalMs = entry.cycle_interval_ms;
      const snappedTs = snapTimestamp(intervalMs, now);

      const items = shopData.items
        .filter((item) => item.name && item.stock > 0)
        .map((item) => ({ itemId: item.name, stock: item.stock }));

      if (items.length === 0) {
        skipped.push(shopType);
        continue;
      }

      const fingerprint = makeFingerprint(shopType, snappedTs, items);

      const { data: insertData, error: insertErr } = await client
        .from("restock_events")
        .insert({
          timestamp: snappedTs,
          shop_type: shopType,
          items: items,
          source: "mg-api",
          fingerprint,
          weather_id: weatherId ?? null,
        })
        .select("id")
        .maybeSingle();

      if (insertErr) {
        if (insertErr.code === "23505") {
          skipped.push(shopType);
          continue;
        }
        console.error(`Insert error for ${shopType}:`, insertErr.message);
        skipped.push(shopType);
        continue;
      }

      if (!insertData) {
        skipped.push(shopType);
        continue;
      }

      // For egg shops, pass 5-minute resolution so ingest_restock_history
      // can distinguish weather-locked egg restocks (SnowEgg, DawnEgg)
      // that happen every 5 min. Non-weather-locked eggs are re-snapped
      // to 15 min inside the function via restock_item_snap_timestamp.
      const ingestTs = shopType === "egg"
        ? Math.floor(now / 300_000) * 300_000
        : snappedTs;

      const { error: historyErr } = await client.rpc("ingest_restock_history", {
        p_shop_type: shopType,
        p_ts: ingestTs,
        p_items: items,
        p_weather_id: weatherId ?? null,
      });

      if (historyErr) {
        console.error(`History ingest error for ${shopType}:`, historyErr.message);
      }

      inserted.push(shopType);
    }

    // ── Weather recording ─────────────────────────────────────────────────
    // Insert one weather event per 5-minute slot. Fingerprint deduplication
    // prevents duplicates if the same weather is polled multiple times in a slot.
    // After any new insert, rebuild weather_history so weather_predictions stays fresh.
    let weatherInserted = false;

    if (weatherId && VALID_WEATHER_IDS.has(weatherId)) {
      const weatherSnappedTs = Math.floor(now / WEATHER_SNAP_INTERVAL) * WEATHER_SNAP_INTERVAL;
      const weatherFingerprint = makeWeatherFingerprint(weatherSnappedTs, weatherId);

      const { error: weatherErr } = await client.from("weather_events").insert({
        timestamp: weatherSnappedTs,
        weather_id: weatherId,
        previous_weather_id: null,
        source: "restock",
        fingerprint: weatherFingerprint,
      });

      if (weatherErr && weatherErr.code !== "23505") {
        console.error("Weather insert error:", weatherErr.message);
      } else if (!weatherErr) {
        // New event inserted — rebuild weather_history to keep predictions fresh.
        weatherInserted = true;
        const { error: rebuildErr } = await client.rpc("rebuild_weather_history");
        if (rebuildErr) {
          console.error("Weather history rebuild error:", rebuildErr.message);
        }
      }
    }

    return json({
      ok: true,
      inserted,
      skipped,
      registered,
      timestamp: now,
      weather: { id: weatherId, raw: rawWeatherString, inserted: weatherInserted },
    }, 200, req);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return json({ ok: false, error: message }, 500, req);
  }
});
