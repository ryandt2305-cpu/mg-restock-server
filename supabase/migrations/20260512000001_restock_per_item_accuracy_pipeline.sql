-- Per-item restock prediction accuracy pipeline.
-- Creates snapshot/outcome telemetry, per-item backtests, and model-selection views.
-- Backend-only: no UI contract changes required.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- Helpers
-- ============================================================

CREATE OR REPLACE FUNCTION public.restock_cycle_ms(p_shop_type text)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(coalesce(p_shop_type, ''))
    WHEN 'seed' THEN 300000::bigint
    WHEN 'egg' THEN 900000::bigint
    WHEN 'decor' THEN 3600000::bigint
    WHEN 'tool' THEN 600000::bigint
    ELSE 300000::bigint
  END
$$;

-- ============================================================
-- Prediction snapshots + scored outcomes
-- ============================================================

CREATE TABLE IF NOT EXISTS public.restock_prediction_snapshots (
  id bigserial PRIMARY KEY,
  predicted_at_ms bigint NOT NULL,
  shop_type text NOT NULL,
  item_id text NOT NULL,
  algorithm_version text NOT NULL,
  predicted_next_ms bigint,
  last_seen bigint,
  current_probability numeric,
  median_interval_ms bigint,
  expected_interval_ms bigint,
  baseline_interval_ms bigint,
  ema_interval_ms bigint,
  current_weather text,
  weather_baseline_ms bigint,
  weather_samples integer,
  weather_used boolean,
  weather_rejected_reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Existing environments may already have these tables with older column sets.
-- Add any missing columns before indexes/views/functions are defined.
ALTER TABLE IF EXISTS public.restock_prediction_snapshots
  ADD COLUMN IF NOT EXISTS predicted_at_ms bigint,
  ADD COLUMN IF NOT EXISTS shop_type text,
  ADD COLUMN IF NOT EXISTS item_id text,
  ADD COLUMN IF NOT EXISTS algorithm_version text,
  ADD COLUMN IF NOT EXISTS predicted_next_ms bigint,
  ADD COLUMN IF NOT EXISTS last_seen bigint,
  ADD COLUMN IF NOT EXISTS current_probability numeric,
  ADD COLUMN IF NOT EXISTS median_interval_ms bigint,
  ADD COLUMN IF NOT EXISTS expected_interval_ms bigint,
  ADD COLUMN IF NOT EXISTS baseline_interval_ms bigint,
  ADD COLUMN IF NOT EXISTS ema_interval_ms bigint,
  ADD COLUMN IF NOT EXISTS current_weather text,
  ADD COLUMN IF NOT EXISTS weather_baseline_ms bigint,
  ADD COLUMN IF NOT EXISTS weather_samples integer,
  ADD COLUMN IF NOT EXISTS weather_used boolean,
  ADD COLUMN IF NOT EXISTS weather_rejected_reason text,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

CREATE UNIQUE INDEX IF NOT EXISTS restock_prediction_snapshots_predicted_key
  ON public.restock_prediction_snapshots (predicted_at_ms, shop_type, item_id);

CREATE INDEX IF NOT EXISTS restock_prediction_snapshots_shop_item_idx
  ON public.restock_prediction_snapshots (shop_type, item_id, predicted_at_ms DESC);

CREATE INDEX IF NOT EXISTS restock_prediction_snapshots_created_idx
  ON public.restock_prediction_snapshots (created_at DESC);

ALTER TABLE public.restock_prediction_snapshots ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.restock_prediction_outcomes (
  id bigserial PRIMARY KEY,
  snapshot_id bigint NOT NULL REFERENCES public.restock_prediction_snapshots(id) ON DELETE CASCADE,
  actual_event_ts bigint NOT NULL,
  absolute_error_ms bigint,
  signed_error_ms bigint,
  within_one_cycle boolean,
  scored_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (snapshot_id, actual_event_ts)
);

ALTER TABLE IF EXISTS public.restock_prediction_outcomes
  ADD COLUMN IF NOT EXISTS snapshot_id bigint,
  ADD COLUMN IF NOT EXISTS actual_event_ts bigint,
  ADD COLUMN IF NOT EXISTS absolute_error_ms bigint,
  ADD COLUMN IF NOT EXISTS signed_error_ms bigint,
  ADD COLUMN IF NOT EXISTS within_one_cycle boolean,
  ADD COLUMN IF NOT EXISTS scored_at timestamptz DEFAULT now();

CREATE INDEX IF NOT EXISTS restock_prediction_outcomes_snapshot_idx
  ON public.restock_prediction_outcomes (snapshot_id);

CREATE INDEX IF NOT EXISTS restock_prediction_outcomes_scored_idx
  ON public.restock_prediction_outcomes (scored_at DESC);

ALTER TABLE public.restock_prediction_outcomes ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- Per-item model backtests
-- ============================================================

CREATE TABLE IF NOT EXISTS public.restock_item_model_backtests (
  id bigserial PRIMARY KEY,
  run_id uuid NOT NULL DEFAULT gen_random_uuid(),
  run_at timestamptz NOT NULL DEFAULT now(),
  shop_type text NOT NULL,
  item_id text NOT NULL,
  model_name text NOT NULL,
  test_events integer NOT NULL,
  mae_ms numeric,
  median_abs_error_ms numeric,
  within_one_cycle_pct numeric,
  within_two_cycle_pct numeric,
  p50_coverage_pct numeric,
  p80_coverage_pct numeric,
  brier_30m numeric,
  log_loss_30m numeric,
  selected boolean NOT NULL DEFAULT false
);

ALTER TABLE IF EXISTS public.restock_item_model_backtests
  ADD COLUMN IF NOT EXISTS run_id uuid DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS run_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS shop_type text,
  ADD COLUMN IF NOT EXISTS item_id text,
  ADD COLUMN IF NOT EXISTS model_name text,
  ADD COLUMN IF NOT EXISTS test_events integer,
  ADD COLUMN IF NOT EXISTS mae_ms numeric,
  ADD COLUMN IF NOT EXISTS median_abs_error_ms numeric,
  ADD COLUMN IF NOT EXISTS within_one_cycle_pct numeric,
  ADD COLUMN IF NOT EXISTS within_two_cycle_pct numeric,
  ADD COLUMN IF NOT EXISTS p50_coverage_pct numeric,
  ADD COLUMN IF NOT EXISTS p80_coverage_pct numeric,
  ADD COLUMN IF NOT EXISTS brier_30m numeric,
  ADD COLUMN IF NOT EXISTS log_loss_30m numeric,
  ADD COLUMN IF NOT EXISTS selected boolean DEFAULT false;

CREATE UNIQUE INDEX IF NOT EXISTS restock_item_model_backtests_run_item_model_key
  ON public.restock_item_model_backtests (run_id, shop_type, item_id, model_name);

CREATE INDEX IF NOT EXISTS restock_item_model_backtests_run_idx
  ON public.restock_item_model_backtests (run_at DESC, run_id);

CREATE INDEX IF NOT EXISTS restock_item_model_backtests_item_idx
  ON public.restock_item_model_backtests (shop_type, item_id, run_at DESC);

ALTER TABLE public.restock_item_model_backtests ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- Policies + grants (read-only for anon/authenticated)
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'restock_prediction_snapshots'
      AND policyname = 'anon_read_restock_prediction_snapshots'
  ) THEN
    CREATE POLICY "anon_read_restock_prediction_snapshots"
      ON public.restock_prediction_snapshots
      FOR SELECT TO anon, authenticated
      USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'restock_prediction_outcomes'
      AND policyname = 'anon_read_restock_prediction_outcomes'
  ) THEN
    CREATE POLICY "anon_read_restock_prediction_outcomes"
      ON public.restock_prediction_outcomes
      FOR SELECT TO anon, authenticated
      USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'restock_item_model_backtests'
      AND policyname = 'anon_read_restock_item_model_backtests'
  ) THEN
    CREATE POLICY "anon_read_restock_item_model_backtests"
      ON public.restock_item_model_backtests
      FOR SELECT TO anon, authenticated
      USING (true);
  END IF;
