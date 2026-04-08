-- Improve restock prediction robustness and adaptability.
--
-- Goals:
-- 1) Canonicalize known celestial aliases server-side so history/predictions do not fragment.
-- 2) Keep prediction stats adaptive without full-table scans by storing recent interval windows.
-- 3) Use robust, celestial-aware interval handling to suppress obvious duplicate-report spikes.
-- 4) Ensure celestial predictions always respect the 22-day cap even when sparse history exists.

-- ============================================================
-- 1. Canonicalization + helpers
-- ============================================================

CREATE OR REPLACE FUNCTION public.canonical_restock_item_id(p_shop_type text, p_item_id text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_item_id IS NULL THEN NULL

    -- Seed celestial aliases
    WHEN p_shop_type = 'seed' AND p_item_id IN ('Dawnbinder', 'DawnbinderPod') THEN 'DawnCelestial'
    WHEN p_shop_type = 'seed' AND p_item_id IN ('Moonbinder', 'MoonbinderPod') THEN 'MoonCelestial'
    WHEN p_shop_type = 'seed' AND p_item_id = 'StarweaverPod' THEN 'Starweaver'

    ELSE p_item_id
  END;
$$;

CREATE OR REPLACE FUNCTION public.is_celestial_item_id(p_item_id text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_item_id IN ('Starweaver', 'MoonCelestial', 'DawnCelestial', 'SunCelestial');
$$;

ALTER TABLE public.restock_history
  ADD COLUMN IF NOT EXISTS recent_intervals_ms bigint[];

-- ============================================================
-- 2. Incremental ingest: canonical IDs + adaptive interval window
-- ============================================================

CREATE OR REPLACE FUNCTION public.ingest_restock_history(p_shop_type text, p_ts bigint, p_items jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  item jsonb;
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
  v_snapped_ts := restock_snap_timestamp(p_shop_type, p_ts);

  IF p_shop_type = 'seed' THEN
    v_shop_interval := 300000;
  ELSIF p_shop_type = 'egg' THEN
    v_shop_interval := 900000;
  ELSIF p_shop_type = 'decor' THEN
    v_shop_interval := 3600000;
  ELSE
    v_shop_interval := 300000;
  END IF;

  -- Increment shop cycle counter once per snapped cycle.
  UPDATE shop_cycle_stats
    SET total_cycles = total_cycles + 1,
        last_cycle_ts = v_snapped_ts
  WHERE shop_type = p_shop_type
    AND (last_cycle_ts IS NULL OR v_snapped_ts > last_cycle_ts);

  SELECT scs.total_cycles INTO v_total_cycles
  FROM shop_cycle_stats scs
  WHERE scs.shop_type = p_shop_type;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_raw_item_id := item->>'itemId';
    IF v_raw_item_id IS NULL THEN
      CONTINUE;
    END IF;

    v_item_id := canonical_restock_item_id(p_shop_type, v_raw_item_id);
    v_stock := COALESCE(NULLIF((item->>'stock')::numeric, 0), NULLIF((item->>'quantity')::numeric, 0));

    SELECT h.last_seen, h.recent_intervals_ms
    INTO v_prev_last_seen, v_recent_intervals
    FROM restock_history h
    WHERE h.item_id = v_item_id
      AND h.shop_type = p_shop_type;

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
      p_shop_type,
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
      AND h.shop_type = p_shop_type;
  END LOOP;
END;
$$;

-- ============================================================
-- 3. Rebuild: canonical IDs + snapped timestamps + recent windows
-- ============================================================

CREATE OR REPLACE FUNCTION public.rebuild_restock_history()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  TRUNCATE TABLE restock_history;

  UPDATE shop_cycle_stats scs
  SET total_cycles = sub.cnt,
      last_cycle_ts = sub.max_ts
  FROM (
    SELECT
      e.shop_type,
      COUNT(DISTINCT restock_snap_timestamp(e.shop_type, e.timestamp)) AS cnt,
      MAX(restock_snap_timestamp(e.shop_type, e.timestamp)) AS max_ts
    FROM restock_events e
    GROUP BY e.shop_type
  ) sub
  WHERE scs.shop_type = sub.shop_type;

  WITH normalized AS (
    SELECT
      canonical_restock_item_id(e.shop_type, (item->>'itemId')::text) AS item_id,
      e.shop_type,
      restock_snap_timestamp(e.shop_type, e.timestamp) AS ts,
      COALESCE(NULLIF((item->>'stock')::numeric, 0), NULLIF((item->>'quantity')::numeric, 0)) AS stock
    FROM restock_events e
    CROSS JOIN LATERAL jsonb_array_elements(e.items) AS item
    WHERE (item->>'itemId') IS NOT NULL
  ),
  dedup AS (
    SELECT DISTINCT ON (item_id, shop_type, ts)
      item_id,
      shop_type,
      ts,
      stock
    FROM normalized
    ORDER BY item_id, shop_type, ts, stock DESC NULLS LAST
  ),
  agg AS (
    SELECT
      item_id,
      shop_type,
      COUNT(*) AS total_occurrences,
      SUM(COALESCE(stock, 0)) AS total_quantity,
      MIN(ts) AS first_seen,
      MAX(ts) AS last_seen,
      AVG(stock) FILTER (WHERE stock IS NOT NULL AND stock > 0) AS average_quantity
    FROM dedup
    GROUP BY item_id, shop_type
  )
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
    a.item_id,
    a.shop_type,
    a.total_occurrences,
    a.total_quantity,
    a.first_seen,
    a.last_seen,
    a.average_quantity,
    NULL::numeric
  FROM agg a;

  -- last_quantity from latest deduped snapshot per item/shop
  WITH normalized AS (
    SELECT
      canonical_restock_item_id(e.shop_type, (item->>'itemId')::text) AS item_id,
      e.shop_type,
      restock_snap_timestamp(e.shop_type, e.timestamp) AS ts,
      COALESCE(NULLIF((item->>'stock')::numeric, 0), NULLIF((item->>'quantity')::numeric, 0)) AS stock
    FROM restock_events e
    CROSS JOIN LATERAL jsonb_array_elements(e.items) AS item
    WHERE (item->>'itemId') IS NOT NULL
  ),
  dedup AS (
    SELECT DISTINCT ON (item_id, shop_type, ts)
      item_id,
      shop_type,
      ts,
      stock
    FROM normalized
    ORDER BY item_id, shop_type, ts DESC, stock DESC NULLS LAST
  )
  UPDATE restock_history h
  SET last_quantity = d.stock
  FROM dedup d
  WHERE h.item_id = d.item_id
    AND h.shop_type = d.shop_type
    AND d.ts = h.last_seen;

  -- Interval stats: recent window + robust celestial filtering
  WITH normalized AS (
    SELECT
      canonical_restock_item_id(e.shop_type, (item->>'itemId')::text) AS item_id,
      e.shop_type,
      restock_snap_timestamp(e.shop_type, e.timestamp) AS ts
    FROM restock_events e
    CROSS JOIN LATERAL jsonb_array_elements(e.items) AS item
    WHERE (item->>'itemId') IS NOT NULL
  ),
  dedup AS (
    SELECT DISTINCT item_id, shop_type, ts
    FROM normalized
  ),
  intervals AS (
    SELECT
      item_id,
      shop_type,
      ts,
      ts - LAG(ts) OVER (PARTITION BY item_id, shop_type ORDER BY ts) AS interval_ms,
      ROW_NUMBER() OVER (PARTITION BY item_id, shop_type ORDER BY ts DESC) AS rn_desc
    FROM dedup
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
        WHEN h.total_occurrences > 1 AND h.first_seen IS NOT NULL AND h.last_seen IS NOT NULL AND h.last_seen > h.first_seen
        THEN ROUND((h.total_occurrences / ((h.last_seen - h.first_seen) / 86400000.0))::numeric, 2)
        ELSE NULL
      END
  FROM shop_cycle_stats scs
  WHERE scs.shop_type = h.shop_type;
END;
$$;

-- ============================================================
-- 4. Prediction view: stable normal model + capped celestial model
-- ============================================================

DROP VIEW IF EXISTS public.restock_predictions;

CREATE OR REPLACE VIEW public.restock_predictions AS
WITH clock AS (
  SELECT (EXTRACT(EPOCH FROM now()) * 1000)::bigint AS now_ms
),
calculations AS (
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

    CASE h.shop_type
      WHEN 'seed' THEN 300000
      WHEN 'egg' THEN 900000
      WHEN 'decor' THEN 3600000
      ELSE 300000
    END::numeric AS cycle_ms,

    is_celestial_item_id(h.item_id) AS is_celestial,

    CASE
      WHEN h.last_seen IS NULL THEN NULL
      ELSE GREATEST(0::numeric, (c.now_ms - h.last_seen)::numeric)
    END AS elapsed_ms,

    CASE
      WHEN is_celestial_item_id(h.item_id)
      THEN LEAST(
        1900800000::numeric, -- 22 days hard cap
        COALESCE(
          h.median_interval_ms::numeric,
          h.last_interval_ms::numeric,
          h.average_interval_ms::numeric,
          950400000::numeric  -- 11-day fallback
        )
      )
      ELSE COALESCE(h.median_interval_ms::numeric, h.average_interval_ms::numeric)
    END AS baseline_interval_ms,

    c.now_ms
  FROM restock_history h
  CROSS JOIN clock c
),
with_probability AS (
  SELECT
    p.*,
    CASE
      WHEN p.is_celestial AND p.elapsed_ms IS NOT NULL AND (p.elapsed_ms / 86400000.0) >= 22 THEN 0.9999
      WHEN p.is_celestial AND p.elapsed_ms IS NOT NULL AND (p.elapsed_ms / 86400000.0) >= 15 THEN LEAST(
        0.9999,
        COALESCE(p.base_rate, 0.0001)
        + (0.9999 - COALESCE(p.base_rate, 0.0001))
          * (((p.elapsed_ms / 86400000.0) - 15.0) / 7.0)
      )
      ELSE COALESCE(p.base_rate, 0.0001)
    END AS current_probability
  FROM calculations p
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
          -- Not overdue celestial
          WHEN (p.last_seen + p.baseline_interval_ms::bigint) >= p.now_ms
          THEN p.last_seen + p.baseline_interval_ms::bigint

          -- Overdue celestial: decay remaining interval toward zero at 22d cap
          ELSE p.now_ms + GREATEST(
            p.cycle_ms::bigint,
            (
              p.baseline_interval_ms
              * GREATEST(0::numeric, (1900800000::numeric - p.elapsed_ms))
              / 1900800000::numeric
            )::bigint
          )
        END

      -- Non-celestial not overdue
      WHEN (p.last_seen + p.baseline_interval_ms::bigint) >= p.now_ms
      THEN p.last_seen + p.baseline_interval_ms::bigint

      -- Non-celestial overdue (memoryless geometric)
      ELSE p.now_ms + (p.cycle_ms / GREATEST(p.current_probability, 0.0001))::bigint
    END
  ) AS estimated_next_timestamp,

  p.baseline_interval_ms::bigint AS expected_interval_ms,
  p.last_interval_ms

FROM with_probability p;

-- ============================================================
-- 5. Rebuild once so new canonical/adaptive stats are populated
-- ============================================================
SELECT rebuild_restock_history();
