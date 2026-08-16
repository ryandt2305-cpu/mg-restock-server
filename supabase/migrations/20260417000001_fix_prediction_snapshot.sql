-- Fix prediction snapshot in ingest_restock_history.
--
-- The previous migration (20260416000002) snapshots estimated_next_timestamp
-- from the restock_predictions VIEW. For rare/overdue items (e.g. Moonbinder
-- with ~0.05% probability), the view computes:
--
--   now_ms + (cycle_ms / probability) ≈ now + 21 days
--
-- When the actual event happens at `now`, diffMs = now - (now+21d) = -21d,
-- producing a bogus "20d 19h early" accuracy reading.
--
-- Fix: snapshot the interval-based prediction (last_seen + median) from
-- restock_history instead. This matches the metric the client uses for
-- accuracy scoring and produces correct results for all item frequencies.

-- ============================================================
-- 1) Re-create ingest_restock_history with fixed prediction snapshot
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

  v_predicted_next bigint;
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

    -- Snapshot the interval-based prediction (last_seen + median/average).
    -- This is the same metric the client uses for accuracy scoring.
    -- Avoids the restock_predictions VIEW which uses probability-based
    -- catch-up that produces wildly wrong values for rare items.
    SELECT h.last_seen + COALESCE(h.median_interval_ms, h.average_interval_ms)
      INTO v_predicted_next
    FROM restock_history h
    WHERE h.item_id = v_item_id
      AND h.shop_type = v_shop_type;

    INSERT INTO restock_item_events(shop_type, item_id, timestamp, quantity, predicted_next_ms)
    VALUES (v_shop_type, v_item_id, v_snapped_ts, v_stock, v_predicted_next)
    ON CONFLICT (shop_type, item_id, timestamp) DO UPDATE
      SET quantity = CASE
        WHEN restock_item_events.quantity IS NULL THEN EXCLUDED.quantity
        WHEN EXCLUDED.quantity IS NULL THEN restock_item_events.quantity
        ELSE GREATEST(restock_item_events.quantity, EXCLUDED.quantity)
      END,
      -- Only set predicted_next_ms if not already set (don't overwrite on dedup).
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
-- 2) Bump algorithm version
-- ============================================================

INSERT INTO public.restock_algorithm_meta (id, algorithm_version, updated_at, notes)
VALUES (
  1,
  'adaptive-v6-interval-prediction',
  now(),
  'Fixed prediction snapshot: use interval-based (last_seen + median) instead of restock_predictions VIEW. Fixes Moonbinder "20d early" regression.'
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
-- 3) Rebuild to recompute predicted_next_ms for existing events
-- ============================================================

SELECT rebuild_restock_history();
