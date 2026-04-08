-- ============================================================================
-- Security Hardening Migration
-- 1. Enable RLS on all public tables
-- 2. Create appropriate access policies
-- 3. Replace hardcoded service role key in cron job with vault secret
-- ============================================================================

-- ── 1. Enable Row Level Security ────────────────────────────────────────────

ALTER TABLE public.restock_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restock_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weather_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weather_summary ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shop_cycle_stats ENABLE ROW LEVEL SECURITY;

-- ── 2. Policies ─────────────────────────────────────────────────────────────
-- Edge functions use the service_role key which bypasses RLS entirely.
-- These policies control direct PostgREST access with the anon key.

-- restock_history: public read-only aggregate data
CREATE POLICY "anon_read_restock_history"
  ON public.restock_history
  FOR SELECT
  TO anon
  USING (true);

-- weather_summary: public read-only aggregate data
CREATE POLICY "anon_read_weather_summary"
  ON public.weather_summary
  FOR SELECT
  TO anon
  USING (true);

-- shop_cycle_stats: public read-only aggregate data
CREATE POLICY "anon_read_shop_cycle_stats"
  ON public.shop_cycle_stats
  FOR SELECT
  TO anon
  USING (true);

-- restock_events: no anon access (only service_role via edge functions)
-- weather_events: no anon access (only service_role via edge functions)
-- (No policies = denied by default with RLS enabled)

-- ── 3. Replace hardcoded key in cron job with vault secret ──────────────────

-- Store a dedicated poll secret in Supabase Vault.
-- IMPORTANT: After running this migration, copy the generated secret value
-- and set it as the POLL_SECRET environment variable on the restock-poll
-- edge function via the Supabase Dashboard > Edge Functions > restock-poll > Secrets.
--
-- To retrieve the generated secret:
--   SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'poll_secret';

SELECT vault.create_secret(
  gen_random_uuid()::text,
  'poll_secret',
  'Shared secret for authenticating cron → restock-poll edge function calls'
);

-- Unschedule the old cron job that uses the hardcoded service role key
SELECT cron.unschedule('poll-restock');

-- Re-create with vault-based secret
SELECT cron.schedule(
  'poll-restock',
  '*/5 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://xjuvryjgrjchbhjixwzh.supabase.co/functions/v1/restock-poll',
    headers := jsonb_build_object(
      'x-poll-secret', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'poll_secret'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
