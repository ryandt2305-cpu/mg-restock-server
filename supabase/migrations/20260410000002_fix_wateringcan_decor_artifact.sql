-- WateringCan/WateringCans was historically ingested under shop_type='decor'
-- (before tool shop support was added). These are tool-only items and must not
-- appear in decor (or any other non-tool) history.
--
-- Fix in two parts:
--   1) Update is_valid_restock_item to reject WateringCan* outside 'tool'.
--      This means any future rebuild will naturally discard those events.
--   2) Explicitly delete the bad rows and rebuild.

-- ============================================================
-- 1) Tighten is_valid_restock_item
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
    )
    -- WateringCan is a tool-only item; reject it under any other shop type.
    AND NOT (
      p_shop_type != 'tool'
      AND p_item_id IN ('WateringCan', 'WateringCans')
    );
$$;

-- ============================================================
-- 2) Delete bad history + event rows for non-tool WateringCan*
-- ============================================================

DELETE FROM public.restock_item_events
WHERE item_id IN ('WateringCan', 'WateringCans')
  AND shop_type != 'tool';

DELETE FROM public.restock_history
WHERE item_id IN ('WateringCan', 'WateringCans')
  AND shop_type != 'tool';

-- ============================================================
-- 3) Rebuild so interval/rate stats are recalculated cleanly
-- ============================================================

SELECT rebuild_restock_history();
