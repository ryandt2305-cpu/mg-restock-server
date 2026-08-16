-- Weather-locked egg tracking: per-item timestamp snapping.
--
-- Problem: SnowEgg and DawnEgg can restock every 5 minutes during their
-- weather, but the system snaps all eggs to 15-minute boundaries. The
-- 3-layer dedup (edge function snap → SQL ON CONFLICT → client merge)
-- silently drops sub-15-minute restocks.
--
-- Fix: introduce per-item snap intervals. Weather-locked eggs use 5-minute
-- resolution; all other items keep their shop-level snap interval.

-- ============================================================
-- 1) Helper: is_weather_locked_egg
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_weather_locked_egg(p_item_id text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
  SELECT p_item_id IN ('SnowEgg', 'DawnEgg');
$$;

-- ============================================================
-- 2) Per-item snap timestamp function
-- ============================================================

CREATE OR REPLACE FUNCTION public.restock_item_snap_timestamp(
  p_shop_type text,
  p_item_id text,
  p_ts bigint
)
RETURNS bigint
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_shop_type = 'egg' AND is_weather_locked_egg(p_item_id)
    THEN (p_ts / 300000) * 300000    -- 5-minute snap
    ELSE restock_snap_timestamp(p_shop_type, p_ts)
  END;
$$;

-- ============================================================
-- 3) Update ingest_restock_history with per-item snapping
-- ============================================================

