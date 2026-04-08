-- Restock Overhaul: clean architecture, server-side polling only
-- Drops restock_snapshots, truncates events/history, fixes functions

-- 1. Drop unused snapshots table
DROP TABLE IF EXISTS public.restock_snapshots;

-- 2. Truncate existing data (will be replaced by MagicShopkeeper seed)
TRUNCATE TABLE restock_events;
TRUNCATE TABLE restock_history;

-- 3. Fix restock_history defaults
UPDATE restock_history SET total_quantity = 0 WHERE total_quantity IS NULL;
ALTER TABLE restock_history
  ALTER COLUMN total_quantity SET NOT NULL,
  ALTER COLUMN total_quantity SET DEFAULT 0;

-- 4. Replace restock_snap_timestamp — clean, no +60000 offset
CREATE OR REPLACE FUNCTION restock_snap_timestamp(p_shop_type text, p_ts bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  interval_ms bigint;
BEGIN
  IF p_shop_type = 'seed' THEN
    interval_ms := 300000;    -- 5 minutes
  ELSIF p_shop_type = 'egg' THEN
    interval_ms := 900000;    -- 15 minutes
  ELSIF p_shop_type = 'decor' THEN
    interval_ms := 3600000;   -- 60 minutes
  ELSE
    interval_ms := 300000;    -- default: 5 minutes
  END IF;

  RETURN (p_ts / interval_ms) * interval_ms;
END;
$$;

-- 5. Replace ingest_restock_history — no appearance filter, true cumulative mean
CREATE OR REPLACE FUNCTION ingest_restock_history(p_shop_type text, p_ts bigint, p_items jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  item jsonb;
  v_item_id text;
  v_stock numeric;
  v_snapped_ts bigint;
  v_new_total int;
  v_first_seen bigint;
  v_last_seen bigint;
  v_total_qty numeric;
  v_interval_ms bigint;
  v_rate numeric;
BEGIN
  v_snapped_ts := restock_snap_timestamp(p_shop_type, p_ts);

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_item_id := item->>'itemId';
    IF v_item_id IS NULL THEN
      CONTINUE;
    END IF;
    v_stock := COALESCE(NULLIF((item->>'stock')::numeric, 0), NULLIF((item->>'quantity')::numeric, 0));

    INSERT INTO restock_history(item_id, shop_type, total_occurrences, total_quantity, first_seen, last_seen, average_quantity, last_quantity)
    VALUES (v_item_id, p_shop_type, 1, COALESCE(v_stock, 0), v_snapped_ts, v_snapped_ts, v_stock, v_stock)
    ON CONFLICT (item_id, shop_type) DO UPDATE
      SET total_occurrences = restock_history.total_occurrences + 1,
          total_quantity = restock_history.total_quantity + COALESCE(v_stock, 0),
          first_seen = LEAST(COALESCE(restock_history.first_seen, v_snapped_ts), v_snapped_ts),
          last_seen = GREATEST(COALESCE(restock_history.last_seen, v_snapped_ts), v_snapped_ts),
          average_quantity = CASE
            WHEN v_stock IS NULL THEN restock_history.average_quantity
            ELSE ROUND((restock_history.total_quantity + COALESCE(v_stock, 0)) / (restock_history.total_occurrences + 1), 2)
          END,
          last_quantity = COALESCE(v_stock, restock_history.last_quantity)
      RETURNING total_occurrences, first_seen, last_seen, total_quantity
      INTO v_new_total, v_first_seen, v_last_seen, v_total_qty;

    IF v_new_total IS NOT NULL AND v_new_total > 1 AND v_first_seen IS NOT NULL AND v_last_seen IS NOT NULL THEN
      v_interval_ms := GREATEST(1, ROUND((v_last_seen - v_first_seen) / (v_new_total - 1))::bigint);
      IF v_last_seen > v_first_seen THEN
        v_rate := ROUND((v_new_total / ((v_last_seen - v_first_seen) / 86400000.0))::numeric, 2);
      ELSE
        v_rate := NULL;
      END IF;
      UPDATE restock_history
        SET average_interval_ms = v_interval_ms,
            estimated_next_timestamp = v_last_seen + v_interval_ms,
            rate_per_day = v_rate
      WHERE restock_history.item_id = v_item_id AND restock_history.shop_type = p_shop_type;
    END IF;
  END LOOP;
END;
$$;

-- 6. Replace rebuild_restock_history — clean rebuild, no appearance filtering
CREATE OR REPLACE FUNCTION rebuild_restock_history()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  TRUNCATE TABLE restock_history;

  -- Insert aggregated data from all events
  INSERT INTO restock_history (
    item_id,
    shop_type,
    total_occurrences,
    total_quantity,
    first_seen,
    last_seen,
    average_quantity,
    last_quantity
  )
  SELECT
    (item->>'itemId')::text AS item_id,
    e.shop_type,
    COUNT(*) AS total_occurrences,
    SUM(COALESCE(NULLIF((item->>'stock')::numeric, 0), 0)) AS total_quantity,
    MIN(restock_snap_timestamp(e.shop_type, e.timestamp)) AS first_seen,
    MAX(restock_snap_timestamp(e.shop_type, e.timestamp)) AS last_seen,
    AVG(NULLIF((item->>'stock')::numeric, 0)) FILTER (WHERE (item->>'stock')::numeric IS NOT NULL AND (item->>'stock')::numeric > 0) AS average_quantity,
    NULL::numeric AS last_quantity
  FROM restock_events e
  CROSS JOIN LATERAL jsonb_array_elements(e.items) AS item
  WHERE (item->>'itemId') IS NOT NULL
  GROUP BY (item->>'itemId')::text, e.shop_type;

  -- Set last_quantity from most recent event per item
  UPDATE restock_history h
  SET last_quantity = sub.stock
  FROM (
    SELECT DISTINCT ON (item_id, shop_type)
      (item->>'itemId')::text AS item_id,
      e.shop_type,
      NULLIF((item->>'stock')::numeric, 0) AS stock
    FROM restock_events e
    CROSS JOIN LATERAL jsonb_array_elements(e.items) AS item
    WHERE (item->>'itemId') IS NOT NULL
    ORDER BY (item->>'itemId')::text, e.shop_type, e.timestamp DESC
  ) sub
  WHERE h.item_id = sub.item_id AND h.shop_type = sub.shop_type;

  -- Compute derived fields
  UPDATE restock_history
  SET average_interval_ms = CASE
        WHEN total_occurrences > 1 AND first_seen IS NOT NULL AND last_seen IS NOT NULL
        THEN GREATEST(1, ROUND((last_seen - first_seen) / (total_occurrences - 1))::bigint)
        ELSE NULL
      END,
      estimated_next_timestamp = CASE
        WHEN total_occurrences > 1 AND first_seen IS NOT NULL AND last_seen IS NOT NULL
        THEN last_seen + GREATEST(1, ROUND((last_seen - first_seen) / (total_occurrences - 1))::bigint)
        ELSE NULL
      END,
      rate_per_day = CASE
        WHEN total_occurrences > 1 AND first_seen IS NOT NULL AND last_seen IS NOT NULL AND last_seen > first_seen
        THEN ROUND((total_occurrences / ((last_seen - first_seen) / 86400000.0))::numeric, 2)
        ELSE NULL
      END
  WHERE true;
END;
$$;

-- 7. finalize_restock_history stays unchanged (already correct)
