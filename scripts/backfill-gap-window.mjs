import fs from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
const DATA_DIR = path.join(ROOT, "data");
const DEFAULT_EVENTS_FILE = path.join(DATA_DIR, "events.json");
const PREVIEW_FILE = path.join(DATA_DIR, "backfill-gap-window.preview.json");
const INSERT_BATCH_SIZE = Number(process.env.BACKFILL_BATCH_SIZE || 500);
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS || 15000);
const SHOP_TYPES = new Set(["seed", "egg", "decor", "tool"]);

function loadEnvFile() {
  const envPath = path.join(ROOT, ".env");
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
    if (process.env[key] === undefined) process.env[key] = value;
  }
}

function parseArgs(argv) {
  const args = {
    eventsFile: DEFAULT_EVENTS_FILE,
    source: "backfill-local-events",
    apply: false,
    fullRebuild: false,
    startMs: null,
    endMs: null,
    shops: null,
  };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--apply") {
      args.apply = true;
      continue;
    }
    if (a === "--dry-run") {
      args.apply = false;
      continue;
    }
    if (a === "--full-rebuild") {
      args.fullRebuild = true;
      continue;
    }
    if (a === "--events-file") {
      args.eventsFile = argv[++i];
      continue;
    }
    if (a === "--source") {
      args.source = argv[++i];
      continue;
    }
    if (a === "--start-ms") {
      args.startMs = Number(argv[++i]);
      continue;
    }
    if (a === "--end-ms") {
      args.endMs = Number(argv[++i]);
      continue;
    }
    if (a === "--start-iso") {
      args.startMs = Date.parse(argv[++i]);
      continue;
    }
    if (a === "--end-iso") {
      args.endMs = Date.parse(argv[++i]);
      continue;
    }
    if (a === "--shops") {
      const raw = String(argv[++i] || "")
        .split(",")
        .map((s) => s.trim().toLowerCase())
        .filter(Boolean);
      args.shops = new Set(raw.filter((s) => SHOP_TYPES.has(s)));
      continue;
    }
    if (a === "--help" || a === "-h") {
      printHelp();
      process.exit(0);
    }
    throw new Error(`Unknown arg: ${a}`);
  }
  if (!Number.isFinite(args.startMs) || !Number.isFinite(args.endMs)) {
    throw new Error("Missing --start-ms/--end-ms or --start-iso/--end-iso");
  }
  if (args.startMs > args.endMs) {
    throw new Error("Invalid window: start > end");
  }
  return args;
}

function printHelp() {
  console.log(`Backfill exact captured events for a gap window.

Usage:
  npm run backfill:gap-window -- --start-iso 2026-04-08T03:30:00Z --end-iso 2026-04-09T01:45:00Z --shops egg,seed,decor
  npm run backfill:gap-window -- --start-ms 1775619000000 --end-ms 1775699100000 --apply

Flags:
  --start-ms <number>   Window start (unix ms)
  --end-ms <number>     Window end (unix ms)
  --start-iso <string>  Window start ISO
  --end-iso <string>    Window end ISO
  --shops <csv>         seed,egg,decor,tool (optional)
  --events-file <path>  Defaults to data/events.json
  --source <text>       Source label for inserted rows
  --apply               Write to Supabase + incremental history ingest
  --full-rebuild        Also run rebuild_restock_history() after incremental ingest
  --dry-run             Preview only (default)
`);
}

