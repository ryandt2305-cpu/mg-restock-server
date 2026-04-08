// Import Discord chat export data to fill gaps in restock + weather data
// Parses MagicShopkeeper bot messages from DiscordChatExporter JSON

import fs from "node:fs";
import path from "node:path";

const FILE_PATH = String.raw`C:\Users\ryand\Feeder-Extension\Gemini-folder\Gemini-server\restock examples\Garlic Bread's Server - Text Channels - whats-in-stock [1408590909842526229].json`;
const SHOPKEEPER_ID = "1399527461242540102";
const LOOKBACK_DAYS = 7; // Cover the 5.5 day gap + buffer
const BATCH_SIZE = 500;

// Load .env
const envPath = path.join(process.cwd(), ".env");
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
    const eq = line.indexOf("=");
    if (eq > 0 && !line.trim().startsWith("#")) {
      const key = line.slice(0, eq).trim();
      const val = line.slice(eq + 1).trim();
      if (!process.env[key]) process.env[key] = val;
    }
  }
}

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!SUPABASE_URL || !SUPABASE_KEY) { console.error("Missing SUPABASE env vars."); process.exit(1); }

const HEADERS = {
  apikey: SUPABASE_KEY,
  Authorization: `Bearer ${SUPABASE_KEY}`,
  "Content-Type": "application/json",
  Prefer: "resolution=ignore-duplicates",
};

const WEATHER_NAMES = new Set(["rain", "snow", "frost", "thunderstorm", "dawn", "ambermoon", "amber", "sunny"]);
const WEATHER_MAP = {
  rain: "Rain", snow: "Snow", frost: "Snow", thunderstorm: "Thunderstorm",
  dawn: "Dawn", amber: "AmberMoon", ambermoon: "AmberMoon", sunny: "Sunny",
};

// Display name → item ID mapping
const NAME_TO_ID = {
  "carrot": "Carrot", "strawberry": "Strawberry", "blueberry": "Blueberry",
  "tomato": "Tomato", "aloe": "Aloe", "apple": "Apple", "lily": "Lily",
  "echeveria": "Echeveria", "burrostail": "BurrosTail", "orangetulip": "OrangeTulip",
  "tulip": "OrangeTulip", "favabean": "FavaBean", "camellia": "Camellia",
  "banana": "Banana", "corn": "Corn", "daffodil": "Daffodil",
  "watermelon": "Watermelon", "cactus": "Cactus", "grape": "Grape",
  "bamboo": "Bamboo", "lychee": "Lychee", "dragonfruit": "DragonFruit",
  "pumpkin": "Pumpkin", "mushroom": "Mushroom", "starweaver": "Starweaver",
  "dawncelestial": "DawnCelestial", "mooncelestial": "MoonCelestial",
  "commonegg": "CommonEgg", "uncommonegg": "UncommonEgg", "rareegg": "RareEgg",
  "legendaryegg": "LegendaryEgg", "planterpot": "PlanterPot",
  "wateringcans": "WateringCans", "wateringcan": "WateringCans",
  "minifairycottage": "MiniFairyCottage", "marblearch": "MarbleArch",
  "marblebench": "MarbleBench", "stonebridge": "StoneBridge",
  "woodenbench": "WoodenBench", "lamppost": "Lamppost",
  "stonepath": "StonePath", "birdhouse": "Birdhouse",
  "fountain": "Fountain", "gazebo": "Gazebo",
  "picketfence": "PicketFence", "trellis": "Trellis",
};

// Detect shop type from item ID
const EGG_IDS = new Set(["CommonEgg", "UncommonEgg", "RareEgg", "LegendaryEgg"]);
const DECOR_IDS = new Set([
  "PlanterPot", "WateringCans", "MiniFairyCottage", "MarbleArch", "MarbleBench",
  "StoneBridge", "WoodenBench", "Lamppost", "StonePath", "Birdhouse",
  "Fountain", "Gazebo", "PicketFence", "Trellis",
]);

