-- Fix: ETA for overdue items uses cycle/probability which grossly inflates
-- predictions for rare items (celestials, rare eggs).
--
-- Problem: When elapsed > baseline, the ELSE branch computes:
--   now + cycle_ms / current_probability
-- For MoonCelestial with 0.023% per-cycle probability, this gives 15+ days.
-- But the actual conditional mean remaining time (from observed intervals
-- that exceeded the current elapsed time) is ~5 days.
--
-- Fix: Add mean_remaining_ms to the survival lateral join and use it
-- as the overdue ETA instead of cycle/probability.

DROP VIEW IF EXISTS public.restock_predictions;

CREATE OR REPLACE VIEW public.restock_predictions AS
WITH clock AS (
  SELECT (EXTRACT(EPOCH FROM now()) * 1000)::bigint AS now_ms
),
meta AS (
  SELECT
    COALESCE(
      (SELECT algorithm_version FROM restock_algorithm_meta WHERE id = 1),
      'adaptive-v9-lifespan-rate'
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
    -- Conditional mean remaining time: E[X - elapsed | X > elapsed]
    -- Used for overdue ETA instead of cycle/probability.
    surv.mean_remaining_ms,
    -- Adaptive pseudo_n: shrinks as data grows (8 -> 2)
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
      COUNT(*) FILTER (WHERE val > b.elapsed_ms AND val <= b.elapsed_ms + b.cycle_ms) AS hits,
      -- Mean excess life: average remaining time for intervals that exceed current elapsed.
      AVG(val - b.elapsed_ms) FILTER (WHERE val > b.elapsed_ms) AS mean_remaining_ms
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
    -- Dormancy detection: item absent > 20x expected interval (min 7 days).
    CASE
      WHEN p.elapsed_ms IS NULL THEN false
      WHEN p.elapsed_ms > GREATEST(
        COALESCE(p.median_interval_ms::numeric, p.baseline_interval_ms) * 20,
        604800000::numeric
      ) THEN true
      ELSE false
    END AS is_dormant,
    -- Current probability (suppressed when dormant).
    CASE
      WHEN p.elapsed_ms IS NOT NULL AND p.elapsed_ms > GREATEST(
        COALESCE(p.median_interval_ms::numeric, p.baseline_interval_ms) * 20,
        604800000::numeric
      )
      THEN GREATEST(0.0001::numeric, p.fallback_rate * 0.1)
      ELSE LEAST(
        0.9999::numeric,
        GREATEST(
          0.0001::numeric,
          p.fallback_rate * 0.2,
          ((1.0::numeric - p.empirical_weight) * p.fallback_rate)
          + (p.empirical_weight * COALESCE(p.empirical_probability, p.fallback_rate))
        )
      )
    END AS current_probability
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
  -- Estimated next: NULL for dormant, survival-based for overdue.
  CASE
    WHEN p.is_dormant THEN NULL::bigint
    ELSE GREATEST(
      p.now_ms + p.cycle_ms::bigint,
      CASE
        WHEN p.last_seen IS NULL THEN p.now_ms + p.cycle_ms::bigint
        WHEN p.baseline_interval_ms IS NULL THEN p.now_ms + p.cycle_ms::bigint
        WHEN (p.last_seen + p.baseline_interval_ms::bigint) >= p.now_ms
        THEN p.last_seen + p.baseline_interval_ms::bigint
        -- Overdue: use conditional mean remaining time from survival analysis.
        -- Falls back to declining fraction of baseline when all intervals exceeded.
        ELSE p.now_ms + GREATEST(
          p.cycle_ms::bigint,
          COALESCE(
            p.mean_remaining_ms::bigint,
            -- All intervals exceeded: predict declining fraction of baseline.
            GREATEST(
              p.cycle_ms::bigint,
              (p.baseline_interval_ms * GREATEST(0.1,
                1.0 - (p.elapsed_ms / NULLIF(p.baseline_interval_ms * 3.0, 0))
              ))::bigint
            )
          )
        )
      END
    )
  END AS estimated_next_timestamp,
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
  p.weather_intervals,
  p.is_dormant
FROM final_probability p
CROSS JOIN meta m;

ALTER VIEW public.restock_predictions SET (security_invoker = true);
GRANT SELECT ON public.restock_predictions TO anon, authenticated;
