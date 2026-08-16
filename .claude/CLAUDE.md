# Gemini-server

## TL;DR
Server-side pipeline for ingesting live shop data and weather from the official Magic Garden platform API (`magicgarden.gg/platform/v1`), plus legacy Discord history, normalizing it, and persisting to Supabase.

## Architecture type
Node.js scripts (no framework) — Supabase as data store

## Commands
- `npm run poll` — poll shop data
- `npm run poll:weather` — poll weather data
- `npm run import:html` / `import:json` / `import:magicshopkeeper` — data import
- `npm run backfill:supabase` / `backfill:gap-window` — backfill historical data
- `npm run clean:supabase` — clean stale data
- `npm run seed` — seed database

## Repo map
- `scripts/` — all pipeline scripts (polling, importing, backfilling)
- `scripts/lib/platformApi.mjs` / `supabase/functions/_shared/platformApi.ts` — official platform API client (keep in sync)
- No `src/` directory

## Related repos
- `mgtokyo-discord-bot` — reads from same Supabase instance (read-only)
- `Gemini-main` — userscript that consumes this data
