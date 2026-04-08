import pg from "pg";
const connectionString = "postgresql://gemini_audit_reader.xjuvryjgrjchbhjixwzh:137920@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres";
const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false }, family: 4 });
const sql = `
  select distinct item->>'itemId' as item_id
  from public.restock_events re
  cross join lateral jsonb_array_elements(re.items) as item
  where (item->>'itemId') ilike '%binder%'
  order by item_id;
`;
(async () => {
  await client.connect();
  const res = await client.query(sql);
  console.log(res.rows);
  await client.end();
})();
