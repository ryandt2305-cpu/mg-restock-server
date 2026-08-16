-- Fix: Replace synchronous matview refresh triggers with a pg_cron schedule.
--
-- Problem: Two AFTER INSERT triggers on restock_events and restock_item_events
-- called REFRESH MATERIALIZED VIEW CONCURRENTLY on every ingest cycle (~1.4s each).
-- This blocked INSERT transactions and held SHARE UPDATE EXCLUSIVE locks that
-- prevented autovacuum from ever running, causing 33x table bloat (83 MB for
-- 2.5 MB of live data).
--
-- Solution: Drop the triggers and refresh the matview via pg_cron every 3 minutes.
-- The poll runs every 5 minutes, so a 3-minute refresh cycle keeps predictions
-- fresh within one cycle. Predictions are inherently estimates -- 3 minutes of
-- staleness is indistinguishable from instant for users.
--
-- Note: The triggers were created directly against the live DB (not in any
-- tracked migration). This migration records their removal for reproducibility.

-- Step 1: Drop synchronous refresh triggers
DROP TRIGGER IF EXISTS trg_refresh_restock_predictions_on_events ON restock_events;
DROP TRIGGER IF EXISTS trg_refresh_restock_predictions_on_item_events ON restock_item_events;

-- Step 2: Schedule periodic matview refresh via pg_cron (idempotent)
SELECT cron.unschedule('refresh-restock-predictions-mat')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'refresh-restock-predictions-mat'
);

SELECT cron.schedule(
  'refresh-restock-predictions-mat',
  '*/3 * * * *',
  $$SELECT public.refresh_restock_predictions();$$
);
