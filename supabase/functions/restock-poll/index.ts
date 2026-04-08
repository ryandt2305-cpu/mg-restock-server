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

type ShopType = "seed" | "egg" | "decor";
type ShopItem = { name: string; stock: number };
type ShopData = { secondsUntilRestock: number; items: ShopItem[] };
type LiveShopsResponse = Record<string, ShopData>;

const SHOP_INTERVALS: Record<ShopType, number> = {
  seed: 300000,   // 5 minutes
  egg: 900000,    // 15 minutes
  decor: 3600000, // 60 minutes
};

const TRACKED_SHOPS: ShopType[] = ["seed", "egg", "decor"];

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

    // ── Shop inventory ────────────────────────────────────────────────────
    for (const shopType of TRACKED_SHOPS) {
      const shopData = shops[shopType];
      if (!shopData || !Array.isArray(shopData.items) || shopData.items.length === 0) {
        skipped.push(shopType);
        continue;
      }

      const snappedTs = snapTimestamp(shopType, now);

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

      const { error: historyErr } = await client.rpc("ingest_restock_history", {
        p_shop_type: shopType,
        p_ts: snappedTs,
        p_items: items,
      });

      if (historyErr) {
        console.error(`History ingest error for ${shopType}:`, historyErr.message);
      }

      inserted.push(shopType);
    }

    // ── Weather recording ─────────────────────────────────────────────────
    // Map the live API weather string to the game enum ID.
    // Insert one weather event per 5-minute slot. Fingerprint deduplication
    // prevents duplicates if the same weather is polled multiple times in a slot.
    // After any new insert, rebuild weather_history so weather_predictions stays fresh.
    const weatherId = LIVE_WEATHER_ID_MAP[rawWeatherString] ?? null;
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
      timestamp: now,
      weather: { id: weatherId, raw: rawWeatherString, inserted: weatherInserted },
    }, 200, req);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return json({ ok: false, error: message }, 500, req);
  }
});