function normalizeKey(s) {
  return s.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function resolveItem(displayName) {
  const key = normalizeKey(displayName);
  return NAME_TO_ID[key] || null;
}

function shopTypeOf(itemId) {
  if (EGG_IDS.has(itemId)) return "egg";
  if (DECOR_IDS.has(itemId)) return "decor";
  return "seed";
}

function parseMessage(content) {
  const parts = content.split("|").map(p => p.trim());
  let weatherId = "Sunny";
  const itemsByShop = { seed: [], egg: [], decor: [] };
  let startIdx = 0;

  // Check first token for weather
  if (parts.length > 0) {
    const first = parts[0].replace(/^@/, "").trim();
    const firstKey = normalizeKey(first);
    // Check if it's ONLY a weather word (no number after it)
    if (WEATHER_NAMES.has(firstKey) && !/\d/.test(first)) {
      weatherId = WEATHER_MAP[firstKey] || "Sunny";
      startIdx = 1;
    }
  }

  for (let i = startIdx; i < parts.length; i++) {
    const part = parts[i].replace(/^@/, "").trim();
    if (!part) continue;
    // Format: "ItemName Qty" — split on last space(s) before number
    const match = part.match(/^(.+?)\s+(\d+)$/);
    if (!match) continue;
    const displayName = match[1].trim();
    const qty = parseInt(match[2], 10);
    const itemId = resolveItem(displayName);
    if (!itemId) continue;
    const shop = shopTypeOf(itemId);
    itemsByShop[shop].push({ itemId, stock: qty });
  }

  return { weatherId, itemsByShop };
}

async function batchInsert(table, rows) {
  for (let i = 0; i < rows.length; i += BATCH_SIZE) {
    const batch = rows.slice(i, i + BATCH_SIZE);
    const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}`, {
      method: "POST",
      headers: HEADERS,
      body: JSON.stringify(batch),
    });
    if (!res.ok) {
      const body = await res.text();
      console.error(`  Batch ${i}-${i + batch.length} failed:`, body.slice(0, 200));
    }
  }
}

async function main() {
  console.log("Reading Discord export...");
  const data = JSON.parse(fs.readFileSync(FILE_PATH, "utf8"));
  console.log(`Total messages: ${data.messages.length}`);

  const cutoff = Date.now() - LOOKBACK_DAYS * 86400000;
  const restockEvents = [];
  const weatherEvents = [];
  let skipped = 0;

  for (const msg of data.messages) {
    if (msg.author.id !== SHOPKEEPER_ID) continue;
    const ts = new Date(msg.timestamp).getTime();
    if (ts < cutoff) continue;

    const { weatherId, itemsByShop } = parseMessage(msg.content);

    // Weather event
    weatherEvents.push({
      timestamp: ts,
      weather_id: weatherId,
      previous_weather_id: null,
      source: "discord-json",
      fingerprint: `weather:discord-json:${ts}:${weatherId}`,
    });

    // Restock events (one per shop type that has items)
    for (const [shopType, items] of Object.entries(itemsByShop)) {
      if (items.length === 0) continue;
      restockEvents.push({
        shop_type: shopType,
        timestamp: ts,
        weather_id: weatherId,
        items,
        source_ip: "discord-import",
        fingerprint: `discord:${shopType}:${ts}`,
      });
    }
  }

  console.log(`Parsed: ${restockEvents.length} restock events, ${weatherEvents.length} weather events`);
  console.log(`Date range: ${new Date(cutoff).toISOString().slice(0, 10)} to now`);

  // Show celestial check
  const celCount = restockEvents.filter(e => {
    const items = e.items;
    return items.some(i => ["Starweaver", "DawnCelestial", "MoonCelestial"].includes(i.itemId));
  }).length;
  console.log(`Celestial events found: ${celCount}`);

  // Insert weather
  console.log("\nInserting weather events...");
  await batchInsert("weather_events", weatherEvents);
  console.log(`  Done (${weatherEvents.length} events)`);

  // Insert restock
  console.log("Inserting restock events...");
  await batchInsert("restock_events", restockEvents);
  console.log(`  Done (${restockEvents.length} events)`);

  // Rebuild both
  console.log("\nRebuilding restock history...");
  let res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/rebuild_restock_history`, {
    method: "POST", headers: HEADERS,
  });
  console.log("  Restock rebuild:", res.ok ? "OK" : await res.text());

  console.log("Rebuilding weather history...");
  res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/rebuild_weather_history`, {
    method: "POST", headers: HEADERS,
  });
  console.log("  Weather rebuild:", res.ok ? "OK" : await res.text());

  console.log("\nDone! Data gap filled.");
}

main().catch(e => { console.error(e); process.exit(1); });
