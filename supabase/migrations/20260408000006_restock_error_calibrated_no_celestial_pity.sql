-- Error-calibrated adaptive restock model with no celestial pity/cap behavior.
--
-- Goals:
-- 1) Remove celestial-only probability ramps/caps and model all items uniformly.
-- 2) Tune empirical/base blending from historical prediction error (MAE) in SQL.
-- 3) Keep metadata row updated so clients can display algorithm update markers.

-- ============================================================
-- 1) Metadata version bump
-- ============================================================

CREATE TABLE IF NOT EXISTS public.restock_algorithm_meta (
  id integer PRIMARY KEY CHECK (id = 1),
  algorithm_version text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  notes text
);

ALTER TABLE public.restock_algorithm_meta ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'restock_algorithm_meta'
      AND policyname = 'anon_read_restock_algorithm_meta'
  ) THEN
    CREATE POLICY "anon_read_restock_algorithm_meta"
      ON public.restock_algorithm_meta
      FOR SELECT
      TO anon
      USING (true);
  END IF;
END
$$;

GRANT SELECT ON public.restock_algorithm_meta TO anon, authenticated;

INSERT INTO public.restock_algorithm_meta (id, algorithm_version, updated_at, notes)
VALUES (
  1,
  'adaptive-v4-errorcal-no-pity',
  now(),
  'Removed celestial pity/cap influence. Blend weight is calibrated from historical interval error (MAE) with sample-size shrinkage.'
)
ON CONFLICT (id) DO UPDATE
SET algorithm_version = EXCLUDED.algorithm_version,
    updated_at = EXCLUDED.updated_at,
    notes = EXCLUDED.notes;

-- ============================================================
-- 2) Incremental ingest (uniform interval handling for all items)
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
BEGIN
  v_shop_type := lower(COALESCE(p_shop_type, ''));
  IF v_shop_type NOT IN ('seed', 'egg', 'decor') THEN
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
  ELSE
    v_shop_interval := 300000;
  END IF;

  INSERT INTO shop_cycle_stats(shop_type, total_cycles, last_cycle_ts)
  VALUES (v_shop_type, 0, NULL)
  ON CONFLICT (shop_type) DO NOTHING;

  -- Increment once per new snapped cycle.
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

    INSERT INTO restock_item_events(shop_type, item_id, timestamp, quantity)
    VALUES (v_shop_type, v_item_id, v_snapped_ts, v_stock)
    ON CONFLICT (shop_type, item_id, timestamp) DO UPDATE
      SET quantity = CASE
        WHEN restock_item_events.quantity IS NULL THEN EXCLUDED.quantity
        WHEN EXCLUDED.quantity IS NULL THEN restock_item_events.quantity
        ELSE GREATEST(restock_item_events.quantity, EXCLUDED.quantity)
      END;

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
      v_snapped_ts,
      v_snapped_ts,
      v_stock,
      v_stock
    )
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

    -- Incremental interval window for adaptive median (uniform across all items).
    v_last_interval_ms := NULL;
    v_median_interval_ms := NULL;

    IF v_prev_last_seen IS NOT NULL AND v_snapped_ts > v_prev_last_seen THEN
      v_last_interval_ms := v_snapped_ts - v_prev_last_seen;
      v_recent_intervals := COALESCE(v_recent_intervals, ARRAY[]::bigint[]);
      v_recent_intervals := array_append(v_recent_intervals, v_last_interval_ms);

      IF array_length(v_recent_intervals, 1) > v_recent_window THEN
        v_recent_intervals := v_recent_intervals[
          (array_length(v_recent_intervals, 1) - v_recent_window + 1):array_length(v_recent_intervals, 1)
        ];
      END IF;

      SELECT ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY val))::bigint
        INTO v_median_interval_ms
      FROM unnest(v_recent_intervals) AS val
      WHERE val IS NOT NULL
        AND val > 0;
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
-- 3) Rebuild path (uniform interval filtering for all items)
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
      restock_snap_timestamp(e.shop_type, e.timestamp) AS ts,
      canonical_restock_item_id(e.shop_type, NULLIF(TRIM(item->>'itemId'), '')) AS item_id,
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
-- 4) Prediction view: error-calibrated blend, no celestial special-casing
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
      'adaptive-v4-errorcal-no-pity'
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
    h.appearance_rate AS base_rate,
    h.last_seen,
    h.average_quantity,
    h.total_quantity,
    h.total_occurrences,
    h.last_interval_ms,
    h.recent_intervals_ms,
    h.average_interval_ms,
    CASE h.shop_type
      WHEN 'seed' THEN 300000::numeric
      WHEN 'egg' THEN 900000::numeric
      WHEN 'decor' THEN 3600000::numeric
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
    LEAST(
      0.9999::numeric,
      GREATEST(0.0001::numeric, COALESCE(b.base_rate, 0.0001::numeric))
    ) AS fallback_rate,
    COALESCE(
      b.median_interval_ms::numeric,
      b.average_interval_ms::numeric,
      CASE
        WHEN b.base_rate IS NOT NULL AND b.base_rate > 0
          THEN b.cycle_ms / GREATEST(b.base_rate, 0.0001::numeric)
        ELSE b.cycle_ms * 6.0
      END
    ) AS baseline_interval_ms
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
      WHEN s.survivors <= 0 THEN 0.9999::numeric
      ELSE LEAST(
        0.9999::numeric,
        GREATEST(
          0.0001::numeric,
          (s.hits::numeric + (8.0 * s.fallback_rate))
          / (s.survivors::numeric + 8.0)
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
  m.algorithm_updated_at_ms
FROM final_probability p
CROSS JOIN meta m;

ALTER VIEW public.restock_predictions SET (security_invoker = true);
GRANT SELECT ON public.restock_predictions TO anon, authenticated;

-- Rebuild once so the new uniform model uses fresh history state.
SELECT rebuild_restock_history();
