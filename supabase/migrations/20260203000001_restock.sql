-- Restock tables + indices + optional RLS policies

create table if not exists restock_events (
  id uuid primary key default gen_random_uuid(),
  timestamp bigint not null,
  shop_type text not null check (shop_type in ('seed','egg','decor')),
  items jsonb not null,
  weather_id text,
  source text,
  source_ip text,
  fingerprint text,
  created_at timestamptz default now()
);

create unique index if not exists restock_events_fingerprint_idx on restock_events (fingerprint);

create table if not exists restock_history (
  item_id text not null,
  shop_type text not null check (shop_type in ('seed','egg','decor')),
  total_occurrences int not null default 0,
  first_seen bigint,
  last_seen bigint,
  average_interval_ms bigint,
  estimated_next_timestamp bigint,
  average_quantity numeric,
  last_quantity numeric,
  rate_per_day numeric,
  primary key (item_id, shop_type)
);

create index if not exists restock_events_shop_time_idx on restock_events (shop_type, created_at);
create index if not exists restock_events_source_time_idx on restock_events (source_ip, created_at);
create index if not exists restock_history_shop_last_idx on restock_history (shop_type, last_seen);

-- Ingest helper to update restock_history from items json
create or replace function ingest_restock_history(shop_type text, ts bigint, items jsonb)
returns void language plpgsql as $$
declare
  item jsonb;
  item_id text;
  item_stock numeric;
  new_total int;
  first_seen_ts bigint;
  last_seen_ts bigint;
  avg_qty numeric;
  interval_ms bigint;
  rate numeric;
begin
  for item in select * from jsonb_array_elements(items)
  loop
    item_id := item->>'itemId';
    if item_id is null then
      continue;
    end if;
    item_stock := nullif((item->>'stock')::numeric, 0);

    insert into restock_history(item_id, shop_type, total_occurrences, first_seen, last_seen, average_quantity, last_quantity)
    values (item_id, shop_type, 1, ts, ts, item_stock, item_stock)
    on conflict (item_id, shop_type) do update
      set total_occurrences = restock_history.total_occurrences + 1,
          first_seen = least(coalesce(restock_history.first_seen, ts), ts),
          last_seen = greatest(coalesce(restock_history.last_seen, ts), ts),
          average_quantity = case
            when item_stock is null then restock_history.average_quantity
            when restock_history.average_quantity is null then item_stock
            else round((restock_history.average_quantity + item_stock) / 2, 2)
          end,
          last_quantity = coalesce(item_stock, restock_history.last_quantity)
      returning total_occurrences, first_seen, last_seen, average_quantity
      into new_total, first_seen_ts, last_seen_ts, avg_qty;

    if new_total is not null and new_total > 1 and first_seen_ts is not null and last_seen_ts is not null then
      interval_ms := greatest(1, round((last_seen_ts - first_seen_ts) / (new_total - 1))::bigint);
      if last_seen_ts > first_seen_ts then
        rate := round((new_total / ((last_seen_ts - first_seen_ts) / 86400000.0))::numeric, 2);
      else
        rate := null;
      end if;
      update restock_history
        set average_interval_ms = interval_ms,
            estimated_next_timestamp = last_seen_ts + interval_ms,
            rate_per_day = rate
      where restock_history.item_id = item_id and restock_history.shop_type = shop_type;
    end if;
  end loop;
end;
$$;

-- Optional: keep history in sync if you ever backfill events
-- create or replace function rebuild_restock_history()
-- returns void language plpgsql as $$
-- begin
--   truncate table restock_history;
--   insert into restock_history(item_id, shop_type, total_occurrences, first_seen, last_seen, recent_timestamps)
--   select
--     (item->>'itemId')::text as item_id,
--     e.shop_type,
--     count(*) as total_occurrences,
--     min(e.timestamp) as first_seen,
--     max(e.timestamp) as last_seen,
--     array_agg(e.timestamp order by e.timestamp) as recent_timestamps
--   from restock_events e
--   cross join lateral jsonb_array_elements(e.items) as item
--   group by item_id, e.shop_type;
-- end;
-- $$;

-- If you want RLS, enable + allow anon for read/write (since we require anon key):
-- alter table restock_events enable row level security;
-- alter table restock_history enable row level security;
-- create policy "allow anon insert events" on restock_events
--   for insert to anon with check (true);
-- create policy "allow anon read history" on restock_history
--   for select to anon using (true);
