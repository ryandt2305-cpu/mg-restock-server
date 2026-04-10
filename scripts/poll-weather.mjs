import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import fetch from "node-fetch";

const ROOT = process.cwd();
const DATA_DIR = path.join(ROOT, "data");
const STATE_FILE = path.join(DATA_DIR, "weather-state.json");

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
    Prefer: "resolution=ignore-duplicates,return=representation",
  }
  : null;

const MG_API_BASE = process.env.MG_API_BASE || "https://mg-api.ariedam.fr";
const WEATHER_POLL_MS = Number(process.env.WEATHER_POLL_MS || 60000);
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS || 15000);
const WEATHER_ONE_SHOT = process.env.WEATHER_ONE_SHOT
  ? process.env.WEATHER_ONE_SHOT !== "0"
  : process.env.GITHUB_ACTIONS === "true";

const WEATHER_ALIASES = new Map([
  ["rain", "Rain"],
  ["snow", "Frost"],
  ["frost", "Frost"],
  ["dawn", "Dawn"],
  ["ambermoon", "AmberMoon"],
  ["amber", "AmberMoon"],
  ["ambermoonweather", "AmberMoon"],
  ["clear", "Sunny"],
  ["sunny", "Sunny"],
  ["thunderstorm", "Thunderstorm"],
  ["storm", "Thunderstorm"],
]);

function normalizeKey(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[\u2019']/g, "")
    .replace(/[^a-z0-9]/g, "");
}

function normalizeWeather(value) {
  if (!value) return "Sunny";
  const key = normalizeKey(String(value));
  return WEATHER_ALIASES.get(key) ?? "Sunny";
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

async function fetchWithTimeout(url) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    return await fetch(url, { signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

function extractWeatherId(payload) {
  if (!payload || typeof payload !== "object") return "Sunny";
  const direct = payload.weather ?? payload.weatherId ?? payload.weather_id ?? payload.id ?? payload.type ?? payload.name;
  if (direct) return normalizeWeather(direct);
  const current = payload.current ?? payload.data ?? payload.state;
  if (current && typeof current === "object") {
    const nested = current.weather ?? current.weatherId ?? current.weather_id ?? current.id ?? current.type ?? current.name;
    if (nested) return normalizeWeather(nested);
  }
  return "Sunny";
}

function extractTimestamp(payload) {
  const raw =
    payload?.timestamp ??
    payload?.ts ??
    payload?.updatedAt ??
    payload?.updated_at ??
    payload?.time ??
    null;
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  const ms = Date.parse(String(raw || ""));
  return Number.isFinite(ms) ? ms : Date.now();
}

function makeFingerprint(timestamp, weatherId, source) {
  return `weather:${source}:${timestamp}:${weatherId}`;
}

async function insertWeatherEvent(event) {
  if (!SUPABASE_HEADERS || !SUPABASE_REST_ENDPOINT) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  }
  const res = await fetch(`${SUPABASE_REST_ENDPOINT}/weather_events?on_conflict=fingerprint`, {
    method: "POST",
    headers: SUPABASE_HEADERS,
    body: JSON.stringify([event]),
  });
  if (!res.ok) {
    const text = await res.text();
    if (res.status === 409) return;
    throw new Error(`Supabase insert weather_events failed: ${res.status} ${text}`);
  }

  // Trigger rebuild of history/predictions
  const rebuildRes = await fetch(`${SUPABASE_REST_ENDPOINT}/rpc/rebuild_weather_history`, {
    method: "POST",
    headers: SUPABASE_HEADERS,
  });
  if (!rebuildRes.ok) {
    console.warn(`[WeatherPoller] Failed to rebuild history: ${rebuildRes.status}`);
  }
}

async function pollLoop() {
  if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
  let state = readJson(STATE_FILE, { lastWeatherId: null, lastTimestamp: null });

  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      const res = await fetchWithTimeout(`${MG_API_BASE}/live/weather`);
      if (!res.ok) throw new Error(`MG API /live/weather failed: ${res.status}`);
      const payload = await res.json();
      const weatherId = extractWeatherId(payload);
      const timestamp = extractTimestamp(payload);

      if (state.lastTimestamp && timestamp <= state.lastTimestamp) {
        if (WEATHER_ONE_SHOT) break;
        await new Promise((resolve) => setTimeout(resolve, WEATHER_POLL_MS));
        continue;
      }

      if (state.lastWeatherId !== weatherId || !state.lastTimestamp) {
        const event = {
          timestamp,
          weather_id: weatherId,
          previous_weather_id: state.lastWeatherId,
          source: "mg-api",
          fingerprint: makeFingerprint(timestamp, weatherId, "mg-api"),
        };
        await insertWeatherEvent(event);
        state = { lastWeatherId: weatherId, lastTimestamp: timestamp };
        writeJson(STATE_FILE, state);
        console.log(`[WeatherPoller] ${weatherId} @ ${timestamp}`);
      } else {
        state = { lastWeatherId: weatherId, lastTimestamp: timestamp };
        writeJson(STATE_FILE, state);
      }
    } catch (err) {
      console.error("[WeatherPoller] Error:", err?.message ?? err);
    }
    if (WEATHER_ONE_SHOT) break;
    await new Promise((resolve) => setTimeout(resolve, WEATHER_POLL_MS));
  }
}

pollLoop().catch((err) => {
  console.error(err);
  process.exit(1);
});
