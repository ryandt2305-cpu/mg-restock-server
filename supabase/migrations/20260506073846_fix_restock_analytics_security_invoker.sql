-- Fix Supabase security advisor warnings for restock analytics views.
--
-- The affected views were created by postgres without security_invoker=true,
-- so anon/authenticated callers could read through the view owner's privileges
-- instead of the caller's RLS-filtered privileges. These analytics objects hold
-- restock prediction/backtest telemetry, not user-owned data, so the intended
-- external surface is read-only analytics.
--
-- This migration therefore:
--   1. makes each view security_invoker=true;
--   2. converts public grants on the views/base tables to read-only;
--   3. adds explicit read-only RLS policies on the analytics base tables.
--
-- The object checks keep this migration safe on environments that have not yet
-- received the prediction accuracy/backtest objects.

alter view if exists public.restock_item_selected_models
  set (security_invoker = true);

alter view if exists public.restock_prediction_accuracy_by_item
  set (security_invoker = true);

alter view if exists public.restock_item_model_candidates
  set (security_invoker = true);

alter table if exists public.restock_item_model_backtests
  enable row level security;

alter table if exists public.restock_prediction_snapshots
  enable row level security;

alter table if exists public.restock_prediction_outcomes
  enable row level security;

do $$
declare
  rel regclass;
begin
  for rel in
    select to_regclass(obj_name)
    from (
      values
        ('public.restock_item_selected_models'),
        ('public.restock_prediction_accuracy_by_item'),
        ('public.restock_item_model_candidates'),
        ('public.restock_item_model_backtests'),
        ('public.restock_prediction_snapshots'),
        ('public.restock_prediction_outcomes')
    ) as objects(obj_name)
    where to_regclass(obj_name) is not null
  loop
    execute format('revoke all privileges on table %s from anon, authenticated', rel);
    execute format('grant select on table %s to anon, authenticated', rel);
  end loop;
end
$$;

do $$
begin
  if to_regclass('public.restock_item_model_backtests') is not null
     and not exists (
       select 1
       from pg_policies
       where schemaname = 'public'
         and tablename = 'restock_item_model_backtests'
         and policyname = 'anon_read_restock_item_model_backtests'
     ) then
    create policy "anon_read_restock_item_model_backtests"
      on public.restock_item_model_backtests
      for select
      to anon, authenticated
      using (true);
  end if;

  if to_regclass('public.restock_prediction_snapshots') is not null
     and not exists (
       select 1
       from pg_policies
       where schemaname = 'public'
         and tablename = 'restock_prediction_snapshots'
         and policyname = 'anon_read_restock_prediction_snapshots'
     ) then
    create policy "anon_read_restock_prediction_snapshots"
      on public.restock_prediction_snapshots
      for select
      to anon, authenticated
      using (true);
  end if;

  if to_regclass('public.restock_prediction_outcomes') is not null
     and not exists (
       select 1
       from pg_policies
       where schemaname = 'public'
         and tablename = 'restock_prediction_outcomes'
         and policyname = 'anon_read_restock_prediction_outcomes'
     ) then
    create policy "anon_read_restock_prediction_outcomes"
      on public.restock_prediction_outcomes
      for select
      to anon, authenticated
      using (true);
  end if;
end
$$;

do $$
declare
  rel regclass;
begin
  for rel in
    select to_regclass(obj_name)
    from (
      values
        ('public.restock_item_selected_models'),
        ('public.restock_prediction_accuracy_by_item'),
        ('public.restock_item_model_candidates')
    ) as objects(obj_name)
    where to_regclass(obj_name) is not null
  loop
    execute format(
      'comment on view %s is %L',
      rel,
      'Read-only restock analytics view. Runs with security_invoker=true so caller permissions and RLS on underlying analytics tables are enforced.'
    );
  end loop;
end
$$;
