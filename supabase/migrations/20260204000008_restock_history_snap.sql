-- Snap restock timestamps to shop boundaries (seed 5m, egg 15m, decor 60m) + 1 minute offset

create or replace function restock_snap_timestamp(p_shop_type text, p_ts bigint)
returns bigint language plpgsql as $$
declare
  interval_ms bigint;
  snapped bigint;
begin
  if p_shop_type = 'seed' then
    interval_ms := 300000;
  elsif p_shop_type = 'egg' then
    interval_ms := 900000;
  elsif p_shop_type = 'decor' then
    interval_ms := 3600000;
  else
    interval_ms := 300000;
  end if;

  snapped := (p_ts / interval_ms) * interval_ms;
  return snapped + 60000; -- 1 minute after boundary
end;
$$;

create or replace function ingest_restock_history(p_shop_type text, p_ts bigint, p_items jsonb)
returns void language plpgsql as $$
declare
  item jsonb;
  item_id text;
  item_stock numeric;
  prev_ts bigint;
  new_total int;
  first_seen_ts bigint;
  last_seen_ts bigint;
  avg_qty numeric;
  interval_ms bigint;
  rate numeric;
  existed boolean;
  snapped_ts bigint;
begin
  select max(timestamp) into prev_ts
  from restock_events
  where shop_type = p_shop_type and timestamp < p_ts;

  snapped_ts := restock_snap_timestamp(p_shop_type, p_ts);

  for item in select * from jsonb_array_elements(p_items)
  loop
    item_id := item->>'itemId';
    if item_id is null then
      continue;
    end if;
    item_stock := nullif(coalesce((item->>'stock')::numeric, (item->>'quantity')::numeric), 0);

    if prev_ts is not null then
      select exists(
        select 1
        from restock_events e
        cross join lateral jsonb_array_elements(e.items) as it
        where e.shop_type = p_shop_type
          and e.timestamp = prev_ts
          and it->>'itemId' = item_id
        limit 1
      ) into existed;
      if existed then
        continue;
      end if;
    end if;

    insert into restock_history(item_id, shop_type, total_occurrences, total_quantity, first_seen, last_seen, average_quantity, last_quantity)
    values (item_id, p_shop_type, 1, coalesce(item_stock, 0), snapped_ts, snapped_ts, item_stock, item_stock)
    on conflict (item_id, shop_type) do update
      set total_occurrences = restock_history.total_occurrences + 1,
          total_quantity = restock_history.total_quantity + coalesce(item_stock, 0),
          first_seen = least(coalesce(restock_history.first_seen, snapped_ts), snapped_ts),
          last_seen = greatest(coalesce(restock_history.last_seen, snapped_ts), snapped_ts),
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
      where restock_history.item_id = item_id and restock_history.shop_type = p_shop_type;
    end if;
  end loop;
end;
$$;

create or replace function rebuild_restock_history()
returns void language plpgsql as $$
begin
  truncate table restock_history;

  with ordered as (
    select
      id,
      shop_type,
      timestamp,
      items,
      lag(timestamp) over (partition by shop_type order by timestamp) as prev_ts
    from restock_events
  ),
  items as (
    select
      o.shop_type,
      o.timestamp,
      o.prev_ts,
      restock_snap_timestamp(o.shop_type, o.timestamp) as snapped_ts,
      (item->>'itemId')::text as item_id,
      nullif(coalesce((item->>'stock')::numeric, (item->>'quantity')::numeric), 0) as stock
    from ordered o
    cross join lateral jsonb_array_elements(o.items) as item
  ),
  appearances as (
    select i.*
    from items i
    where i.prev_ts is null
       or not exists (
         select 1
         from restock_events e2
         cross join lateral jsonb_array_elements(e2.items) as it
         where e2.shop_type = i.shop_type
           and e2.timestamp = i.prev_ts
           and it->>'itemId' = i.item_id
         limit 1
       )
  )
  insert into restock_history (
    item_id,
    shop_type,
    total_occurrences,
    total_quantity,
    first_seen,
    last_seen,
    average_quantity,
    last_quantity
  )
  select
    item_id,
    shop_type,
    count(*) as total_occurrences,
    sum(coalesce(stock, 0)) as total_quantity,
    min(snapped_ts) as first_seen,
    max(snapped_ts) as last_seen,
    avg(stock) filter (where stock is not null) as average_quantity,
    null::numeric as last_quantity
  from appearances
  group by item_id, shop_type;

  update restock_history h
  set last_quantity = a.stock
  from (
    select distinct on (item_id, shop_type)
      item_id,
      shop_type,
      stock
    from appearances
    order by item_id, shop_type, snapped_ts desc
  ) a
  where h.item_id = a.item_id and h.shop_type = a.shop_type;

  update restock_history
  set average_interval_ms = case
        when total_occurrences > 1 and first_seen is not null and last_seen is not null
        then greatest(1, round((last_seen - first_seen) / (total_occurrences - 1))::bigint)
        else null
      end,
      estimated_next_timestamp = case
        when total_occurrences > 1 and first_seen is not null and last_seen is not null
        then last_seen + greatest(1, round((last_seen - first_seen) / (total_occurrences - 1))::bigint)
        else null
      end,
      rate_per_day = case
        when total_occurrences > 1 and first_seen is not null and last_seen is not null and last_seen > first_seen
        then round((total_occurrences / ((last_seen - first_seen) / 86400000.0))::numeric, 2)
        else null
      end;
end;
$$;
