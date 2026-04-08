-- Fix Supabase security advisor warnings
--
-- 1. security_definer_view: restock_predictions and weather_predictions
--    Views created without security_invoker = true run as the view owner
--    (postgres superuser), bypassing RLS on the underlying tables.
--    Fix: set security_invoker = true so they execute under the calling
--    role's permissions and respect RLS normally.
--
-- 2. rls_disabled_in_public: weather_history
--    The security hardening migration (20260207000004) enabled RLS on the
--    tables that existed at that time. weather_history was created later
--    (20260209000001) without RLS. Fix: enable RLS + add anon read policy
--    to match the pattern used by restock_history.

-- ── 1. Prediction views: switch to security invoker ───────────────────────────

ALTER VIEW public.restock_predictions SET (security_invoker = true);
ALTER VIEW public.weather_predictions SET (security_invoker = true);

-- With security_invoker = true the views now execute as the querying role,
-- so that role needs base SELECT on the underlying tables they read from.
GRANT SELECT ON public.restock_history TO anon, authenticated;
GRANT SELECT ON public.weather_history TO anon, authenticated;

-- Also grant SELECT on the views themselves.
GRANT SELECT ON public.restock_predictions TO anon, authenticated;
GRANT SELECT ON public.weather_predictions TO anon, authenticated;

-- ── 2. weather_history: enable RLS + public read policy ──────────────────────

ALTER TABLE public.weather_history ENABLE ROW LEVEL SECURITY;

-- Public read-only — matches the pattern for restock_history.
-- service_role bypasses RLS for all writes, so no write policy is needed.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'weather_history'
      AND policyname = 'anon_read_weather_history'
  ) THEN
    CREATE POLICY "anon_read_weather_history"
      ON public.weather_history
      FOR SELECT
      TO anon
      USING (true);
  END IF;
END
$$;
