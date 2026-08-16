-- ============================================================================
-- Phase 1: shop_type_registry table — single source of truth for shop types
-- ============================================================================

-- 1.1 Create registry table
CREATE TABLE public.shop_type_registry (
  shop_type          text PRIMARY KEY,
  cycle_interval_ms  bigint NOT NULL,
  discovered_at      timestamptz NOT NULL DEFAULT now(),
  discovered_from    text,
  is_active          boolean NOT NULL DEFAULT true,
  config             jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- Seed with known shops
INSERT INTO public.shop_type_registry (shop_type, cycle_interval_ms, discovered_from, config) VALUES
  ('seed',  300000,  'initial-seed', '{}'::jsonb),
  ('egg',   900000,  'initial-seed', '{}'::jsonb),
  ('decor', 3600000, 'initial-seed', '{}'::jsonb),
  ('tool',  600000,  'initial-seed', '{}'::jsonb),
  ('dawn',  300000,  'initial-seed', '{"session_dedup_gap_ms": 600000, "weather_gated": "Dawn", "weather_snap_grid_ms": 14400000}'::jsonb);

-- RLS: anon can SELECT, no public writes
ALTER TABLE public.shop_type_registry ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_read_shop_type_registry"
  ON public.shop_type_registry
  FOR SELECT
  TO anon
  USING (true);

-- register_shop_type: safe auto-registration of new shop types
CREATE OR REPLACE FUNCTION public.register_shop_type(
  p_shop_type text,
  p_cycle_interval_ms bigint DEFAULT 300000,
  p_discovered_from text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO shop_type_registry (shop_type, cycle_interval_ms, discovered_from)
  VALUES (lower(p_shop_type), p_cycle_interval_ms, p_discovered_from)
  ON CONFLICT (shop_type) DO NOTHING;

  IF FOUND THEN
    RAISE LOG 'shop_type_registry: registered new shop type "%" (cycle_interval_ms=%, from=%)',
      p_shop_type, p_cycle_interval_ms, COALESCE(p_discovered_from, 'unknown');
  END IF;
END;
$function$;

-- 1.2 Drop CHECK constraints, add FK constraints

ALTER TABLE public.restock_events
  DROP CONSTRAINT restock_events_shop_type_check;

ALTER TABLE public.restock_history
  DROP CONSTRAINT restock_history_shop_type_check;

ALTER TABLE public.restock_item_events
  DROP CONSTRAINT restock_item_events_shop_type_check;

ALTER TABLE public.shop_cycle_stats
  DROP CONSTRAINT shop_cycle_stats_shop_type_check;

ALTER TABLE public.restock_events
  ADD CONSTRAINT restock_events_shop_type_fk
  FOREIGN KEY (shop_type) REFERENCES public.shop_type_registry(shop_type);

ALTER TABLE public.restock_history
  ADD CONSTRAINT restock_history_shop_type_fk
  FOREIGN KEY (shop_type) REFERENCES public.shop_type_registry(shop_type);

ALTER TABLE public.restock_item_events
  ADD CONSTRAINT restock_item_events_shop_type_fk
  FOREIGN KEY (shop_type) REFERENCES public.shop_type_registry(shop_type);

ALTER TABLE public.shop_cycle_stats
  ADD CONSTRAINT shop_cycle_stats_shop_type_fk
  FOREIGN KEY (shop_type) REFERENCES public.shop_type_registry(shop_type);


-- ============================================================================
-- Phase 2: Replace hardcoded functions with registry lookups
-- ============================================================================

-- 2.1 restock_snap_timestamp — IMMUTABLE → STABLE, registry lookup
CREATE OR REPLACE FUNCTION public.restock_snap_timestamp(p_shop_type text, p_ts bigint)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE interval_ms bigint;
BEGIN
  SELECT cycle_interval_ms INTO interval_ms
  FROM shop_type_registry
  WHERE shop_type = p_shop_type;

  IF interval_ms IS NULL THEN
    interval_ms := 300000;
  END IF;

  RETURN (p_ts / interval_ms) * interval_ms;
END;
$function$;

-- 2.2 restock_cycle_ms — registry lookup
CREATE OR REPLACE FUNCTION public.restock_cycle_ms(p_shop_type text)
RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT cycle_interval_ms FROM shop_type_registry WHERE shop_type = lower(COALESCE(p_shop_type, ''))),
    300000::bigint
  );
$function$;

-- 2.2b restock_shop_cycle_ms — registry lookup
CREATE OR REPLACE FUNCTION public.restock_shop_cycle_ms(p_shop_type text)
RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT cycle_interval_ms FROM shop_type_registry WHERE shop_type = lower(COALESCE(p_shop_type, ''))),
    300000::bigint
  );
$function$;

