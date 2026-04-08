-- Fix AmberMoon deduplication + Unified prediction model
--
-- Issues fixed:
-- 1. AmberMoon: PARTITION BY weather_id in change detection meant weather_id never
--    "changed" within partition → only 1 event counted. Fix: use timestamp gaps.
-- 2. Celestial predictions: replace transition model + overdue combo with ONE formula:
--    - Not overdue: last_seen + median (same as normal items)
--    - Overdue normal: now + cycle/rate (geometric memoryless, proven correct)
--    - Overdue celestial: now + median * (22d - elapsed) / 22d (linear decay to cap)
--    This is smooth, data-driven, and uses median as the single estimator.

-- ============================================================
-- 1. Fix weather rebuild: use timestamp gaps for occurrence detection
-- ============================================================
CREATE OR REPLACE FUNCTION rebuild_weather_history()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  TRUNCATE TABLE weather_history;

  WITH raw_events AS (
    SELECT
      CASE
        WHEN weather_id IN ('Dawn', 'AmberMoon', 'dawn', 'ambermoon') THEN
          to_timestamp(ROUND(extract(epoch from to_timestamp(timestamp/1000.0)) / 14400) * 14400)
        WHEN weather_id IN ('Rain', 'Snow', 'Thunderstorm', 'rain', 'snow', 'frost', 'thunderstorm') THEN
          to_timestamp(ROUND(extract(epoch from to_timestamp(timestamp/1000.0)) / 21600) * 21600)
        ELSE
          to_timestamp(timestamp/1000.0)
      END AS snapped_time,
      timestamp AS original_ts,
      CASE
        WHEN weather_id = 'Frost' THEN 'Snow'
        WHEN weather_id IS NULL OR weather_id = '' THEN 'Sunny'
        ELSE weather_id
      END AS normalized_weather_id
    FROM weather_events
  ),
  -- One entry per (weather_id, snapped_time) — prevents Dawn/AmberMoon clobbering
  per_weather_blocks AS (
    SELECT DISTINCT ON (normalized_weather_id, extract(epoch from snapped_time)::bigint)
      extract(epoch from snapped_time)::bigint * 1000 AS timestamp,
      normalized_weather_id
    FROM raw_events
    ORDER BY normalized_weather_id, extract(epoch from snapped_time)::bigint ASC, original_ts DESC
  ),
  -- Detect new occurrences: gap > 1 snap interval means a new event
  -- (consecutive blocks of same weather = one continuous event)
  with_gaps AS (
    SELECT
      timestamp,
      normalized_weather_id,
      timestamp - LAG(timestamp) OVER (
        PARTITION BY normalized_weather_id ORDER BY timestamp ASC
      ) AS gap_ms
    FROM per_weather_blocks
  ),
  event_starts AS (
    SELECT timestamp, normalized_weather_id
    FROM with_gaps
    WHERE gap_ms IS NULL  -- first ever occurrence
       OR (normalized_weather_id IN ('Dawn', 'AmberMoon') AND gap_ms > 14400000)   -- > 1 four-hour block
       OR (normalized_weather_id NOT IN ('Dawn', 'AmberMoon') AND gap_ms > 21600000) -- > 1 six-hour block
  ),
  stats AS (
    SELECT
      normalized_weather_id AS weather_id,
      COUNT(*) AS total_occurrences,
      MIN(timestamp) AS first_seen,
      MAX(timestamp) AS last_seen
    FROM event_starts
    GROUP BY normalized_weather_id
  )
  INSERT INTO weather_history (
    weather_id, total_occurrences, first_seen, last_seen,
    average_interval_ms, estimated_next_timestamp, rate_per_day
  )
  SELECT
    s.weather_id,
    s.total_occurrences,
    s.first_seen,
    s.last_seen,
    CASE
      WHEN s.total_occurrences > 1
      THEN GREATEST(1, ROUND((s.last_seen - s.first_seen) / (s.total_occurrences - 1))::bigint)
      ELSE NULL
    END AS average_interval_ms,
    CASE
      WHEN s.total_occurrences > 1
      THEN s.last_seen + GREATEST(1, ROUND((s.last_seen - s.first_seen) / (s.total_occurrences - 1))::bigint)
      ELSE NULL
    END AS estimated_next_timestamp,
    CASE
      WHEN s.total_occurrences > 1 AND s.last_seen > s.first_seen
      THEN ROUND((s.total_occurrences / ((s.last_seen - s.first_seen) / 86400000.0))::numeric, 2)
      ELSE NULL
    END AS rate_per_day
  FROM stats s;
END;
$$;

