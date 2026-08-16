import fs from "node:fs";
import path from "node:path";

function loadEnvFile() {
  const envPath = path.join(process.cwd(), ".env");
  if (!fs.existsSync(envPath)) return;
  for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
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

loadEnvFile();

const SUPABASE_URL = process.env.SUPABASE_URL || "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || "";

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
}

const headers = {
  apikey: SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
};

async function query(pathQ) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathQ}`, { headers });
  if (!res.ok) {
    throw new Error(`${res.status} ${await res.text()}`);
  }
  return res.json();
}

const latestRuns = await query(
  "restock_item_model_backtests?select=run_id,run_at&order=run_at.desc&limit=1"
);
const latestRun = latestRuns[0]?.run_id ?? null;

if (!latestRun) {
  console.log(JSON.stringify({ message: "No backtest runs found." }, null, 2));
  process.exit(0);
}

const [selectedRows, candidateRows, accuracyRows] = await Promise.all([
  query(
    `restock_item_selected_models?select=shop_type,item_id,model_name,test_events,mae_ms,median_abs_error_ms,within_one_cycle_pct,p80_coverage_pct,run_at&run_id=eq.${latestRun}&order=shop_type.asc,item_id.asc`
  ),
  query(
    `restock_item_model_candidates?select=shop_type,item_id,model_name,model_rank,test_events,mae_ms,median_abs_error_ms,within_one_cycle_pct,selected&run_id=eq.${latestRun}&order=model_rank.asc`
  ),
  query(
    "restock_prediction_accuracy_by_item?select=shop_type,item_id,algorithm_version,scored_predictions,mae_min,median_abs_error_min,within_one_cycle_pct,last_scored_at&order=mae_min.desc&limit=200"
  ),
]);

const topWorst = accuracyRows.slice(0, 25);
const topBest = [...accuracyRows]
  .filter((r) => Number.isFinite(r.mae_min))
  .sort((a, b) => a.mae_min - b.mae_min)
  .slice(0, 25);

const byModel = new Map();
for (const row of selectedRows) {
  const key = row.model_name ?? "unknown";
  byModel.set(key, (byModel.get(key) ?? 0) + 1);
}

const summary = {
  generated_at: new Date().toISOString(),
  latest_run_id: latestRun,
  selected_model_count: selectedRows.length,
  candidate_rows_latest_run: candidateRows.length,
  selected_models_by_name: Object.fromEntries([...byModel.entries()].sort((a, b) => b[1] - a[1])),
  scoring_rows: accuracyRows.length,
  worst_accuracy_items: topWorst,
  best_accuracy_items: topBest,
};

console.log(JSON.stringify(summary, null, 2));
