-- Weather Prediction System
-- Tracks weather patterns similar to item restocks

-- 1. Create weather_history table
CREATE TABLE IF NOT EXISTS public.weather_history (
    weather_id text PRIMARY KEY,
    total_occurrences int NOT NULL DEFAULT 0,
    first_seen bigint,
    last_seen bigint, -- Timestamp of the *start* of the last occurrence
    average_interval_ms bigint,
    rate_per_day numeric,
    estimated_next_timestamp bigint
);

-- 2. Function to rebuild weather_history from raw weather_events
CREATE OR REPLACE FUNCTION rebuild_weather_history()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  TRUNCATE TABLE weather_history;

  WITH raw_events AS (
    SELECT
      -- Snapping Logic
      CASE
        -- Lunar: Snap to nearest 4-hour block (14400s)
        WHEN weather_id IN ('Dawn', 'AmberMoon', 'dawn', 'ambermoon') THEN
          to_timestamp(ROUND(extract(epoch from to_timestamp(timestamp/1000.0)) / 14400) * 14400)
        -- Random Weather: Snap to nearest 6-hour block (21600s) based on user's "seed timer" comment
        WHEN weather_id IN ('Rain', 'Snow', 'Thunderstorm', 'rain', 'snow', 'frost', 'thunderstorm') THEN
          to_timestamp(ROUND(extract(epoch from to_timestamp(timestamp/1000.0)) / 21600) * 21600)
        ELSE
          to_timestamp(timestamp/1000.0)
      END AS snapped_time,
      
      timestamp AS original_ts,
      
      -- Consolidate Frost -> Snow, Default -> Sunny
      CASE 
        WHEN weather_id = 'Frost' THEN 'Snow'
        WHEN weather_id IS NULL OR weather_id = '' THEN 'Sunny'
        ELSE weather_id 
      END AS normalized_weather_id
    FROM weather_events
  ),
  -- Prioritize events if they snap to the same time (e.g. Rain beats Sunny)
  prioritized_events AS (
    SELECT DISTINCT ON (extract(epoch from snapped_time)::bigint)
      extract(epoch from snapped_time)::bigint * 1000 AS timestamp,
      normalized_weather_id
    FROM raw_events
    ORDER BY extract(epoch from snapped_time)::bigint ASC,
             CASE WHEN normalized_weather_id = 'Sunny' THEN 0 ELSE 1 END DESC, -- Prefer non-Sunny
             original_ts DESC -- Prefer latest report
  ),
  deduped_events AS (
    SELECT
      timestamp,
      normalized_weather_id,
      -- Detect change in weather status (Event Start)
      CASE 
        WHEN normalized_weather_id IS DISTINCT FROM LAG(normalized_weather_id) OVER (ORDER BY timestamp ASC) 
        THEN 1 
        ELSE 0 
      END AS is_new_event
    FROM prioritized_events
  ),
  event_starts AS (
    SELECT
      timestamp,
      normalized_weather_id
    FROM deduped_events
    WHERE is_new_event = 1
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
    weather_id, 
    total_occurrences, 
    first_seen, 
    last_seen,
    average_interval_ms,
    estimated_next_timestamp,
    rate_per_day
  )
  SELECT
    s.weather_id,
    s.total_occurrences,
    s.first_seen,
    s.last_seen,
    -- Calculate derived stats
    CASE
        WHEN s.total_occurrences > 1 AND s.first_seen IS NOT NULL AND s.last_seen IS NOT NULL
        THEN GREATEST(1, ROUND((s.last_seen - s.first_seen) / (s.total_occurrences - 1))::bigint)
        ELSE NULL
    END AS average_interval_ms,
    CASE
        WHEN s.total_occurrences > 1 AND s.first_seen IS NOT NULL AND s.last_seen IS NOT NULL
        THEN s.last_seen + GREATEST(1, ROUND((s.last_seen - s.first_seen) / (s.total_occurrences - 1))::bigint)
        ELSE NULL
    END AS estimated_next_timestamp,
    CASE
        WHEN s.total_occurrences > 1 AND s.first_seen IS NOT NULL AND s.last_seen IS NOT NULL AND s.last_seen > s.first_seen
        THEN ROUND((s.total_occurrences / ((s.last_seen - s.first_seen) / 86400000.0))::numeric, 2)
        ELSE NULL
    END AS rate_per_day
  FROM stats s;
  
END;
$$;

-- 3. Create view for credentials-free access (if needed) or easier querying
-- This matches the structure of restock_predictions for consistency
DROP VIEW IF EXISTS weather_predictions;
CREATE OR REPLACE VIEW weather_predictions AS
SELECT
  h.weather_id,
  h.total_occurrences,
  h.last_seen,
  h.average_interval_ms,
  -- Prediction Logic:
  -- Dawn/AmberMoon: Fixed 4-hour schedule (0, 4, 8, 12, 16, 20 UTC)
  -- Others: Last Seen + Average Interval
  CASE
    WHEN h.weather_id = 'Dawn' THEN
        -- Next 4-hour block from NOW (in milliseconds)
        (ceil(extract(epoch from now()) / 14400.0) * 14400)::bigint * 1000
    WHEN h.weather_id = 'AmberMoon' THEN
        -- Suppress prediction for AmberMoon as it shares the slot with Dawn
        NULL
  ELSE
    CASE
        WHEN h.estimated_next_timestamp >= (extract(epoch from now()) * 1000)::bigint THEN
            h.estimated_next_timestamp
        ELSE
            -- Calculate intervals passed: (NOW - ESTIMATED) / INTERVAL
            -- New EST = ESTIMATED + (IntervalsPassed + 1) * INTERVAL
            h.estimated_next_timestamp + (
                ceil(
                    ((extract(epoch from now()) * 1000) - h.estimated_next_timestamp) / GREATEST(h.average_interval_ms, 60000) -- Prevent div/0
                ) * h.average_interval_ms
            )::bigint
    END
  END AS estimated_next_timestamp,
  h.rate_per_day AS appearance_rate,
  -- Duration helper for frontend "Active Now" check
  CASE 
    WHEN h.weather_id IN ('AmberMoon', 'Dawn') THEN 600000 -- 10 mins
    ELSE 300000 -- 5 mins (Rain, Snow, Sunny, Thunderstorm)
  END AS duration_ms
FROM weather_history h;

-- 4. Initial Rebuild
SELECT rebuild_weather_history();
