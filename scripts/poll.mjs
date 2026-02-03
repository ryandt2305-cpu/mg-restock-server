import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import fetch from "node-fetch";

const API_URL = "https://mg-api.ariedam.fr/live/shops";

const ROOT = process.cwd();
const DATA_DIR = path.join(ROOT, "data");
const MGDATA_PATH = path.join(ROOT, "data", "mgdata.json");
const SNAPSHOT_FILE = path.join(DATA_DIR, "snapshot.json");
const HISTORY_FILE = path.join(DATA_DIR, "history.json");
const EVENTS_FILE = path.join(DATA_DIR, "events.json");
const META_FILE = path.join(DATA_DIR, "meta.json");

const SHOP_TYPES = ["seed", "egg", "decor"];
const SHOP_INTERVALS_SEC = {
  seed: 300,
  egg: 900,
  decor: 3600,
};
const MAX_RECENT_TIMESTAMPS = 50;
const MAX_EVENTS = 100000;
const HISTORY_SEED_FILE = path.join(DATA_DIR, "history-seed.json");
const HISTORY_EGG_FILE = path.join(DATA_DIR, "history-egg.json");
const HISTORY_DECOR_FILE = path.join(DATA_DIR, "history-decor.json");


function toNameSet(value) {
  if (!value || typeof value !== "object") return null;
  if (Array.isArray(value)) return new Set(value.map((v) => String(v)));
  return new Set(Object.keys(value));
}

function loadMgData() {
  const mg = readJson(MGDATA_PATH, null);
  if (!mg || typeof mg !== "object") return null;
  const seed = mg.seed && typeof mg.seed === "object" ? mg.seed : {};
  const egg = mg.egg && typeof mg.egg === "object" ? mg.egg : {};
  const decor = mg.decor && typeof mg.decor === "object" ? mg.decor : {};
  return {
    seed: toNameSet(seed),
    egg: toNameSet(egg),
    decor: toNameSet(decor),
  };
}

function validateItems(shopType, items, mgSets) {
  if (!mgSets) return items;
  const set = shopType === "seed" ? mgSets.seed : shopType === "egg" ? mgSets.egg : mgSets.decor;
  if (!set || set.size === 0) return items;
  return items.filter((item) => set.has(item.name));
}
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

function nowMs() {
  return Date.now();
}

function keyOf(shopType, itemId) {
  return `${shopType}:${itemId}`;
}

function normalizeSnapshot(snapshot) {
  const out = {};
  for (const shopType of SHOP_TYPES) {
    const shop = snapshot?.[shopType] ?? null;
    const items = Array.isArray(shop?.items) ? shop.items : [];
    out[shopType] = {
      secondsUntilRestock: typeof shop?.secondsUntilRestock === "number" ? shop.secondsUntilRestock : 0,
      lastRestockAt: typeof shop?.lastRestockAt === "number" ? shop.lastRestockAt : null,
      items: items.map((item) => ({
        name: String(item?.name ?? ""),
        stock: typeof item?.stock === "number" ? item.stock : 0,
      })),
    };
  }
  return out;
}

function indexItems(items) {
  const map = new Map();
  for (const item of items) {
    if (!item?.name) continue;
    map.set(item.name, item);
  }
  return map;
}

function detectRestock(prev, next, shopType) {
  if (!prev) return true;
  const prevSec = typeof prev.secondsUntilRestock === "number" ? prev.secondsUntilRestock : 0;
  const nextSec = typeof next.secondsUntilRestock === "number" ? next.secondsUntilRestock : 0;
  if (prevSec > 0 && nextSec > prevSec + 30) return true;
  if (prevSec > 0 && nextSec === 0) return true;
  if (prevSec <= 5 && nextSec > prevSec) return true;

  const intervalSec = SHOP_INTERVALS_SEC[shopType] ?? null;
  if (intervalSec && prev.lastRestockAt && typeof prev.lastRestockAt === "number") {
    const since = Date.now() - prev.lastRestockAt;
    if (since >= intervalSec * 1000 && nextSec > prevSec) return true;
  }
  return false;
}

