import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import fetch from "node-fetch";

const ROOT = process.cwd();
const DATA_DIR = path.join(ROOT, "data");
const EVENTS_FILE = path.join(DATA_DIR, "events.json");

function loadEnvFile() {
  const envPath = path.join(process.cwd(), ".env");
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
    if (process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}

loadEnvFile();

const SUPABASE_URL = process.env.SUPABASE_URL || "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
const SUPABASE_REST_ENDPOINT = SUPABASE_URL ? `${SUPABASE_URL}/rest/v1` : "";
const SUPABASE_HEADERS = SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
  ? {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
    }
  : null;

const CHUNK_MS = Number(process.env.REBUILD_CHUNK_MS || 86400000); // 1 day
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS || 15000);
const RETRY_ATTEMPTS = Number(process.env.REST_RETRY_ATTEMPTS || 8);
const RETRY_BASE_MS = Number(process.env.REST_RETRY_BASE_MS || 750);
const SKIP_TRUNCATE = process.env.SKIP_TRUNCATE === "1";
const FORCE_DB_MINMAX = process.env.FORCE_DB_MINMAX === "1";

async function fetchWithTimeout(url, options = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchWithRetry(url, options = {}, attempts = RETRY_ATTEMPTS) {
  let lastErr = null;
  for (let i = 0; i < attempts; i += 1) {
    try {
      const res = await fetchWithTimeout(url, options);
      if (res.status === 503 || res.status === 502 || res.status === 504) {
        lastErr = new Error(`Upstream unavailable: ${res.status}`);
      } else {
        return res;
      }
    } catch (err) {
      lastErr = err;
    }
    const delay = RETRY_BASE_MS * Math.pow(2, i);
    await new Promise((r) => setTimeout(r, delay));
  }
  throw lastErr ?? new Error("Request failed after retries");
}

async function getMinMaxTimestamp() {
  const minRes = await fetchWithRetry(
    `${SUPABASE_REST_ENDPOINT}/restock_events?select=timestamp&order=timestamp.asc&limit=1`,
    { headers: SUPABASE_HEADERS }
  );
  if (!minRes.ok) throw new Error(`Failed to fetch min timestamp: ${minRes.status}`);
  const minRows = await minRes.json();
  const min = minRows?.[0]?.timestamp ?? null;

  const maxRes = await fetchWithRetry(
    `${SUPABASE_REST_ENDPOINT}/restock_events?select=timestamp&order=timestamp.desc&limit=1`,
    { headers: SUPABASE_HEADERS }
  );
  if (!maxRes.ok) throw new Error(`Failed to fetch max timestamp: ${maxRes.status}`);
  const maxRows = await maxRes.json();
  const max = maxRows?.[0]?.timestamp ?? null;

  return { min, max };
}

async function truncateHistory() {
  const res = await fetchWithRetry(`${SUPABASE_REST_ENDPOINT}/restock_history?item_id=not.is.null`, {
    method: "DELETE",
    headers: SUPABASE_HEADERS,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Failed to truncate restock_history: ${res.status} ${text}`);
  }
}

async function callChunk(from, to) {
  const res = await fetchWithRetry(`${SUPABASE_REST_ENDPOINT}/rpc/rebuild_restock_history_chunk`, {
    method: "POST",
    headers: SUPABASE_HEADERS,
    body: JSON.stringify({ p_from: from, p_to: to }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Chunk failed (${from}-${to}): ${res.status} ${text}`);
  }
}

async function finalize() {
  const res = await fetchWithRetry(`${SUPABASE_REST_ENDPOINT}/rpc/finalize_restock_history`, {
    method: "POST",
    headers: SUPABASE_HEADERS,
    body: JSON.stringify({}),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Finalize failed: ${res.status} ${text}`);
  }
}

function getMinMaxFromLocalEvents() {
  if (!fs.existsSync(EVENTS_FILE)) return null;
  const raw = fs.readFileSync(EVENTS_FILE, "utf8");
  const data = JSON.parse(raw);
  if (!Array.isArray(data) || data.length === 0) return null;
  let min = Infinity;
  let max = -Infinity;
  for (const ev of data) {
    const ts = typeof ev?.timestamp === "number" ? ev.timestamp : null;
    if (!ts) continue;
    if (ts < min) min = ts;
    if (ts > max) max = ts;
  }
  if (!Number.isFinite(min) || !Number.isFinite(max)) return null;
  return { min, max };
}

async function main() {
  if (!SUPABASE_HEADERS || !SUPABASE_REST_ENDPOINT) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  }
  const minOverride = process.env.MIN_TS ? Number(process.env.MIN_TS) : null;
  const maxOverride = process.env.MAX_TS ? Number(process.env.MAX_TS) : null;

  console.log("Fetching min/max timestamps...");
  let range = null;
  if (minOverride && maxOverride) {
    range = { min: minOverride, max: maxOverride };
  } else {
    try {
      range = await getMinMaxTimestamp();
    } catch (err) {
      if (FORCE_DB_MINMAX) {
        throw err;
      }
      const local = getMinMaxFromLocalEvents();
      if (local) {
        console.warn("Falling back to local events.json for min/max");
        range = local;
      } else {
        throw err;
      }
    }
  }
  const { min, max } = range ?? { min: null, max: null };
  if (!min || !max) {
    console.log("No restock_events found.");
    return;
  }
  console.log(`Min: ${min}, Max: ${max}`);

  if (SKIP_TRUNCATE) {
    console.log("Skipping truncate (SKIP_TRUNCATE=1)");
  } else {
    console.log("Truncating restock_history...");
    await truncateHistory();
  }

  let from = min;
  let idx = 0;
  while (from < max) {
    const to = Math.min(from + CHUNK_MS, max + 1);
    idx += 1;
    console.log(`Chunk ${idx}: ${from} -> ${to}`);
    await callChunk(from, to);
    from = to;
  }

  console.log("Finalizing history stats...");
  await finalize();
  console.log("Chunked rebuild complete.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
