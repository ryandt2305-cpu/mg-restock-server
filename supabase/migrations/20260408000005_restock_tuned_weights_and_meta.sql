-- Tune adaptive prediction weights from historical error and expose algorithm metadata.
--
-- Key updates:
-- 1) Add algorithm metadata table for client-visible "Estimation Algorithm Updated" markers.
-- 2) Relax rebuild filtering so rare valid items (for example MythicalEgg) are not discarded.
-- 3) Tune empirical blend weights and add Bayesian smoothing to avoid zero-probability collapse.

-- ============================================================
-- 1) Algorithm metadata
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
  'adaptive-v3-bayes8',
  now(),
  'Tuned with historical error minimization; Bayesian-smoothed empirical hazard; stronger empirical weighting.'
)
ON CONFLICT (id) DO UPDATE
SET algorithm_version = EXCLUDED.algorithm_version,
    updated_at = EXCLUDED.updated_at,
    notes = EXCLUDED.notes;

-- ============================================================
-- 2) Rebuild function fix: keep all valid canonical items
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
      AND (
        NOT is_celestial_item_id(item_id)
        OR interval_ms >= 21600000
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
-- 3) Tuned prediction view
-- ============================================================

DROP VIEW IF EXISTS public.restock_predictions;

CREATE OR REPLACE VIEW public.restock_predictions AS
WITH clock AS (
  SELECT (EXTRACT(EPOCH FROM now()) * 1000)::bigint AS now_ms
),
meta AS (
  SELECT
    algorithm_version,
    (EXTRACT(EPOCH FROM updated_at) * 1000)::bigint AS algorithm_updated_at_ms
  FROM restock_algorithm_meta
  WHERE id = 1
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
        OR val >= 21600000
      )
  ) surv ON TRUE
),
empirical AS (
  SELECT
    s.*,
    COALESCE(s.base_rate, 0.0001::numeric) AS fallback_rate,
    CASE
      WHEN s.elapsed_ms IS NULL OR s.interval_samples = 0 THEN NULL
      WHEN s.survivors <= 0 THEN 0.9999::numeric
      ELSE LEAST(
        0.9999::numeric,
        GREATEST(
          0.0001::numeric,
          (s.hits::numeric + (8.0 * COALESCE(s.base_rate, 0.0001::numeric)))
          / (s.survivors::numeric + 8.0)
        )
      )
    END AS empirical_probability
  FROM interval_stats s
),
blended AS (
  SELECT
    e.*,
    CASE
      WHEN e.is_celestial THEN LEAST(1.0::numeric, COALESCE(e.interval_samples, 0)::numeric / 10.0)
      ELSE LEAST(1.0::numeric, COALESCE(e.interval_samples, 0)::numeric / 14.0)
    END AS empirical_weight
  FROM empirical e
),
probability AS (
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
    ) AS adaptive_probability,
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
            ) * 1.2,
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
        AND q.elapsed_ms >= (q.celestial_dynamic_cap_ms * 0.8)
      THEN LEAST(
        0.9999::numeric,
        q.adaptive_probability
        + (0.9999::numeric - q.adaptive_probability)
          * (
            (q.elapsed_ms - (q.celestial_dynamic_cap_ms * 0.8))
            / GREATEST(q.celestial_dynamic_cap_ms * 0.2, q.cycle_ms)
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
  p.last_interval_ms,
  m.algorithm_version,
  m.algorithm_updated_at_ms
FROM final_probability p
CROSS JOIN meta m;

ALTER VIEW public.restock_predictions SET (security_invoker = true);
GRANT SELECT ON public.restock_predictions TO anon, authenticated;

-- Rebuild once so tuned logic uses fresh canonical history.
SELECT rebuild_restock_history();
