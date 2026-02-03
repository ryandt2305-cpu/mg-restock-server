import fs from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
const DATA_DIR = path.join(ROOT, "data");
const HISTORY_FILE = path.join(DATA_DIR, "history.json");
const EVENTS_FILE = path.join(DATA_DIR, "events.json");
const META_FILE = path.join(DATA_DIR, "meta.json");

const MAX_RECENT_TIMESTAMPS = 50;
const MAX_EVENTS = 100000;
const HISTORY_SEED_FILE = path.join(DATA_DIR, "history-seed.json");
const HISTORY_EGG_FILE = path.join(DATA_DIR, "history-egg.json");
const HISTORY_DECOR_FILE = path.join(DATA_DIR, "history-decor.json");

const IGNORE_MENTIONS = new Set([
  "ping for weather & rare plants",
  "ping for weather",
  "ping for plants",
  "ping/DM",
  "weather",
  "rain",
  "snow",
  "storm",
  "wind",
  "fog",
  "frost",
  "sun",
]);

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

function decodeHtml(text) {
  return text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ");
}

function keyOf(shopType, itemId) {
  return `${shopType}:${itemId}`;
}

function normalizeMention(raw) {
  const text = decodeHtml(raw).trim();
  if (!text.startsWith("@")) return null;
  const name = text.slice(1).trim();
  if (!name) return null;
  return name;
}

function isIgnored(name) {
  const lc = name.toLowerCase();
  for (const ignore of IGNORE_MENTIONS) {
    if (lc.includes(ignore)) return true;
  }
  return false;
}

function shopTypeForName(name) {
  if (/egg/i.test(name)) return "egg";
  return "seed";
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

function parseMessages(html) {
  const segments = html.split("class=chatlog__message-container ");
  const events = [];

  for (let i = 1; i < segments.length; i++) {
    const segment = segments[i];

    const idMatch = segment.match(/data-message-id=(\d+)/) || segment.match(/data-message-id="(\d+)"/);
    const messageId = idMatch ? idMatch[1] : null;

    const tsMatch = segment.match(/chatlog__timestamp title=\"([^\"]+)\"/) || segment.match(/chatlog__timestamp title=([^>]+)>/);
    const timestampStr = tsMatch ? decodeHtml(tsMatch[1]) : null;
    const timestamp = timestampStr ? Date.parse(timestampStr) : NaN;

    if (!messageId || Number.isNaN(timestamp)) continue;

    const mentions = [];
    const mentionRegex = /chatlog__markdown-mention[^>]*>([^<]+)</g;
    let m;
    while ((m = mentionRegex.exec(segment)) !== null) {
      const name = normalizeMention(m[1]);
      if (!name) continue;
      if (isIgnored(name)) continue;
      mentions.push(name);
    }

    if (!mentions.length) continue;

    const items = mentions.map((name) => ({
      itemId: name,
      shopType: shopTypeForName(name),
      quantity: 1,
    }));

    const byShop = new Map();
    for (const item of items) {
      const list = byShop.get(item.shopType) ?? [];
      list.push(item);
      byShop.set(item.shopType, list);
    }

    for (const [shopType, list] of byShop.entries()) {
      events.push({
        id: messageId,
        source: "discord-html",
        timestamp,
        shopType,
        items: list,
      });
    }
  }

  return events;
}

function main() {
  const inputPath = process.argv[2];
  if (!inputPath) {
    console.error("Usage: node scripts/import-html.mjs <path-to-discord-export.html>");
    process.exit(1);
  }

  if (!fs.existsSync(inputPath)) {
    console.error(`File not found: ${inputPath}`);
    process.exit(1);
  }

  const html = fs.readFileSync(inputPath, "utf8");
  const parsedEvents = parseMessages(html);

  const history = readJson(HISTORY_FILE, {});
  const events = readJson(EVENTS_FILE, []);
  const meta = readJson(META_FILE, {});
  const existingIds = new Set(events.map((e) => `${e.id}:${e.shopType}`));

  for (const ev of parsedEvents) {
    const dedupeKey = `${ev.id}:${ev.shopType}`;
    if (existingIds.has(dedupeKey)) continue;
    events.push(ev);
    existingIds.add(dedupeKey);
    updateHistory(history, ev);
  }

  events.sort((a, b) => b.timestamp - a.timestamp);
  if (events.length > MAX_EVENTS) events.length = MAX_EVENTS;

  writeJson(EVENTS_FILE, events);
  writeJson(HISTORY_FILE, history);
  writeJson(META_FILE, {
    ...meta,
    importedAt: meta.importedAt ?? Date.now(),
    importSource: meta.importSource ?? "discord-html",
    importFile: meta.importFile ?? path.basename(inputPath),
  });
  const split = splitHistoryByShop(history);
  writeJson(HISTORY_SEED_FILE, split.seed);
  writeJson(HISTORY_EGG_FILE, split.egg);
  writeJson(HISTORY_DECOR_FILE, split.decor);

  console.log(`Imported ${parsedEvents.length} events from HTML. Total events: ${events.length}`);
}

main();