END
$$;

REVOKE ALL ON TABLE public.restock_prediction_snapshots FROM anon, authenticated;
REVOKE ALL ON TABLE public.restock_prediction_outcomes FROM anon, authenticated;
REVOKE ALL ON TABLE public.restock_item_model_backtests FROM anon, authenticated;

GRANT SELECT ON TABLE public.restock_prediction_snapshots TO anon, authenticated;
GRANT SELECT ON TABLE public.restock_prediction_outcomes TO anon, authenticated;
GRANT SELECT ON TABLE public.restock_item_model_backtests TO anon, authenticated;

-- ============================================================
-- Snapshot + scoring RPCs
-- ============================================================

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
    NULL::boolean,
    NULL::text
  FROM public.restock_predictions rp
  ON CONFLICT (predicted_at_ms, shop_type, item_id) DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.score_restock_prediction_outcomes(p_max_rows integer DEFAULT 20000)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer;
BEGIN
  INSERT INTO public.restock_prediction_outcomes (
    snapshot_id,
    actual_event_ts,
    absolute_error_ms,
    signed_error_ms,
    within_one_cycle
  )
  SELECT
    s.id,
    e.timestamp,
    ABS(e.timestamp - s.predicted_next_ms)::bigint,
    (e.timestamp - s.predicted_next_ms)::bigint,
    ABS(e.timestamp - s.predicted_next_ms) <= public.restock_cycle_ms(s.shop_type)
  FROM public.restock_prediction_snapshots s
  JOIN LATERAL (
    SELECT rie.timestamp
    FROM public.restock_item_events rie
    WHERE rie.shop_type = s.shop_type
      AND rie.item_id = s.item_id
      AND rie.timestamp >= s.predicted_at_ms
    ORDER BY rie.timestamp ASC
    LIMIT 1
  ) e ON TRUE
  WHERE s.predicted_next_ms IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.restock_prediction_outcomes o
      WHERE o.snapshot_id = s.id
        AND o.actual_event_ts = e.timestamp
    )
  ORDER BY s.id
  LIMIT GREATEST(100, LEAST(COALESCE(p_max_rows, 20000), 500000));

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- ============================================================
-- Model selection helpers
-- ============================================================

