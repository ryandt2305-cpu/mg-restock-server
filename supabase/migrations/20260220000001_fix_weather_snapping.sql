-- Fix weather event snapping intervals
--
-- Problem: weather events were snapped to 6-hour (Rain/Snow) and 4-hour (Dawn/AmberMoon)
-- blocks. This made last_seen timestamps hours off from reality, so the frontend's
-- 5-minute "Active Now" window check was mathematically impossible to satisfy.
-- It also made rate_per_day wildly inaccurate (collapsing many events into one block).
--
-- Fix: snap to event-duration-aligned intervals:
--   Rain/Snow/Frost: 5-minute events  → snap to 300s blocks, gap > 300s = new occurrence
--   Dawn/AmberMoon:  10-minute events → snap to 600s blocks, gap > 600s = new occurrence
--
-- Also: remove the Dawn fixed-time-slot formula from the weather_predictions view.
-- Dawn no longer uses a hardcoded 4-hour UTC schedule; all weathers now use the same
-- rolling-average formula driven by real observed data.

-- ============================================================
-- 1. Rebuild function: correct snap intervals and gap thresholds
-- ============================================================
CREATE OR REPLACE FUNCTION rebuild_weather_history()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  TRUNCATE TABLE weather_history;

  WITH raw_events AS (
    SELECT
      CASE
        WHEN weather_id IN ('Dawn', 'AmberMoon', 'dawn', 'ambermoon') THEN
          -- Snap to nearest 10-minute (600s) block — matches Dawn's event duration
          to_timestamp(ROUND(extract(epoch from to_timestamp(timestamp/1000.0)) / 600) * 600)
        ELSE
          -- Snap to nearest 5-minute (300s) block — matches Rain's event duration
          to_timestamp(ROUND(extract(epoch from to_timestamp(timestamp/1000.0)) / 300) * 300)
      END AS snapped_time,
      timestamp AS original_ts,
      CASE
        WHEN weather_id = 'Frost'                THEN 'Snow'
        WHEN weather_id IS NULL OR weather_id = '' THEN 'Sunny'
        ELSE weather_id
      END AS normalized_weather_id
    FROM weather_events
  ),
  -- One row per (weather_id, snapped_time) — prevents simultaneous reports from the
  -- same event inflating the occurrence count.
  per_weather_blocks AS (
    SELECT DISTINCT ON (normalized_weather_id, extract(epoch from snapped_time)::bigint)
      extract(epoch from snapped_time)::bigint * 1000 AS timestamp,
      normalized_weather_id
    FROM raw_events
    ORDER BY
      normalized_weather_id,
      extract(epoch from snapped_time)::bigint ASC,
      original_ts DESC
  ),
  -- Detect new occurrences via timestamp gaps.
  -- Consecutive blocks of the same weather = one continuous event.
  -- A gap larger than one snap interval signals a new, distinct event.
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
    WHERE
      gap_ms IS NULL  -- first-ever occurrence for this weather_id
      OR (normalized_weather_id IN ('Dawn', 'AmberMoon') AND gap_ms > 600000)  -- > 1 ten-min block
      OR (normalized_weather_id NOT IN ('Dawn', 'AmberMoon') AND gap_ms > 300000) -- > 1 five-min block
  ),
  stats AS (
    SELECT
      normalized_weather_id AS weather_id,
      COUNT(*)              AS total_occurrences,
      MIN(timestamp)        AS first_seen,
      MAX(timestamp)        AS last_seen
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
-- 2. weather_predictions view: unified rolling-average formula
--
-- Removes the special-case fixed-slot formula for Dawn.  All weathers now use
-- the same rolling-average prediction: last_seen + average_interval, rolling
-- forward by whole intervals when overdue.
-- duration_ms stays as-is (Rain/Snow = 300 000 ms, Dawn/AmberMoon = 600 000 ms).
-- ============================================================
DROP VIEW IF EXISTS weather_predictions;
CREATE OR REPLACE VIEW weather_predictions AS
SELECT
  h.weather_id,
  h.total_occurrences,
  h.last_seen,
  h.average_interval_ms,
  CASE
    WHEN h.estimated_next_timestamp IS NULL THEN NULL
    WHEN h.estimated_next_timestamp >= (extract(epoch from now()) * 1000)::bigint THEN
      h.estimated_next_timestamp
    ELSE
      -- Roll forward by whole intervals until we land in the future
      h.estimated_next_timestamp + (
        ceil(
          ((extract(epoch from now()) * 1000) - h.estimated_next_timestamp)::numeric
          / GREATEST(h.average_interval_ms, 60000)
        ) * h.average_interval_ms
      )::bigint
  END AS estimated_next_timestamp,
  h.rate_per_day AS appearance_rate,
  -- Duration of each event — used by the frontend for display context only.
  -- "Active Now" is determined by the live /live API endpoint, not by this field.
  CASE
    WHEN h.weather_id IN ('Dawn', 'AmberMoon') THEN 600000  -- 10 minutes
    ELSE 300000                                             -- 5 minutes
  END AS duration_ms
FROM weather_history h;

-- ============================================================
-- 3. Rebuild history with the corrected snap intervals
-- ============================================================
SELECT rebuild_weather_history();
