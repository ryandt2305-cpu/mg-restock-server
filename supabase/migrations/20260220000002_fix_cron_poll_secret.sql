-- Fix restock-poll cron job to include x-poll-secret header
--
-- Problem: the original cron job (20260207000002_restock_cron.sql) only sent
-- an Authorization: Bearer header with the service role JWT. After POLL_SECRET
-- was set (20260207000005), the function's auth check required the bearer token
-- to equal POLL_SECRET, which the service role JWT does not. Every cron tick
-- was silently rejected with 403, so no shop or weather data was recorded.
--
-- Fix: drop and recreate the cron job with x-poll-secret in the headers.
-- The x-poll-secret header is checked first in the function, so it passes.

SELECT cron.unschedule('poll-restock');

-- NOTE: Replace <SERVICE_ROLE_JWT> and <POLL_SECRET> with your actual values from
-- Supabase Dashboard → Project Settings → API and your vault secret respectively.
-- Do not commit real credentials here.
SELECT cron.schedule(
  'poll-restock',
  '*/5 * * * *',
  $$
  SELECT net.http_post(
    url := '<SUPABASE_PROJECT_URL>/functions/v1/restock-poll',
    headers := jsonb_build_object(
      'Authorization', 'Bearer <SERVICE_ROLE_JWT>',
      'Content-Type', 'application/json',
      'x-poll-secret', '<POLL_SECRET>'
    ),
    body := '{}'::jsonb
  );
  $$
);
