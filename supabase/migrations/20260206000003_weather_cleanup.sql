-- Ensure restock_events fingerprint non-null for future writes
alter table if exists public.restock_events
  alter column fingerprint set not null;

-- Backfill fingerprints for any nulls (deterministic)
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

-- Create derived weather summary table (clean transitions only)
create table if not exists public.weather_summary (
  id uuid primary key default gen_random_uuid(),
  timestamp bigint not null,
  weather_id text not null,
  previous_weather_id text null,
  source text not null default 'discord-json',
  fingerprint text not null
);

create unique index if not exists weather_summary_fingerprint_key on public.weather_summary (fingerprint);
create index if not exists weather_summary_timestamp_idx on public.weather_summary ("timestamp" desc);
create index if not exists weather_summary_weather_idx on public.weather_summary (weather_id, "timestamp" desc);

-- Function to rebuild weather_summary from weather_events
create or replace function public.rebuild_weather_summary()
returns void
language plpgsql
as $$
begin
  truncate table public.weather_summary;
  insert into public.weather_summary (timestamp, weather_id, previous_weather_id, source, fingerprint)
  select
    t.timestamp,
    t.weather_id,
    t.prev_weather_id,
    t.source,
    concat('summary:', t.timestamp::text, ':', t.weather_id, ':', coalesce(t.prev_weather_id,'')) as fingerprint
  from (
    select
      w.timestamp,
      w.weather_id,
      lag(w.weather_id) over (order by w.timestamp) as prev_weather_id,
      w.source,
      lag(w.weather_id) over (order by w.timestamp) is distinct from w.weather_id as changed
    from public.weather_events w
    where w.weather_id is not null
  ) t
  where t.changed;
end;
$$;

-- Ensure unique fingerprint constraint remains
create unique index if not exists restock_events_fingerprint_idx on public.restock_events (fingerprint);
create unique index if not exists weather_events_fingerprint_key on public.weather_events (fingerprint);