CREATE OR REPLACE FUNCTION public.refresh_restock_item_model_selection(p_run_id uuid DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_run_id uuid;
  v_count integer;
BEGIN
  SELECT COALESCE(
    p_run_id,
    (SELECT run_id FROM public.restock_item_model_backtests ORDER BY run_at DESC LIMIT 1)
  ) INTO v_run_id;

  IF v_run_id IS NULL THEN
    RETURN 0;
  END IF;

  WITH ranked AS (
    SELECT
      id,
      ROW_NUMBER() OVER (
        PARTITION BY shop_type, item_id
        ORDER BY
          CASE WHEN test_events >= 30 THEN 0 ELSE 1 END,
          median_abs_error_ms ASC NULLS LAST,
          within_one_cycle_pct DESC NULLS LAST,
          ABS(COALESCE(p80_coverage_pct, 0) - 80) ASC,
          brier_30m ASC NULLS LAST,
          mae_ms ASC NULLS LAST,
          id ASC
      ) AS model_rank
    FROM public.restock_item_model_backtests
    WHERE run_id = v_run_id
  )
  UPDATE public.restock_item_model_backtests b
  SET selected = (r.model_rank = 1)
  FROM ranked r
  WHERE b.id = r.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.run_restock_item_model_backtests(
  p_lookback_days integer DEFAULT 90,
  p_min_samples integer DEFAULT 12,
  p_min_backtest_events integer DEFAULT 8,
  p_max_backtest_events integer DEFAULT 40
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_run_id uuid := gen_random_uuid();
  v_current_weather text;
  rec record;
  v_n integer;
  v_test_n integer;
  v_cycle_ms bigint;
  v_train bigint[];
  v_test bigint[];
  v_last40 bigint[];
  v_model text;
  v_pred_ms numeric;
  v_prob_30m numeric;

  v_test_events integer;
  v_mae_ms numeric;
  v_median_abs_error_ms numeric;
  v_within_one_cycle_pct numeric;
  v_within_two_cycle_pct numeric;
  v_p50_coverage_pct numeric;
  v_p80_coverage_pct numeric;
  v_brier_30m numeric;
  v_log_loss_30m numeric;

  v_base_rate numeric;
  v_item_median bigint;
  v_weather_median numeric;
  v_weather_samples integer;
BEGIN
  p_lookback_days := GREATEST(7, LEAST(COALESCE(p_lookback_days, 90), 365));
  p_min_samples := GREATEST(6, LEAST(COALESCE(p_min_samples, 12), 400));
  p_min_backtest_events := GREATEST(4, LEAST(COALESCE(p_min_backtest_events, 8), 80));
  p_max_backtest_events := GREATEST(p_min_backtest_events, LEAST(COALESCE(p_max_backtest_events, 40), 120));

  SELECT weather_id
    INTO v_current_weather
  FROM public.weather_events
  ORDER BY timestamp DESC
  LIMIT 1;

  FOR rec IN
    WITH item_intervals AS (
      SELECT
        e.shop_type,
        e.item_id,
        e.timestamp,
        (e.timestamp - LAG(e.timestamp) OVER (PARTITION BY e.shop_type, e.item_id ORDER BY e.timestamp))::bigint AS interval_ms
      FROM public.restock_item_events e
      WHERE e.timestamp >= FLOOR(EXTRACT(EPOCH FROM now() - make_interval(days => p_lookback_days)) * 1000)::bigint
        AND e.shop_type IN ('seed', 'egg', 'decor', 'tool')
    )
    SELECT
      shop_type,
      item_id,
      ARRAY_AGG(interval_ms ORDER BY timestamp ASC) FILTER (WHERE interval_ms IS NOT NULL AND interval_ms > 0) AS intervals
    FROM item_intervals
    GROUP BY shop_type, item_id
    HAVING COUNT(*) FILTER (WHERE interval_ms IS NOT NULL AND interval_ms > 0) >= p_min_samples
  LOOP
    v_n := COALESCE(array_length(rec.intervals, 1), 0);
    IF v_n < p_min_samples THEN
      CONTINUE;
    END IF;

    v_test_n := GREATEST(p_min_backtest_events, LEAST(p_max_backtest_events, FLOOR(v_n * 0.25)::int));
    IF v_test_n >= v_n THEN
      v_test_n := v_n - 1;
    END IF;
    IF v_test_n < 1 THEN
      CONTINUE;
    END IF;

    v_train := rec.intervals[1:(v_n - v_test_n)];
    v_test := rec.intervals[(v_n - v_test_n + 1):v_n];
    v_last40 := v_train[GREATEST(1, COALESCE(array_length(v_train, 1), 1) - 39):COALESCE(array_length(v_train, 1), 1)];
    v_cycle_ms := public.restock_cycle_ms(rec.shop_type);

    SELECT h.appearance_rate, h.median_interval_ms
      INTO v_base_rate, v_item_median
    FROM public.restock_history h
    WHERE h.shop_type = rec.shop_type
      AND h.item_id = rec.item_id;

    v_weather_median := NULL;
    v_weather_samples := NULL;

    IF v_current_weather IS NOT NULL THEN
      SELECT
        (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY (v)::double precision))::numeric,
        COUNT(*)::int
      INTO v_weather_median, v_weather_samples
      FROM jsonb_array_elements_text(
        COALESCE(
          (
            SELECT CASE
              WHEN h.weather_intervals IS NOT NULL
                   AND jsonb_typeof(h.weather_intervals) = 'object'
                   AND h.weather_intervals ? v_current_weather
              THEN h.weather_intervals -> v_current_weather
              ELSE '[]'::jsonb
            END
            FROM public.restock_history h
            WHERE h.shop_type = rec.shop_type
              AND h.item_id = rec.item_id
          ),
          '[]'::jsonb
        )
      ) AS v;
    END IF;

    FOREACH v_model IN ARRAY ARRAY[
      'rolling_median_40',
      'rolling_mean_40',
      'trimmed_mean_40',
      'overall_median',
      'empirical_survival_p50',
      'empirical_survival_p80',
      'cycle_hazard_geometric',
      'corrected_weather_median',
      'corrected_weather_hazard'
    ]
    LOOP
      v_pred_ms := NULL;

      IF v_model = 'rolling_median_40' THEN
        SELECT (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY x::double precision))::numeric
          INTO v_pred_ms
        FROM unnest(v_last40) x
        WHERE x > 0;

      ELSIF v_model = 'rolling_mean_40' THEN
        SELECT AVG(x)::numeric
          INTO v_pred_ms
        FROM unnest(v_last40) x
        WHERE x > 0;

      ELSIF v_model = 'trimmed_mean_40' THEN
        WITH vals AS (
          SELECT x::numeric AS val,
                 ROW_NUMBER() OVER (ORDER BY x) AS rn,
                 COUNT(*) OVER () AS cnt
          FROM unnest(v_last40) x
          WHERE x > 0
        )
        SELECT COALESCE(
          AVG(val) FILTER (
            WHERE rn > GREATEST(1, FLOOR(cnt * 0.1)::int)
              AND rn <= LEAST(cnt, CEIL(cnt * 0.9)::int)
          ),
          AVG(val)
        )
        INTO v_pred_ms
        FROM vals;

      ELSIF v_model IN ('overall_median', 'empirical_survival_p50') THEN
        SELECT (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY x::double precision))::numeric
          INTO v_pred_ms
        FROM unnest(v_train) x
        WHERE x > 0;

      ELSIF v_model = 'empirical_survival_p80' THEN
        SELECT (PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY x::double precision))::numeric
          INTO v_pred_ms
        FROM unnest(v_train) x
        WHERE x > 0;

      ELSIF v_model = 'cycle_hazard_geometric' THEN
        IF v_base_rate IS NOT NULL AND v_base_rate > 0 THEN
          v_pred_ms := v_cycle_ms::numeric / GREATEST(v_base_rate, 0.0001::numeric);
        END IF;

      ELSIF v_model = 'corrected_weather_median' THEN
        IF v_weather_samples IS NOT NULL
           AND v_weather_samples >= 20
           AND v_weather_median IS NOT NULL
           AND v_weather_median > 0
           AND v_item_median IS NOT NULL
           AND v_item_median > 0
           AND v_weather_median BETWEEN v_item_median * 0.35 AND v_item_median * 2.5
        THEN
          v_pred_ms := v_weather_median;
        END IF;

      ELSIF v_model = 'corrected_weather_hazard' THEN
        IF v_weather_samples IS NOT NULL
           AND v_weather_samples >= 20
           AND v_weather_median IS NOT NULL
           AND v_weather_median > 0
           AND v_item_median IS NOT NULL
           AND v_item_median > 0
           AND v_weather_median BETWEEN v_item_median * 0.35 AND v_item_median * 2.5
        THEN
          v_pred_ms := GREATEST(v_weather_median, v_cycle_ms::numeric * 1.5);
        END IF;
      END IF;

      IF v_pred_ms IS NULL OR v_pred_ms <= 0 THEN
        CONTINUE;
      END IF;

      v_prob_30m := LEAST(0.9999, GREATEST(0.0001, 1800000::numeric / v_pred_ms));

      SELECT
        COUNT(*)::int,
        AVG(ABS(v - v_pred_ms))::numeric,
        (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ABS(v - v_pred_ms)::double precision))::numeric,
        100.0 * AVG(((ABS(v - v_pred_ms) <= v_cycle_ms)::int)::numeric),
        100.0 * AVG(((ABS(v - v_pred_ms) <= v_cycle_ms * 2)::int)::numeric),
        100.0 * AVG(((v <= v_pred_ms)::int)::numeric),
        100.0 * AVG(((v <= v_pred_ms * 1.6)::int)::numeric),
        AVG(POWER(v_prob_30m - (CASE WHEN v <= 1800000 THEN 1 ELSE 0 END), 2))::numeric,
        AVG(-((CASE WHEN v <= 1800000 THEN 1 ELSE 0 END) * LN(v_prob_30m)
              + (1 - (CASE WHEN v <= 1800000 THEN 1 ELSE 0 END)) * LN(1 - v_prob_30m)))::numeric
      INTO
        v_test_events,
        v_mae_ms,
        v_median_abs_error_ms,
        v_within_one_cycle_pct,
        v_within_two_cycle_pct,
        v_p50_coverage_pct,
        v_p80_coverage_pct,
        v_brier_30m,
        v_log_loss_30m
      FROM unnest(v_test) v;

      INSERT INTO public.restock_item_model_backtests (
        run_id,
        run_at,
        shop_type,
        item_id,
        model_name,
        test_events,
        mae_ms,
        median_abs_error_ms,
        within_one_cycle_pct,
        within_two_cycle_pct,
        p50_coverage_pct,
        p80_coverage_pct,
        brier_30m,
        log_loss_30m,
        selected
      ) VALUES (
        v_run_id,
        now(),
        rec.shop_type,
        rec.item_id,
        v_model,
        v_test_events,
        v_mae_ms,
        v_median_abs_error_ms,
        v_within_one_cycle_pct,
        v_within_two_cycle_pct,
        v_p50_coverage_pct,
        v_p80_coverage_pct,
        v_brier_30m,
        v_log_loss_30m,
        false
      )
      ON CONFLICT (run_id, shop_type, item_id, model_name) DO UPDATE
      SET test_events = EXCLUDED.test_events,
          mae_ms = EXCLUDED.mae_ms,
          median_abs_error_ms = EXCLUDED.median_abs_error_ms,
          within_one_cycle_pct = EXCLUDED.within_one_cycle_pct,
          within_two_cycle_pct = EXCLUDED.within_two_cycle_pct,
          p50_coverage_pct = EXCLUDED.p50_coverage_pct,
          p80_coverage_pct = EXCLUDED.p80_coverage_pct,
          brier_30m = EXCLUDED.brier_30m,
          log_loss_30m = EXCLUDED.log_loss_30m,
          selected = false;
    END LOOP;
  END LOOP;

  PERFORM public.refresh_restock_item_model_selection(v_run_id);
  RETURN v_run_id;
