#!/usr/bin/env bash

# Import Celestial Seeds from Community Discord Logs
# Replaces existing celestial data with authoritative community logs

SUPABASE_URL="https://xjuvryjgrjchbhjixwzh.supabase.co"
SUPABASE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhqdXZyeWpncmpjaGJoaml4d3poIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDEwNjI4MywiZXhwIjoyMDg1NjgyMjgzfQ._wJgsTkz8RH3aZCyU53hPtLsNcq8zqGCE4cq8Stf75w"

echo "🌟 Celestial Seed Import Script"
echo "================================"
echo ""

# Step 1: Count existing celestials
echo "📊 Checking existing celestials..."
COUNT=$(curl -s "$SUPABASE_URL/rest/v1/restock_events?shop_type=eq.seed&select=count" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Authorization: Bearer $SUPABASE_KEY" \
  -H "Prefer: count=exact" | grep -o '"count":[0-9]*' | cut -d':' -f2)

echo "   Found celestials in database"
echo ""

# Step 2: Delete existing celestials
echo "🗑️  Deleting existing celestials..."
curl -s -X DELETE "$SUPABASE_URL/rest/v1/restock_events?shop_type=eq.seed&or=(items->>0->>itemId.eq.StarweaverPod,items->>0->>itemId.eq.DawnbinderPod,items->>0->>itemId.eq.MoonbinderPod)" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Authorization: Bearer $SUPABASE_KEY" > /dev/null

echo "   ✅ Deleted existing celestials"
echo ""

# Step 3: Insert new events
echo "💾 Inserting 41 celestial events from community logs..."

# Create JSON payload with all 41 events (with fingerprints)
cat > /tmp/celestials.json << 'EOF'
[
  {"timestamp": 1753543500000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 1}], "fingerprint": "seed:1753543500000:StarweaverPod:1"},
  {"timestamp": 1753997100000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 2}], "fingerprint": "seed:1753997100000:StarweaverPod:2"},
  {"timestamp": 1754348640000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 3}]},
  {"timestamp": 1755786600000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 4}]},
  {"timestamp": 1756397100000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 5}]},
  {"timestamp": 1756429800000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 6}]},
  {"timestamp": 1756866600000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 7}]},
  {"timestamp": 1757560246000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 8}]},
  {"timestamp": 1757690400000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 9}]},
  {"timestamp": 1759283700000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 10}]},
  {"timestamp": 1759644326000, "shop_type": "seed", "items": [{"itemId": "MoonbinderPod", "stock": 1}]},
  {"timestamp": 1759912853000, "shop_type": "seed", "items": [{"itemId": "DawnbinderPod", "stock": 1}]},
  {"timestamp": 1760120141000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 11}]},
  {"timestamp": 1760280953000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 12}]},
  {"timestamp": 1760873737000, "shop_type": "seed", "items": [{"itemId": "DawnbinderPod", "stock": 2}]},
  {"timestamp": 1760991934000, "shop_type": "seed", "items": [{"itemId": "MoonbinderPod", "stock": 2}]},
  {"timestamp": 1761050128000, "shop_type": "seed", "items": [{"itemId": "DawnbinderPod", "stock": 3}]},
  {"timestamp": 1761834015000, "shop_type": "seed", "items": [{"itemId": "MoonbinderPod", "stock": 3}]},
  {"timestamp": 1761884452000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 13}]},
  {"timestamp": 1762033802000, "shop_type": "seed", "items": [{"itemId": "MoonbinderPod", "stock": 4}]},
  {"timestamp": 1762050947000, "shop_type": "seed", "items": [{"itemId": "DawnbinderPod", "stock": 4}]},
  {"timestamp": 1762551901000, "shop_type": "seed", "items": [{"itemId": "DawnbinderPod", "stock": 5}]},
  {"timestamp": 1762971900000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 14}]},
  {"timestamp": 1762982100000, "shop_type": "seed", "items": [{"itemId": "MoonbinderPod", "stock": 5}]},
  {"timestamp": 1763086500000, "shop_type": "seed", "items": [{"itemId": "DawnbinderPod", "stock": 6}]},
  {"timestamp": 1763937000000, "shop_type": "seed", "items": [{"itemId": "MoonbinderPod", "stock": 6}]},
  {"timestamp": 1764630300000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 15}]},
  {"timestamp": 1764661500000, "shop_type": "seed", "items": [{"itemId": "DawnbinderPod", "stock": 7}]},
  {"timestamp": 1764936600000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 16}]},
  {"timestamp": 1765580700000, "shop_type": "seed", "items": [{"itemId": "MoonbinderPod", "stock": 7}]},
  {"timestamp": 1766058300000, "shop_type": "seed", "items": [{"itemId": "DawnbinderPod", "stock": 8}]},
  {"timestamp": 1766441100000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 17}]},
  {"timestamp": 1766874600000, "shop_type": "seed", "items": [{"itemId": "MoonbinderPod", "stock": 8}]},
  {"timestamp": 1767486300000, "shop_type": "seed", "items": [{"itemId": "MoonbinderPod", "stock": 9}]},
  {"timestamp": 1767518400000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 18}]},
  {"timestamp": 1767833700000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 19}]},
  {"timestamp": 1767951300000, "shop_type": "seed", "items": [{"itemId": "DawnbinderPod", "stock": 9}]},
  {"timestamp": 1768686000000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 20}]},
  {"timestamp": 1768915200000, "shop_type": "seed", "items": [{"itemId": "MoonbinderPod", "stock": 10}]},
  {"timestamp": 1769151000000, "shop_type": "seed", "items": [{"itemId": "DawnbinderPod", "stock": 10}]},
  {"timestamp": 1769538600000, "shop_type": "seed", "items": [{"itemId": "StarweaverPod", "stock": 21}]}
]
EOF

curl -s -X POST "$SUPABASE_URL/rest/v1/restock_events" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Authorization: Bearer $SUPABASE_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/celestials.json > /dev/null

echo "   ✅ Inserted 41 events"
echo "   - Starweaver: 21"
echo "   - Dawnbinder: 10"
echo "   - Moonbinder: 10"
echo ""

# Step 4: Rebuild history
echo "🔄 Rebuilding restock_history..."
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/rebuild_restock_history" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Authorization: Bearer $SUPABASE_KEY" \
  -H "Content-Type: application/json" > /dev/null

echo "   ✅ History rebuilt"
echo ""

# Step 5: Verify
echo "✅ Verifying appearance rates..."
curl -s "$SUPABASE_URL/rest/v1/restock_history?shop_type=eq.seed&item_id=in.(StarweaverPod,DawnbinderPod,MoonbinderPod)&select=item_id,total_occurrences,appearance_rate" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Authorization: Bearer $SUPABASE_KEY" | \
  python3 -c "import sys, json; data=json.load(sys.stdin); [print(f\"   - {item['item_id']}: {item['total_occurrences']} occurrences, {float(item['appearance_rate'])*100:.4f}% rate\") for item in data]"

echo ""
echo "🎉 Celestial import complete!"
