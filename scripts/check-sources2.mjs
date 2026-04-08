import fs from "node:fs";
import path from "node:path";

const envPath = path.join(process.cwd(), ".env");
const env = {};
for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
  const eq = line.indexOf("=");
  if (eq > 0 && !line.trim().startsWith("#")) {
    env[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
}

const H = {
  apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
};

// Check all distinct source_ip values across all events
const r = await fetch(`${env.SUPABASE_URL}/rest/v1/restock_events?select=source_ip&order=source_ip`, { headers: { ...H, Prefer: "count=exact" } });

// Get distinct fingerprint patterns to understand sources
const r2 = await fetch(`${env.SUPABASE_URL}/rest/v1/restock_events?select=fingerprint,source_ip&order=timestamp.desc&limit=10`, { headers: H });
const samples = await r2.json();
console.log("=== Recent event fingerprints ===");
for (const s of samples) {
  console.log(`  source_ip=${s.source_ip || "(null)"}  fingerprint=${s.fingerprint}`);
}

// Check if there's a Supabase Edge Function or cron job
// Look at the server directory for edge functions
console.log("\n=== Checking for edge functions ===");
const edgePath = path.join(process.cwd(), "supabase", "functions");
if (fs.existsSync(edgePath)) {
  const funcs = fs.readdirSync(edgePath);
  console.log("Edge functions found:", funcs);
} else {
  console.log("No supabase/functions directory");
}

// Check if there's a Vercel/Netlify deployment or similar
const serverDir = process.cwd();
const possibleConfigs = ["vercel.json", "netlify.toml", "fly.toml", "railway.json", "render.yaml", "Procfile", "Dockerfile"];
console.log("\n=== Checking for deployment configs ===");
for (const f of possibleConfigs) {
  if (fs.existsSync(path.join(serverDir, f))) {
    console.log(`  Found: ${f}`);
  }
}

// Check the poll.mjs to see what source_ip it sets
const pollPath = path.join(serverDir, "scripts", "poll.mjs");
if (fs.existsSync(pollPath)) {
  const pollContent = fs.readFileSync(pollPath, "utf8");
  const sourceMatch = pollContent.match(/source_ip[^}]*/g);
  console.log("\n=== poll.mjs source_ip usage ===");
  if (sourceMatch) {
    for (const m of sourceMatch) console.log(`  ${m.slice(0, 80)}`);
  } else {
    console.log("  No source_ip field found in poll.mjs");
  }
}

// Check for a server.mjs or index.mjs that might be deployed
const serverFiles = ["server.mjs", "server.js", "index.mjs", "index.js", "src/index.ts", "src/server.ts"];
console.log("\n=== Checking for server entry points ===");
for (const f of serverFiles) {
  if (fs.existsSync(path.join(serverDir, f))) {
    console.log(`  Found: ${f}`);
  }
}