-- ============================================================
-- 2. Fix weather_predictions view: AmberMoon gets real predictions
-- ============================================================
DROP VIEW IF EXISTS weather_predictions;
CREATE OR REPLACE VIEW weather_predictions AS
SELECT
  h.weather_id,
  h.total_occurrences,
  h.last_seen,
  h.average_interval_ms,
  CASE
    WHEN h.weather_id = 'Dawn' THEN
      (ceil(extract(epoch from now()) / 14400.0) * 14400)::bigint * 1000
    ELSE
      CASE
        WHEN h.estimated_next_timestamp >= (extract(epoch from now()) * 1000)::bigint THEN
          h.estimated_next_timestamp
        ELSE
          h.estimated_next_timestamp + (
            ceil(
              ((extract(epoch from now()) * 1000) - h.estimated_next_timestamp)::numeric / GREATEST(h.average_interval_ms, 60000)
            ) * h.average_interval_ms
          )::bigint
      END
  END AS estimated_next_timestamp,
  h.rate_per_day AS appearance_rate,
  CASE
    WHEN h.weather_id IN ('AmberMoon', 'Dawn') THEN 600000
    ELSE 300000
  END AS duration_ms
FROM weather_history h;

-- ============================================================
-- 3. Unified restock prediction model
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

    CASE h.shop_type
      WHEN 'seed' THEN 300000
      WHEN 'egg' THEN 900000
      WHEN 'decor' THEN 3600000
      ELSE 300000
    END::numeric AS cycle_ms,

    -- Days since last seen
    (EXTRACT(EPOCH FROM (now() - to_timestamp(h.last_seen / 1000.0))) / 86400) AS days_since,

    -- Baseline interval (median preferred)
    COALESCE(h.median_interval_ms, h.average_interval_ms) AS baseline_interval_ms,

    -- Is this a celestial item?
    CASE WHEN h.item_id IN (
      'Starweaver', 'StarweaverPod', 'MoonCelestial', 'Moonbinder',
      'MoonbinderPod', 'DawnCelestial', 'Dawnbinder', 'DawnbinderPod', 'SunCelestial'
    ) THEN true ELSE false END AS is_celestial

  FROM restock_history h
),
with_probability AS (
  SELECT
    c.*,

    -- Probability display: graduated pity ramp for celestials
    CASE
      WHEN c.is_celestial AND c.days_since >= 22 THEN 0.9999
      WHEN c.is_celestial AND c.days_since >= 15 THEN LEAST(0.9999,
        COALESCE(c.base_rate, 0.0001) + (0.9999 - COALESCE(c.base_rate, 0.0001)) * ((c.days_since - 15.0) / 7.0)
      )
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

  -- UNIFIED PREDICTION MODEL
  -- One formula, minimal special-casing
  GREATEST(
    -- Floor: always at least one cycle in the future
    (EXTRACT(EPOCH FROM now()) * 1000)::bigint + p.cycle_ms::bigint,

    CASE
      -- No baseline data: predict next cycle
      WHEN p.baseline_interval_ms IS NULL
      THEN (EXTRACT(EPOCH FROM now()) * 1000)::bigint + p.cycle_ms::bigint

      -- NOT OVERDUE: predict last_seen + median (same for all items)
      WHEN (p.last_seen + p.baseline_interval_ms) >= (EXTRACT(EPOCH FROM now()) * 1000)::bigint
      THEN p.last_seen + p.baseline_interval_ms

      -- OVERDUE CELESTIAL: linear decay of median toward 22-day cap
      -- remaining = median × (22d - elapsed) / 22d
      -- Smooth from full median at day 0 → zero at day 22
      -- At day 13.5 with median 9.9: remaining = 9.9 × 8.5/22 = 3.8d
      WHEN p.is_celestial
      THEN (EXTRACT(EPOCH FROM now()) * 1000)::bigint +
        GREATEST(
          p.cycle_ms::bigint,
          (p.baseline_interval_ms::numeric
            * GREATEST(0, (22.0 * 86400000 - (EXTRACT(EPOCH FROM now()) * 1000 - p.last_seen)))
            / (22.0 * 86400000)
          )::bigint
        )

      -- OVERDUE NORMAL: geometric memoryless (now + cycle/rate)
      -- Proven correct: CV matches sqrt(1-p) to 3 decimal places
      ELSE (EXTRACT(EPOCH FROM now()) * 1000)::bigint +
        (p.cycle_ms / GREATEST(p.current_probability, 0.0001))::bigint
    END
  ) AS estimated_next_timestamp,

  p.baseline_interval_ms AS expected_interval_ms

FROM with_probability p;

-- ============================================================
-- 4. Rebuild everything
-- ============================================================
SELECT rebuild_restock_history();
SELECT rebuild_weather_history();
