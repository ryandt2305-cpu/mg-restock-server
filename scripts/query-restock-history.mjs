import pg from "pg";
const connectionString = "postgresql://gemini_audit_reader.xjuvryjgrjchbhjixwzh:137920@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres";
const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false }, family: 4 });
const items = ['Moonbinder','Dawnbinder','Starweaver','MoonbinderPod','DawnbinderPod','StarweaverPod','SmallGravestone','Blueberry','FavaBean'];
const shopTypes = ['seed','egg','decor'];
const likeItems = items.map((_,i)=>`$${i+1}`).join(',');
const shopParams = shopTypes.map((_,i)=>`$${items.length+i+1}`).join(',');
const sql = `
  select item_id, shop_type, total_quantity, last_quantity, last_seen, total_occurrences
  from public.restock_history
  where item_id = any($1)
  order by shop_type, item_id
`;
(async () => {
  await client.connect();
  const res = await client.query(sql, [items]);
  console.log(res.rows);
  await client.end();
})();