-- 2.3 ingest_restock_history — registry-driven, no hardcoded shop types
CREATE OR REPLACE FUNCTION public.ingest_restock_history(p_shop_type text, p_ts bigint, p_items jsonb, p_weather_id text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
  v_config jsonb;

  v_new_total int;
  v_first_seen bigint;
  v_last_seen bigint;

  v_prev_last_seen bigint;
  v_prev_avg_interval bigint;
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
  v_lifespan_cycles numeric;

  v_predicted_next bigint;

  v_current_weather text;
  v_weather_intervals jsonb;
  v_weather_bucket jsonb;
  v_weather_arr bigint[];

  v_outlier_cap bigint;

  v_shop_first_ts bigint;
  v_shop_lifespan_cycles numeric;

  v_prev_cycle_ts bigint;
  v_is_new_session boolean;

  v_session_dedup_gap_ms bigint;
  v_weather_gated text;
  v_dawn_weather_interval bigint := 21492537; -- ~6h, from weather_predictions
BEGIN
  v_shop_type := lower(COALESCE(p_shop_type, ''));

  -- Look up registry; auto-register if unknown
  SELECT cycle_interval_ms, config
    INTO v_shop_interval, v_config
  FROM shop_type_registry
  WHERE shop_type = v_shop_type;

  IF v_shop_interval IS NULL THEN
    -- Unknown shop type: register with conservative default
    PERFORM register_shop_type(v_shop_type, 300000, 'auto-ingest');
    v_shop_interval := 300000;
    v_config := '{}'::jsonb;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN;
  END IF;

  v_snapped_ts := restock_snap_timestamp(v_shop_type, p_ts);

  -- Extract config-driven behavior
  v_session_dedup_gap_ms := (v_config->>'session_dedup_gap_ms')::bigint;
  v_weather_gated := v_config->>'weather_gated';

  INSERT INTO shop_cycle_stats(shop_type, total_cycles, last_cycle_ts)
  VALUES (v_shop_type, 0, NULL)
  ON CONFLICT (shop_type) DO NOTHING;

  -- Session-based cycle counting (for weather-gated shops like dawn)
  -- vs standard cycle counting for other shops.
  IF v_session_dedup_gap_ms IS NOT NULL THEN
    SELECT last_cycle_ts INTO v_prev_cycle_ts
    FROM shop_cycle_stats WHERE shop_type = v_shop_type;

    v_is_new_session := (v_prev_cycle_ts IS NULL OR (v_snapped_ts - v_prev_cycle_ts) > v_session_dedup_gap_ms);

    IF v_is_new_session AND (v_prev_cycle_ts IS NULL OR v_snapped_ts > v_prev_cycle_ts) THEN
      UPDATE shop_cycle_stats
        SET total_cycles = total_cycles + 1,
            last_cycle_ts = v_snapped_ts
      WHERE shop_type = v_shop_type;
    ELSIF v_snapped_ts > COALESCE(v_prev_cycle_ts, 0) THEN
      UPDATE shop_cycle_stats
        SET last_cycle_ts = v_snapped_ts
      WHERE shop_type = v_shop_type;
    END IF;
  ELSE
    UPDATE shop_cycle_stats
      SET total_cycles = total_cycles + 1,
          last_cycle_ts = v_snapped_ts
    WHERE shop_type = v_shop_type
      AND (last_cycle_ts IS NULL OR v_snapped_ts > last_cycle_ts);
  END IF;

  SELECT scs.total_cycles
    INTO v_total_cycles
  FROM shop_cycle_stats scs
  WHERE scs.shop_type = v_shop_type;

  v_current_weather := NULLIF(TRIM(COALESCE(p_weather_id, '')), '');
  IF v_current_weather IS NULL THEN
    SELECT we.weather_id INTO v_current_weather
    FROM weather_events we
    WHERE we.timestamp <= p_ts
    ORDER BY we.timestamp DESC
    LIMIT 1;
  END IF;

  -- Shop's earliest event for lifespan floor (non-weather-gated shops only)
  IF v_weather_gated IS NULL THEN
    SELECT MIN(e.timestamp) INTO v_shop_first_ts
    FROM restock_events e
    WHERE e.shop_type = v_shop_type;
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

    SELECT h.last_seen, h.recent_intervals_ms, h.ema_interval_ms,
           h.weather_intervals, h.median_interval_ms, h.average_interval_ms
      INTO v_prev_last_seen, v_recent_intervals, v_prev_ema,
           v_weather_intervals, v_prev_median, v_prev_avg_interval
    FROM restock_history h
    WHERE h.item_id = v_item_id
      AND h.shop_type = v_shop_type;

    -- Dedup: skip if same snapped timestamp
    IF v_prev_last_seen IS NOT NULL AND v_item_snapped_ts = v_prev_last_seen THEN
      CONTINUE;
    END IF;

    -- Session dedup: skip if within same session (gap <= session_dedup_gap_ms)
    -- Items in session-based shops persist across multiple polls in the same weather window.
    -- Only record a new event when a new session starts.
    IF v_session_dedup_gap_ms IS NOT NULL AND v_prev_last_seen IS NOT NULL
       AND (v_item_snapped_ts - v_prev_last_seen) <= v_session_dedup_gap_ms THEN
      UPDATE restock_history
        SET last_seen = v_item_snapped_ts
      WHERE item_id = v_item_id AND shop_type = v_shop_type
        AND last_seen < v_item_snapped_ts;
      CONTINUE;
    END IF;

    v_predicted_next := CASE
      WHEN v_prev_last_seen IS NOT NULL
      THEN v_prev_last_seen + COALESCE(v_prev_median, v_prev_avg_interval)
      ELSE NULL
    END;

    INSERT INTO restock_item_events(shop_type, item_id, timestamp, quantity, predicted_next_ms)
    VALUES (v_shop_type, v_item_id, v_item_snapped_ts, v_stock, v_predicted_next)
    ON CONFLICT (shop_type, item_id, timestamp) DO UPDATE
      SET quantity = CASE
        WHEN restock_item_events.quantity IS NULL THEN EXCLUDED.quantity
        WHEN EXCLUDED.quantity IS NULL THEN restock_item_events.quantity
        ELSE GREATEST(restock_item_events.quantity, EXCLUDED.quantity)
      END,
      predicted_next_ms = COALESCE(restock_item_events.predicted_next_ms, EXCLUDED.predicted_next_ms);

    v_weather_intervals := COALESCE(v_weather_intervals, '{}'::jsonb);

    INSERT INTO restock_history(
      item_id, shop_type, total_occurrences, total_quantity,
      first_seen, last_seen, average_quantity, last_quantity
    )
    VALUES (
      v_item_id, v_shop_type, 1, COALESCE(v_stock, 0),
      v_item_snapped_ts, v_item_snapped_ts, v_stock, v_stock
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

    -- Rate calculation: weather-gated shops use session-based counting,
    -- other shops use lifespan-based counting.
    IF v_weather_gated IS NOT NULL THEN
      -- Weather-gated: rate = occurrences / total sessions
      v_rate := GREATEST(0.0001, LEAST(0.9999,
        ROUND(v_new_total::numeric / GREATEST(1, v_total_cycles), 4)));
      -- Interval aligned to weather cycle, not shop cycle
      v_interval_ms := ROUND(v_dawn_weather_interval::numeric / GREATEST(v_rate, 0.0001))::bigint;
    ELSE
      -- Non-weather-gated: lifespan-based rate with shop observation window floor
      v_lifespan_cycles := GREATEST(1, ROUND((v_last_seen - v_first_seen)::numeric / v_shop_interval) + 1);

      IF v_shop_first_ts IS NOT NULL AND v_last_seen IS NOT NULL THEN
        v_shop_lifespan_cycles := GREATEST(1,
          ROUND((v_last_seen - v_shop_first_ts)::numeric / v_shop_interval) + 1);
        v_lifespan_cycles := GREATEST(v_lifespan_cycles, v_shop_lifespan_cycles);
      END IF;

      v_rate := GREATEST(0.0001, LEAST(0.9999, ROUND(v_new_total::numeric / v_lifespan_cycles, 4)));
      v_interval_ms := ROUND(v_shop_interval::numeric / GREATEST(v_rate, 0.0001))::bigint;
    END IF;

    v_last_interval_ms := NULL;
    v_median_interval_ms := NULL;
    v_ema_interval_ms := NULL;

    IF v_prev_last_seen IS NOT NULL AND v_item_snapped_ts > v_prev_last_seen THEN
      v_last_interval_ms := v_item_snapped_ts - v_prev_last_seen;

      -- Session-based shops: only track intervals between sessions,
      -- skip within-session polls that don't represent real restock intervals.
      IF v_session_dedup_gap_ms IS NOT NULL AND v_last_interval_ms <= v_session_dedup_gap_ms THEN
        v_last_interval_ms := NULL;
      END IF;

      IF v_last_interval_ms IS NOT NULL THEN
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
          WHERE val IS NOT NULL AND val > 0;
        END IF;

        v_outlier_cap := COALESCE(v_median_interval_ms, v_prev_median, v_last_interval_ms) * 10;
        IF v_last_interval_ms <= v_outlier_cap THEN
          v_ema_interval_ms := CASE
            WHEN v_prev_ema IS NOT NULL
            THEN ROUND(0.15 * v_last_interval_ms + 0.85 * v_prev_ema)::bigint
            ELSE v_last_interval_ms
          END;
        ELSE
          v_ema_interval_ms := v_prev_ema;
        END IF;

        IF v_current_weather IS NOT NULL AND v_last_interval_ms > 0 THEN
          v_weather_bucket := COALESCE(v_weather_intervals->v_current_weather, '[]'::jsonb);
          v_weather_bucket := v_weather_bucket || to_jsonb(v_last_interval_ms);
          IF jsonb_array_length(v_weather_bucket) > v_weather_max_per_bucket THEN
            v_weather_bucket := (
              SELECT COALESCE(jsonb_agg(elem ORDER BY ord), '[]'::jsonb)
              FROM (
                SELECT elem, ord
                FROM jsonb_array_elements(v_weather_bucket) WITH ORDINALITY AS e(elem, ord)
                ORDER BY ord DESC
                LIMIT v_weather_max_per_bucket
              ) kept
            );
          END IF;
          v_weather_intervals := jsonb_set(v_weather_intervals, ARRAY[v_current_weather], v_weather_bucket);
        END IF;
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
$function$;

-- 2.4 rebuild_restock_history — registry JOINs instead of CASE statements
CREATE OR REPLACE FUNCTION public.rebuild_restock_history()
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
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
      shop_type, item_id, ts, qty, weather_id
    FROM filtered
    ORDER BY shop_type, item_id, ts, qty DESC NULLS LAST
  )
  INSERT INTO restock_item_events(shop_type, item_id, timestamp, quantity)
  SELECT d.shop_type, d.item_id, d.ts, d.qty
  FROM dedup d
  ORDER BY d.shop_type, d.item_id, d.ts;

  INSERT INTO restock_history (
    item_id, shop_type, total_occurrences, total_quantity,
    first_seen, last_seen, average_quantity, last_quantity
  )
  SELECT
    e.item_id, e.shop_type,
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
      shop_type, item_id, quantity
    FROM restock_item_events
    ORDER BY shop_type, item_id, timestamp DESC
  ) sub
  WHERE h.item_id = sub.item_id
    AND h.shop_type = sub.shop_type;

  -- Interval stats with celestial micro-gap filter.
  WITH intervals AS (
    SELECT
      item_id, shop_type, timestamp AS ts,
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
    SELECT * FROM filtered WHERE rn_desc <= 40
  ),
  recent_stats AS (
    SELECT
      item_id, shop_type,
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

  UPDATE restock_history
  SET ema_interval_ms = compute_ema_from_array(recent_intervals_ms, 0.15, median_interval_ms)
  WHERE recent_intervals_ms IS NOT NULL;

  -- Weather-stratified intervals from historical data.
  WITH event_weather AS (
    SELECT
      d.shop_type, d.item_id, d.ts, d.qty,
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
      ew.item_id, ew.shop_type, ew.weather_id, ew.ts,
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
      item_id, shop_type,
      jsonb_object_agg(weather_id, intervals_arr) AS weather_intervals
    FROM (
      SELECT
        item_id, shop_type, weather_id,
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

  -- Rate and derived fields — registry-driven cycle intervals
  WITH shop_spans AS (
    SELECT shop_type,
      MIN(timestamp) AS shop_first_ts,
      MAX(timestamp) AS shop_last_ts
    FROM restock_events
    GROUP BY shop_type
  )
  UPDATE restock_history h
  SET appearance_rate = CASE
        WHEN h.first_seen IS NOT NULL AND h.last_seen IS NOT NULL AND h.last_seen > h.first_seen
        THEN GREATEST(0.0001, LEAST(0.9999, ROUND(
          h.total_occurrences::numeric / GREATEST(
            GREATEST(1, ROUND((h.last_seen - h.first_seen)::numeric / reg.cycle_interval_ms) + 1),
            GREATEST(1, ROUND((COALESCE(ss.shop_last_ts, h.last_seen) - COALESCE(ss.shop_first_ts, h.first_seen))::numeric / reg.cycle_interval_ms) + 1)
          ), 4)))
        WHEN scs.total_cycles > 0
        THEN GREATEST(0.0001, LEAST(0.9999, ROUND(h.total_occurrences::numeric /
          GREATEST(scs.total_cycles,
            GREATEST(1, ROUND((COALESCE(ss.shop_last_ts, 0) - COALESCE(ss.shop_first_ts, 0))::numeric / reg.cycle_interval_ms) + 1)
          ), 4)))
        ELSE NULL
      END,
      average_interval_ms = CASE
        WHEN scs.total_cycles > 0 AND h.total_occurrences > 0
        THEN ROUND(
          reg.cycle_interval_ms::numeric / LEAST(1.0, h.total_occurrences::numeric / scs.total_cycles)
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
  JOIN shop_type_registry reg ON reg.shop_type = h.shop_type
  LEFT JOIN shop_spans ss ON ss.shop_type = h.shop_type
  WHERE scs.shop_type = h.shop_type;
END;
$function$;


-- ============================================================================
-- Phase 3: Replace hardcoded views with registry JOINs
-- ============================================================================

-- 3.1 restock_item_interval_stats — replace CASE cycle_ms with registry JOIN
CREATE OR REPLACE VIEW public.restock_item_interval_stats AS
 WITH clock AS (
         SELECT (EXTRACT(epoch FROM now()) * 1000::numeric)::bigint AS now_ms
        ), meta AS (
         SELECT COALESCE(( SELECT restock_algorithm_meta.algorithm_version
                   FROM restock_algorithm_meta
                  WHERE restock_algorithm_meta.id = 1), 'adaptive-v15-estimator-v2-phase-b-slice2'::text) AS algorithm_version,
            COALESCE(( SELECT (EXTRACT(epoch FROM restock_algorithm_meta.updated_at) * 1000::numeric)::bigint AS int8
                   FROM restock_algorithm_meta
                  WHERE restock_algorithm_meta.id = 1), (EXTRACT(epoch FROM now()) * 1000::numeric)::bigint) AS algorithm_updated_at_ms
        ), current_weather AS (
         SELECT ( SELECT weather_events.weather_id
                   FROM weather_events
                  ORDER BY weather_events."timestamp" DESC
                 LIMIT 1) AS weather_id
        ), base AS (
         SELECT h.item_id,
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
            COALESCE(reg.cycle_interval_ms::numeric, 300000::numeric) AS cycle_ms,
                CASE
                    WHEN h.last_seen IS NULL THEN NULL::numeric
                    ELSE GREATEST(0::numeric, (c.now_ms - h.last_seen)::numeric)
                END AS elapsed_ms,
            c.now_ms,
            wm.weather_values_ms,
            wm.weather_median_ms,
            wm.weather_samples,
            cw.weather_id AS current_weather,
            sm.model_name AS selected_model_name,
            sm.test_events AS selected_model_test_events,
            sm.within_one_cycle_pct AS selected_model_within_one_cycle_pct
           FROM restock_history h
             CROSS JOIN clock c
             CROSS JOIN current_weather cw
             LEFT JOIN shop_type_registry reg ON reg.shop_type = h.shop_type
             LEFT JOIN LATERAL ( WITH weather_vals AS (
                         SELECT weather_data.raw_val::bigint AS val,
                            weather_data.ord
                           FROM jsonb_array_elements_text(
                                CASE
                                    WHEN cw.weather_id IS NOT NULL AND h.weather_intervals IS NOT NULL AND jsonb_typeof(h.weather_intervals) = 'object'::text AND h.weather_intervals ? cw.weather_id THEN h.weather_intervals -> cw.weather_id
                                    ELSE '[]'::jsonb
                                END) WITH ORDINALITY weather_data(raw_val, ord)
                          WHERE weather_data.raw_val::bigint > 0
                        )
                 SELECT array_agg(weather_vals.val ORDER BY weather_vals.ord) AS weather_values_ms,
                    percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (weather_vals.val::double precision))::numeric AS weather_median_ms,
                    count(*)::integer AS weather_samples
                   FROM weather_vals) wm ON true
             LEFT JOIN LATERAL ( SELECT s.model_name,
                    s.test_events,
                    s.within_one_cycle_pct
                   FROM restock_item_selected_models s
                  WHERE s.shop_type = h.shop_type AND s.item_id = h.item_id
                  ORDER BY s.run_at DESC NULLS LAST
                 LIMIT 1) sm ON true
        )
 SELECT b.item_id,
    b.shop_type,
    b.median_interval_ms,
    b.ema_interval_ms,
    b.base_rate,
    b.last_seen,
    b.average_quantity,
    b.total_quantity,
    b.total_occurrences,
    b.last_interval_ms,
    b.recent_intervals_ms,
    b.average_interval_ms,
    b.weather_intervals,
    b.cycle_ms,
    b.elapsed_ms,
    b.now_ms,
    b.weather_values_ms,
    b.weather_median_ms,
    b.weather_samples,
    b.current_weather,
    b.selected_model_name,
    b.selected_model_test_events,
    b.selected_model_within_one_cycle_pct,
    COALESCE(cardinality(b.recent_intervals_ms), 0) AS interval_samples,
    COALESCE(surv.survivors, 0::bigint) AS survivors,
    COALESCE(surv.hits, 0::bigint) AS hits,
    surv.mean_remaining_ms,
    rs.recent_mean_ms,
    rs.recent_p50_ms,
    rs.recent_p80_ms,
    rs.recent_trimmed_mean_ms,
    restock_array_tail_percentile_ms(b.recent_intervals_ms, 8, 0.5::double precision) AS rolling_median_w8_ms,
    restock_array_tail_percentile_ms(b.recent_intervals_ms, 16, 0.5::double precision) AS rolling_median_w16_ms,
    restock_array_tail_percentile_ms(b.recent_intervals_ms, 24, 0.5::double precision) AS rolling_median_w24_ms,
    restock_array_tail_percentile_ms(b.recent_intervals_ms, 40, 0.5::double precision) AS rolling_median_w40_ms,
    restock_array_tail_percentile_ms(b.recent_intervals_ms, 80, 0.5::double precision) AS rolling_median_w80_ms,
    restock_array_tail_mean_ms(b.recent_intervals_ms, 8) AS rolling_mean_w8_ms,
    restock_array_tail_mean_ms(b.recent_intervals_ms, 16) AS rolling_mean_w16_ms,
    restock_array_tail_mean_ms(b.recent_intervals_ms, 24) AS rolling_mean_w24_ms,
    restock_array_tail_mean_ms(b.recent_intervals_ms, 40) AS rolling_mean_w40_ms,
    restock_array_tail_mean_ms(b.recent_intervals_ms, 80) AS rolling_mean_w80_ms,
    restock_array_tail_trimmed_mean_ms(b.recent_intervals_ms, 8, 0.10) AS trimmed_mean_w8_ms,
    restock_array_tail_trimmed_mean_ms(b.recent_intervals_ms, 16, 0.10) AS trimmed_mean_w16_ms,
    restock_array_tail_trimmed_mean_ms(b.recent_intervals_ms, 24, 0.10) AS trimmed_mean_w24_ms,
    restock_array_tail_trimmed_mean_ms(b.recent_intervals_ms, 40, 0.10) AS trimmed_mean_w40_ms,
    restock_array_tail_trimmed_mean_ms(b.recent_intervals_ms, 80, 0.10) AS trimmed_mean_w80_ms,
    lb.lookback_median_30d_ms,
    lb.lookback_median_90d_ms,
    lb.lookback_median_180d_ms,
    restock_array_tail_percentile_ms(b.weather_values_ms, 20, 0.5::double precision) AS weather_median_w20_ms,
    restock_array_tail_percentile_ms(b.weather_values_ms, 40, 0.5::double precision) AS weather_median_w40_ms,
    restock_array_tail_percentile_ms(b.weather_values_ms, 80, 0.5::double precision) AS weather_median_w80_ms,
        CASE
            WHEN COALESCE(cardinality(b.recent_intervals_ms), 0) <= 3 THEN 8.0
            WHEN COALESCE(cardinality(b.recent_intervals_ms), 0) <= 10 THEN 6.0
            WHEN COALESCE(cardinality(b.recent_intervals_ms), 0) <= 20 THEN 4.0
            ELSE GREATEST(2.0, 8.0 - COALESCE(cardinality(b.recent_intervals_ms), 0)::numeric / 10.0)
        END AS pseudo_n,
    LEAST(0.9999, GREATEST(0.0001, COALESCE(b.base_rate, 0.0001))) AS fallback_rate,
        CASE
            WHEN b.current_weather IS NULL THEN false
            WHEN b.weather_median_ms IS NULL OR b.weather_median_ms <= 0::numeric THEN false
            WHEN b.weather_samples IS NULL OR b.weather_samples < 20 THEN false
            WHEN b.median_interval_ms IS NULL OR b.median_interval_ms <= 0 THEN false
            WHEN b.weather_median_ms < (b.median_interval_ms::numeric * 0.35) THEN false
            WHEN b.weather_median_ms > (b.median_interval_ms::numeric * 2.5) THEN false
            ELSE true
        END AS weather_used,
        CASE
            WHEN b.current_weather IS NULL THEN 'no_current_weather'::text
            WHEN b.weather_median_ms IS NULL OR b.weather_median_ms <= 0::numeric THEN 'missing_weather_bucket'::text
            WHEN b.weather_samples IS NULL OR b.weather_samples < 20 THEN 'too_few_samples'::text
            WHEN b.median_interval_ms IS NULL OR b.median_interval_ms <= 0 THEN 'outside_safe_ratio'::text
            WHEN b.weather_median_ms < (b.median_interval_ms::numeric * 0.35) OR b.weather_median_ms > (b.median_interval_ms::numeric * 2.5) THEN 'outside_safe_ratio'::text
            ELSE 'used'::text
        END AS weather_rejected_reason,
        CASE
            WHEN b.current_weather IS NULL THEN NULL::numeric
            WHEN b.weather_median_ms IS NULL OR b.weather_median_ms <= 0::numeric THEN NULL::numeric
            WHEN b.weather_samples IS NULL OR b.weather_samples < 20 THEN NULL::numeric
            WHEN b.median_interval_ms IS NULL OR b.median_interval_ms <= 0 THEN NULL::numeric
            WHEN b.weather_median_ms < (b.median_interval_ms::numeric * 0.35) THEN NULL::numeric
            WHEN b.weather_median_ms > (b.median_interval_ms::numeric * 2.5) THEN NULL::numeric
            ELSE b.weather_median_ms
        END AS effective_weather_median_ms,
    m.algorithm_version,
    m.algorithm_updated_at_ms
   FROM base b
     CROSS JOIN meta m
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE val.val::numeric > b.elapsed_ms) AS survivors,
            count(*) FILTER (WHERE val.val::numeric > b.elapsed_ms AND val.val::numeric <= (b.elapsed_ms + b.cycle_ms)) AS hits,
            avg(val.val::numeric - b.elapsed_ms) FILTER (WHERE val.val::numeric > b.elapsed_ms) AS mean_remaining_ms
           FROM unnest(b.recent_intervals_ms) val(val)
          WHERE val.val IS NOT NULL AND val.val > 0) surv ON true
     LEFT JOIN LATERAL ( WITH vals AS (
                 SELECT x.x::numeric AS val
                   FROM unnest(b.recent_intervals_ms) x(x)
                  WHERE x.x IS NOT NULL AND x.x > 0
                ), ranked AS (
                 SELECT vals.val,
                    row_number() OVER (ORDER BY vals.val) AS rn,
                    count(*) OVER () AS cnt
                   FROM vals
                )
         SELECT avg(ranked.val) AS recent_mean_ms,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (ranked.val::double precision))::numeric AS recent_p50_ms,
            percentile_cont(0.8::double precision) WITHIN GROUP (ORDER BY (ranked.val::double precision))::numeric AS recent_p80_ms,
            COALESCE(avg(ranked.val) FILTER (WHERE ranked.rn > GREATEST(1, floor(ranked.cnt::numeric * 0.10)::integer) AND ranked.rn <= LEAST(ranked.cnt, ceil(ranked.cnt::numeric * 0.90)::integer::bigint)), avg(ranked.val)) AS recent_trimmed_mean_ms
           FROM ranked) rs ON true
     LEFT JOIN LATERAL ( WITH item_intervals AS (
                 SELECT e."timestamp",
                    e."timestamp" - lag(e."timestamp") OVER (ORDER BY e."timestamp") AS interval_ms
                   FROM restock_item_events e
                  WHERE e.shop_type = b.shop_type AND e.item_id = b.item_id AND e."timestamp" >= (b.now_ms - 180::bigint * 86400000)
                )
         SELECT percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (item_intervals.interval_ms::double precision)) FILTER (WHERE item_intervals.interval_ms > 0 AND item_intervals."timestamp" >= (b.now_ms - 30::bigint * 86400000))::numeric AS lookback_median_30d_ms,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (item_intervals.interval_ms::double precision)) FILTER (WHERE item_intervals.interval_ms > 0 AND item_intervals."timestamp" >= (b.now_ms - 90::bigint * 86400000))::numeric AS lookback_median_90d_ms,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (item_intervals.interval_ms::double precision)) FILTER (WHERE item_intervals.interval_ms > 0)::numeric AS lookback_median_180d_ms
           FROM item_intervals) lb ON true;

