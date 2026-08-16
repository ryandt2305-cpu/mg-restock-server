-- Drop the orphaned 3-parameter overload of ingest_restock_history.
--
-- Migration 20260418000001 created: ingest_restock_history(text, bigint, jsonb)
-- Migration 20260418000002 created: ingest_restock_history(text, bigint, jsonb, text)
--
-- CREATE OR REPLACE FUNCTION only replaces when the argument type list
-- matches exactly. Since (text, bigint, jsonb) != (text, bigint, jsonb, text),
-- both functions coexist as overloads. PostgREST cannot unambiguously resolve
-- which to call, causing ingest_restock_history RPC calls to fail.
--
-- Fix: drop the old 3-param version. The 4-param version has
-- p_weather_id DEFAULT NULL so callers omitting it still work.

DROP FUNCTION IF EXISTS public.ingest_restock_history(text, bigint, jsonb);
