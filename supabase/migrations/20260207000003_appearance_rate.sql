-- Appearance Rate Model: rate-based predictions instead of interval-based
-- Adds shop_cycle_stats table, appearance_rate column, rewrites ingest/rebuild

-- 1. Create shop_cycle_stats table
CREATE TABLE IF NOT EXISTS shop_cycle_stats (
  shop_type text PRIMARY KEY CHECK (shop_type IN ('seed','egg','decor')),
  total_cycles bigint NOT NULL DEFAULT 0,
  last_cycle_ts bigint
);
INSERT INTO shop_cycle_stats VALUES ('seed',0,NULL),('egg',0,NULL),('decor',0,NULL)
ON CONFLICT DO NOTHING;

-- 2. Add appearance_rate column
ALTER TABLE restock_history ADD COLUMN IF NOT EXISTS appearance_rate numeric;

-- 3. Replace ingest_restock_history — rate-based model
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
  v_total_cycles bigint;
  v_shop_interval bigint;
  v_rate numeric;
  v_interval_ms bigint;
BEGIN
  v_snapped_ts := restock_snap_timestamp(p_shop_type, p_ts);

  -- Determine shop interval
  IF p_shop_type = 'seed' THEN
    v_shop_interval := 300000;
  ELSIF p_shop_type = 'egg' THEN
    v_shop_interval := 900000;
  ELSIF p_shop_type = 'decor' THEN
    v_shop_interval := 3600000;
  ELSE
    v_shop_interval := 300000;
  END IF;

  -- Check if this is a new cycle and increment counter
  UPDATE shop_cycle_stats
    SET total_cycles = total_cycles + 1,
        last_cycle_ts = v_snapped_ts
  WHERE shop_type = p_shop_type
    AND (last_cycle_ts IS NULL OR v_snapped_ts > last_cycle_ts);

  -- Read current total_cycles
  SELECT scs.total_cycles INTO v_total_cycles
  FROM shop_cycle_stats scs
  WHERE scs.shop_type = p_shop_type;

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

    -- Compute rate-based fields
    IF v_total_cycles IS NOT NULL AND v_total_cycles > 0 THEN
      v_rate := LEAST(1.0, ROUND(v_new_total::numeric / v_total_cycles, 4));
      IF v_rate > 0 THEN
        v_interval_ms := ROUND(v_shop_interval / v_rate)::bigint;
      ELSE
        v_interval_ms := NULL;
      END IF;

      UPDATE restock_history
        SET appearance_rate = v_rate,
            average_interval_ms = v_interval_ms,
            estimated_next_timestamp = CASE
              WHEN v_interval_ms IS NOT NULL AND v_last_seen IS NOT NULL
              THEN v_last_seen + v_interval_ms
              ELSE NULL
            END,
            rate_per_day = CASE
              WHEN v_last_seen > v_first_seen
              THEN ROUND((v_new_total / ((v_last_seen - v_first_seen) / 86400000.0))::numeric, 2)
              ELSE NULL
            END
      WHERE restock_history.item_id = v_item_id AND restock_history.shop_type = p_shop_type;
    END IF;
  END LOOP;
END;
$$;

-- 4. Replace rebuild_restock_history — rate-based model
CREATE OR REPLACE FUNCTION rebuild_restock_history()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  TRUNCATE TABLE restock_history;

  -- Populate shop_cycle_stats from existing events
  UPDATE shop_cycle_stats scs
  SET total_cycles = sub.cnt,
      last_cycle_ts = sub.max_ts
  FROM (
    SELECT
      e.shop_type,
      COUNT(DISTINCT restock_snap_timestamp(e.shop_type, e.timestamp)) AS cnt,
      MAX(restock_snap_timestamp(e.shop_type, e.timestamp)) AS max_ts
    FROM restock_events e
    GROUP BY e.shop_type
  ) sub
  WHERE scs.shop_type = sub.shop_type;

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

  -- Compute rate-based derived fields
  UPDATE restock_history h
  SET appearance_rate = CASE
        WHEN scs.total_cycles > 0
        THEN LEAST(1.0, ROUND(h.total_occurrences::numeric / scs.total_cycles, 4))
        ELSE NULL
      END,
      average_interval_ms = CASE
        WHEN scs.total_cycles > 0 AND h.total_occurrences > 0
        THEN ROUND(
          CASE h.shop_type
            WHEN 'seed' THEN 300000
            WHEN 'egg' THEN 900000
            WHEN 'decor' THEN 3600000
            ELSE 300000
          END::numeric
          / LEAST(1.0, h.total_occurrences::numeric / scs.total_cycles)
        )::bigint
        ELSE NULL
      END,
      estimated_next_timestamp = CASE
        WHEN scs.total_cycles > 0 AND h.total_occurrences > 0 AND h.last_seen IS NOT NULL
        THEN h.last_seen + ROUND(
          CASE h.shop_type
            WHEN 'seed' THEN 300000
            WHEN 'egg' THEN 900000
            WHEN 'decor' THEN 3600000
            ELSE 300000
          END::numeric
          / LEAST(1.0, h.total_occurrences::numeric / scs.total_cycles)
        )::bigint
        ELSE NULL
      END,
      rate_per_day = CASE
        WHEN h.total_occurrences > 1 AND h.first_seen IS NOT NULL AND h.last_seen IS NOT NULL AND h.last_seen > h.first_seen
        THEN ROUND((h.total_occurrences / ((h.last_seen - h.first_seen) / 86400000.0))::numeric, 2)
        ELSE NULL
      END
  FROM shop_cycle_stats scs
  WHERE scs.shop_type = h.shop_type;
END;
$$;
