import pg from "pg";
const connectionString = "postgresql://gemini_audit_reader.xjuvryjgrjchbhjixwzh:137920@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres";
const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false }, family: 4 });
const items = ['Starweaver','Dawnbinder','Moonbinder','StarweaverPod','DawnbinderPod','MoonbinderPod','SmallGravestone'];
const sql = `
  select re.timestamp, re.shop_type, item->>'itemId' as item_id, item->>'stock' as stock
  from public.restock_events re
  cross join lateral jsonb_array_elements(re.items) as item
  where item->>'itemId' = any($1)
  order by re.timestamp desc
  limit 30;
`;
(async () => {
  await client.connect();
  const res = await client.query(sql, [items]);
  console.log(res.rows);
  await client.end();
})();
