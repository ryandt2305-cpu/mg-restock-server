-- Fix EMA accuracy: outlier filtering + conditional blend.
--
-- Two issues confirmed from production data:
--
-- 1) EMA outlier sensitivity: A single large interval (e.g. from the 20h outage)
--    wrecks EMA for ~15 observations. CropCleanser went from 600K to 10.16M EMA
--    because of one 75.6M outlier in 40 intervals.
--    Fix: skip intervals > 10x median in EMA computation.
--
-- 2) EMA/median blend is noise for common items: Carrot has EMA 3.88M vs median
--    300K (12.9x ratio) because EMA measures polling frequency, not item rarity.
--    Blending 40% of that into baseline inflates ETAs (29 min vs 5 min actual).
--    Fix: only blend EMA when EMA <= 3x median (meaningful signal).

-- ============================================================
-- 1) Update compute_ema_from_array — add outlier filtering
-- ============================================================

CREATE OR REPLACE FUNCTION public.compute_ema_from_array(
  intervals bigint[],
  alpha numeric DEFAULT 0.15,
  p_median bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  ema numeric;
  i int;
  outlier_cap bigint;
BEGIN
  IF intervals IS NULL OR cardinality(intervals) = 0 THEN
    RETURN NULL;
  END IF;

  -- Cap: skip intervals > 10x median (polling gaps / outages, not item behavior).
  -- If no median provided, compute it from the array.
  IF p_median IS NOT NULL AND p_median > 0 THEN
    outlier_cap := p_median * 10;
  ELSE
    SELECT ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY val))::bigint * 10
      INTO outlier_cap
    FROM unnest(intervals) AS val
    WHERE val IS NOT NULL AND val > 0;
  END IF;

  -- Initialize EMA with first non-outlier value.
  ema := NULL;
  FOR i IN 1..cardinality(intervals) LOOP
    IF intervals[i] IS NOT NULL AND intervals[i] > 0
       AND (outlier_cap IS NULL OR intervals[i] <= outlier_cap)
    THEN
      IF ema IS NULL THEN
        ema := intervals[i];
      ELSE
        ema := alpha * intervals[i] + (1.0 - alpha) * ema;
      END IF;
    END IF;
  END LOOP;

  IF ema IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN ROUND(ema)::bigint;
END;
$$;

-- ============================================================
-- 2) Update ingest_restock_history — outlier-aware incremental EMA
-- ============================================================

-- The live function is the 4-param version from migration 20260418000002.
-- We only change the incremental EMA block to skip outlier intervals.

CREATE OR REPLACE FUNCTION public.ingest_restock_history(
  p_shop_type text,
  p_ts bigint,
  p_items jsonb,
  p_weather_id text DEFAULT NULL
)
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
  v_prev_ema bigint;
  v_prev_median bigint;
  v_recent_window int := 40;
  v_weather_max_per_bucket int := 20;

  v_last_interval_ms bigint;
  v_median_interval_ms bigint;
  v_ema_interval_ms bigint;
  v_rate numeric;
  v_interval_ms bigint;
  v_effective_interval_ms bigint;

  v_predicted_next bigint;

  v_current_weather text;
  v_weather_intervals jsonb;
  v_weather_bucket jsonb;
  v_weather_arr bigint[];

  v_outlier_cap bigint;