function readJson(file, fallback) {
  try {
    if (!fs.existsSync(file)) return fallback;
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function normalizeShopType(value) {
  const v = String(value || "").toLowerCase().trim();
  return SHOP_TYPES.has(v) ? v : null;
}

function normalizeItem(item) {
  const itemId = String(item?.itemId ?? item?.name ?? "").trim();
  if (!itemId) return null;
  const stockRaw = item?.stock ?? item?.quantity ?? null;
  const stock = Number.isFinite(stockRaw) ? Number(stockRaw) : null;
  return { itemId, stock };
}

function makeFingerprint(ev) {
  const parts = ev.items
    .map((item) => `${item.itemId}:${item.stock ?? ""}`)
    .sort()
    .join("|");
  return `${ev.shopType}:${ev.timestamp}:${parts}`;
}

function normalizeEvent(raw, sourceOverride) {
  const timestamp = Number(raw?.timestamp);
  if (!Number.isFinite(timestamp)) return null;
  const shopType = normalizeShopType(raw?.shopType);
  if (!shopType) return null;
  const itemsRaw = Array.isArray(raw?.items) ? raw.items : [];
  const items = itemsRaw.map(normalizeItem).filter(Boolean);
  if (!items.length) return null;
  const weatherId = raw?.weatherId ?? raw?.weather ?? raw?.weather_id ?? null;
  const normalized = {
    timestamp,
    shopType,
    weatherId: weatherId == null ? null : String(weatherId),
    source: sourceOverride || String(raw?.source || "backfill-local-events"),
    items,
  };
  return { ...normalized, fingerprint: makeFingerprint(normalized) };
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

async function fetchExistingFingerprints({
  supabaseUrl,
  headers,
  startMs,
  endMs,
  shops,
}) {
  const out = new Set();
  let offset = 0;
  const limit = 1000;
  while (true) {
    let url =
      `${supabaseUrl}/rest/v1/restock_events?select=fingerprint,timestamp,shop_type` +
      `&timestamp=gte.${startMs}&timestamp=lte.${endMs}` +
      `&order=timestamp.asc&limit=${limit}&offset=${offset}`;
    if (shops && shops.size > 0) {
      url += `&shop_type=in.(${Array.from(shops).join(",")})`;
    }
    const res = await fetchWithTimeout(url, { headers });
    if (!res.ok) {
      throw new Error(`Supabase read failed: ${res.status} ${await res.text()}`);
    }
    const rows = await res.json();
    if (!Array.isArray(rows) || rows.length === 0) break;
    for (const row of rows) {
      if (row?.fingerprint) out.add(String(row.fingerprint));
    }
    if (rows.length < limit) break;
    offset += rows.length;
  }
  return out;
}

async function insertEvents(supabaseUrl, headers, events) {
  if (!events.length) return;
  for (let i = 0; i < events.length; i += INSERT_BATCH_SIZE) {
    const batch = events.slice(i, i + INSERT_BATCH_SIZE);
    const payload = batch.map((ev) => ({
      timestamp: ev.timestamp,
      shop_type: ev.shopType,
      weather_id: ev.weatherId,
      source: ev.source,
      items: ev.items.map((it) => ({ itemId: it.itemId, stock: it.stock })),
      fingerprint: ev.fingerprint,
    }));
    const res = await fetchWithTimeout(
      `${supabaseUrl}/rest/v1/restock_events?on_conflict=fingerprint`,
      {
        method: "POST",
        headers: {
          ...headers,
          "Content-Type": "application/json",
          Prefer: "resolution=ignore-duplicates,return=minimal",
        },
        body: JSON.stringify(payload),
      }
    );
    if (!res.ok) {
      throw new Error(`Supabase insert failed: ${res.status} ${await res.text()}`);
    }
    console.log(
      `[backfill-gap-window] inserted ${Math.min(i + INSERT_BATCH_SIZE, events.length)}/${events.length}`
    );
  }
}

async function rebuildHistory(supabaseUrl, headers) {
  const res = await fetchWithTimeout(`${supabaseUrl}/rest/v1/rpc/rebuild_restock_history`, {
    method: "POST",
    headers: {
      ...headers,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({}),
  });
  if (!res.ok) {
    throw new Error(`rebuild_restock_history failed: ${res.status} ${await res.text()}`);
  }
}

async function ingestIncrementalEvents(supabaseUrl, headers, events) {
  if (!events.length) return;
  for (let i = 0; i < events.length; i += 1) {
    const ev = events[i];
    const res = await fetchWithTimeout(`${supabaseUrl}/rest/v1/rpc/ingest_restock_history`, {
      method: "POST",
      headers: {
        ...headers,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_shop_type: ev.shopType,
        p_ts: ev.timestamp,
        p_items: ev.items.map((item) => ({ itemId: item.itemId, stock: item.stock })),
      }),
    });
    if (!res.ok) {
      throw new Error(
        `ingest_restock_history failed (${ev.shopType}:${ev.timestamp}): ${res.status} ${await res.text()}`
      );
    }
    if ((i + 1) % 100 === 0 || i + 1 === events.length) {
      console.log(`[backfill-gap-window] ingested ${i + 1}/${events.length}`);
    }
  }
}

function summarize(events) {
  const byShop = {};
  let minTs = Number.POSITIVE_INFINITY;
  let maxTs = Number.NEGATIVE_INFINITY;
  for (const ev of events) {
    byShop[ev.shopType] = (byShop[ev.shopType] || 0) + 1;
    if (ev.timestamp < minTs) minTs = ev.timestamp;
    if (ev.timestamp > maxTs) maxTs = ev.timestamp;
  }
  return {
    count: events.length,
    byShop,
    minTs: Number.isFinite(minTs) ? minTs : null,
    maxTs: Number.isFinite(maxTs) ? maxTs : null,
    minIso: Number.isFinite(minTs) ? new Date(minTs).toISOString() : null,
    maxIso: Number.isFinite(maxTs) ? new Date(maxTs).toISOString() : null,
  };
}

async function main() {
  loadEnvFile();
  const args = parseArgs(process.argv);
  const rawEvents = readJson(args.eventsFile, []);
  if (!Array.isArray(rawEvents)) {
    throw new Error(`Invalid JSON array: ${args.eventsFile}`);
  }
  const normalized = rawEvents
    .map((ev) => normalizeEvent(ev, args.source))
    .filter(Boolean)
    .filter((ev) => ev.timestamp >= args.startMs && ev.timestamp <= args.endMs)
    .filter((ev) => !args.shops || args.shops.has(ev.shopType));

  const byFingerprint = new Map();
  for (const ev of normalized) {
    if (!byFingerprint.has(ev.fingerprint)) byFingerprint.set(ev.fingerprint, ev);
  }
  const candidates = Array.from(byFingerprint.values()).sort((a, b) => a.timestamp - b.timestamp);
  const summaryCandidates = summarize(candidates);

  const supabaseUrl = process.env.SUPABASE_URL || "";
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
  if (!supabaseUrl || !serviceKey) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env");
  }
  const headers = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` };

  const existing = await fetchExistingFingerprints({
    supabaseUrl,
    headers,
    startMs: args.startMs,
    endMs: args.endMs,
    shops: args.shops,
  });
  const missing = candidates.filter((ev) => !existing.has(ev.fingerprint));
  const summaryMissing = summarize(missing);

  const preview = {
    window: {
      startMs: args.startMs,
      endMs: args.endMs,
      startIso: new Date(args.startMs).toISOString(),
      endIso: new Date(args.endMs).toISOString(),
    },
    shops: args.shops ? Array.from(args.shops) : null,
    candidates: summaryCandidates,
    missing: summaryMissing,
    sampleMissing: missing.slice(0, 25).map((ev) => ({
      timestamp: ev.timestamp,
      timestampIso: new Date(ev.timestamp).toISOString(),
      shopType: ev.shopType,
      items: ev.items,
      source: ev.source,
      fingerprint: ev.fingerprint,
    })),
  };
  fs.writeFileSync(PREVIEW_FILE, `${JSON.stringify(preview, null, 2)}\n`, "utf8");

  console.log(`[backfill-gap-window] preview written: ${PREVIEW_FILE}`);
  console.log(
    `[backfill-gap-window] candidates=${summaryCandidates.count}, missing=${summaryMissing.count}, mode=${args.apply ? "apply" : "dry-run"}`
  );

  if (!args.apply) return;
  if (!missing.length) {
    console.log("[backfill-gap-window] nothing to insert");
    return;
  }
  await insertEvents(supabaseUrl, headers, missing);
  await ingestIncrementalEvents(supabaseUrl, headers, missing);
  console.log("[backfill-gap-window] incremental ingest complete");
  if (args.fullRebuild) {
    await rebuildHistory(supabaseUrl, headers);
    console.log("[backfill-gap-window] rebuild_restock_history complete");
  }
}

main().catch((err) => {
  console.error(`[backfill-gap-window] ${err?.message || err}`);
  process.exit(1);
});
