-- Raw snapshot storage for MagicShopkeeper and other sources
create table if not exists public.restock_snapshots (
  id uuid primary key default gen_random_uuid(),
  timestamp bigint not null,
  weather_id text,
  source text not null default 'magicshopkeeper',
  payload jsonb not null,
  fingerprint text not null,
  created_at timestamptz not null default now()
);

create unique index if not exists restock_snapshots_fingerprint_key
  on public.restock_snapshots (fingerprint);

create index if not exists restock_snapshots_timestamp_idx
  on public.restock_snapshots (timestamp desc);

create index if not exists restock_snapshots_source_idx
  on public.restock_snapshots (source, timestamp desc);
