
-- Fix for Celestial Pity Fallback when Median is NULL
-- This prevents "now" predictions for items clearly on 11d cycles but with sparse history.

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

  -- Calculate Median Intervals
  WITH item_intervals AS (
    SELECT
      item_id,
      shop_type,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY interval_ms) AS median_ms
    FROM (
      SELECT
        (item->>'itemId')::text AS item_id,
        e.shop_type,
        e.timestamp - LAG(e.timestamp) OVER (PARTITION BY (item->>'itemId')::text, e.shop_type ORDER BY e.timestamp) AS interval_ms
      FROM restock_events e
      CROSS JOIN LATERAL jsonb_array_elements(e.items) AS item
      WHERE (item->>'itemId') IS NOT NULL
    ) sub
    WHERE interval_ms IS NOT NULL
    GROUP BY item_id, shop_type
  )
  UPDATE restock_history h
  SET median_interval_ms = ii.median_ms
  FROM item_intervals ii
  WHERE h.item_id = ii.item_id AND h.shop_type = ii.shop_type;

  -- Compute rate-based derived fields with clamping
  UPDATE restock_history h
  SET appearance_rate = CASE
        WHEN scs.total_cycles > 0
        THEN GREATEST(0.0001, LEAST(0.9999, ROUND(h.total_occurrences::numeric / scs.total_cycles, 4)))
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
        -- 1. Median exists (Ideal)
        WHEN h.median_interval_ms IS NOT NULL AND h.last_seen IS NOT NULL
        THEN h.last_seen + h.median_interval_ms
        
        -- 2. Celestial Fallback (If Median is NULL, force ~11.5 days)
        -- Prevents "Now" logic on sparse data
        WHEN h.item_id IN ('Starweaver', 'StarweaverPod', 'MoonCelestial', 'Moonbinder', 'MoonbinderPod', 'DawnCelestial', 'Dawnbinder', 'DawnbinderPod', 'SunCelestial') AND h.last_seen IS NOT NULL
        THEN h.last_seen + 993600000::bigint
        
        -- 3. Average Fallback (Standard Logic)
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

SELECT rebuild_restock_history();
