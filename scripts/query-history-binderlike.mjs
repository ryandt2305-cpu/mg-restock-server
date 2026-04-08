import pg from "pg";
const connectionString = "postgresql://gemini_audit_reader.xjuvryjgrjchbhjixwzh:137920@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres";
const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false }, family: 4 });
(async () => {
  await client.connect();
  const res = await client.query("select item_id, shop_type, total_quantity, last_seen from public.restock_history where item_id ilike '%binder%' order by item_id");
  console.log(res.rows);
  await client.end();
})();
