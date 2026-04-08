-- Allow anon key to read restock_events (required by QPM-GR item detail view).
-- RLS was enabled in 20260207000004 but no read policy was added for anon.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'restock_events'
      AND policyname = 'anon_read_restock_events'
  ) THEN
    CREATE POLICY "anon_read_restock_events"
      ON public.restock_events
      FOR SELECT TO anon
      USING (true);
  END IF;
END
$$;

-- GIN index for jsonb containment queries: items=cs.[{"itemId":"X"}]
CREATE INDEX IF NOT EXISTS restock_events_items_gin
  ON public.restock_events USING gin(items);

-- Composite index for ordered per-shop queries
CREATE INDEX IF NOT EXISTS restock_events_shop_timestamp_idx
  ON public.restock_events (shop_type, "timestamp" DESC);