END;
$$;

-- ============================================================
-- Analytics views
-- ============================================================

CREATE OR REPLACE VIEW public.restock_item_model_candidates
WITH (security_invoker = true)
AS
WITH latest_run AS (
  SELECT run_id
  FROM public.restock_item_model_backtests
  ORDER BY run_at DESC
  LIMIT 1
), ranked AS (
  SELECT
    b.run_id,
    b.shop_type,
    b.item_id,
    b.model_name,
    b.test_events,
    b.mae_ms,
    b.median_abs_error_ms,
    b.within_one_cycle_pct,
    b.within_two_cycle_pct,
    b.selected,
    ROW_NUMBER() OVER (
      PARTITION BY b.shop_type, b.item_id
      ORDER BY
        CASE WHEN b.test_events >= 30 THEN 0 ELSE 1 END,
        b.median_abs_error_ms ASC NULLS LAST,
        b.within_one_cycle_pct DESC NULLS LAST,
        ABS(COALESCE(b.p80_coverage_pct, 0) - 80) ASC,
        b.brier_30m ASC NULLS LAST,
        b.mae_ms ASC NULLS LAST,
        b.id ASC
    ) AS model_rank,
    b.run_at,
    b.p80_coverage_pct,
    b.brier_30m
  FROM public.restock_item_model_backtests b
  JOIN latest_run lr ON lr.run_id = b.run_id
)
SELECT *
FROM ranked;

