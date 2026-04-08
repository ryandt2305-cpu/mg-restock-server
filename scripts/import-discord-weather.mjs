import fs from "fs";
import path from "path";
import process from "process";
import fetch from "node-fetch";

// Config
const FILE_PATH = String.raw`C:\Users\ryand\Feeder-Extension\Gemini-folder\Gemini-server\restock examples\Garlic Bread's Server - Text Channels - whats-in-stock [1408590909842526229].json`;
const SHOPKEEPER_ID = "1399527461242540102";
const LOOKBACK_DAYS = 3;
const BATCH_SIZE = 1000;

// Env loading (simplified)
function loadEnv() {
    const envPath = path.join(process.cwd(), ".env");
    if (fs.existsSync(envPath)) {
        const lines = fs.readFileSync(envPath, "utf8").split("\n");
        for (const line of lines) {
            const parts = line.split("=");
            if (parts.length >= 2 && !line.trim().startsWith("#")) {
                process.env[parts[0].trim()] = parts.slice(1).join("=").trim();
            }
        }
    }
}
loadEnv();

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SUPABASE_KEY) {
    console.error("Missing SUPABASE env vars.");
    process.exit(1);
}

const HEADERS = {
    apikey: SUPABASE_KEY,
    Authorization: `Bearer ${SUPABASE_KEY}`,
    "Content-Type": "application/json",
    "Prefer": "resolution=ignore-duplicates"
};

const WEATHER_MAP = {
    "rain": "Rain",
    "snow": "Snow", // File says "Snow", schema might map it to Frost, but logic maps Frost->Snow. 
    // Let's use "Snow" as the ID to match what we assume.
    "frost": "Snow",
    "thunderstorm": "Thunderstorm",
    "dawn": "Dawn",
    "amber": "AmberMoon",
    "ambermoon": "AmberMoon"
};

function normalizeWeather(text) {
    if (!text) return "Sunny";
    const firstPart = text.split("|")[0].trim().toLowerCase();

    // Check for explicit matches
    for (const [key, val] of Object.entries(WEATHER_MAP)) {
        if (firstPart.includes(key)) return val;
    }

    // Check if it looks like a shop list (starts with item name)
    // If it doesn't match a weather keyword, assume Sunny
    return "Sunny";
}

async function main() {
    console.log("Reading JSON file...");
    const raw = fs.readFileSync(FILE_PATH, "utf8");
    const data = JSON.parse(raw);

    console.log(`Total messages: ${data.messages.length}`);

    const now = Date.now();
    const cutoff = now - (LOOKBACK_DAYS * 24 * 60 * 60 * 1000);

    const events = [];

    for (const msg of data.messages) {
        if (msg.author.id !== SHOPKEEPER_ID) continue;

        const ts = new Date(msg.timestamp).getTime();
        if (ts < cutoff) continue;

        const weather = normalizeWeather(msg.content);

        events.push({
            timestamp: ts,
            weather_id: weather,
            source: "discord-import",
            fingerprint: `discord:${ts}:${weather}`
        });
    }

    console.log(`Found ${events.length} relevant events from the last ${LOOKBACK_DAYS} days.`);

    // Sort by timestamp
    events.sort((a, b) => a.timestamp - b.timestamp);

    // Batch insert
    for (let i = 0; i < events.length; i += BATCH_SIZE) {
        const batch = events.slice(i, i + BATCH_SIZE);
        console.log(`Inserting batch ${i} - ${i + batch.length}...`);

        const res = await fetch(`${SUPABASE_URL}/rest/v1/weather_events`, {
            method: "POST",
            headers: HEADERS,
            body: JSON.stringify(batch)
        });

        if (!res.ok) {
            // Continue but warn
            console.error("Batch failed:", await res.text());
        }
    }

    console.log("Rebuilding history...");
    const rebuildRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/rebuild_weather_history`, {
        method: "POST",
        headers: HEADERS
    });

    if (rebuildRes.ok) {
        console.log("History rebuild complete.");
    } else {
        console.error("History rebuild failed:", await rebuildRes.text());
    }
}

main();
