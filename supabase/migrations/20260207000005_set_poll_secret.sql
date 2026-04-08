-- Update the vault poll_secret to a known value so it can be set on the edge function.
-- Use vault API function since direct table access is restricted.
SELECT vault.update_secret(
  (SELECT id FROM vault.secrets WHERE name = 'poll_secret'),
  '36f79893-0668-48f3-ba40-0ecf79ab10ba',
  'poll_secret',
  'Shared secret for authenticating cron to restock-poll edge function calls'
);
