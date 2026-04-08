# Gemini Server

Server-side pipeline for **Gemini** that ingests live shop data and community weather history, normalizes it, and writes to Supabase for the userscript to consume.

## What This Repo Does

- Polls **mg-api** shop snapshots to build `restock_events` + `restock_history`
- Imports **Discord JSON** history and normalizes it into structured events
- Builds **weather events** and **clean transition summaries** for prediction
- Exposes Supabase functions for restock ingestion and weather queries

## Architecture Overview

**Inputs**
- `https://mg-api.ariedam.fr/live/shops` (shop snapshots)
- `https://mg-api.ariedam.fr/live/weather` (weather snapshot)
- Discord export JSON (legacy history)

**Outputs**
- `public.restock_events` (raw restocks)
- `public.restock_history` (aggregated stats)
- `public.weather_events` (raw community weather)
- `public.weather_summary` (clean weather transitions)

## Core Tables

### `restock_events`
Raw events keyed by `fingerprint`:
- `timestamp` (ms epoch)
- `shop_type` (`seed` | `egg` | `decor`)
- `items` (jsonb list)
- `weather_id` (filled via live weather)

### `restock_history`
- Aggregated counts, rates, and prediction stats per item + shop

### `weather_events`
- Raw community weather history (discord + mg-api + optional client)

### `weather_summary`
- Clean transition-only dataset derived from `weather_events`
- Used for prediction in Gemini-main

## Scripts

```bash
npm run poll               # Poll mg-api shops and write restock_events/history
npm run poll:weather       # Poll mg-api weather (change-only)
npm run import:json        # Import Discord JSON export
npm run backfill:supabase  # Insert events.json into Supabase
npm run clean:supabase     # Rebuild Supabase from events.json
```

## Environment Variables

```bash
$env:SUPABASE_URL="https://YOUR_PROJECT.supabase.co"
$env:SUPABASE_SERVICE_ROLE_KEY="YOUR_SERVICE_ROLE_KEY"
$env:MG_API_BASE="https://mg-api.ariedam.fr"   # optional
$env:MGDATA_CACHE_MS="3600000"                 # optional (1 hour)
$env:FETCH_TIMEOUT_MS="15000"                  # optional
$env:LOAD_HISTORY_FROM_DB="1"                  # optional (default)
$env:USE_DB_INGEST="1"                         # optional (default)
$env:WRITE_JSON="1"                            # optional (force JSON files)
```

## Supabase Functions

- `restock-ingest` (HTTP POST)
  - accepts { shopType, items, source?, weatherId? }
- `restock-history` (HTTP GET)
  - reads aggregated restock stats
- `weather-events` (HTTP GET/POST)
  - GET defaults to `weather_summary`
  - `summary=0` returns raw `weather_events`

## Weather Summary (Critical)

`weather_summary` is derived via:

```sql
select public.rebuild_weather_summary();
```

Run this whenever:
- new Discord data is imported
- you want prediction quality refreshed

## Data Files (Local)

- `data/snapshot.json` - last live snapshot
- `data/events.json` - rolling list of restock events
- `data/history.json` - aggregated per-item history
- `data/history-seed.json` / `history-egg.json` / `history-decor.json`
- `data/meta.json` - metadata
- `data/weather-state.json` - poller checkpoint

## Common Workflows

### Import Discord JSON + rebuild weather summary
```bash
npm run import:json -- "C:\path\to\DiscordExport.json"
node scripts/backfill-supabase.mjs
```

Then in Supabase SQL editor:
```sql
select public.rebuild_weather_summary();
```

### Full rebuild from events.json
```bash
npm run clean:supabase
```

## Migrations

Key migrations:
- `supabase/migrations/20260204_restock_history_fix.sql`
- `supabase/migrations/20260205_restock_weather.sql`
- `supabase/migrations/20260206_weather_cleanup.sql` (adds weather_summary + rebuild function)

## Notes

- `restock_events.weather_id` is populated using `/live/weather` to support weather-aware analysis.
- Discord data is preserved but predictions use `weather_summary` to avoid noise.
