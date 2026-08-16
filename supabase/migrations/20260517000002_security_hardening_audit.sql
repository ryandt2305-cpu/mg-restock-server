-- Security Hardening Audit Migration
-- Resolves: 10 anon_security_definer_function_executable warnings,
--           2 rls_disabled_in_public errors, duplicate policies, duplicate indexes

-- =============================================================================
-- Step 1: Revoke EXECUTE on SECURITY DEFINER functions from PUBLIC
-- (anon/authenticated inherit from PUBLIC, so revoking from PUBLIC is required)
-- service_role retains access via explicit grant
-- =============================================================================

REVOKE EXECUTE ON FUNCTION public.ingest_restock_history(text, bigint, jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_restock_predictions() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trigger_refresh_restock_predictions() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.run_restock_item_model_backtests(integer, integer, integer, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_restock_item_model_selection(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_restock_item_serving_state(numeric, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_restock_item_bias_corrections(integer, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.score_restock_prediction_outcomes(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.snapshot_restock_predictions(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.backfill_restock_item_serving_state_gaps() FROM PUBLIC;

-- =============================================================================
-- Step 2: Fix mutable search_path on functions missing it
-- =============================================================================

ALTER FUNCTION public.refresh_restock_predictions() SET search_path = public;
ALTER FUNCTION public.trigger_refresh_restock_predictions() SET search_path = public;

-- =============================================================================
-- Step 3: Enable RLS on baseline tables + add read-only policy
-- =============================================================================

ALTER TABLE public._prediction_baseline_20260517 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public._accuracy_baseline_20260517 ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_read_prediction_baseline"
  ON public._prediction_baseline_20260517
  FOR SELECT USING (true);

CREATE POLICY "anon_read_accuracy_baseline"
  ON public._accuracy_baseline_20260517
  FOR SELECT USING (true);

-- =============================================================================
-- Step 4: Remove duplicate RLS policies (keep the newer naming convention)
-- =============================================================================

DROP POLICY IF EXISTS "anon_read_backtests" ON public.restock_item_model_backtests;
DROP POLICY IF EXISTS "anon_read_prediction_outcomes" ON public.restock_prediction_outcomes;
DROP POLICY IF EXISTS "anon_read_prediction_snapshots" ON public.restock_prediction_snapshots;

-- =============================================================================
-- Step 5: Remove duplicate/unused indexes
-- =============================================================================

DROP INDEX IF EXISTS public.restock_prediction_snapshots_item_idx;
DROP INDEX IF EXISTS public.restock_prediction_outcomes_scored_idx;
DROP INDEX IF EXISTS public.weather_summary_timestamp_idx;
DROP INDEX IF EXISTS public.weather_summary_weather_idx;
DROP INDEX IF EXISTS public.restock_prediction_snapshots_created_idx;
DROP INDEX IF EXISTS public.restock_events_items_gin;
