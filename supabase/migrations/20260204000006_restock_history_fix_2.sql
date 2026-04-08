-- Fix ambiguous item_id reference in ingest_restock_history

create or replace function ingest_restock_history(p_shop_type text, p_ts bigint, p_items jsonb)
returns void language plpgsql as $$
declare
  v_item jsonb;
  v_item_id text;
  v_item_stock numeric;
  v_new_total int;
  v_first_seen_ts bigint;
  v_last_seen_ts bigint;
  v_avg_qty numeric;
  v_interval_ms bigint;
  v_rate numeric;
begin
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_item_id := v_item->>'itemId';
    if v_item_id is null then
      continue;
    end if;
    v_item_stock := nullif((v_item->>'stock')::numeric, 0);

    insert into restock_history(item_id, shop_type, total_occurrences, first_seen, last_seen, average_quantity, last_quantity)
    values (v_item_id, p_shop_type, 1, p_ts, p_ts, v_item_stock, v_item_stock)
    on conflict (item_id, shop_type) do update
      set total_occurrences = restock_history.total_occurrences + 1,
          first_seen = least(coalesce(restock_history.first_seen, p_ts), p_ts),
          last_seen = greatest(coalesce(restock_history.last_seen, p_ts), p_ts),
          average_quantity = case
            when v_item_stock is null then restock_history.average_quantity
            when restock_history.average_quantity is null then v_item_stock
            else round((restock_history.average_quantity + v_item_stock) / 2, 2)
          end,
          last_quantity = coalesce(v_item_stock, restock_history.last_quantity)
      returning total_occurrences, first_seen, last_seen, average_quantity
      into v_new_total, v_first_seen_ts, v_last_seen_ts, v_avg_qty;

    if v_new_total is not null and v_new_total > 1 and v_first_seen_ts is not null and v_last_seen_ts is not null then
      v_interval_ms := greatest(1, round((v_last_seen_ts - v_first_seen_ts) / (v_new_total - 1))::bigint);
      if v_last_seen_ts > v_first_seen_ts then
        v_rate := round((v_new_total / ((v_last_seen_ts - v_first_seen_ts) / 86400000.0))::numeric, 2);
      else
        v_rate := null;
      end if;
      update restock_history
        set average_interval_ms = v_interval_ms,
            estimated_next_timestamp = v_last_seen_ts + v_interval_ms,
            rate_per_day = v_rate
      where restock_history.item_id = v_item_id and restock_history.shop_type = p_shop_type;
    end if;
  end loop;
end;
$$;
