-- Transition-Aware Celestial Prediction Model
--
-- Based on statistical analysis of 47,934 seed shop snapshots (RESTOCK_RESEARCH.md):
-- - Normal items: perfect geometric (memoryless Bernoulli) — no changes needed
-- - Celestials: hidden timer with transition-dependent behavior (joint p=0.0001)
--   * Short gaps (<5d) NEVER follow short gaps
--   * Long gaps (>13d) NEVER follow long gaps
--   * After long wait → expect medium (~7d)
--   * After short burst → expect longer (~12d)
--   * After medium → use median
--
-- Changes:
-- 1. Add last_interval_ms column to restock_history
-- 2. Populate it during rebuild_restock_history()
-- 3. Update restock_predictions view to use transition-aware logic for celestials

-- ============================================================
-- 1. Add last_interval_ms column
-- ============================================================
ALTER TABLE restock_history ADD COLUMN IF NOT EXISTS last_interval_ms bigint;

-- ============================================================
-- 2. Update rebuild_restock_history() to populate last_interval_ms
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

  -- Calculate last_interval_ms (gap between the two most recent appearances)
  WITH last_two AS (
    SELECT
      item_id,
      shop_type,
      ts,
      LAG(ts) OVER (PARTITION BY item_id, shop_type ORDER BY ts) AS prev_ts,
      ROW_NUMBER() OVER (PARTITION BY item_id, shop_type ORDER BY ts DESC) AS rn
    FROM (
      SELECT
        (item->>'itemId')::text AS item_id,
        e.shop_type,
        restock_snap_timestamp(e.shop_type, e.timestamp) AS ts
      FROM restock_events e
      CROSS JOIN LATERAL jsonb_array_elements(e.items) AS item
      WHERE (item->>'itemId') IS NOT NULL
    ) appearances
  )
  UPDATE restock_history h
  SET last_interval_ms = lt.interval_ms
  FROM (
    SELECT item_id, shop_type, (ts - prev_ts) AS interval_ms
    FROM last_two
    WHERE rn = 1 AND prev_ts IS NOT NULL
  ) lt
  WHERE h.item_id = lt.item_id AND h.shop_type = lt.shop_type;

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
-- 3. Recreate restock_predictions view with transition-aware celestials
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
    h.last_interval_ms,

    -- Cycle Time
    CASE h.shop_type
      WHEN 'seed' THEN 300000
      WHEN 'egg' THEN 900000
      WHEN 'decor' THEN 3600000
      ELSE 300000
    END::numeric AS cycle_ms,

    -- Days since last seen
    (EXTRACT(EPOCH FROM (now() - to_timestamp(h.last_seen / 1000.0))) / 86400) AS days_since,

    -- Last interval in days (for transition logic)
    CASE WHEN h.last_interval_ms IS NOT NULL
      THEN h.last_interval_ms / 86400000.0
      ELSE NULL
    END AS last_interval_days,

    -- Baseline Estimate (Median preferred, average fallback)
    COALESCE(h.median_interval_ms, h.average_interval_ms) AS baseline_interval_ms

  FROM restock_history h
),
with_probability AS (
  SELECT
    c.*,

    -- Graduated Pity Ramp (per-item, independent 22-day cap)
    CASE
      WHEN c.days_since >= 22 THEN 0.9999
      WHEN c.days_since >= 15 THEN LEAST(0.9999,
        COALESCE(c.base_rate, 0.0001) + (0.9999 - COALESCE(c.base_rate, 0.0001)) * ((c.days_since - 15.0) / 7.0)
      )
      ELSE COALESCE(c.base_rate, 0.0001)
    END AS current_probability,

    -- Transition-aware expected interval for celestials (in ms)
    -- Based on RESTOCK_RESEARCH.md Part 3 transition analysis:
    --   After short gap (<5d): expect ~12 days (long never follows short, medium/long likely)
    --   After long gap (>13d): expect ~7 days (short/medium likely, long never follows long)
    --   After medium gap (5-13d): use median (all outcomes possible)
    --   No last_interval data: use median
    CASE
      WHEN c.item_id IN ('Starweaver', 'StarweaverPod', 'MoonCelestial', 'Moonbinder',
                         'MoonbinderPod', 'DawnCelestial', 'Dawnbinder', 'DawnbinderPod', 'SunCelestial')
      THEN
        CASE
          WHEN c.last_interval_days IS NOT NULL AND c.last_interval_days < 5
          THEN 12.0 * 86400000  -- After burst: expect longer wait
          WHEN c.last_interval_days IS NOT NULL AND c.last_interval_days > 13
          THEN 7.0 * 86400000   -- After long wait: expect shorter next time
          ELSE COALESCE(c.baseline_interval_ms, 11.0 * 86400000)  -- Medium or unknown: use median
        END
      ELSE NULL  -- Not celestial, not used
    END AS celestial_expected_ms

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

  -- Prediction Logic: always returns a FUTURE timestamp
  GREATEST(
    -- Floor: at minimum, predict next cycle from now
    (EXTRACT(EPOCH FROM now()) * 1000)::bigint + p.cycle_ms::bigint,

    CASE
      -- ========== CELESTIAL ITEMS ==========
      WHEN p.item_id IN ('Starweaver', 'StarweaverPod', 'MoonCelestial', 'Moonbinder',
                         'MoonbinderPod', 'DawnCelestial', 'Dawnbinder', 'DawnbinderPod', 'SunCelestial')
      THEN
        CASE
          -- Pity zone (day 22+): must appear imminently
          WHEN p.days_since >= 22
          THEN (EXTRACT(EPOCH FROM now()) * 1000)::bigint + p.cycle_ms::bigint

          -- Pity ramp zone (day 15-22): accelerating expectation
          WHEN p.days_since >= 15
          THEN (EXTRACT(EPOCH FROM now()) * 1000)::bigint
               + ((22.0 - p.days_since) * 86400000 * 0.5)::bigint

          -- Overdue (past transition-aware expected interval, before pity zone)
          -- Celestials are MORE regular than geometric (CV 0.41-0.66 vs ~1.0)
          -- Use proportional ramp: remaining = (22 - days_since) * 0.5 days
          -- This smoothly connects to the pity ramp at day 15: (22-15)*0.5 = 3.5d
          WHEN p.celestial_expected_ms IS NOT NULL
            AND (p.last_seen + p.celestial_expected_ms::bigint) < (EXTRACT(EPOCH FROM now()) * 1000)::bigint
          THEN
            (EXTRACT(EPOCH FROM now()) * 1000)::bigint
            + ((22.0 - p.days_since) * 86400000 * 0.5)::bigint

          -- Not yet overdue: use transition-aware expected time
          WHEN p.celestial_expected_ms IS NOT NULL
          THEN LEAST(
            p.last_seen + p.celestial_expected_ms::bigint,
            p.last_seen + 1900800000::bigint  -- Never exceed 22d cap
          )

          -- Fallback: 22 days from last seen
          ELSE p.last_seen + 1900800000::bigint
        END

      -- ========== NORMAL ITEMS (geometric/memoryless) ==========
      ELSE
        CASE
          -- Overdue: geometric wait from now (memoryless property)
          WHEN p.baseline_interval_ms IS NOT NULL
            AND (p.last_seen + p.baseline_interval_ms) < (EXTRACT(EPOCH FROM now()) * 1000)::bigint
          THEN (EXTRACT(EPOCH FROM now()) * 1000)::bigint + (p.cycle_ms / GREATEST(p.current_probability, 0.0001))::bigint

          -- Not overdue: median-based prediction
          WHEN p.baseline_interval_ms IS NOT NULL
          THEN (p.last_seen + p.baseline_interval_ms)

          -- No data: next cycle
          ELSE (EXTRACT(EPOCH FROM now()) * 1000)::bigint + p.cycle_ms::bigint
        END
    END
  ) AS estimated_next_timestamp,

  p.baseline_interval_ms AS expected_interval_ms,
  p.last_interval_ms,
  p.celestial_expected_ms

FROM with_probability p;

-- ============================================================
-- 4. Rebuild to populate last_interval_ms
-- ============================================================
SELECT rebuild_restock_history();