CREATE OR REPLACE VIEW public.restock_item_selected_models
WITH (security_invoker = true)
AS
SELECT
  run_id,
  shop_type,
  item_id,
  model_name,
  test_events,
  mae_ms,
  median_abs_error_ms,
  within_one_cycle_pct,
  within_two_cycle_pct,
  p80_coverage_pct,
  brier_30m,
  run_at
FROM public.restock_item_model_candidates
WHERE model_rank = 1
  AND selected = true;

CREATE OR REPLACE VIEW public.restock_prediction_accuracy_by_item
WITH (security_invoker = true)
AS
SELECT
  s.shop_type,
  s.item_id,
  s.algorithm_version,
  COUNT(*) AS scored_predictions,
  ROUND((AVG(o.absolute_error_ms) / 60000.0)::numeric, 1) AS mae_min,
  ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY o.absolute_error_ms::double precision) / 60000.0)::numeric, 1) AS median_abs_error_min,
  ROUND((100.0 * AVG(((o.within_one_cycle)::int)::numeric))::numeric, 1) AS within_one_cycle_pct,
  MAX(o.scored_at) AS last_scored_at
FROM public.restock_prediction_snapshots s
JOIN public.restock_prediction_outcomes o
  ON o.snapshot_id = s.id
GROUP BY s.shop_type, s.item_id, s.algorithm_version;

