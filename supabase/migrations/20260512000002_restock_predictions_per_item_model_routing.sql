-- Per-item model routing + weather quality gates for live restock predictions.
-- Keeps existing response contract, adds explainability/debug columns,
-- and uses selected per-item model candidates when available.

CREATE OR REPLACE VIEW public.restock_predictions AS
WITH clock AS (
  SELECT (EXTRACT(EPOCH FROM now()) * 1000)::bigint AS now_ms
),
meta AS (
  SELECT
    COALESCE(
      (SELECT algorithm_version FROM restock_algorithm_meta WHERE id = 1),
      'adaptive-v12-per-item-routing'
    ) AS algorithm_version,
    COALESCE(
      (SELECT (EXTRACT(EPOCH FROM updated_at) * 1000)::bigint FROM restock_algorithm_meta WHERE id = 1),
      (EXTRACT(EPOCH FROM now()) * 1000)::bigint
    ) AS algorithm_updated_at_ms
),
current_weather AS (
  -- Always returns exactly one row. Falls back to NULL when no weather data.
  SELECT (SELECT weather_id FROM weather_events ORDER BY "timestamp" DESC LIMIT 1) AS weather_id
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
    c.now_ms,
    wm.weather_median_ms,
    wm.weather_samples,
    cw.weather_id AS current_weather,
    sm.model_name AS selected_model_name,
    sm.test_events AS selected_model_test_events,
    sm.within_one_cycle_pct AS selected_model_within_one_cycle_pct
  FROM restock_history h
  CROSS JOIN clock c
  CROSS JOIN current_weather cw
  LEFT JOIN LATERAL (
    SELECT
      (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v::double precision))::numeric AS weather_median_ms,
      COUNT(*)::int AS weather_samples
    FROM jsonb_array_elements_text(
      CASE
        WHEN cw.weather_id IS NOT NULL
             AND h.weather_intervals IS NOT NULL
             AND jsonb_typeof(h.weather_intervals) = 'object'
             AND h.weather_intervals ? cw.weather_id
        THEN h.weather_intervals -> cw.weather_id
        ELSE NULL
      END
    ) AS v
    WHERE v::bigint > 0
  ) wm ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      s.model_name,
      s.test_events,
      s.within_one_cycle_pct
    FROM public.restock_item_selected_models s
    WHERE s.shop_type = h.shop_type
      AND s.item_id = h.item_id
    ORDER BY s.run_at DESC NULLS LAST
    LIMIT 1
  ) sm ON TRUE
),
interval_stats AS (
  SELECT
    b.*,
    COALESCE(cardinality(b.recent_intervals_ms), 0) AS interval_samples,
    COALESCE(surv.survivors, 0) AS survivors,
    COALESCE(surv.hits, 0) AS hits,
    surv.mean_remaining_ms,
    rs.recent_mean_ms,
    rs.recent_p50_ms,
    rs.recent_p80_ms,
    rs.recent_trimmed_mean_ms,
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
    CASE
      WHEN b.current_weather IS NULL THEN false
      WHEN b.weather_median_ms IS NULL OR b.weather_median_ms <= 0 THEN false
      WHEN b.weather_samples IS NULL OR b.weather_samples < 20 THEN false
      WHEN b.median_interval_ms IS NULL OR b.median_interval_ms <= 0 THEN false
      WHEN b.weather_median_ms < b.median_interval_ms * 0.35 THEN false
      WHEN b.weather_median_ms > b.median_interval_ms * 2.5 THEN false
      ELSE true
    END AS weather_used,
    CASE
      WHEN b.current_weather IS NULL THEN 'no_current_weather'
      WHEN b.weather_median_ms IS NULL OR b.weather_median_ms <= 0 THEN 'missing_weather_bucket'
      WHEN b.weather_samples IS NULL OR b.weather_samples < 20 THEN 'too_few_samples'
      WHEN b.median_interval_ms IS NULL OR b.median_interval_ms <= 0 THEN 'outside_safe_ratio'
      WHEN b.weather_median_ms < b.median_interval_ms * 0.35
        OR b.weather_median_ms > b.median_interval_ms * 2.5 THEN 'outside_safe_ratio'
      ELSE 'used'
    END AS weather_rejected_reason,
    CASE
      WHEN b.current_weather IS NULL THEN NULL
      WHEN b.weather_median_ms IS NULL OR b.weather_median_ms <= 0 THEN NULL
      WHEN b.weather_samples IS NULL OR b.weather_samples < 20 THEN NULL
      WHEN b.median_interval_ms IS NULL OR b.median_interval_ms <= 0 THEN NULL
      WHEN b.weather_median_ms < b.median_interval_ms * 0.35 THEN NULL
      WHEN b.weather_median_ms > b.median_interval_ms * 2.5 THEN NULL
      ELSE b.weather_median_ms
    END AS effective_weather_median_ms
  FROM base b
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) FILTER (WHERE val > b.elapsed_ms) AS survivors,
      COUNT(*) FILTER (WHERE val > b.elapsed_ms AND val <= b.elapsed_ms + b.cycle_ms) AS hits,
      AVG(val - b.elapsed_ms) FILTER (WHERE val > b.elapsed_ms) AS mean_remaining_ms
    FROM unnest(b.recent_intervals_ms) AS val
    WHERE val IS NOT NULL
      AND val > 0
  ) surv ON TRUE
  LEFT JOIN LATERAL (
    WITH vals AS (
      SELECT x::numeric AS val
      FROM unnest(b.recent_intervals_ms) x
      WHERE x IS NOT NULL AND x > 0
    ), ranked AS (
      SELECT
        val,
        ROW_NUMBER() OVER (ORDER BY val) AS rn,
        COUNT(*) OVER () AS cnt
      FROM vals
    )
    SELECT
      AVG(val) AS recent_mean_ms,
      (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val::double precision))::numeric AS recent_p50_ms,
      (PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY val::double precision))::numeric AS recent_p80_ms,
      COALESCE(
        AVG(val) FILTER (
          WHERE rn > GREATEST(1, FLOOR(cnt * 0.10)::int)
            AND rn <= LEAST(cnt, CEIL(cnt * 0.90)::int)
        ),
        AVG(val)
      ) AS recent_trimmed_mean_ms
    FROM ranked
  ) rs ON TRUE
),
model_routed AS (
  SELECT
    s.*,
    CASE
      WHEN s.selected_model_name = 'rolling_median_40' THEN s.recent_p50_ms
      WHEN s.selected_model_name = 'rolling_mean_40' THEN s.recent_mean_ms
      WHEN s.selected_model_name = 'trimmed_mean_40' THEN s.recent_trimmed_mean_ms
      WHEN s.selected_model_name = 'overall_median' THEN s.median_interval_ms::numeric
      WHEN s.selected_model_name = 'empirical_survival_p50' THEN s.recent_p50_ms
      WHEN s.selected_model_name = 'empirical_survival_p80' THEN s.recent_p80_ms
      WHEN s.selected_model_name = 'cycle_hazard_geometric'
        THEN CASE
          WHEN s.base_rate IS NOT NULL AND s.base_rate > 0
            THEN s.cycle_ms / GREATEST(s.base_rate, 0.0001::numeric)
          ELSE NULL
        END
      WHEN s.selected_model_name = 'corrected_weather_median'
        THEN CASE WHEN s.weather_used THEN s.weather_median_ms END
      WHEN s.selected_model_name = 'corrected_weather_hazard'
        THEN CASE
          WHEN s.weather_used THEN GREATEST(COALESCE(s.weather_median_ms, 0), COALESCE(s.recent_p80_ms, 0))
          ELSE NULL
        END
      ELSE NULL
    END AS model_baseline_ms,
    COALESCE(
      CASE
        WHEN s.ema_interval_ms IS NOT NULL AND COALESCE(s.effective_weather_median_ms, s.median_interval_ms::numeric) IS NOT NULL
             AND s.ema_interval_ms <= COALESCE(s.effective_weather_median_ms, s.median_interval_ms::numeric) * 3
             AND s.effective_weather_median_ms IS NOT NULL
             AND s.median_interval_ms IS NOT NULL
             AND ABS(s.effective_weather_median_ms - s.median_interval_ms::numeric)
                 > s.median_interval_ms::numeric * 0.3
        THEN ROUND(0.2 * s.ema_interval_ms + 0.8 * COALESCE(s.effective_weather_median_ms, s.median_interval_ms::numeric))::bigint
        WHEN s.ema_interval_ms IS NOT NULL AND COALESCE(s.effective_weather_median_ms, s.median_interval_ms::numeric) IS NOT NULL
             AND s.ema_interval_ms <= COALESCE(s.effective_weather_median_ms, s.median_interval_ms::numeric) * 3
        THEN ROUND(0.4 * s.ema_interval_ms + 0.6 * COALESCE(s.effective_weather_median_ms, s.median_interval_ms::numeric))::bigint
        ELSE COALESCE(s.effective_weather_median_ms::bigint, s.median_interval_ms, s.ema_interval_ms)
      END,
      s.average_interval_ms,
      CASE
        WHEN s.base_rate IS NOT NULL AND s.base_rate > 0
          THEN (s.cycle_ms / GREATEST(s.base_rate, 0.0001::numeric))::bigint
        ELSE (s.cycle_ms * 6.0)::bigint
      END
    )::numeric AS fallback_baseline_ms
  FROM interval_stats s
),
empirical AS (
  SELECT
    mr.*,
    COALESCE(mr.model_baseline_ms, mr.fallback_baseline_ms) AS baseline_interval_ms,
    CASE
      WHEN mr.elapsed_ms IS NULL OR mr.interval_samples = 0 THEN NULL
      WHEN mr.survivors <= 0 THEN
        LEAST(
          0.9999::numeric,
          GREATEST(
            mr.fallback_rate,
            mr.fallback_rate * LEAST(
              3.0::numeric,
              1.0::numeric + COALESCE(
                mr.elapsed_ms / NULLIF(COALESCE(mr.model_baseline_ms, mr.fallback_baseline_ms), 0),
                0
              )::numeric
            )
          )
        )
      ELSE LEAST(
        0.9999::numeric,
        GREATEST(
          0.0001::numeric,
          (mr.hits::numeric + (mr.pseudo_n * mr.fallback_rate))
          / (mr.survivors::numeric + mr.pseudo_n)
        )
      )
    END AS empirical_probability
  FROM model_routed mr
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
    CASE
      WHEN p.elapsed_ms IS NULL THEN false
      WHEN p.elapsed_ms > GREATEST(
        COALESCE(p.median_interval_ms::numeric, p.baseline_interval_ms) * 20,
        604800000::numeric
      ) THEN true
      ELSE false
    END AS is_dormant,
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
  CASE
    WHEN p.is_dormant THEN NULL::bigint
    ELSE (
      SELECT
        CASE
          WHEN p.shop_type = 'dawn' THEN GREATEST(
            ((sub.base_eta + 7200000)::bigint / 14400000) * 14400000,
            COALESCE(
              (
                SELECT wp.estimated_next_timestamp
                FROM public.weather_predictions wp
                WHERE wp.weather_id = 'Dawn'
              ),
              ((sub.base_eta + 7200000)::bigint / 14400000) * 14400000
            )
          )
          ELSE sub.base_eta
        END
      FROM (
        SELECT GREATEST(
          p.now_ms + p.cycle_ms::bigint,
          CASE
            WHEN p.last_seen IS NULL THEN p.now_ms + p.cycle_ms::bigint
            WHEN p.baseline_interval_ms IS NULL THEN p.now_ms + p.cycle_ms::bigint
            WHEN (p.last_seen + p.baseline_interval_ms::bigint) >= p.now_ms
            THEN p.last_seen + p.baseline_interval_ms::bigint
            ELSE p.now_ms + GREATEST(
              p.cycle_ms::bigint,
              COALESCE(
                p.mean_remaining_ms::bigint,
                GREATEST(
                  p.cycle_ms::bigint,
                  (p.baseline_interval_ms * GREATEST(0.1,
                    1.0 - (p.elapsed_ms / NULLIF(p.baseline_interval_ms * 3.0, 0))
                  ))::bigint
                )
              )
            )
          END
        ) AS base_eta
      ) sub
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
  p.is_dormant,
  p.current_weather,
  p.weather_median_ms::bigint AS weather_baseline_ms,
  p.weather_samples,
  p.weather_used,
  p.weather_rejected_reason,
  p.selected_model_name,
  p.selected_model_test_events,
  p.selected_model_within_one_cycle_pct
FROM final_probability p
CROSS JOIN meta m;

ALTER VIEW public.restock_predictions SET (security_invoker = true);
GRANT SELECT ON public.restock_predictions TO anon, authenticated;

-- Refresh snapshot RPC so new weather diagnostics columns are persisted.
CREATE OR REPLACE FUNCTION public.snapshot_restock_predictions(p_predicted_at_ms bigint DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer;
  v_now_ms bigint;
BEGIN
  v_now_ms := COALESCE(
    p_predicted_at_ms,
    FLOOR(EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint
  );

  INSERT INTO public.restock_prediction_snapshots (
    predicted_at_ms,
    shop_type,
    item_id,
    algorithm_version,
    predicted_next_ms,
    last_seen,
    current_probability,
    median_interval_ms,
    expected_interval_ms,
    baseline_interval_ms,
    ema_interval_ms,
    current_weather,
    weather_baseline_ms,
    weather_samples,
    weather_used,
    weather_rejected_reason
  )
  SELECT
    v_now_ms,
    rp.shop_type,
    rp.item_id,
    rp.algorithm_version,
    rp.estimated_next_timestamp,
    rp.last_seen,
    rp.current_probability,
    rp.median_interval_ms,
    rp.expected_interval_ms,
    rp.baseline_interval_ms::bigint,
    rp.ema_interval_ms,
    rp.current_weather,
    rp.weather_baseline_ms,
    rp.weather_samples,
    rp.weather_used,
    rp.weather_rejected_reason
  FROM public.restock_predictions rp
  ON CONFLICT (predicted_at_ms, shop_type, item_id) DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

INSERT INTO public.restock_algorithm_meta (id, algorithm_version, updated_at, notes)
VALUES (
  1,
  'adaptive-v12-per-item-routing',
  now(),
  'Per-item model routing in restock_predictions with weather quality gates and rejection diagnostics.'
)
ON CONFLICT (id) DO UPDATE
SET algorithm_version = EXCLUDED.algorithm_version,
    updated_at = EXCLUDED.updated_at,
    notes = EXCLUDED.notes;
