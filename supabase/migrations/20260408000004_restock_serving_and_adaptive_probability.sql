-- Restock serving/performance + adaptive probability refinements.
--
-- Goals:
-- 1) Keep malformed or known-invalid shop/item pairs out of history calculations.
-- 2) Materialize canonical per-item restock events for fast, scalable detail queries.
-- 3) Blend base appearance rate with empirical conditional probability from recent intervals.
-- 4) Keep celestial handling adaptive and data-driven (no fixed pity cap constant).

-- ============================================================
-- 1) Validation helpers
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_valid_restock_item(p_shop_type text, p_item_id text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    p_item_id IS NOT NULL
    AND p_item_id ~ '^[A-Za-z][A-Za-z0-9]{1,63}$'
    -- Known stale seed-side decor artifacts.
    AND NOT (
      p_shop_type = 'seed'
      AND p_item_id IN ('StoneBirdbath', 'StoneGnome', 'WoodBirdhouse', 'WoodOwl')
    );
$$;

-- ============================================================
-- 2) Canonical item-event table for scalable detail windows
-- ============================================================

CREATE TABLE IF NOT EXISTS public.restock_item_events (
  shop_type text NOT NULL CHECK (shop_type IN ('seed', 'egg', 'decor')),
  item_id text NOT NULL,
  timestamp bigint NOT NULL,
  quantity numeric,
  PRIMARY KEY (shop_type, item_id, timestamp)
);

CREATE INDEX IF NOT EXISTS restock_item_events_shop_item_ts_idx
  ON public.restock_item_events (shop_type, item_id, "timestamp" DESC);

ALTER TABLE public.restock_item_events ENABLE ROW LEVEL SECURITY;

-- RPC used by clients for per-item restock history lookups.
CREATE OR REPLACE FUNCTION public.get_item_restock_events(
  p_shop_type text,
  p_item_id text,
  p_limit integer DEFAULT 35
)
RETURNS TABLE(
  event_ts bigint,
  quantity numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH params AS (
    SELECT
      lower(COALESCE(p_shop_type, '')) AS shop_type,
      canonical_restock_item_id(lower(COALESCE(p_shop_type, '')), p_item_id) AS item_id,
      GREATEST(5, LEAST(COALESCE(p_limit, 35), 100)) AS row_limit
  )
  SELECT e.timestamp AS event_ts, e.quantity
  FROM restock_item_events e
  JOIN params p
    ON e.shop_type = p.shop_type
   AND e.item_id = p.item_id
  ORDER BY e.timestamp DESC
  LIMIT (SELECT row_limit FROM params);
$$;

GRANT EXECUTE ON FUNCTION public.get_item_restock_events(text, text, integer) TO anon, authenticated;

-- ============================================================
-- 3) Incremental ingest with canonical events + validation
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

    -- Incremental interval window for adaptive median.
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

      -- Robustness: ignore clearly duplicated micro-gaps for celestials.
      IF is_celestial_item_id(v_item_id) THEN
        SELECT ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY val))::bigint
          INTO v_median_interval_ms
        FROM unnest(v_recent_intervals) AS val
        WHERE val >= 21600000; -- >= 6h
      ELSE
        SELECT ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY val))::bigint
          INTO v_median_interval_ms
        FROM unnest(v_recent_intervals) AS val;
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
-- 4) Rebuild path now materializes canonical item events
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
      END AS qty,
      e.source
    FROM restock_events e
    CROSS JOIN LATERAL jsonb_array_elements(e.items) AS item
  ),
  trusted_pairs AS (
    SELECT DISTINCT n.shop_type, n.item_id
    FROM normalized n
    WHERE n.source = 'mg-api'
      AND n.item_id IS NOT NULL
      AND n.qty IS NOT NULL
      AND n.qty > 0
      AND is_valid_restock_item(n.shop_type, n.item_id)
  ),
  filtered AS (
    SELECT n.*
    FROM normalized n
    WHERE n.item_id IS NOT NULL
      AND n.qty IS NOT NULL
      AND n.qty > 0
      AND is_valid_restock_item(n.shop_type, n.item_id)
      AND (
        NOT EXISTS (SELECT 1 FROM trusted_pairs)
        OR EXISTS (
          SELECT 1
          FROM trusted_pairs tp
          WHERE tp.shop_type = n.shop_type
            AND tp.item_id = n.item_id
        )
      )
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

  -- last_quantity from latest canonical event per item/shop
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

  -- Interval stats: recent window + robust celestial filtering
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
      AND (
        NOT is_celestial_item_id(item_id)
        OR interval_ms >= 21600000 -- >= 6h for celestial robustness
      )
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

  -- Rate and derived fields
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
-- 5) Adaptive prediction view (empirical conditional + base blend)
-- ============================================================

DROP VIEW IF EXISTS public.restock_predictions;

