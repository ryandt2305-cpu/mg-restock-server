# Gemini Server Operational Runbook

## Overview
This runbook covers the core operational tasks for the Gemini server pipeline.
It assumes Supabase is configured and the poller runs on a schedule.

## Daily Checks
1. Verify poller runs successfully (GitHub Actions).
2. Check `restock_events` rows are increasing.
3. Confirm `weather_summary` has recent timestamps.

## Key Tables
- `restock_events`: raw restock snapshots (must have non-null fingerprint and weather_id)
- `restock_history`: aggregated stats for UI
- `weather_events`: raw community weather data (discord + mg-api)
- `weather_summary`: clean transition dataset used for predictions

## Common Tasks

### Poll shops once (manual)
```bash
npm run poll
```

### Poll weather once (manual)
```bash
npm run poll:weather
```

### Import Discord JSON + rebuild summary
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

### Backfill missing fingerprints
```sql
update public.restock_events
set fingerprint = concat(
  shop_type, ':', timestamp::text, ':',
  coalesce(
    (
      select string_agg(item_part, '|' order by item_part)
      from (
        select concat(coalesce(item->>'itemId',''), ':', coalesce(item->>'stock', item->>'quantity', '')) as item_part
        from jsonb_array_elements(items) as item
      ) parts
    ),
    ''
  )
)
where fingerprint is null;

alter table public.restock_events
  alter column fingerprint set not null;
```

### Rebuild weather_summary
```sql
select public.rebuild_weather_summary();
```

## Troubleshooting

### restock_events.weather_id is null
- Ensure `scripts/poll.mjs` is updated
- Verify `/live/weather` reachable
- Run `npm run poll` once

### Weather predictions look wrong
- Run `select public.rebuild_weather_summary();`
- Confirm `weather_summary` timestamps are recent

### Supabase functions returning 404
- Deploy functions in `supabase/functions/`
- Verify `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`

## Health Queries
```sql
select count(*) as rows from public.restock_events;
select count(*) as rows from public.weather_summary;
select max(timestamp) from public.restock_events;
select max(timestamp) from public.weather_summary;
```
