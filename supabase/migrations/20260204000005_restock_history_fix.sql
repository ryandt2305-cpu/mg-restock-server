-- Fix missing columns + add fast rebuild RPCs

alter table if exists restock_history
  add column if not exists total_quantity numeric,
  add column if not exists average_interval_ms bigint,
  add column if not exists estimated_next_timestamp bigint,
  add column if not exists average_quantity numeric,
  add column if not exists last_quantity numeric,
  add column if not exists rate_per_day numeric;

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

create or replace function rebuild_restock_history()
returns void language plpgsql as $$
begin
  truncate table restock_history;

  with expanded as (
    select
      e.shop_type,
      (item->>'itemId')::text as item_id,
      nullif((item->>'stock')::numeric, 0) as stock,
      e.timestamp as ts
    from restock_events e
    cross join lateral jsonb_array_elements(e.items) as item
  ),
  ranked as (
    select
      *,
      row_number() over (partition by shop_type, item_id order by ts desc) as rn
    from expanded
  ),
  agg as (
    select
      shop_type,
      item_id,
      count(*)::int as total_occurrences,
      min(ts) as first_seen,
      max(ts) as last_seen,
      avg(stock) filter (where stock is not null) as average_quantity,
      max(stock) filter (where rn = 1) as last_quantity
    from ranked
    group by shop_type, item_id
  )
  insert into restock_history(
    item_id,
    shop_type,
    total_occurrences,
    first_seen,
    last_seen,
    average_interval_ms,
    estimated_next_timestamp,
    average_quantity,
    last_quantity,
    rate_per_day
  )
  select
    item_id,
    shop_type,
    total_occurrences,
    first_seen,
    last_seen,
    case
      when total_occurrences > 1 then greatest(1, round((last_seen - first_seen) / (total_occurrences - 1))::bigint)
      else null
    end as average_interval_ms,
    case
      when total_occurrences > 1 then last_seen + greatest(1, round((last_seen - first_seen) / (total_occurrences - 1))::bigint)
      else null
    end as estimated_next_timestamp,
    average_quantity,
    last_quantity,
    case
      when last_seen > first_seen then round((total_occurrences / ((last_seen - first_seen) / 86400000.0))::numeric, 2)
      else null
    end as rate_per_day
  from agg;
end;
$$;

create or replace function truncate_and_rebuild_restock()
returns void language plpgsql as $$
begin
  perform rebuild_restock_history();
end;
$$;
