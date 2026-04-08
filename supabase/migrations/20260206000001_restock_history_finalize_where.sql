-- Allow finalize via PostgREST by adding a WHERE clause
create or replace function finalize_restock_history()
returns void language plpgsql as $$
begin
  update restock_history
  set average_interval_ms = case
        when total_occurrences > 1 and first_seen is not null and last_seen is not null
        then greatest(1, round((last_seen - first_seen) / (total_occurrences - 1))::bigint)
        else null
      end,
      estimated_next_timestamp = case
        when total_occurrences > 1 and first_seen is not null and last_seen is not null
        then last_seen + greatest(1, round((last_seen - first_seen) / (total_occurrences - 1))::bigint)
        else null
      end,
      rate_per_day = case
        when total_occurrences > 1 and first_seen is not null and last_seen is not null and last_seen > first_seen
        then round((total_occurrences / ((last_seen - first_seen) / 86400000.0))::numeric, 2)
        else null
      end
  where true;
end;
$$;
