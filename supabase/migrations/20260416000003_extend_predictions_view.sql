-- Extend restock_predictions view to expose model internals for client-side
-- accuracy measurement, bump algorithm version, and rebuild all shop types
-- with the restored celestial micro-gap filter.

-- ============================================================
-- 1) Recreate predictions view with exposed model internals
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
      'adaptive-v5-prediction-logged'
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
  m.algorithm_updated_at_ms,
  -- NEW: exposed model internals for client-side accuracy measurement
  p.recent_intervals_ms,
  p.empirical_weight,
  p.empirical_probability,
  p.fallback_rate,
  p.baseline_interval_ms
FROM final_probability p
CROSS JOIN meta m;

ALTER VIEW public.restock_predictions SET (security_invoker = true);
GRANT SELECT ON public.restock_predictions TO anon, authenticated;

-- ============================================================
-- 2) Algorithm version history table
-- ============================================================

CREATE TABLE IF NOT EXISTS public.restock_algorithm_history (
  id serial PRIMARY KEY,
  algorithm_version text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  notes text
);

ALTER TABLE public.restock_algorithm_history ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'restock_algorithm_history'
      AND policyname = 'restock_algorithm_history_anon_select'
  ) THEN
    CREATE POLICY restock_algorithm_history_anon_select
      ON public.restock_algorithm_history
      FOR SELECT TO anon, authenticated
      USING (true);
  END IF;
END
$$;

GRANT SELECT ON public.restock_algorithm_history TO anon, authenticated;

-- Seed with the current v4 entry before overwriting it.
INSERT INTO public.restock_algorithm_history (algorithm_version, updated_at, notes)
SELECT m.algorithm_version, m.updated_at, m.notes
FROM public.restock_algorithm_meta m
WHERE m.id = 1
  AND NOT EXISTS (
    SELECT 1 FROM public.restock_algorithm_history h
    WHERE h.algorithm_version = m.algorithm_version
      AND h.updated_at = m.updated_at
  );

-- ============================================================
-- 3) Bump algorithm version (and log to history)
-- ============================================================

INSERT INTO public.restock_algorithm_meta (id, algorithm_version, updated_at, notes)
VALUES (
  1,
  'adaptive-v5-prediction-logged',
  now(),
  'Restored celestial micro-gap filter. Added prediction logging to restock_item_events. Exposed model internals in restock_predictions view.'
)
ON CONFLICT (id) DO UPDATE
SET algorithm_version = EXCLUDED.algorithm_version,
    updated_at = EXCLUDED.updated_at,
    notes = EXCLUDED.notes;

-- Log the new version to history.
INSERT INTO public.restock_algorithm_history (algorithm_version, updated_at, notes)
SELECT m.algorithm_version, m.updated_at, m.notes
FROM public.restock_algorithm_meta m
WHERE m.id = 1
  AND NOT EXISTS (
    SELECT 1 FROM public.restock_algorithm_history h
    WHERE h.algorithm_version = m.algorithm_version
  );

-- ============================================================
-- 4) RPC to fetch algorithm version history
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_algorithm_version_history()
RETURNS TABLE(algorithm_version text, updated_at_ms bigint, notes text)
LANGUAGE sql STABLE SECURITY INVOKER
AS $$
  SELECT
    h.algorithm_version,
    (EXTRACT(EPOCH FROM h.updated_at) * 1000)::bigint AS updated_at_ms,
    h.notes
  FROM public.restock_algorithm_history h
  ORDER BY h.updated_at ASC;
$$;

GRANT EXECUTE ON FUNCTION public.get_algorithm_version_history() TO anon, authenticated;

-- ============================================================
-- 5) Rebuild all shop types with restored celestial filter
-- ============================================================

SELECT rebuild_restock_history();
