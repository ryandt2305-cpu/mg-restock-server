import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import fetch from "node-fetch";

const ROOT = process.cwd();

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

const SOURCE = "magicshopkeeper";
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS || 300000);
const RETRY_ATTEMPTS = Number(process.env.REST_RETRY_ATTEMPTS || 6);
const RETRY_BASE_MS = Number(process.env.REST_RETRY_BASE_MS || 750);
const RESTOCK_CHUNK_MS = Number(process.env.CLEANUP_RESTOCK_CHUNK_MS || 7 * 86400000);
const WEATHER_CHUNK_MS = Number(process.env.CLEANUP_WEATHER_CHUNK_MS || 7 * 86400000);

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
      if (res.status === 503 || res.status === 502 || res.status === 504 || res.status === 521 || res.status === 522) {
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

async function getMinMax(table) {
  const minRes = await fetchWithRetry(
    `${SUPABASE_REST_ENDPOINT}/${table}?select=timestamp&source=eq.${SOURCE}&order=timestamp.asc&limit=1`,
    { headers: SUPABASE_HEADERS }
  );
  if (!minRes.ok) throw new Error(`Failed to fetch min ${table}: ${minRes.status}`);
  const minRows = await minRes.json();
  const min = minRows?.[0]?.timestamp ?? null;

  const maxRes = await fetchWithRetry(
    `${SUPABASE_REST_ENDPOINT}/${table}?select=timestamp&source=eq.${SOURCE}&order=timestamp.desc&limit=1`,
    { headers: SUPABASE_HEADERS }
  );
  if (!maxRes.ok) throw new Error(`Failed to fetch max ${table}: ${maxRes.status}`);
  const maxRows = await maxRes.json();
  const max = maxRows?.[0]?.timestamp ?? null;

  return { min, max };
}

async function deleteChunk(table, from, to) {
  const url = `${SUPABASE_REST_ENDPOINT}/${table}?source=eq.${SOURCE}&timestamp=gte.${from}&timestamp=lt.${to}`;
  const res = await fetchWithRetry(url, { method: "DELETE", headers: SUPABASE_HEADERS });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Delete failed (${table} ${from}-${to}): ${res.status} ${text}`);
  }
}

async function deleteAllHistory() {
  const url = `${SUPABASE_REST_ENDPOINT}/restock_history?item_id=not.is.null`;
  const res = await fetchWithRetry(url, { method: "DELETE", headers: SUPABASE_HEADERS });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Failed to truncate restock_history: ${res.status} ${text}`);
  }
}

async function cleanupTable(table, chunkMs) {
  console.log(`Fetching min/max for ${table}...`);
  const { min, max } = await getMinMax(table);
  if (!min || !max) {
    console.log(`No ${table} rows for source=${SOURCE}.`);
    return;
  }
  console.log(`${table} range: ${min} -> ${max}`);
  let from = min;
  let idx = 0;
  while (from <= max) {
    const to = Math.min(from + chunkMs, max + 1);
    idx += 1;
    console.log(`Delete ${table} chunk ${idx}: ${from} -> ${to}`);
    await deleteChunk(table, from, to);
    from = to;
  }
}

async function main() {
  if (!SUPABASE_HEADERS || !SUPABASE_REST_ENDPOINT) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  }

  await cleanupTable("weather_events", WEATHER_CHUNK_MS);
  await cleanupTable("restock_events", RESTOCK_CHUNK_MS);
  console.log("Truncating restock_history...");
  await deleteAllHistory();
  console.log("Cleanup complete.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
