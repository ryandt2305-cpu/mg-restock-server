-- Normalize "WateringCans" (plural) → "WateringCan" in canonical_restock_item_id
-- so future ingestion never creates a second row.

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
    WHEN p_shop_type = 'seed' AND p_item_id = 'StarweaverPod'                   THEN 'Starweaver'

    -- Tool plural normalization
    WHEN p_shop_type = 'tool' AND p_item_id = 'WateringCans'                    THEN 'WateringCan'

    ELSE p_item_id
  END;
$$;

-- -----------------------------------------------------------------------
-- Direct cleanup: merge the live WateringCans row into WateringCan and
-- delete it. This runs immediately on migration apply, before the rebuild.
-- -----------------------------------------------------------------------

-- 1. Re-canonicalize any WateringCans rows already in restock_item_events.
--    ON CONFLICT keeps the max quantity for any timestamp that already has
--    a WateringCan event, otherwise inserts the renamed row.
INSERT INTO public.restock_item_events (shop_type, item_id, timestamp, quantity)
SELECT shop_type, 'WateringCan', timestamp, quantity
FROM public.restock_item_events
WHERE shop_type = 'tool' AND item_id = 'WateringCans'
ON CONFLICT (shop_type, item_id, timestamp) DO UPDATE
  SET quantity = GREATEST(restock_item_events.quantity, EXCLUDED.quantity);

DELETE FROM public.restock_item_events WHERE shop_type = 'tool' AND item_id = 'WateringCans';

-- 2. Merge the WateringCans history row into WateringCan, then delete it.
INSERT INTO public.restock_history (
  item_id, shop_type, total_occurrences, total_quantity,
  first_seen, last_seen, average_quantity, last_quantity,
  average_interval_ms, estimated_next_timestamp, rate_per_day,
  recent_intervals_ms, median_interval_ms, last_interval_ms, appearance_rate
)
SELECT
  'WateringCan', shop_type,
  total_occurrences, total_quantity,
  first_seen, last_seen, average_quantity, last_quantity,
  average_interval_ms, estimated_next_timestamp, rate_per_day,
  recent_intervals_ms, median_interval_ms, last_interval_ms, appearance_rate
FROM public.restock_history
WHERE shop_type = 'tool' AND item_id = 'WateringCans'
ON CONFLICT (item_id, shop_type) DO UPDATE
  SET total_occurrences      = restock_history.total_occurrences + EXCLUDED.total_occurrences,
      total_quantity         = restock_history.total_quantity + EXCLUDED.total_quantity,
      first_seen             = LEAST(restock_history.first_seen, EXCLUDED.first_seen),
      last_seen              = GREATEST(restock_history.last_seen, EXCLUDED.last_seen),
      average_quantity       = ROUND(
                                 (restock_history.total_quantity + EXCLUDED.total_quantity)
                                 / NULLIF(restock_history.total_occurrences + EXCLUDED.total_occurrences, 0),
                                 2),
      last_quantity          = CASE
                                 WHEN EXCLUDED.last_seen > restock_history.last_seen
                                 THEN EXCLUDED.last_quantity
                                 ELSE restock_history.last_quantity
                               END;

DELETE FROM public.restock_history WHERE shop_type = 'tool' AND item_id = 'WateringCans';

-- 3. Full rebuild so interval stats, appearance_rate, and predictions are
--    recalculated correctly from the now-merged event log.
SELECT rebuild_restock_history();