BEGIN
  v_shop_type := lower(COALESCE(p_shop_type, ''));
  IF v_shop_type NOT IN ('seed', 'egg', 'decor', 'tool') THEN
    RETURN;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN;
  END IF;

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

  UPDATE shop_cycle_stats
    SET total_cycles = total_cycles + 1,
        last_cycle_ts = v_snapped_ts
  WHERE shop_type = v_shop_type
    AND (last_cycle_ts IS NULL OR v_snapped_ts > last_cycle_ts);

  SELECT scs.total_cycles
    INTO v_total_cycles
  FROM shop_cycle_stats scs
  WHERE scs.shop_type = v_shop_type;

  -- Resolve weather: prefer parameter, fall back to weather_events table.
  v_current_weather := NULLIF(TRIM(COALESCE(p_weather_id, '')), '');
  IF v_current_weather IS NULL THEN
    SELECT we.weather_id INTO v_current_weather
    FROM weather_events we
    WHERE we.timestamp <= p_ts
    ORDER BY we.timestamp DESC
    LIMIT 1;
  END IF;

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

    v_item_snapped_ts := restock_item_snap_timestamp(v_shop_type, v_item_id, p_ts);

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

    SELECT h.last_seen, h.recent_intervals_ms, h.ema_interval_ms,
           h.weather_intervals, h.median_interval_ms
      INTO v_prev_last_seen, v_recent_intervals, v_prev_ema,
           v_weather_intervals, v_prev_median
    FROM restock_history h
    WHERE h.item_id = v_item_id
      AND h.shop_type = v_shop_type;

    v_weather_intervals := COALESCE(v_weather_intervals, '{}'::jsonb);

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

    IF v_total_cycles IS NOT NULL AND v_total_cycles > 0 THEN
      v_rate := GREATEST(0.0001, LEAST(0.9999, ROUND(v_new_total::numeric / v_total_cycles, 4)));
      v_interval_ms := ROUND(v_shop_interval::numeric / GREATEST(v_rate, 0.0001))::bigint;
    ELSE
      v_rate := NULL;
      v_interval_ms := NULL;
    END IF;

    v_last_interval_ms := NULL;
    v_median_interval_ms := NULL;
    v_ema_interval_ms := NULL;

    IF v_prev_last_seen IS NOT NULL AND v_item_snapped_ts > v_prev_last_seen THEN
      v_last_interval_ms := v_item_snapped_ts - v_prev_last_seen;
      v_recent_intervals := COALESCE(v_recent_intervals, ARRAY[]::bigint[]);
      v_recent_intervals := array_append(v_recent_intervals, v_last_interval_ms);

      IF array_length(v_recent_intervals, 1) > v_recent_window THEN
        v_recent_intervals := v_recent_intervals[
          (array_length(v_recent_intervals, 1) - v_recent_window + 1):array_length(v_recent_intervals, 1)
        ];
      END IF;

      IF is_celestial_item_id(v_item_id) THEN
        SELECT ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY val))::bigint
          INTO v_median_interval_ms
        FROM unnest(v_recent_intervals) AS val
        WHERE val >= 21600000;
      ELSE
        SELECT ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY val))::bigint
          INTO v_median_interval_ms
        FROM unnest(v_recent_intervals) AS val
        WHERE val IS NOT NULL
          AND val > 0;
      END IF;

      -- Outlier-aware incremental EMA: skip intervals > 10x median.
      v_outlier_cap := COALESCE(v_median_interval_ms, v_prev_median, v_last_interval_ms) * 10;
      IF v_last_interval_ms <= v_outlier_cap THEN
        v_ema_interval_ms := CASE
          WHEN v_prev_ema IS NOT NULL
          THEN ROUND(0.15 * v_last_interval_ms + 0.85 * v_prev_ema)::bigint
          ELSE v_last_interval_ms
        END;
      ELSE
        -- Outlier: keep previous EMA unchanged.
        v_ema_interval_ms := v_prev_ema;
      END IF;

      -- Weather-stratified interval bucketing.
      IF v_current_weather IS NOT NULL AND v_last_interval_ms > 0 THEN
        v_weather_bucket := COALESCE(v_weather_intervals->v_current_weather, '[]'::jsonb);
        v_weather_bucket := v_weather_bucket || to_jsonb(v_last_interval_ms);
        IF jsonb_array_length(v_weather_bucket) > v_weather_max_per_bucket THEN
          v_weather_bucket := (
            SELECT jsonb_agg(elem)
            FROM (
              SELECT elem
              FROM jsonb_array_elements(v_weather_bucket) AS elem
              ORDER BY elem::bigint DESC
              LIMIT v_weather_max_per_bucket
            ) sub
          );
        END IF;
        v_weather_intervals := jsonb_set(v_weather_intervals, ARRAY[v_current_weather], v_weather_bucket);
      END IF;
    END IF;

    v_effective_interval_ms := COALESCE(v_median_interval_ms, v_interval_ms);

    UPDATE restock_history h
    SET appearance_rate = COALESCE(v_rate, h.appearance_rate),
        average_interval_ms = COALESCE(v_interval_ms, h.average_interval_ms),
        last_interval_ms = COALESCE(v_last_interval_ms, h.last_interval_ms),
        recent_intervals_ms = COALESCE(v_recent_intervals, h.recent_intervals_ms),
        median_interval_ms = COALESCE(v_median_interval_ms, h.median_interval_ms),
        ema_interval_ms = COALESCE(v_ema_interval_ms, h.ema_interval_ms),
        weather_intervals = v_weather_intervals,
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
-- 3) Update rebuild — pass median to compute_ema_from_array
-- ============================================================