-- 3.2 restock_predictions — replace dawn-specific logic with registry config
-- Need to drop and recreate matview since the underlying view changes
DROP MATERIALIZED VIEW IF EXISTS public.restock_predictions_mat;

CREATE OR REPLACE VIEW public.restock_predictions AS
 WITH empirical AS (
         SELECT mr.item_id,
            mr.shop_type,
            mr.median_interval_ms,
            mr.ema_interval_ms,
            mr.base_rate,
            mr.last_seen,
            mr.average_quantity,
            mr.total_quantity,
            mr.total_occurrences,
            mr.last_interval_ms,
            mr.recent_intervals_ms,
            mr.average_interval_ms,
            mr.weather_intervals,
            mr.cycle_ms,
            mr.elapsed_ms,
            mr.now_ms,
            mr.weather_values_ms,
            mr.weather_median_ms,
            mr.weather_samples,
            mr.current_weather,
            mr.selected_model_name,
            mr.selected_model_test_events,
            mr.selected_model_within_one_cycle_pct,
            mr.interval_samples,
            mr.survivors,
            mr.hits,
            mr.mean_remaining_ms,
            mr.recent_mean_ms,
            mr.recent_p50_ms,
            mr.recent_p80_ms,
            mr.recent_trimmed_mean_ms,
            mr.rolling_median_w8_ms,
            mr.rolling_median_w16_ms,
            mr.rolling_median_w24_ms,
            mr.rolling_median_w40_ms,
            mr.rolling_median_w80_ms,
            mr.rolling_mean_w8_ms,
            mr.rolling_mean_w16_ms,
            mr.rolling_mean_w24_ms,
            mr.rolling_mean_w40_ms,
            mr.rolling_mean_w80_ms,
            mr.trimmed_mean_w8_ms,
            mr.trimmed_mean_w16_ms,
            mr.trimmed_mean_w24_ms,
            mr.trimmed_mean_w40_ms,
            mr.trimmed_mean_w80_ms,
            mr.lookback_median_30d_ms,
            mr.lookback_median_90d_ms,
            mr.lookback_median_180d_ms,
            mr.weather_median_w20_ms,
            mr.weather_median_w40_ms,
            mr.weather_median_w80_ms,
            mr.pseudo_n,
            mr.fallback_rate,
            mr.weather_used,
            mr.weather_rejected_reason,
            mr.effective_weather_median_ms,
            mr.algorithm_version,
            mr.algorithm_updated_at_ms,
            mr.model_baseline_ms,
            mr.fallback_baseline_ms,
            mr.bias_factor_applied,
            mr.baseline_interval_ms,
                CASE
                    WHEN mr.elapsed_ms IS NULL OR mr.interval_samples = 0 THEN NULL::numeric
                    WHEN mr.survivors <= 0 THEN LEAST(0.9999, GREATEST(mr.fallback_rate, mr.fallback_rate * LEAST(3.0, 1.0 + COALESCE(mr.elapsed_ms / NULLIF(mr.baseline_interval_ms, 0::numeric), 0::numeric))))
                    ELSE LEAST(0.9999, GREATEST(0.0001, (mr.hits::numeric + mr.pseudo_n * mr.fallback_rate) / (mr.survivors::numeric + mr.pseudo_n)))
                END AS empirical_probability
           FROM restock_item_baseline mr
        ), error_weight AS (
         SELECT e.item_id,
            e.shop_type,
            e.median_interval_ms,
            e.ema_interval_ms,
            e.base_rate,
            e.last_seen,
            e.average_quantity,
            e.total_quantity,
            e.total_occurrences,
            e.last_interval_ms,
            e.recent_intervals_ms,
            e.average_interval_ms,
            e.weather_intervals,
            e.cycle_ms,
            e.elapsed_ms,
            e.now_ms,
            e.weather_values_ms,
            e.weather_median_ms,
            e.weather_samples,
            e.current_weather,
            e.selected_model_name,
            e.selected_model_test_events,
            e.selected_model_within_one_cycle_pct,
            e.interval_samples,
            e.survivors,
            e.hits,
            e.mean_remaining_ms,
            e.recent_mean_ms,
            e.recent_p50_ms,
            e.recent_p80_ms,
            e.recent_trimmed_mean_ms,
            e.rolling_median_w8_ms,
            e.rolling_median_w16_ms,
            e.rolling_median_w24_ms,
            e.rolling_median_w40_ms,
            e.rolling_median_w80_ms,
            e.rolling_mean_w8_ms,
            e.rolling_mean_w16_ms,
            e.rolling_mean_w24_ms,
            e.rolling_mean_w40_ms,
            e.rolling_mean_w80_ms,
            e.trimmed_mean_w8_ms,
            e.trimmed_mean_w16_ms,
            e.trimmed_mean_w24_ms,
            e.trimmed_mean_w40_ms,
            e.trimmed_mean_w80_ms,
            e.lookback_median_30d_ms,
            e.lookback_median_90d_ms,
            e.lookback_median_180d_ms,
            e.weather_median_w20_ms,
            e.weather_median_w40_ms,
            e.weather_median_w80_ms,
            e.pseudo_n,
            e.fallback_rate,
            e.weather_used,
            e.weather_rejected_reason,
            e.effective_weather_median_ms,
            e.algorithm_version,
            e.algorithm_updated_at_ms,
            e.model_baseline_ms,
            e.fallback_baseline_ms,
            e.bias_factor_applied,
            e.baseline_interval_ms,
            e.empirical_probability,
            COALESCE(w.error_tuned_weight, LEAST(0.92, GREATEST(0.08, e.interval_samples::numeric / 14.0))) AS empirical_weight
           FROM empirical e
             LEFT JOIN LATERAL ( WITH arr AS (
                         SELECT COALESCE(e.recent_intervals_ms, ARRAY[]::bigint[]) AS a
                        ), idx AS (
                         SELECT g.i
                           FROM arr,
                            LATERAL generate_subscripts(arr.a, 1) g(i)
                          WHERE g.i >= 6
                        ), calc AS (
                         SELECT idx.i,
                            ( SELECT avg(arr.a[j.j]::numeric) AS avg
                                   FROM generate_series(GREATEST(1, idx.i - 5), idx.i - 1) j(j)) AS empirical_pred_ms,
                            arr.a[idx.i]::numeric AS actual_ms,
                            e.baseline_interval_ms AS base_pred_ms
                           FROM arr,
                            idx
                        ), errs AS (
                         SELECT count(*)::numeric AS n,
                            avg(abs(calc.actual_ms - calc.empirical_pred_ms)) AS mae_emp,
                            avg(abs(calc.actual_ms - calc.base_pred_ms)) AS mae_base
                           FROM calc
                          WHERE calc.empirical_pred_ms IS NOT NULL AND calc.actual_ms IS NOT NULL AND calc.actual_ms > 0::numeric AND calc.base_pred_ms IS NOT NULL AND calc.base_pred_ms > 0::numeric
                        )
                 SELECT
                        CASE
                            WHEN errs.n < 6::numeric OR errs.mae_emp IS NULL OR errs.mae_base IS NULL THEN NULL::numeric
                            ELSE LEAST(0.95, GREATEST(0.05, errs.mae_base / NULLIF(errs.mae_base + errs.mae_emp, 0::numeric) * (errs.n / (errs.n + 4.0))))
                        END AS error_tuned_weight
                   FROM errs) w ON true
        ), final_probability AS (
         SELECT p_1.item_id,
            p_1.shop_type,
            p_1.median_interval_ms,
            p_1.ema_interval_ms,
            p_1.base_rate,
            p_1.last_seen,
            p_1.average_quantity,
            p_1.total_quantity,
            p_1.total_occurrences,
            p_1.last_interval_ms,
            p_1.recent_intervals_ms,
            p_1.average_interval_ms,
            p_1.weather_intervals,
            p_1.cycle_ms,
            p_1.elapsed_ms,
            p_1.now_ms,
            p_1.weather_values_ms,
            p_1.weather_median_ms,
            p_1.weather_samples,
            p_1.current_weather,
            p_1.selected_model_name,
            p_1.selected_model_test_events,
            p_1.selected_model_within_one_cycle_pct,
            p_1.interval_samples,
            p_1.survivors,
            p_1.hits,
            p_1.mean_remaining_ms,
            p_1.recent_mean_ms,
            p_1.recent_p50_ms,
            p_1.recent_p80_ms,
            p_1.recent_trimmed_mean_ms,
            p_1.rolling_median_w8_ms,
            p_1.rolling_median_w16_ms,
            p_1.rolling_median_w24_ms,
            p_1.rolling_median_w40_ms,
            p_1.rolling_median_w80_ms,
            p_1.rolling_mean_w8_ms,
            p_1.rolling_mean_w16_ms,
            p_1.rolling_mean_w24_ms,
            p_1.rolling_mean_w40_ms,
            p_1.rolling_mean_w80_ms,
            p_1.trimmed_mean_w8_ms,
            p_1.trimmed_mean_w16_ms,
            p_1.trimmed_mean_w24_ms,
            p_1.trimmed_mean_w40_ms,
            p_1.trimmed_mean_w80_ms,
            p_1.lookback_median_30d_ms,
            p_1.lookback_median_90d_ms,
            p_1.lookback_median_180d_ms,
            p_1.weather_median_w20_ms,
            p_1.weather_median_w40_ms,
            p_1.weather_median_w80_ms,
            p_1.pseudo_n,
            p_1.fallback_rate,
            p_1.weather_used,
            p_1.weather_rejected_reason,
            p_1.effective_weather_median_ms,
            p_1.algorithm_version,
            p_1.algorithm_updated_at_ms,
            p_1.model_baseline_ms,
            p_1.fallback_baseline_ms,
            p_1.bias_factor_applied,
            p_1.baseline_interval_ms,
            p_1.empirical_probability,
            p_1.empirical_weight,
                CASE
                    WHEN p_1.elapsed_ms IS NULL THEN false
                    WHEN p_1.elapsed_ms > GREATEST(COALESCE(p_1.median_interval_ms::numeric, p_1.baseline_interval_ms) * 20::numeric, 604800000::numeric) THEN true
                    ELSE false
                END AS is_dormant,
                CASE
                    WHEN p_1.elapsed_ms IS NOT NULL AND p_1.elapsed_ms > GREATEST(COALESCE(p_1.median_interval_ms::numeric, p_1.baseline_interval_ms) * 20::numeric, 604800000::numeric) THEN GREATEST(0.0001, p_1.fallback_rate * 0.1)
                    ELSE LEAST(0.9999, GREATEST(0.0001, p_1.fallback_rate * 0.2, (1.0 - p_1.empirical_weight) * p_1.fallback_rate + p_1.empirical_weight * COALESCE(p_1.empirical_probability, p_1.fallback_rate)))
                END AS current_probability
           FROM error_weight p_1
        )
 SELECT p.item_id,
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
            ELSE ( SELECT
                    CASE
                        WHEN (reg.config->>'weather_gated') IS NOT NULL THEN
                          GREATEST(
                            (sub.base_eta + (reg.config->>'weather_snap_grid_ms')::bigint / 2)
                              / (reg.config->>'weather_snap_grid_ms')::bigint
                              * (reg.config->>'weather_snap_grid_ms')::bigint,
                            COALESCE(
                              (SELECT wp.estimated_next_timestamp
                               FROM weather_predictions wp
                               WHERE wp.weather_id = reg.config->>'weather_gated'),
                              (sub.base_eta + (reg.config->>'weather_snap_grid_ms')::bigint / 2)
                                / (reg.config->>'weather_snap_grid_ms')::bigint
                                * (reg.config->>'weather_snap_grid_ms')::bigint
                            )
                          )
                        ELSE sub.base_eta
                    END AS base_eta
               FROM ( SELECT GREATEST(p.now_ms + p.cycle_ms::bigint,
                            CASE
                                WHEN p.last_seen IS NULL THEN p.now_ms + p.cycle_ms::bigint
                                WHEN p.baseline_interval_ms IS NULL THEN p.now_ms + p.cycle_ms::bigint
                                WHEN (p.last_seen + p.baseline_interval_ms::bigint) >= p.now_ms THEN p.last_seen + p.baseline_interval_ms::bigint
                                ELSE p.now_ms + GREATEST(p.cycle_ms::bigint, COALESCE(p.mean_remaining_ms::bigint, GREATEST(p.cycle_ms::bigint, (p.baseline_interval_ms * GREATEST(0.1, 1.0 - p.elapsed_ms / NULLIF(p.baseline_interval_ms * 3.0, 0::numeric)))::bigint)))
                            END) AS base_eta) sub)
        END AS estimated_next_timestamp,
    p.baseline_interval_ms::bigint AS expected_interval_ms,
    p.last_interval_ms,
    p.algorithm_version,
    p.algorithm_updated_at_ms,
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
   LEFT JOIN shop_type_registry reg ON reg.shop_type = p.shop_type;

-- 3.3 Recreate materialized view (matching original index name and column order)
CREATE MATERIALIZED VIEW public.restock_predictions_mat AS
  SELECT * FROM public.restock_predictions;

CREATE UNIQUE INDEX idx_restock_predictions_mat_pk
  ON public.restock_predictions_mat (shop_type, item_id);

-- Refresh to populate
REFRESH MATERIALIZED VIEW public.restock_predictions_mat;

-- Restrict register_shop_type to service_role only (not anon/authenticated)
REVOKE EXECUTE ON FUNCTION public.register_shop_type(text, bigint, text) FROM anon, authenticated;