CREATE OR REPLACE VIEW public.restock_predictions AS
WITH clock AS (
  SELECT (EXTRACT(EPOCH FROM now()) * 1000)::bigint AS now_ms
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

    is_celestial_item_id(h.item_id) AS is_celestial,

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
    surv.p95_interval_ms,
    surv.max_interval_ms
  FROM base b
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) FILTER (WHERE val > b.elapsed_ms) AS survivors,
      COUNT(*) FILTER (WHERE val > b.elapsed_ms AND val <= b.elapsed_ms + b.cycle_ms) AS hits,
      ROUND(percentile_cont(0.95) WITHIN GROUP (ORDER BY val))::numeric AS p95_interval_ms,
      MAX(val)::numeric AS max_interval_ms
    FROM unnest(b.recent_intervals_ms) AS val
    WHERE val IS NOT NULL
      AND (
        NOT b.is_celestial
        OR val >= 21600000 -- ignore micro-gaps for celestial items
      )
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
        GREATEST(0.0001::numeric, s.hits::numeric / GREATEST(s.survivors::numeric, 1::numeric))
      )
    END AS empirical_probability
  FROM interval_stats s
),
blended AS (
  SELECT
    e.*,
    LEAST(1.0::numeric, COALESCE(e.interval_samples, 0)::numeric / 24.0) AS empirical_weight,
    COALESCE(e.base_rate, 0.0001::numeric) AS fallback_rate
  FROM empirical e
),
probability AS (
  SELECT
    p.*,
    LEAST(
      0.9999::numeric,
      GREATEST(
        0.0001::numeric,
        ((1.0::numeric - p.empirical_weight) * p.fallback_rate)
        + (p.empirical_weight * COALESCE(p.empirical_probability, p.fallback_rate))
      )
    ) AS adaptive_probability,
    -- Data-driven celestial envelope:
    -- baseline = central tendency
    -- dynamic cap = high quantile / recent max expansion (no fixed-day constant)
    CASE
      WHEN p.is_celestial
      THEN COALESCE(
        p.median_interval_ms::numeric,
        p.last_interval_ms::numeric,
        p.average_interval_ms::numeric
      )
      ELSE COALESCE(p.median_interval_ms::numeric, p.average_interval_ms::numeric)
    END AS baseline_interval_ms,
    CASE
      WHEN p.is_celestial THEN
        CASE
          WHEN COALESCE(
            p.median_interval_ms::numeric,
            p.last_interval_ms::numeric,
            p.average_interval_ms::numeric
          ) IS NULL THEN NULL
          ELSE GREATEST(
            COALESCE(
              p.median_interval_ms::numeric,
              p.last_interval_ms::numeric,
              p.average_interval_ms::numeric
            ) * 1.25,
            COALESCE(
              p.p95_interval_ms,
              COALESCE(
                p.median_interval_ms::numeric,
                p.last_interval_ms::numeric,
                p.average_interval_ms::numeric
              ) * 1.75
            ),
            COALESCE(
              p.max_interval_ms,
              COALESCE(
                p.median_interval_ms::numeric,
                p.last_interval_ms::numeric,
                p.average_interval_ms::numeric
              ) * 1.75
            )
          )
        END
      ELSE NULL
    END AS celestial_dynamic_cap_ms
  FROM blended p
),
final_probability AS (
  SELECT
    q.*,
    CASE
      WHEN q.is_celestial
        AND q.elapsed_ms IS NOT NULL
        AND q.celestial_dynamic_cap_ms IS NOT NULL
        AND q.elapsed_ms >= q.celestial_dynamic_cap_ms
      THEN 0.9999::numeric

      WHEN q.is_celestial
        AND q.elapsed_ms IS NOT NULL
        AND q.celestial_dynamic_cap_ms IS NOT NULL
        AND q.elapsed_ms >= (q.celestial_dynamic_cap_ms * 0.75)
      THEN LEAST(
        0.9999::numeric,
        q.adaptive_probability
        + (0.9999::numeric - q.adaptive_probability)
          * (
            (q.elapsed_ms - (q.celestial_dynamic_cap_ms * 0.75))
            / GREATEST(q.celestial_dynamic_cap_ms * 0.25, q.cycle_ms)
          )
      )

      ELSE q.adaptive_probability
    END AS current_probability
  FROM probability q
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

      WHEN p.is_celestial THEN
        CASE
          WHEN (p.last_seen + p.baseline_interval_ms::bigint) >= p.now_ms
          THEN p.last_seen + p.baseline_interval_ms::bigint
          WHEN p.celestial_dynamic_cap_ms IS NULL
          THEN p.now_ms + GREATEST(p.cycle_ms::bigint, p.baseline_interval_ms::bigint)
          ELSE p.now_ms + GREATEST(
            p.cycle_ms::bigint,
            (
              p.baseline_interval_ms
              * GREATEST(0::numeric, (p.celestial_dynamic_cap_ms - p.elapsed_ms))
              / GREATEST(p.celestial_dynamic_cap_ms, p.cycle_ms)
            )::bigint
          )
        END

      WHEN (p.last_seen + p.baseline_interval_ms::bigint) >= p.now_ms
      THEN p.last_seen + p.baseline_interval_ms::bigint

      ELSE p.now_ms + (p.cycle_ms / GREATEST(p.current_probability, 0.0001::numeric))::bigint
    END
  ) AS estimated_next_timestamp,

  p.baseline_interval_ms::bigint AS expected_interval_ms,
  p.last_interval_ms
FROM final_probability p;

-- ============================================================
-- 6) One-time rebuild for canonical event table + fresh predictions
-- ============================================================

SELECT rebuild_restock_history();
