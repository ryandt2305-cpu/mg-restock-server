import fs from "node:fs";
import path from "node:path";

const env = {};
for (const line of fs.readFileSync(path.join(process.cwd(), ".env"), "utf8").split(/\r?\n/)) {
  const i = line.indexOf("=");
  if (i > 0 && !line.trim().startsWith("#")) {
    env[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
}

const BASE = `${env.SUPABASE_URL}/rest/v1`;
const H = {
  apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
};

const CELESTIAL = new Set(["Starweaver", "MoonCelestial", "DawnCelestial", "SunCelestial"]);
const SHOP_CYCLE_MS = { seed: 300000, egg: 900000, decor: 3600000 };
const MIN_TRAIN = 8;
const MAX_WINDOW = 40;
const MAX_STEPS = 40;

function clamp01(x) {
  if (!Number.isFinite(x)) return 0.0001;
  return Math.min(0.9999, Math.max(0.0001, x));
}

function quantile(sorted, q) {
  if (!sorted.length) return null;
  if (sorted.length === 1) return sorted[0];
  const idx = (sorted.length - 1) * q;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo];
  const t = idx - lo;
  return sorted[lo] * (1 - t) + sorted[hi] * t;
}

function median(values) {
  if (!values.length) return null;
  const s = values.slice().sort((a, b) => a - b);
  return quantile(s, 0.5);
}

async function fetchAllEvents() {
  const perPage = 1000;
  let offset = 0;
  const grouped = new Map();

  while (true) {
    const url = `${BASE}/restock_item_events?select=shop_type,item_id,timestamp&order=shop_type.asc,item_id.asc,timestamp.asc&limit=${perPage}&offset=${offset}`;
    const r = await fetch(url, { headers: H });
    if (!r.ok) {
      throw new Error(`HTTP ${r.status}: ${await r.text()}`);
    }
    const rows = await r.json();
    if (!Array.isArray(rows) || rows.length === 0) break;

    for (const row of rows) {
      const key = `${row.shop_type}:${row.item_id}`;
      const arr = grouped.get(key) ?? [];
      arr.push(Number(row.timestamp));
      grouped.set(key, arr);
    }

    offset += rows.length;
    if (offset % 100000 === 0) {
      console.log(`Fetched ${offset} rows...`);
    }
    if (rows.length < perPage) break;
  }

  return grouped;
}

function evalSeries(intervals, cycleMs, isCelestial, p) {
  let ll = 0;
  let br = 0;
  let n = 0;

  for (let i = 1; i < intervals.length; i += 2) {
    const start = Math.max(0, i - MAX_WINDOW);
    let train = intervals.slice(start, i).filter((v) => Number.isFinite(v) && v > 0);
    if (isCelestial) train = train.filter((v) => v >= 21600000);
    if (train.length < MIN_TRAIN) continue;

    const mean = train.reduce((s, v) => s + v, 0) / train.length;
    const fallback = clamp01(cycleMs / Math.max(mean, cycleMs));
    const w = Math.min(1, train.length / (isCelestial ? p.wc : p.wn));

    const sorted = train.slice().sort((a, b) => a - b);
    const baseMed = median(sorted);
    const p95 = quantile(sorted, 0.95);
    const maxV = sorted[sorted.length - 1];
    const cap = isCelestial && baseMed
      ? Math.max(baseMed * p.capMin, (p95 ?? baseMed * p.capHi), (maxV ?? baseMed * p.capHi))
      : null;

    const I = intervals[i];
    const rawSteps = Math.max(1, Math.ceil(I / cycleMs));
    const steps = Math.min(MAX_STEPS, rawSteps);
    for (let s = 0; s < steps; s++) {
      const elapsed = s * cycleMs;
      const y = I <= elapsed + cycleMs ? 1 : 0;

      let survivors = 0;
      let hits = 0;
      for (const v of train) {
        if (v > elapsed) {
          survivors++;
          if (v <= elapsed + cycleMs) hits++;
        }
      }
      const empirical = survivors <= 0
        ? 0.9999
        : clamp01((hits + p.alpha * fallback) / (survivors + p.alpha));

      let prob = clamp01((1 - w) * fallback + w * empirical);
      if (isCelestial && cap) {
        if (elapsed >= cap) {
          prob = 0.9999;
        } else {
          const rs = cap * p.ramp;
          if (elapsed >= rs) {
            const span = Math.max(cap - rs, cycleMs);
            const t = (elapsed - rs) / span;
            prob = clamp01(prob + (0.9999 - prob) * t);
          }
        }
      }

      const eps = 1e-12;
      ll += -(y * Math.log(Math.max(eps, prob)) + (1 - y) * Math.log(Math.max(eps, 1 - prob)));
      br += (prob - y) * (prob - y);
      n++;
    }
  }

  return { ll, br, n };
}

function score(grouped, p) {
  let ll = 0;
  let br = 0;
  let n = 0;

  for (const [key, ts] of grouped) {
    if (ts.length < 10) continue;
    const [shop, item] = key.split(":");
    const cycle = SHOP_CYCLE_MS[shop] ?? 300000;

    const intervals = [];
    for (let i = 1; i < ts.length; i++) {
      const d = ts[i] - ts[i - 1];
      if (Number.isFinite(d) && d > 0) intervals.push(d);
    }
    if (intervals.length < MIN_TRAIN + 1) continue;

    const part = evalSeries(intervals, cycle, CELESTIAL.has(item), p);
    ll += part.ll;
    br += part.br;
    n += part.n;
  }

  return {
    ...p,
    samples: n,
    meanLogLoss: n ? ll / n : Infinity,
    meanBrier: n ? br / n : Infinity,
  };
}

async function main() {
  const grouped = await fetchAllEvents();
  console.log(`Series groups: ${grouped.size}`);

  const grid = [];
  for (const wn of [8, 10, 12, 14]) {
    for (const wc of [6, 8, 10]) {
      for (const capMin of [1.1, 1.2, 1.3]) {
        for (const capHi of [1.5, 1.75]) {
          for (const ramp of [0.75, 0.8]) {
            for (const alpha of [2, 4, 8]) {
              grid.push({ wn, wc, capMin, capHi, ramp, alpha });
            }
          }
        }
      }
    }
  }
  console.log(`Grid size: ${grid.length}`);

  const scored = [];
  for (let i = 0; i < grid.length; i++) {
    scored.push(score(grouped, grid[i]));
    if ((i + 1) % 24 === 0) {
      console.log(`Scored ${i + 1}/${grid.length}`);
    }
  }
  scored.sort((a, b) => a.meanLogLoss - b.meanLogLoss || a.meanBrier - b.meanBrier);

  console.log("\n=== Top 12 ===");
  for (const s of scored.slice(0, 12)) {
    console.log(JSON.stringify(s));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

