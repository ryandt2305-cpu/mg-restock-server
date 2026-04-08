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
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhqdXZyeWpncmpjaGJoaml4d3poIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDEwNjI4MywiZXhwIjoyMDg1NjgyMjgzfQ._wJgsTkz8RH3aZCyU53hPtLsNcq8zqGCE4cq8Stf75w',
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