REVOKE ALL ON TABLE public.restock_item_model_candidates FROM anon, authenticated;
REVOKE ALL ON TABLE public.restock_item_selected_models FROM anon, authenticated;
REVOKE ALL ON TABLE public.restock_prediction_accuracy_by_item FROM anon, authenticated;

GRANT SELECT ON TABLE public.restock_item_model_candidates TO anon, authenticated;
GRANT SELECT ON TABLE public.restock_item_selected_models TO anon, authenticated;
GRANT SELECT ON TABLE public.restock_prediction_accuracy_by_item TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.snapshot_restock_predictions(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.score_restock_prediction_outcomes(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.refresh_restock_item_model_selection(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.run_restock_item_model_backtests(integer, integer, integer, integer) TO service_role;

-- Maintain permissive historical behavior for authenticated/anon RPC invocation,
-- while relying on SECURITY DEFINER and secret-bearing callers in workflows.
GRANT EXECUTE ON FUNCTION public.snapshot_restock_predictions(bigint) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.score_restock_prediction_outcomes(integer) TO authenticated, anon;

-- Track algorithm revision for rollout visibility.
INSERT INTO public.restock_algorithm_meta (id, algorithm_version, updated_at, notes)
VALUES (
  1,
  'adaptive-v12-per-item-pipeline',
  now(),
  'Added prediction snapshots/outcomes, per-item model backtests, and selected-model analytics views.'
)
ON CONFLICT (id) DO UPDATE
SET algorithm_version = EXCLUDED.algorithm_version,
    updated_at = EXCLUDED.updated_at,
    notes = EXCLUDED.notes;
