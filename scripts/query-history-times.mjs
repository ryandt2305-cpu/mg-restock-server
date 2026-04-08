import pg from "pg";
const connectionString = "postgresql://gemini_audit_reader.xjuvryjgrjchbhjixwzh:137920@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres";
const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false }, family: 4 });
const items = ['Moonbinder','Dawnbinder','Starweaver','Blueberry','FavaBean','SmallGravestone'];
const sql = `
  select item_id, shop_type, total_quantity, last_quantity, last_seen
  from public.restock_history
  where item_id = any($1)
  order by shop_type, item_id;
`;
(async () => {
  await client.connect();
  const res = await client.query(sql, [items]);
  const out = res.rows.map(r => ({
    ...r,
    last_seen_iso: r.last_seen ? new Date(Number(r.last_seen)).toISOString() : null,
  }));
  console.log(out);
  await client.end();
})();
