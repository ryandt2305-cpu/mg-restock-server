import pg from "pg";
const connectionString = "postgresql://gemini_audit_reader.xjuvryjgrjchbhjixwzh:137920@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres";
const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false }, family: 4 });
const sql = `
  select re.timestamp, re.shop_type, re.source, re.fingerprint, re.items
  from public.restock_events re
  where re.items @> '[{"itemId":"Starweaver"}]'::jsonb
  order by re.timestamp desc
  limit 10;
`;
(async () => {
  await client.connect();
  const res = await client.query(sql);
  console.log(res.rows.map(r => ({
    timestamp: r.timestamp,
    source: r.source,
    fingerprint: r.fingerprint,
    items: r.items
  })));
  await client.end();
})();