function itemsChanged(prevItems, nextItems) {
  const prevMap = indexItems(prevItems);
  const nextMap = indexItems(nextItems);
  if (prevMap.size !== nextMap.size) return true;
  for (const [name, nextItem] of nextMap.entries()) {
    const prevItem = prevMap.get(name);
    if (!prevItem) return true;
    if ((prevItem.stock ?? 0) !== (nextItem.stock ?? 0)) return true;
  }
  return false;
}

function pushEvent(events, event) {
  events.unshift(event);
  if (events.length > MAX_EVENTS) events.length = MAX_EVENTS;
}

function updateHistory(history, event) {
  for (const item of event.items) {
    const k = keyOf(event.shopType, item.itemId);
    const existing = history[k];
    if (!existing) {
      history[k] = {
        itemId: item.itemId,
        shopType: event.shopType,
        totalOccurrences: 1,
        firstSeen: event.timestamp,
        lastSeen: event.timestamp,
        recentTimestamps: [event.timestamp],
      };
      continue;
    }
    existing.totalOccurrences += 1;
    existing.lastSeen = event.timestamp;
    if (!existing.firstSeen || event.timestamp < existing.firstSeen) {
      existing.firstSeen = event.timestamp;
    }
    existing.recentTimestamps.push(event.timestamp);
    if (existing.recentTimestamps.length > MAX_RECENT_TIMESTAMPS) {
      existing.recentTimestamps = existing.recentTimestamps.slice(-MAX_RECENT_TIMESTAMPS);
    }
  }
}

function splitHistoryByShop(history) {
  const seed = {};
  const egg = {};
  const decor = {};
  for (const [key, value] of Object.entries(history)) {
    if (value.shopType === "seed") seed[key] = value;
    else if (value.shopType === "egg") egg[key] = value;
    else if (value.shopType === "decor") decor[key] = value;
  }
  return { seed, egg, decor };
}

async function main() {
  if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

  const prevSnapshot = readJson(SNAPSHOT_FILE, null);
  const history = readJson(HISTORY_FILE, {});
  const events = readJson(EVENTS_FILE, []);
  const meta = readJson(META_FILE, {});

  const res = await fetch(API_URL, { headers: { "User-Agent": "Gemini-Server" } });
  if (!res.ok) {
    throw new Error(`Failed to fetch live shops: ${res.status}`);
  }
  const live = await res.json();
  const mgSets = loadMgData();
  const nextSnapshot = normalizeSnapshot(live);
  if (!mgSets || (!mgSets.seed && !mgSets.egg && !mgSets.decor)) {
    console.warn("MGDATA validation disabled or empty; skipping item validation.");
  }

  const timestamp = nowMs();

  for (const shopType of SHOP_TYPES) {
    const prevShop = prevSnapshot?.[shopType] ?? null;
    const nextShop = nextSnapshot[shopType];
    const restockByTimer = detectRestock(prevShop, nextShop, shopType);
    const restockByItems = itemsChanged(prevShop?.items ?? [], nextShop.items);

    if (restockByTimer || restockByItems) {
      const validatedItems = validateItems(shopType, nextShop.items, mgSets);
      if (mgSets && validatedItems.length === 0 && nextShop.items.length > 0) {
        continue;
      }
      const event = {
        shopType,
        timestamp,
        items: validatedItems.map((item) => ({
          itemId: item.name,
          stock: item.stock,
        })),
        reason: restockByTimer ? "timer" : "items",
      };
      pushEvent(events, event);
      updateHistory(history, event);
      nextSnapshot[shopType].lastRestockAt = timestamp;
    } else if (prevShop?.lastRestockAt) {
      nextSnapshot[shopType].lastRestockAt = prevShop.lastRestockAt;
    }
    if (!nextSnapshot[shopType].lastRestockAt) {
      nextSnapshot[shopType].lastRestockAt = timestamp;
    }
  }

  writeJson(SNAPSHOT_FILE, nextSnapshot);
  writeJson(HISTORY_FILE, history);
  const split = splitHistoryByShop(history);
  writeJson(HISTORY_SEED_FILE, split.seed);
  writeJson(HISTORY_EGG_FILE, split.egg);
  writeJson(HISTORY_DECOR_FILE, split.decor);
  writeJson(EVENTS_FILE, events);
  writeJson(META_FILE, {
    lastUpdated: timestamp,
    source: API_URL,
    shopTypes: SHOP_TYPES,
    eventCount: events.length,
    historyCount: Object.keys(history).length,
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