CREATE OR REPLACE FUNCTION public.rebuild_restock_history()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  TRUNCATE TABLE restock_history;
  TRUNCATE TABLE restock_item_events;

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
      END AS qty,
      e.weather_id
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
      qty,
      weather_id
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

  -- Interval stats with celestial micro-gap filter.
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

  -- EMA from rebuilt arrays — pass median for outlier filtering.
  UPDATE restock_history
  SET ema_interval_ms = compute_ema_from_array(recent_intervals_ms, 0.15, median_interval_ms)
  WHERE recent_intervals_ms IS NOT NULL;

  -- Weather-stratified intervals from historical data.
  WITH event_weather AS (
    SELECT
      d.shop_type,
      d.item_id,
      d.ts,
      d.qty,
      COALESCE(
        d.weather_id,
        (SELECT we.weather_id FROM weather_events we WHERE we.timestamp <= d.ts ORDER BY we.timestamp DESC LIMIT 1)
      ) AS weather_id
    FROM (
      SELECT DISTINCT ON (n.shop_type, n.item_id, n.ts)
        n.shop_type, n.item_id, n.ts, n.qty, n.weather_id
      FROM (
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
            ELSE NULL
          END AS qty,
          e.weather_id
        FROM restock_events e
        CROSS JOIN LATERAL jsonb_array_elements(e.items) AS item
        WHERE e.weather_id IS NOT NULL
      ) n
      WHERE n.item_id IS NOT NULL AND n.qty IS NOT NULL AND n.qty > 0
      ORDER BY n.shop_type, n.item_id, n.ts, n.qty DESC NULLS LAST
    ) d
  ),
  weather_intervals_calc AS (
    SELECT
      ew.item_id,
      ew.shop_type,
      ew.weather_id,
      ew.ts,
      ew.ts - LAG(ew.ts) OVER (PARTITION BY ew.item_id, ew.shop_type ORDER BY ew.ts) AS interval_ms
    FROM event_weather ew
    WHERE ew.weather_id IS NOT NULL
  ),
  weather_intervals_filtered AS (
    SELECT *
    FROM weather_intervals_calc
    WHERE interval_ms IS NOT NULL
      AND interval_ms > 0
      AND (NOT is_celestial_item_id(item_id) OR interval_ms >= 21600000)
  ),
  weather_agg AS (
    SELECT
      item_id,
      shop_type,
      jsonb_object_agg(
        weather_id,
        intervals_arr
      ) AS weather_intervals
    FROM (
      SELECT
        item_id,
        shop_type,
        weather_id,
        (SELECT jsonb_agg(val ORDER BY val)
         FROM (
           SELECT interval_ms AS val
           FROM weather_intervals_filtered wif2
           WHERE wif2.item_id = wif.item_id
             AND wif2.shop_type = wif.shop_type
             AND wif2.weather_id = wif.weather_id
           ORDER BY wif2.ts DESC
           LIMIT 20
         ) sub
        ) AS intervals_arr
      FROM weather_intervals_filtered wif
      GROUP BY item_id, shop_type, weather_id
    ) grouped
    GROUP BY item_id, shop_type
  )
  UPDATE restock_history h
  SET weather_intervals = wa.weather_intervals
  FROM weather_agg wa
  WHERE h.item_id = wa.item_id
    AND h.shop_type = wa.shop_type;

  -- Rate and derived fields.
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
-- 4) Update predictions view — conditional EMA blend
-- ============================================================

DROP VIEW IF EXISTS public.restock_predictions;

