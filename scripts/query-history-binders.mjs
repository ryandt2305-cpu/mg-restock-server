import pg from "pg";
const connectionString = "postgresql://gemini_audit_reader.xjuvryjgrjchbhjixwzh:137920@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres";
const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false }, family: 4 });
const sql = `
  select item_id, shop_type, total_quantity, last_quantity, last_seen
  from public.restock_history
  where item_id in ('Moonbinder','Dawnbinder','Starweaver')
  order by item_id;
`;
(async () => {
  await client.connect();
  const res = await client.query(sql);
  console.log(res.rows);
  await client.end();
})();