CREATE OR REPLACE FUNCTION public.ingest_restock_history(p_shop_type text, p_ts bigint, p_items jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  item jsonb;
  v_shop_type text;
  v_raw_item_id text;
  v_item_id text;
  v_stock numeric;

  v_snapped_ts bigint;
  v_item_snapped_ts bigint;
  v_shop_interval bigint;
  v_total_cycles bigint;

  v_new_total int;
  v_first_seen bigint;
  v_last_seen bigint;

  v_prev_last_seen bigint;
  v_recent_intervals bigint[];
  v_recent_window int := 40;

  v_last_interval_ms bigint;
  v_median_interval_ms bigint;
  v_rate numeric;
  v_interval_ms bigint;
  v_effective_interval_ms bigint;

  v_predicted_next bigint;
BEGIN
  v_shop_type := lower(COALESCE(p_shop_type, ''));
  IF v_shop_type NOT IN ('seed', 'egg', 'decor', 'tool') THEN
    RETURN;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN;
  END IF;

  -- Shop-level snap for cycle stats (unchanged).
  v_snapped_ts := restock_snap_timestamp(v_shop_type, p_ts);

  IF v_shop_type = 'seed' THEN
    v_shop_interval := 300000;
  ELSIF v_shop_type = 'egg' THEN
    v_shop_interval := 900000;
  ELSIF v_shop_type = 'decor' THEN
    v_shop_interval := 3600000;
  ELSIF v_shop_type = 'tool' THEN
    v_shop_interval := 600000;
  ELSE
    v_shop_interval := 300000;
  END IF;

  INSERT INTO shop_cycle_stats(shop_type, total_cycles, last_cycle_ts)
  VALUES (v_shop_type, 0, NULL)
  ON CONFLICT (shop_type) DO NOTHING;

  -- Increment once per new snapped cycle (shop-level).
  UPDATE shop_cycle_stats
    SET total_cycles = total_cycles + 1,
        last_cycle_ts = v_snapped_ts
  WHERE shop_type = v_shop_type
    AND (last_cycle_ts IS NULL OR v_snapped_ts > last_cycle_ts);

  SELECT scs.total_cycles
    INTO v_total_cycles
  FROM shop_cycle_stats scs
  WHERE scs.shop_type = v_shop_type;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_raw_item_id := NULLIF(TRIM(item->>'itemId'), '');
    IF v_raw_item_id IS NULL THEN
      CONTINUE;
    END IF;

    v_item_id := canonical_restock_item_id(v_shop_type, v_raw_item_id);
    IF NOT is_valid_restock_item(v_shop_type, v_item_id) THEN
      CONTINUE;
    END IF;

    v_stock := COALESCE(
      NULLIF((item->>'stock')::numeric, 0),
      NULLIF((item->>'quantity')::numeric, 0)
    );
    IF v_stock IS NULL OR v_stock <= 0 THEN
      CONTINUE;
    END IF;

    -- Per-item snap: weather-locked eggs get 5-min resolution,
    -- everything else uses the shop-level snap.
    v_item_snapped_ts := restock_item_snap_timestamp(v_shop_type, v_item_id, p_ts);

    -- Snapshot the interval-based prediction (last_seen + median/average).
    SELECT h.last_seen + COALESCE(h.median_interval_ms, h.average_interval_ms)
      INTO v_predicted_next
    FROM restock_history h
    WHERE h.item_id = v_item_id
      AND h.shop_type = v_shop_type;

    INSERT INTO restock_item_events(shop_type, item_id, timestamp, quantity, predicted_next_ms)
    VALUES (v_shop_type, v_item_id, v_item_snapped_ts, v_stock, v_predicted_next)
    ON CONFLICT (shop_type, item_id, timestamp) DO UPDATE
      SET quantity = CASE
        WHEN restock_item_events.quantity IS NULL THEN EXCLUDED.quantity
        WHEN EXCLUDED.quantity IS NULL THEN restock_item_events.quantity
        ELSE GREATEST(restock_item_events.quantity, EXCLUDED.quantity)
      END,
      predicted_next_ms = COALESCE(restock_item_events.predicted_next_ms, EXCLUDED.predicted_next_ms);

    SELECT h.last_seen, h.recent_intervals_ms
      INTO v_prev_last_seen, v_recent_intervals
    FROM restock_history h
    WHERE h.item_id = v_item_id
      AND h.shop_type = v_shop_type;

    INSERT INTO restock_history(
      item_id,
      shop_type,
      total_occurrences,
      total_quantity,
      first_seen,
      last_seen,
      average_quantity,
      last_quantity
    )
    VALUES (
      v_item_id,
      v_shop_type,
      1,
      COALESCE(v_stock, 0),
      v_item_snapped_ts,
      v_item_snapped_ts,
      v_stock,
      v_stock
    )
    ON CONFLICT (item_id, shop_type) DO UPDATE
      SET total_occurrences = restock_history.total_occurrences + 1,
          total_quantity = restock_history.total_quantity + COALESCE(v_stock, 0),
          first_seen = LEAST(COALESCE(restock_history.first_seen, v_item_snapped_ts), v_item_snapped_ts),
          last_seen = GREATEST(COALESCE(restock_history.last_seen, v_item_snapped_ts), v_item_snapped_ts),
          average_quantity = CASE
            WHEN v_stock IS NULL THEN restock_history.average_quantity
            ELSE ROUND((restock_history.total_quantity + COALESCE(v_stock, 0)) / (restock_history.total_occurrences + 1), 2)
          END,
          last_quantity = COALESCE(v_stock, restock_history.last_quantity)
    RETURNING total_occurrences, first_seen, last_seen
      INTO v_new_total, v_first_seen, v_last_seen;

    -- Appearance-rate model (global, per shop cycles).
    IF v_total_cycles IS NOT NULL AND v_total_cycles > 0 THEN
      v_rate := GREATEST(0.0001, LEAST(0.9999, ROUND(v_new_total::numeric / v_total_cycles, 4)));
      v_interval_ms := ROUND(v_shop_interval::numeric / GREATEST(v_rate, 0.0001))::bigint;
    ELSE
      v_rate := NULL;
      v_interval_ms := NULL;
    END IF;

    -- Incremental interval window for adaptive median.
    v_last_interval_ms := NULL;
    v_median_interval_ms := NULL;

    IF v_prev_last_seen IS NOT NULL AND v_item_snapped_ts > v_prev_last_seen THEN
      v_last_interval_ms := v_item_snapped_ts - v_prev_last_seen;
      v_recent_intervals := COALESCE(v_recent_intervals, ARRAY[]::bigint[]);
      v_recent_intervals := array_append(v_recent_intervals, v_last_interval_ms);

      IF array_length(v_recent_intervals, 1) > v_recent_window THEN
        v_recent_intervals := v_recent_intervals[
          (array_length(v_recent_intervals, 1) - v_recent_window + 1):array_length(v_recent_intervals, 1)
        ];
      END IF;

      -- Celestial micro-gap filter: ignore intervals < 6h for celestial items.
      IF is_celestial_item_id(v_item_id) THEN
        SELECT ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY val))::bigint
          INTO v_median_interval_ms
        FROM unnest(v_recent_intervals) AS val
        WHERE val >= 21600000; -- >= 6h
      ELSE
        SELECT ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY val))::bigint
          INTO v_median_interval_ms
        FROM unnest(v_recent_intervals) AS val
        WHERE val IS NOT NULL
          AND val > 0;
      END IF;
    END IF;

    v_effective_interval_ms := COALESCE(v_median_interval_ms, v_interval_ms);

    UPDATE restock_history h
    SET appearance_rate = COALESCE(v_rate, h.appearance_rate),
        average_interval_ms = COALESCE(v_interval_ms, h.average_interval_ms),
        last_interval_ms = COALESCE(v_last_interval_ms, h.last_interval_ms),
        recent_intervals_ms = COALESCE(v_recent_intervals, h.recent_intervals_ms),
        median_interval_ms = COALESCE(v_median_interval_ms, h.median_interval_ms),
        estimated_next_timestamp = CASE
          WHEN v_effective_interval_ms IS NOT NULL AND v_last_seen IS NOT NULL
          THEN v_last_seen + v_effective_interval_ms
          ELSE h.estimated_next_timestamp
        END,
        rate_per_day = CASE
          WHEN v_last_seen > v_first_seen
          THEN ROUND((v_new_total / ((v_last_seen - v_first_seen) / 86400000.0))::numeric, 2)
          ELSE h.rate_per_day
        END
    WHERE h.item_id = v_item_id
      AND h.shop_type = v_shop_type;
  END LOOP;
