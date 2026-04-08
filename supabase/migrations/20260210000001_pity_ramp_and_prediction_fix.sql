-- Graduated Celestial Pity Ramp + Stable Overdue Predictions
--
-- Changes:
-- 1. Pity ramp: linear interpolation from base_rate (day 15) to 0.9999 (day 22)
--    instead of flat 5x jump at day 15
-- 2. Celestial fallback: 22 days (confirmed max) instead of arbitrary 11.5 days
-- 3. Overdue prediction: anchored to last_seen, not drifting with now()

-- ============================================================
-- 1. Update rebuild_restock_history() with 22-day celestial fallback
-- ============================================================
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

        -- 2. Celestial Fallback: 22 days (confirmed max pity timer per item)
        WHEN h.item_id IN ('Starweaver', 'StarweaverPod', 'MoonCelestial', 'Moonbinder', 'MoonbinderPod', 'DawnCelestial', 'Dawnbinder', 'DawnbinderPod', 'SunCelestial') AND h.last_seen IS NOT NULL
        THEN h.last_seen + 1900800000::bigint

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

-- ============================================================
-- 2. Recreate restock_predictions view with graduated pity ramp
--    and stable overdue predictions
-- ============================================================
DROP VIEW IF EXISTS restock_predictions;

CREATE OR REPLACE VIEW restock_predictions AS
WITH calculations AS (
  SELECT
    h.item_id,
    h.shop_type,
    h.median_interval_ms,
    h.appearance_rate AS base_rate,
    h.last_seen,
    h.average_quantity,
    h.total_quantity,
    h.total_occurrences,

    -- Cycle Time Helper
    CASE h.shop_type
      WHEN 'seed' THEN 300000
      WHEN 'egg' THEN 900000
      WHEN 'decor' THEN 3600000
      ELSE 300000
    END::numeric AS cycle_ms,

    -- Days since last seen
    (EXTRACT(EPOCH FROM (now() - to_timestamp(h.last_seen / 1000.0))) / 86400) AS days_since,

    -- Baseline Estimate (Median preferred, average fallback)
    COALESCE(h.median_interval_ms, h.average_interval_ms) AS baseline_interval_ms

  FROM restock_history h
),
with_probability AS (
  SELECT
    c.*,

    -- Graduated Pity Ramp (per-item, independent 22-day cap)
    CASE
      -- Hard Cap: Day 22+ = guaranteed
      WHEN c.days_since >= 22
      THEN 0.9999

      -- Graduated Ramp: Day 15-22 = linear interpolation from base_rate to 0.9999
      -- At day 15: probability = base_rate (no discontinuous jump)
      -- At day 22: probability = 0.9999 (guaranteed)
      WHEN c.days_since >= 15
      THEN LEAST(0.9999,
        COALESCE(c.base_rate, 0.0001) + (0.9999 - COALESCE(c.base_rate, 0.0001)) * ((c.days_since - 15.0) / 7.0)
      )

      -- Standard Phase: Day 0-15 = base appearance rate
      ELSE COALESCE(c.base_rate, 0.0001)
    END AS current_probability

  FROM calculations c
)
SELECT
  p.item_id,
  p.shop_type,
  p.median_interval_ms,
  p.base_rate,
  p.last_seen,
  p.current_probability,
  p.average_quantity,
  p.total_quantity,
  p.total_occurrences,

  -- Prediction Logic
  -- Always returns a FUTURE timestamp (no "Late" predictions)
  GREATEST(
    -- Floor: at minimum, predict next cycle from now
    (EXTRACT(EPOCH FROM now()) * 1000)::bigint + p.cycle_ms::bigint,

    CASE
      -- Scenario A: Overdue (now > last_seen + baseline)
      WHEN p.baseline_interval_ms IS NOT NULL
        AND (p.last_seen + p.baseline_interval_ms) < (EXTRACT(EPOCH FROM now()) * 1000)::bigint
      THEN
        -- For celestials: min(geometric wait from now, hard 22-day cap from last_seen)
        -- For normal items: geometric wait from now (memoryless)
        CASE
          WHEN p.item_id IN ('Starweaver', 'StarweaverPod', 'MoonCelestial', 'Moonbinder',
                             'MoonbinderPod', 'DawnCelestial', 'Dawnbinder', 'DawnbinderPod', 'SunCelestial')
          THEN LEAST(
            (EXTRACT(EPOCH FROM now()) * 1000)::bigint + (p.cycle_ms / GREATEST(p.current_probability, 0.0001))::bigint,
            p.last_seen + 1900800000::bigint  -- last_seen + 22 days
          )
          ELSE (EXTRACT(EPOCH FROM now()) * 1000)::bigint + (p.cycle_ms / GREATEST(p.current_probability, 0.0001))::bigint
        END

      -- Scenario B: Not overdue — median-based prediction
      WHEN p.baseline_interval_ms IS NOT NULL
      THEN (p.last_seen + p.baseline_interval_ms)

      ELSE (EXTRACT(EPOCH FROM now()) * 1000)::bigint + p.cycle_ms::bigint
    END
  ) AS estimated_next_timestamp,

  p.baseline_interval_ms AS expected_interval_ms

FROM with_probability p;

-- ============================================================
-- 3. Rebuild to apply new fallback values
-- ============================================================
SELECT rebuild_restock_history();
