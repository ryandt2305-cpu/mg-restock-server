import { assertEquals, assertRejects } from "https://deno.land/std@0.192.0/testing/asserts.ts";
import {
  extractWeatherId,
  fetchPlatformShops,
  fetchPlatformWeather,
  isPreRestockStale,
  normalizePlatformShops,
  normalizeWeather,
} from "./platformApi.ts";

const SHOPS_PAYLOAD = {
  shops: {
    seed: {
      open: true,
      nextRestockAt: "2026-08-16T05:30:00.000Z",
      items: [
        { itemId: "Carrot", itemType: "Seed", name: "Carrot Seed", coinPrice: 10, stock: 12 },
        { itemId: "Camellia", itemType: "Seed", name: "Camellia Seed", coinPrice: 55000, stock: 1 },
      ],
      catalog: [
        { itemId: "Carrot", itemType: "Seed", name: "Carrot Seed", coinPrice: 10, stock: 12 },
        { itemId: "FavaBean", itemType: "Seed", name: "Fava Bean", coinPrice: 250, stock: 0 },
        { itemId: "Camellia", itemType: "Seed", name: "Camellia Seed", coinPrice: 55000, stock: 1 },
      ],
    },
    tool: {
      open: true,
      nextRestockAt: "2026-08-16T05:30:00.000Z",
      items: [
        { itemId: "WateringCan", itemType: "Tool", name: "Watering Can", coinPrice: 5000, stock: 5 },
        { itemId: "DecorShed", itemType: "Decor", name: "Decor Shed", coinPrice: null, stock: 1 },
        { itemId: "XPPotion", itemType: "Tool", name: "XP Potion", coinPrice: null, stock: 0 },
      ],
      catalog: [],
    },
    dawn: { open: false, nextRestockAt: null, items: [], catalog: [] },
  },
};
const T_0529 = Date.parse("2026-08-16T05:29:30.000Z");
const T_0530 = Date.parse("2026-08-16T05:30:00.000Z");

Deno.test("normalizePlatformShops keeps stock>0 items, full catalog, ms timestamps", () => {
  const shops = normalizePlatformShops(SHOPS_PAYLOAD, T_0529);
  assertEquals(Object.keys(shops), ["seed", "tool", "dawn"]);
  assertEquals(shops.seed.nextRestockAt, T_0530);
  assertEquals(shops.seed.secondsUntilRestock, 30);
  assertEquals(shops.seed.items.map((i) => i.itemId), ["Carrot", "Camellia"]);
  assertEquals(shops.seed.catalog.length, 3);
  assertEquals(shops.tool.items.map((i) => i.itemId), ["WateringCan", "DecorShed"]);
  assertEquals(shops.dawn.open, false);
  assertEquals(shops.dawn.nextRestockAt, null);
  assertEquals(normalizePlatformShops(null), {});
  assertEquals(normalizePlatformShops({ shops: { seed: 5 } }), {});
});

Deno.test("isPreRestockStale only for open shops at/after boundary", () => {
  const shops = normalizePlatformShops(SHOPS_PAYLOAD, T_0529);
  assertEquals(isPreRestockStale(shops, T_0529), false);
  assertEquals(isPreRestockStale(shops, T_0530), true);
  assertEquals(isPreRestockStale({ dawn: shops.dawn }, T_0530 + 10_000), false);
});

Deno.test("weather extraction", () => {
  assertEquals(extractWeatherId(null), "Sunny");
  assertEquals(extractWeatherId("Rain"), "Rain"); // real payload observed 2026-08-16 05:55Z: bare JSON string
  assertEquals(normalizeWeather("Clear Skies"), "Sunny");
  assertEquals(normalizeWeather("Snow"), "Frost");
  assertEquals(normalizeWeather("Amber Moon"), "AmberMoon");
  assertEquals(normalizeWeather("Volcano"), null);
  assertEquals(extractWeatherId({ weather: "Rain" }), "Rain");
  assertEquals(extractWeatherId({ current: { name: "Snow" } }), "Frost");
  assertEquals(extractWeatherId({ foo: "bar" }), null);
  assertEquals(extractWeatherId(42), null);
});

function fakeFetch(bodies: unknown[]) {
  let i = 0;
  const calls: string[] = [];
  const fetchImpl = ((url: string | URL | Request) => {
    calls.push(String(url));
    const body = bodies[Math.min(i, bodies.length - 1)];
    i += 1;
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as unknown as Response);
  }) as typeof fetch;
  return { fetchImpl, calls };
}

Deno.test("fetchPlatformShops refetches while stale, bounded", async () => {
  const fresh = JSON.parse(JSON.stringify(SHOPS_PAYLOAD));
  fresh.shops.seed.nextRestockAt = "2026-08-16T05:35:00.000Z";
  fresh.shops.tool.nextRestockAt = "2026-08-16T05:40:00.000Z";
  const { fetchImpl, calls } = fakeFetch([SHOPS_PAYLOAD, SHOPS_PAYLOAD, fresh]);
  const slept: number[] = [];
  const r = await fetchPlatformShops("https://example.test/v1", {
    fetchImpl,
    now: () => T_0530 + 200,
    sleep: (ms) => {
      slept.push(ms);
      return Promise.resolve();
    },
    staleRetries: 3,
  });
  assertEquals(calls.length, 3);
  assertEquals(slept, [2000, 2000]);
  assertEquals(r.staleRetries, 2);
  assertEquals(r.shops.seed.nextRestockAtIso, "2026-08-16T05:35:00.000Z");
});

Deno.test("fetchPlatformShops rejects on non-2xx", async () => {
  const fetchImpl = (() => Promise.resolve({ ok: false, status: 503 } as unknown as Response)) as typeof fetch;
  await assertRejects(() => fetchPlatformShops("https://example.test/v1", { fetchImpl }), Error, "503");
});

Deno.test("fetchPlatformWeather", async () => {
  let r = await fetchPlatformWeather("https://example.test/v1", { fetchImpl: fakeFetch([null]).fetchImpl });
  assertEquals(r, { raw: null, weatherId: "Sunny" });
  r = await fetchPlatformWeather("https://example.test/v1", { fetchImpl: fakeFetch([{ weather: "Rain" }]).fetchImpl });
  assertEquals(r.weatherId, "Rain");
});