END;
$$;

-- ============================================================
-- 4) Update rebuild_restock_history with per-item snapping
-- ============================================================

CREATE OR REPLACE FUNCTION public.rebuild_restock_history()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  TRUNCATE TABLE restock_history;
  TRUNCATE TABLE restock_item_events;

  -- Shop cycle stats use shop-level snap (unchanged).
  INSERT INTO shop_cycle_stats(shop_type, total_cycles, last_cycle_ts)
  SELECT
    e.shop_type,
    COUNT(DISTINCT restock_snap_timestamp(e.shop_type, e.timestamp)) AS total_cycles,
    MAX(restock_snap_timestamp(e.shop_type, e.timestamp)) AS last_cycle_ts
  FROM restock_events e
  GROUP BY e.shop_type
  ON CONFLICT (shop_type) DO UPDATE
    SET total_cycles = EXCLUDED.total_cycles,
        last_cycle_ts = EXCLUDED.last_cycle_ts;

  -- Per-item snap: weather-locked eggs get 5-min resolution.
  WITH normalized AS (
    SELECT
      e.shop_type,
      canonical_restock_item_id(e.shop_type, NULLIF(TRIM(item->>'itemId'), '')) AS item_id,
      restock_item_snap_timestamp(
        e.shop_type,
        canonical_restock_item_id(e.shop_type, NULLIF(TRIM(item->>'itemId'), '')),
        e.timestamp
      ) AS ts,
      CASE
        WHEN (item->>'stock') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN NULLIF((item->>'stock')::numeric, 0)
        WHEN (item->>'quantity') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN NULLIF((item->>'quantity')::numeric, 0)
        ELSE NULL
      END AS qty
    FROM restock_events e
    CROSS JOIN LATERAL jsonb_array_elements(e.items) AS item
  ),
  filtered AS (
    SELECT n.*
    FROM normalized n
    WHERE n.item_id IS NOT NULL
      AND n.qty IS NOT NULL
      AND n.qty > 0
      AND is_valid_restock_item(n.shop_type, n.item_id)
  ),
  dedup AS (
    SELECT DISTINCT ON (shop_type, item_id, ts)
      shop_type,
      item_id,
      ts,
      qty
    FROM filtered
    ORDER BY shop_type, item_id, ts, qty DESC NULLS LAST
  )
  INSERT INTO restock_item_events(shop_type, item_id, timestamp, quantity)
  SELECT d.shop_type, d.item_id, d.ts, d.qty
  FROM dedup d
  ORDER BY d.shop_type, d.item_id, d.ts;

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
    e.item_id,
    e.shop_type,
    COUNT(*) AS total_occurrences,
    SUM(COALESCE(e.quantity, 0)) AS total_quantity,
    MIN(e.timestamp) AS first_seen,
    MAX(e.timestamp) AS last_seen,
    AVG(e.quantity) FILTER (WHERE e.quantity IS NOT NULL AND e.quantity > 0) AS average_quantity,
    NULL::numeric AS last_quantity
  FROM restock_item_events e
  GROUP BY e.item_id, e.shop_type;

  UPDATE restock_history h
  SET last_quantity = sub.quantity
  FROM (
    SELECT DISTINCT ON (shop_type, item_id)
      shop_type,
      item_id,
      quantity
    FROM restock_item_events
    ORDER BY shop_type, item_id, timestamp DESC
  ) sub
  WHERE h.item_id = sub.item_id
    AND h.shop_type = sub.shop_type;

  -- Celestial micro-gap filter (>= 6h) in interval stats.
  WITH intervals AS (
    SELECT
      item_id,
      shop_type,
      timestamp AS ts,
      timestamp - LAG(timestamp) OVER (PARTITION BY item_id, shop_type ORDER BY timestamp) AS interval_ms,
      ROW_NUMBER() OVER (PARTITION BY item_id, shop_type ORDER BY timestamp DESC) AS rn_desc
    FROM restock_item_events
  ),
  filtered AS (
    SELECT *
    FROM intervals
    WHERE interval_ms IS NOT NULL
      AND interval_ms > 0
      AND (NOT is_celestial_item_id(item_id) OR interval_ms >= 21600000)
  ),
  recent40 AS (
    SELECT *
    FROM filtered
    WHERE rn_desc <= 40
  ),
  recent_stats AS (
    SELECT
      item_id,
      shop_type,
      ARRAY_AGG(interval_ms ORDER BY ts ASC) AS recent_intervals_ms,
      ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY interval_ms))::bigint AS median_interval_ms,
      MAX(interval_ms) FILTER (WHERE rn_desc = 1) AS last_interval_ms
    FROM recent40
    GROUP BY item_id, shop_type
  )
  UPDATE restock_history h
  SET recent_intervals_ms = rs.recent_intervals_ms,
      median_interval_ms = rs.median_interval_ms,
      last_interval_ms = rs.last_interval_ms
  FROM recent_stats rs
  WHERE h.item_id = rs.item_id
    AND h.shop_type = rs.shop_type;

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
            WHEN 'tool' THEN 600000
            ELSE 300000
          END::numeric / LEAST(1.0, h.total_occurrences::numeric / scs.total_cycles)
        )::bigint
        ELSE NULL
      END,
      estimated_next_timestamp = CASE
        WHEN h.last_seen IS NULL THEN NULL
        WHEN h.median_interval_ms IS NOT NULL THEN h.last_seen + h.median_interval_ms
        WHEN h.average_interval_ms IS NOT NULL THEN h.last_seen + h.average_interval_ms
        ELSE NULL
      END,
      rate_per_day = CASE
        WHEN h.total_occurrences > 1
          AND h.first_seen IS NOT NULL
          AND h.last_seen IS NOT NULL
          AND h.last_seen > h.first_seen
        THEN ROUND((h.total_occurrences / ((h.last_seen - h.first_seen) / 86400000.0))::numeric, 2)
        ELSE NULL
      END
  FROM shop_cycle_stats scs
  WHERE scs.shop_type = h.shop_type;
END;
$$;

-- ============================================================
-- 5) Bump algorithm version
-- ============================================================

INSERT INTO public.restock_algorithm_meta (id, algorithm_version, updated_at, notes)
VALUES (
  1,
  'adaptive-v6-weather-locked-eggs',
  now(),
  'Per-item timestamp snapping for weather-locked eggs (SnowEgg, DawnEgg). 5-minute resolution instead of 15-minute egg shop cycle.'
)
ON CONFLICT (id) DO UPDATE
SET algorithm_version = EXCLUDED.algorithm_version,
    updated_at = EXCLUDED.updated_at,
    notes = EXCLUDED.notes;

INSERT INTO public.restock_algorithm_history (algorithm_version, updated_at, notes)
SELECT m.algorithm_version, m.updated_at, m.notes
FROM public.restock_algorithm_meta m
WHERE m.id = 1
  AND NOT EXISTS (
    SELECT 1 FROM public.restock_algorithm_history h
    WHERE h.algorithm_version = m.algorithm_version
  );

-- ============================================================
-- 6) Rebuild with per-item snapping
-- ============================================================

SELECT rebuild_restock_history();
