-- This migration replaces the previous helper functions with optimized ingest
-- Run this in Supabase SQL editor

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
