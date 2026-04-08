alter table if exists public.restock_events
  add column if not exists weather_id text;

create index if not exists restock_events_weather_timestamp_idx
  on public.restock_events (weather_id, timestamp);

create table if not exists public.weather_events (
  id uuid primary key default gen_random_uuid(),
  timestamp bigint not null,
  weather_id text not null,
  previous_weather_id text null,
  source text not null default 'restock',
  fingerprint text unique,
  created_at timestamptz not null default now()
);

create index if not exists weather_events_timestamp_idx
  on public.weather_events (timestamp desc);

create index if not exists weather_events_weather_idx
  on public.weather_events (weather_id, timestamp desc);
