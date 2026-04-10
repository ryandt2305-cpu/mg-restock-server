-- Recovery + backfill playbook for restock tracking.
-- Run sections in order in Supabase SQL Editor.
-- Safe to re-run: inserts use dedupe on fingerprint.

-- ============================================================
-- 1) Verify polling health (events are still arriving)
-- ============================================================
select
  shop_type,
  max(timestamp) as last_event_ts,
  to_timestamp(max(timestamp) / 1000.0) at time zone 'Australia/Brisbane' as last_event_brisbane,
  round((extract(epoch from now()) * 1000 - max(timestamp)) / 3600000.0, 2) as age_hours
from public.restock_events
group by shop_type
order by shop_type;

-- Optional: source split in last 24h (mg-api vs poller vs backfill).
select
  coalesce(source, 'null') as source,
  count(*) as rows_24h
from public.restock_events
where timestamp >= (
  (extract(epoch from now()) * 1000)::bigint
  - (24::bigint * 3600000)
)
group by source
order by rows_24h desc;

-- ============================================================
-- 2) Verify Supabase cron is active (primary edge polling path)
-- ============================================================
select
  jobid,
  jobname,
  schedule,
  active
from cron.job
where jobname = 'poll-restock';

-- If no row is returned, recreate cron outside this script
-- using your current poll secret/header strategy.

-- ============================================================
-- 3) Detect major ingestion gaps (last 30 days)
-- ============================================================
with ordered as (
  select
    shop_type,
    timestamp,
    lag(timestamp) over (partition by shop_type order by timestamp) as prev_ts
  from public.restock_events
  where source = 'mg-api'
    and timestamp >= (
      (extract(epoch from now()) * 1000)::bigint
      - (30::bigint * 24 * 3600000)
    )
),
gaps as (
  select
    shop_type,
    prev_ts,
    timestamp as next_ts,
    (timestamp - prev_ts) as gap_ms
  from ordered
  where prev_ts is not null
)
select
  shop_type,
  round(gap_ms / 60000.0, 2) as gap_minutes,
  to_timestamp(prev_ts / 1000.0) at time zone 'Australia/Brisbane' as gap_start_brisbane,
  to_timestamp(next_ts / 1000.0) at time zone 'Australia/Brisbane' as gap_end_brisbane
from gaps
where gap_ms > 3600000
order by gap_ms desc;

-- ============================================================
-- 4) Backfill staging table
-- ============================================================
create temporary table if not exists temp_backfill_events (
  timestamp bigint not null,
  shop_type text not null check (shop_type in ('seed', 'egg', 'decor', 'tool')),
  weather_id text null,
  source text not null default 'manual-backfill',
  items jsonb not null
) on commit drop;

-- Example insert (replace with your real rows).
-- NOTE: each items value is a JSON array of {itemId, stock}.
-- delete from temp_backfill_events;
-- insert into temp_backfill_events (timestamp, shop_type, weather_id, source, items) values
-- (1775619000000, 'egg', 'Sunny', 'manual-backfill', '[{"itemId":"CommonEgg","stock":1},{"itemId":"UncommonEgg","stock":1}]'::jsonb),
-- (1775619900000, 'egg', 'Sunny', 'manual-backfill', '[{"itemId":"MythicalEgg","stock":1}]'::jsonb);

-- Quick review before insert:
select * from temp_backfill_events order by timestamp, shop_type;

-- ============================================================
-- 5) Insert staged rows into restock_events with fingerprint dedupe
-- ============================================================
insert into public.restock_events (timestamp, shop_type, weather_id, source, items, fingerprint)
select
  t.timestamp,
  t.shop_type,
  t.weather_id,
  t.source,
  t.items,
  (
    t.shop_type || ':' || t.timestamp::text || ':' ||
    coalesce((
      select string_agg(
        (elem->>'itemId') || ':' || coalesce(elem->>'stock', elem->>'quantity', ''),
        '|' order by (elem->>'itemId'), coalesce(elem->>'stock', elem->>'quantity', '')
      )
      from jsonb_array_elements(t.items) elem
    ), '')
  ) as fingerprint
from temp_backfill_events t
on conflict (fingerprint) do nothing;

-- ============================================================
-- 6) Rebuild canonical history + predictions from raw events
-- ============================================================
select public.rebuild_restock_history();

-- ============================================================
-- 7) Post-backfill verification
-- ============================================================
-- Mythical egg check:
select
  item_id,
  shop_type,
  last_seen,
  to_timestamp(last_seen / 1000.0) at time zone 'Australia/Brisbane' as last_seen_brisbane,
  total_occurrences
from public.restock_history
where shop_type = 'egg'
  and item_id = 'MythicalEgg';

-- Active stale rows (>48h) in predictions:
select
  shop_type,
  item_id,
  last_seen,
  round((extract(epoch from now()) * 1000 - last_seen) / 3600000.0, 2) as age_hours,
  total_occurrences,
  base_rate,
  current_probability
from public.restock_predictions
where last_seen is not null
  and (
    (extract(epoch from now()) * 1000)::bigint - last_seen
  ) > (48::bigint * 3600000)
order by age_hours desc;
