/**
 * Import Celestial Seeds from Community Discord Logs
 *
 * Replaces existing celestial data in database with authoritative community logs.
 * - Deletes 17 existing Starweaver from MagicShopkeeper source
 * - Imports all 41 celestials from community (21 Starweaver, 10 Dawnbinder, 10 Moonbinder)
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as path from "https://deno.land/std@0.192.0/path/mod.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  Deno.exit(1);
}

const client = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// Discord unix timestamps (in seconds) from celestial logs
const CELESTIAL_LOGS = [
  { timestamp: 1753543500, item: "Starweaver", stock: 1 },
  { timestamp: 1753997100, item: "Starweaver", stock: 2 },
  { timestamp: 1754348640, item: "Starweaver", stock: 3 },
  { timestamp: 1755786600, item: "Starweaver", stock: 4 },
  { timestamp: 1756397100, item: "Starweaver", stock: 5 },
  { timestamp: 1756429800, item: "Starweaver", stock: 6 },
  { timestamp: 1756866600, item: "Starweaver", stock: 7 },
  { timestamp: 1757560246, item: "Starweaver", stock: 8 },
  { timestamp: 1757690400, item: "Starweaver", stock: 9 },
  { timestamp: 1759283700, item: "Starweaver", stock: 10 },
  { timestamp: 1759644326, item: "Moonbinder", stock: 1 },
  { timestamp: 1759912853, item: "Dawnbinder", stock: 1 },
  { timestamp: 1760120141, item: "Starweaver", stock: 11 },
  { timestamp: 1760280953, item: "Starweaver", stock: 12 },
  { timestamp: 1760873737, item: "Dawnbinder", stock: 2 },
  { timestamp: 1760991934, item: "Moonbinder", stock: 2 },
  { timestamp: 1761050128, item: "Dawnbinder", stock: 3 },
  { timestamp: 1761834015, item: "Moonbinder", stock: 3 },
  { timestamp: 1761884452, item: "Starweaver", stock: 13 },
  { timestamp: 1762033802, item: "Moonbinder", stock: 4 },
  { timestamp: 1762050947, item: "Dawnbinder", stock: 4 },
  { timestamp: 1762551901, item: "Dawnbinder", stock: 5 },
  { timestamp: 1762971900, item: "Starweaver", stock: 14 },
  { timestamp: 1762982100, item: "Moonbinder", stock: 5 },
  { timestamp: 1763086500, item: "Dawnbinder", stock: 6 },
  { timestamp: 1763937000, item: "Moonbinder", stock: 6 },
  { timestamp: 1764630300, item: "Starweaver", stock: 15 },
  { timestamp: 1764661500, item: "Dawnbinder", stock: 7 },
  { timestamp: 1764936600, item: "Starweaver", stock: 16 },
  { timestamp: 1765580700, item: "Moonbinder", stock: 7 },
  { timestamp: 1766058300, item: "Dawnbinder", stock: 8 },
  { timestamp: 1766441100, item: "Starweaver", stock: 17 },
  { timestamp: 1766874600, item: "Moonbinder", stock: 8 },
  { timestamp: 1767486300, item: "Moonbinder", stock: 9 },
  { timestamp: 1767518400, item: "Starweaver", stock: 18 },
  { timestamp: 1767833700, item: "Starweaver", stock: 19 },
  { timestamp: 1767951300, item: "Dawnbinder", stock: 9 },
  { timestamp: 1768686000, item: "Starweaver", stock: 20 },
  { timestamp: 1768915200, item: "Moonbinder", stock: 10 },
  { timestamp: 1769151000, item: "Dawnbinder", stock: 10 },
  { timestamp: 1769538600, item: "Starweaver", stock: 21 },
];

// Snap timestamp to 5-minute seed shop cycle boundary
function snapToSeedCycle(unixSeconds: number): number {
  const ms = unixSeconds * 1000;
  const interval = 300000; // 5 minutes in ms
  return Math.floor(ms / interval) * interval;
}

// Format item name for database (Starweaver, Dawnbinder, Moonbinder)
function formatItemId(item: string): string {
  return `${item}Pod`; // StarweaverPod, DawnbinderPod, MoonbinderPod
}

async function main() {
  console.log("🌟 Celestial Seed Import Script");
  console.log("================================\n");

  // Step 1: Count existing celestials
  console.log("📊 Checking existing celestials in database...");
  const { data: existingCelestials, error: countError } = await client
    .from("restock_events")
    .select("*")
    .eq("shop_type", "seed")
    .or("items->0->>itemId.eq.StarweaverPod,items->0->>itemId.eq.DawnbinderPod,items->0->>itemId.eq.MoonbinderPod")
    .order("timestamp");

  if (countError) {
    console.error("❌ Error querying existing celestials:", countError);
    Deno.exit(1);
  }

  console.log(`   Found ${existingCelestials?.length ?? 0} existing celestial events`);
  if (existingCelestials && existingCelestials.length > 0) {
    const starCount = existingCelestials.filter(e => e.items?.[0]?.itemId === "StarweaverPod").length;
    const dawnCount = existingCelestials.filter(e => e.items?.[0]?.itemId === "DawnbinderPod").length;
    const moonCount = existingCelestials.filter(e => e.items?.[0]?.itemId === "MoonbinderPod").length;
    console.log(`   - Starweaver: ${starCount}`);
    console.log(`   - Dawnbinder: ${dawnCount}`);
    console.log(`   - Moonbinder: ${moonCount}\n`);
  }

  // Step 2: Delete existing celestials
  if (existingCelestials && existingCelestials.length > 0) {
    console.log("🗑️  Deleting existing celestials from database...");
    const { error: deleteError } = await client
      .from("restock_events")
      .delete()
      .eq("shop_type", "seed")
      .or("items->0->>itemId.eq.StarweaverPod,items->0->>itemId.eq.DawnbinderPod,items->0->>itemId.eq.MoonbinderPod");

    if (deleteError) {
      console.error("❌ Error deleting celestials:", deleteError);
      Deno.exit(1);
    }
    console.log(`   ✅ Deleted ${existingCelestials.length} events\n`);
  }

  // Step 3: Prepare new events
  console.log("📦 Preparing 41 celestial events from community logs...");
  const newEvents = CELESTIAL_LOGS.map((log) => {
    const snappedTimestamp = snapToSeedCycle(log.timestamp);
    return {
      timestamp: snappedTimestamp,
      shop_type: "seed",
      items: [
        {
          itemId: formatItemId(log.item),
          stock: log.stock,
        },
      ],
    };
  });

  console.log(`   - Starweaver: ${newEvents.filter(e => e.items[0].itemId === "StarweaverPod").length}`);
  console.log(`   - Dawnbinder: ${newEvents.filter(e => e.items[0].itemId === "DawnbinderPod").length}`);
  console.log(`   - Moonbinder: ${newEvents.filter(e => e.items[0].itemId === "MoonbinderPod").length}\n`);

  // Step 4: Insert new events
  console.log("💾 Inserting new celestial events...");
  const { error: insertError } = await client.from("restock_events").insert(newEvents);

  if (insertError) {
    console.error("❌ Error inserting celestials:", insertError);
    Deno.exit(1);
  }
  console.log("   ✅ Inserted 41 celestial events\n");

  // Step 5: Rebuild history
  console.log("🔄 Rebuilding restock_history table...");
  const { error: rebuildError } = await client.rpc("rebuild_restock_history");

  if (rebuildError) {
    console.error("❌ Error rebuilding history:", rebuildError);
    Deno.exit(1);
  }
  console.log("   ✅ History rebuilt successfully\n");

  // Step 6: Verify results
  console.log("✅ Verifying appearance rates...");
  const { data: historyData, error: historyError } = await client
    .from("restock_history")
    .select("item_id, shop_type, total_occurrences, appearance_rate")
    .eq("shop_type", "seed")
    .in("item_id", ["StarweaverPod", "DawnbinderPod", "MoonbinderPod"]);

  if (historyError) {
    console.error("❌ Error querying history:", historyError);
    Deno.exit(1);
  }

  if (historyData) {
    for (const item of historyData) {
      const rate = item.appearance_rate ? (item.appearance_rate * 100).toFixed(4) : "N/A";
      console.log(`   - ${item.item_id}: ${item.total_occurrences} occurrences, ${rate}% rate`);
    }
  }

  console.log("\n🎉 Celestial import complete!");
}

main();
