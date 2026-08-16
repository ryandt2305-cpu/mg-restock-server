-- Enable required extensions for scheduled polling
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- Grant usage to postgres role (needed for cron to call net functions)
GRANT USAGE ON SCHEMA cron TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA cron TO postgres;

-- Schedule restock-poll to run every 5 minutes
SELECT cron.schedule(
  'poll-restock',
  '*/5 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://xjuvryjgrjchbhjixwzh.supabase.co/functions/v1/restock-poll',
    headers := jsonb_build_object(
      -- SECURITY: original service_role JWT was rotated 2026-08-16. This migration is
      -- superseded by 20260207000004_security_hardening.sql, which drops this cron job
      -- and re-creates it reading the shared secret from Supabase Vault. The literal
      -- token here is redacted so it cannot be re-exposed by rerunning this file.
      'Authorization', 'Bearer <REDACTED_ROTATED_2026-08-16>',
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
