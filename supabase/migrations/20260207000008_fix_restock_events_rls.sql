-- Force RLS on restock_events (applies even to table owner)
ALTER TABLE public.restock_events FORCE ROW LEVEL SECURITY;

-- Drop any pre-existing permissive policies that may have been added via Dashboard
DO $$
DECLARE
  pol RECORD;
BEGIN
  FOR pol IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'restock_events'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.restock_events', pol.policyname);
    RAISE NOTICE 'Dropped policy: %', pol.policyname;
  END LOOP;
END;
$$;
