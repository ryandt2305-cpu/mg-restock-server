import pg from "pg";

const connectionString = "postgresql://gemini_audit_reader.xjuvryjgrjchbhjixwzh:137920@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres";

const client = new pg.Client({
  connectionString,
  ssl: { rejectUnauthorized: false },
  statement_timeout: 20000,
  query_timeout: 20000,
  family: 4,
});

const queries = [
  { name: "now", sql: "select now() as now" },
  { name: "table_counts", sql: "select relname as table, n_live_tup::bigint as rows from pg_stat_user_tables order by relname" },
  { name: "restock_events_summary", sql: `
    select
      count(*) as rows,
      count(distinct fingerprint) as distinct_fingerprint,
      count(*) - count(distinct fingerprint) as duplicate_fingerprint,
      sum((fingerprint is null)::int) as null_fingerprint,
      min(timestamp) as min_ts,
      max(timestamp) as max_ts,
      min(created_at) as min_created,
      max(created_at) as max_created,
      sum((weather_id is null)::int) as null_weather,
      count(distinct shop_type) as shop_types
    from public.restock_events
  ` },
  { name: "restock_events_by_shop", sql: "select shop_type, count(*) as rows from public.restock_events group by shop_type order by rows desc" },
  { name: "restock_events_weather_top", sql: "select weather_id, count(*) as rows from public.restock_events group by weather_id order by rows desc limit 10" },
  { name: "restock_events_items_stats", sql: `
    select
      avg(jsonb_array_length(items))::numeric(10,2) as avg_items,
      min(jsonb_array_length(items)) as min_items,
      max(jsonb_array_length(items)) as max_items
    from public.restock_events
  ` },
  { name: "restock_history_summary", sql: `
    select
      count(*) as rows,
      sum((total_occurrences = 0)::int) as zero_occurrences,
      sum((first_seen is null)::int) as null_first_seen,
      sum((last_seen is null)::int) as null_last_seen,
      sum((average_interval_ms is null)::int) as null_avg_interval,
      sum((estimated_next_timestamp is null)::int) as null_next_ts,
      sum((average_quantity is null)::int) as null_avg_qty,
      sum((last_quantity is null)::int) as null_last_qty,
      sum((total_quantity is null)::int) as null_total_qty
    from public.restock_history
  ` },
  { name: "restock_history_anomalies", sql: `
    select
      sum((last_seen < first_seen)::int) as last_before_first,
      sum((total_occurrences < 0)::int) as negative_occ,
      sum((total_quantity < 0)::int) as negative_qty
    from public.restock_history
  ` },
  { name: "weather_events_summary", sql: `
    select
      count(*) as rows,
      count(distinct fingerprint) as distinct_fingerprint,
      count(*) - count(distinct fingerprint) as duplicate_fingerprint,
      sum((previous_weather_id is null)::int) as null_prev,
      min(timestamp) as min_ts,
      max(timestamp) as max_ts,
      min(created_at) as min_created,
      max(created_at) as max_created
    from public.weather_events
  ` },
  { name: "weather_events_by_source", sql: "select source, count(*) as rows from public.weather_events group by source order by rows desc" },
  { name: "weather_events_by_weather", sql: "select weather_id, count(*) as rows from public.weather_events group by weather_id order by rows desc" },
  { name: "weather_events_intervals", sql: `
    with ordered as (
      select timestamp, lag(timestamp) over (order by timestamp) as prev_ts
      from public.weather_events
    )
    select
      avg(timestamp - prev_ts) as avg_diff,
      percentile_cont(0.5) within group (order by (timestamp - prev_ts)) as median_diff,
      min(timestamp - prev_ts) as min_diff,
      max(timestamp - prev_ts) as max_diff
    from ordered
    where prev_ts is not null
  ` },
  { name: "weather_events_intervals_rain", sql: `
    with ordered as (
      select timestamp, lag(timestamp) over (order by timestamp) as prev_ts
      from public.weather_events
      where weather_id = 'Rain'
    )
    select
      avg(timestamp - prev_ts) as avg_diff,
      percentile_cont(0.5) within group (order by (timestamp - prev_ts)) as median_diff,
      min(timestamp - prev_ts) as min_diff,
      max(timestamp - prev_ts) as max_diff
    from ordered
    where prev_ts is not null
  ` },
  { name: "indexes", sql: `
    select tablename, indexname, indexdef
    from pg_indexes
    where schemaname='public'
    order by tablename, indexname
  ` },
  { name: "restock_events_weather_missing_count", sql: `
    select count(*) as rows from public.restock_events where weather_id is null
  ` },
  { name: "restock_events_null_fingerprint", sql: `
    select count(*) as rows from public.restock_events where fingerprint is null
  ` },
  { name: "restock_events_duplicate_fingerprint", sql: `
    select fingerprint, count(*) as rows
    from public.restock_events
    group by fingerprint
    having count(*) > 1
    order by rows desc
    limit 20
  ` },
];

function printResult(name, rows) {
  console.log(`\n=== ${name} ===`);
  if (!rows || rows.length === 0) {
    console.log("(no rows)");
    return;
  }
  for (const row of rows) {
    console.log(JSON.stringify(row));
  }
}

async function run() {
  await client.connect();
  try {
    for (const q of queries) {
      const res = await client.query({ text: q.sql, statement_timeout: 20000, query_timeout: 20000 });
      printResult(q.name, res.rows);
    }
  } finally {
    await client.end();
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
