-- Chunked rebuild for restock_history using appearance-based model

create or replace function rebuild_restock_history_chunk(p_from bigint, p_to bigint)
returns void language plpgsql as $$
begin
  with ordered as (
    select
      id,
      shop_type,
      timestamp,
      items,
      lag(timestamp) over (partition by shop_type order by timestamp) as prev_ts
    from restock_events
    where timestamp >= p_from and timestamp < p_to
  ),
  items as (
    select
      o.shop_type,
      o.timestamp,
      o.prev_ts,
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
    min(timestamp) as first_seen,
    max(timestamp) as last_seen,
    avg(stock) filter (where stock is not null) as average_quantity,
    null::numeric as last_quantity
  from appearances
  group by item_id, shop_type
  on conflict (item_id, shop_type) do update
    set total_occurrences = restock_history.total_occurrences + excluded.total_occurrences,
        total_quantity = restock_history.total_quantity + excluded.total_quantity,
        first_seen = least(coalesce(restock_history.first_seen, excluded.first_seen), excluded.first_seen),
        last_seen = greatest(coalesce(restock_history.last_seen, excluded.last_seen), excluded.last_seen),
        average_quantity = case
          when excluded.average_quantity is null then restock_history.average_quantity
          when restock_history.average_quantity is null then excluded.average_quantity
          else round((restock_history.average_quantity + excluded.average_quantity) / 2, 2)
        end;

  update restock_history h
  set last_quantity = a.stock
  from (
    select distinct on (item_id, shop_type)
      item_id,
      shop_type,
      stock
    from appearances
    order by item_id, shop_type, timestamp desc
  ) a
  where h.item_id = a.item_id and h.shop_type = a.shop_type;
end;
$$;

create or replace function finalize_restock_history()
returns void language plpgsql as $$
begin
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