CREATE OR REPLACE VIEW public.restock_predictions AS
WITH clock AS (
  SELECT (EXTRACT(EPOCH FROM now()) * 1000)::bigint AS now_ms
),
meta AS (
  SELECT
    COALESCE(
      (SELECT algorithm_version FROM restock_algorithm_meta WHERE id = 1),
      'adaptive-v8-ema-outlier'
    ) AS algorithm_version,
    COALESCE(
      (SELECT (EXTRACT(EPOCH FROM updated_at) * 1000)::bigint FROM restock_algorithm_meta WHERE id = 1),
      (EXTRACT(EPOCH FROM now()) * 1000)::bigint
    ) AS algorithm_updated_at_ms
),
base AS (
  SELECT
    h.item_id,
    h.shop_type,
    h.median_interval_ms,
    h.ema_interval_ms,
    h.appearance_rate AS base_rate,
    h.last_seen,
    h.average_quantity,
    h.total_quantity,
    h.total_occurrences,
    h.last_interval_ms,
    h.recent_intervals_ms,
    h.average_interval_ms,
    h.weather_intervals,
    CASE h.shop_type
      WHEN 'seed' THEN 300000::numeric
      WHEN 'egg' THEN 900000::numeric
      WHEN 'decor' THEN 3600000::numeric
      WHEN 'tool' THEN 600000::numeric
      ELSE 300000::numeric
    END AS cycle_ms,
    CASE
      WHEN h.last_seen IS NULL THEN NULL
      ELSE GREATEST(0::numeric, (c.now_ms - h.last_seen)::numeric)
    END AS elapsed_ms,
    c.now_ms
  FROM restock_history h
  CROSS JOIN clock c
),
interval_stats AS (
  SELECT
    b.*,
    COALESCE(cardinality(b.recent_intervals_ms), 0) AS interval_samples,
    COALESCE(surv.survivors, 0) AS survivors,
    COALESCE(surv.hits, 0) AS hits,
    -- Adaptive pseudo_n: shrinks as data grows (8 → 2)
    CASE
      WHEN COALESCE(cardinality(b.recent_intervals_ms), 0) <= 3  THEN 8.0::numeric
      WHEN COALESCE(cardinality(b.recent_intervals_ms), 0) <= 10 THEN 6.0::numeric
      WHEN COALESCE(cardinality(b.recent_intervals_ms), 0) <= 20 THEN 4.0::numeric
      ELSE GREATEST(2.0::numeric, 8.0::numeric - (COALESCE(cardinality(b.recent_intervals_ms), 0)::numeric / 10.0))
    END AS pseudo_n,
    LEAST(
      0.9999::numeric,
      GREATEST(0.0001::numeric, COALESCE(b.base_rate, 0.0001::numeric))
    ) AS fallback_rate,
    -- Conditional EMA blend: only when EMA carries real signal (within 3x of median).
    -- When EMA >> median, it's measuring polling frequency, not item behavior.
    COALESCE(
      CASE
        WHEN b.ema_interval_ms IS NOT NULL AND b.median_interval_ms IS NOT NULL
             AND b.ema_interval_ms <= b.median_interval_ms * 3
        THEN ROUND(0.4 * b.ema_interval_ms + 0.6 * b.median_interval_ms)::bigint
        ELSE COALESCE(b.median_interval_ms, b.ema_interval_ms)
      END,
      b.average_interval_ms,
      CASE
        WHEN b.base_rate IS NOT NULL AND b.base_rate > 0
          THEN (b.cycle_ms / GREATEST(b.base_rate, 0.0001::numeric))::bigint
        ELSE (b.cycle_ms * 6.0)::bigint
      END
    )::numeric AS baseline_interval_ms
  FROM base b
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) FILTER (WHERE val > b.elapsed_ms) AS survivors,
      COUNT(*) FILTER (WHERE val > b.elapsed_ms AND val <= b.elapsed_ms + b.cycle_ms) AS hits
    FROM unnest(b.recent_intervals_ms) AS val
    WHERE val IS NOT NULL
      AND val > 0
  ) surv ON TRUE
),
empirical AS (
  SELECT
    s.*,
    CASE
      WHEN s.elapsed_ms IS NULL OR s.interval_samples = 0 THEN NULL
      WHEN s.survivors <= 0 THEN
        LEAST(
          0.9999::numeric,
          GREATEST(
            s.fallback_rate,
            s.fallback_rate * LEAST(
              3.0::numeric,
              1.0::numeric + COALESCE(
                s.elapsed_ms / NULLIF(s.baseline_interval_ms, 0),
                0
              )::numeric
            )
          )
        )
      ELSE LEAST(
        0.9999::numeric,
        GREATEST(
          0.0001::numeric,
          (s.hits::numeric + (s.pseudo_n * s.fallback_rate))
          / (s.survivors::numeric + s.pseudo_n)
        )
      )
    END AS empirical_probability
  FROM interval_stats s
),
error_weight AS (
  SELECT
    e.*,
    COALESCE(w.error_tuned_weight, LEAST(0.92::numeric, GREATEST(0.08::numeric, e.interval_samples::numeric / 14.0))) AS empirical_weight
  FROM empirical e
  LEFT JOIN LATERAL (
    WITH arr AS (
      SELECT COALESCE(e.recent_intervals_ms, ARRAY[]::bigint[]) AS a
    ),
    idx AS (
      SELECT i
      FROM arr, generate_subscripts(a, 1) AS g(i)
      WHERE i >= 6
    ),
    calc AS (
      SELECT
        i,
        (SELECT AVG((arr.a[j])::numeric) FROM generate_series(GREATEST(1, i - 5), i - 1) AS j) AS empirical_pred_ms,
        (arr.a[i])::numeric AS actual_ms,
        e.baseline_interval_ms AS base_pred_ms
      FROM arr, idx
    ),
    errs AS (
      SELECT
        COUNT(*)::numeric AS n,
        AVG(ABS(actual_ms - empirical_pred_ms)) AS mae_emp,
        AVG(ABS(actual_ms - base_pred_ms)) AS mae_base
      FROM calc
      WHERE empirical_pred_ms IS NOT NULL
        AND actual_ms IS NOT NULL
        AND actual_ms > 0
        AND base_pred_ms IS NOT NULL
        AND base_pred_ms > 0
    )
    SELECT
      CASE
        WHEN n < 6 OR mae_emp IS NULL OR mae_base IS NULL THEN NULL
        ELSE LEAST(
          0.95::numeric,
          GREATEST(
            0.05::numeric,
            (mae_base / NULLIF(mae_base + mae_emp, 0))
            * (n / (n + 4.0))
          )
        )
      END AS error_tuned_weight
    FROM errs
  ) w ON TRUE
),
final_probability AS (
  SELECT
    p.*,
    LEAST(
      0.9999::numeric,
      GREATEST(
        0.0001::numeric,
        p.fallback_rate * 0.2,
        ((1.0::numeric - p.empirical_weight) * p.fallback_rate)
        + (p.empirical_weight * COALESCE(p.empirical_probability, p.fallback_rate))
      )
    ) AS current_probability
  FROM error_weight p
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
  GREATEST(
    p.now_ms + p.cycle_ms::bigint,
    CASE
      WHEN p.last_seen IS NULL THEN p.now_ms + p.cycle_ms::bigint
      WHEN p.baseline_interval_ms IS NULL THEN p.now_ms + p.cycle_ms::bigint
      WHEN (p.last_seen + p.baseline_interval_ms::bigint) >= p.now_ms
      THEN p.last_seen + p.baseline_interval_ms::bigint
      ELSE p.now_ms + (p.cycle_ms / GREATEST(p.current_probability, 0.0001::numeric))::bigint
    END
  ) AS estimated_next_timestamp,
  p.baseline_interval_ms::bigint AS expected_interval_ms,
  p.last_interval_ms,
  m.algorithm_version,
  m.algorithm_updated_at_ms,
  p.recent_intervals_ms,
  p.empirical_weight,
  p.empirical_probability,
  p.fallback_rate,
  p.baseline_interval_ms,
  p.ema_interval_ms,
  p.weather_intervals
FROM final_probability p
CROSS JOIN meta m;

ALTER VIEW public.restock_predictions SET (security_invoker = true);
GRANT SELECT ON public.restock_predictions TO anon, authenticated;

-- ============================================================
-- 5) Bump algorithm version
-- ============================================================

INSERT INTO public.restock_algorithm_meta (id, algorithm_version, updated_at, notes)
VALUES (
  1,
  'adaptive-v8-ema-outlier',
  now(),
  'EMA outlier filter (skip >10x median). Conditional EMA/median blend (only when EMA <= 3x median). Prevents polling gaps from inflating baselines.'
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
-- 6) Rebuild with new EMA logic
-- ============================================================

SELECT rebuild_restock_history();
