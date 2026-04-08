import pg from "pg";
const connectionString = "postgresql://gemini_audit_reader.xjuvryjgrjchbhjixwzh:137920@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres";
const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false }, family: 4 });
(async () => {
  await client.connect();
  const res = await client.query("select source, count(*) as rows, max(timestamp) as max_ts from public.restock_events group by source order by rows desc");
  console.log(res.rows);
  await client.end();
})();
