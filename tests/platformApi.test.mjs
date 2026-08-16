import { test } from "node:test";
import assert from "node:assert/strict";
import {
  extractWeatherId,
  normalizeWeather,
  normalizePlatformShops,
  isPreRestockStale,
  didRestock,
  fetchPlatformShops,
  fetchPlatformWeather,
} from "../scripts/lib/platformApi.mjs";

// Trimmed real payload captured 2026-08-16T05:25:02Z
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
        // defensive: if the API ever puts stock:0 in items, we must drop it
        { itemId: "XPPotion", itemType: "Tool", name: "XP Potion", coinPrice: null, stock: 0 },
      ],
      catalog: [],
    },
    dawn: { open: false, nextRestockAt: null, items: [], catalog: [] },
  },
};

const T_0529 = Date.parse("2026-08-16T05:29:30.000Z");
const T_0530 = Date.parse("2026-08-16T05:30:00.000Z");

test("normalizePlatformShops: keeps only stock>0 in items, full catalog, ms timestamps", () => {
  const shops = normalizePlatformShops(SHOPS_PAYLOAD, T_0529);
  assert.deepEqual(Object.keys(shops), ["seed", "tool", "dawn"]);
  assert.equal(shops.seed.open, true);
  assert.equal(shops.seed.nextRestockAt, T_0530);
  assert.equal(shops.seed.nextRestockAtIso, "2026-08-16T05:30:00.000Z");
  assert.equal(shops.seed.secondsUntilRestock, 30);
  assert.deepEqual(shops.seed.items.map((i) => i.itemId), ["Carrot", "Camellia"]);
  assert.equal(shops.seed.catalog.length, 3);
  assert.deepEqual(shops.tool.items.map((i) => i.itemId), ["WateringCan", "DecorShed"]);
  assert.equal(shops.tool.items[1].coinPrice, null);
  assert.equal(shops.dawn.open, false);
  assert.equal(shops.dawn.nextRestockAt, null);
  assert.equal(shops.dawn.secondsUntilRestock, 0);
  assert.deepEqual(shops.dawn.items, []);
});

test("normalizePlatformShops: accepts inner shops object and garbage input", () => {
  assert.deepEqual(Object.keys(normalizePlatformShops(SHOPS_PAYLOAD.shops)), ["seed", "tool", "dawn"]);
  assert.deepEqual(normalizePlatformShops(null), {});
  assert.deepEqual(normalizePlatformShops("nope"), {});
  assert.deepEqual(normalizePlatformShops({ shops: { seed: 5 } }), {});
});

test("isPreRestockStale: true only for OPEN shops whose nextRestockAt has passed", () => {
  const shops = normalizePlatformShops(SHOPS_PAYLOAD, T_0529);
  assert.equal(isPreRestockStale(shops, T_0529), false);
  assert.equal(isPreRestockStale(shops, T_0530), true); // exactly on boundary => stale
  assert.equal(isPreRestockStale(shops, T_0530 + 400), true);
  // closed shop with null nextRestockAt never marks stale
  assert.equal(isPreRestockStale({ dawn: shops.dawn }, T_0530 + 10_000), false);
});

test("didRestock: moved timestamp, unchanged, missing on either side => null", () => {
  assert.equal(didRestock(T_0530, T_0530 + 300_000), true);
  assert.equal(didRestock(T_0530, T_0530), false);
  assert.equal(didRestock(null, T_0530), null);      // legacy snapshot / shop just opened
  assert.equal(didRestock(undefined, T_0530), null);
  assert.equal(didRestock(T_0530, null), null);      // shop closed
  assert.equal(didRestock(null, null), null);
});

test("normalizeWeather / extractWeatherId: null => Sunny, aliases, unknown => null", () => {
  assert.equal(extractWeatherId(null), "Sunny");
  assert.equal(extractWeatherId(undefined), "Sunny");
  assert.equal(normalizeWeather("Clear Skies"), "Sunny");
  assert.equal(normalizeWeather("Snow"), "Frost");
  assert.equal(normalizeWeather("Amber Moon"), "AmberMoon");
  assert.equal(normalizeWeather("AmberMoon"), "AmberMoon");
  assert.equal(normalizeWeather("Thunderstorm"), "Thunderstorm");
  assert.equal(normalizeWeather("Rain"), "Rain");
  assert.equal(normalizeWeather("Dawn"), "Dawn");
  assert.equal(normalizeWeather("Volcano"), null);
  assert.equal(normalizeWeather(""), null);
  assert.equal(extractWeatherId("Rain"), "Rain"); // real payload observed 2026-08-16 05:55Z: bare JSON string
  assert.equal(extractWeatherId({ weather: "Rain" }), "Rain");
  assert.equal(extractWeatherId({ weatherId: "Frost", startedAt: 1 }), "Frost");
  assert.equal(extractWeatherId({ id: "Dawn" }), "Dawn");
  assert.equal(extractWeatherId({ type: "AmberMoon" }), "AmberMoon");
  assert.equal(extractWeatherId({ current: { name: "Snow" } }), "Frost");
  assert.equal(extractWeatherId({ event: { kind: "Thunderstorm" } }), "Thunderstorm");
  assert.equal(extractWeatherId({ something: "else" }), null);
  assert.equal(extractWeatherId({ weather: "Volcano" }), null);
  assert.equal(extractWeatherId(42), null);
});

function fakeFetchSequence(bodies) {
  let i = 0;
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    const body = bodies[Math.min(i, bodies.length - 1)];
    i += 1;
    return { ok: true, status: 200, json: async () => body };
  };
  return { fetchImpl, calls };
}

test("fetchPlatformShops: refetches while pre-restock stale, bounded", async () => {
  const stale = SHOPS_PAYLOAD; // nextRestockAt 05:30
  const fresh = JSON.parse(JSON.stringify(SHOPS_PAYLOAD));
  fresh.shops.seed.nextRestockAt = "2026-08-16T05:35:00.000Z";
  fresh.shops.tool.nextRestockAt = "2026-08-16T05:40:00.000Z";
  const { fetchImpl, calls } = fakeFetchSequence([stale, stale, fresh]);
  const slept = [];
  const result = await fetchPlatformShops("https://example.test/v1", {
    fetchImpl,
    now: () => T_0530 + 200,
    sleep: async (ms) => slept.push(ms),
    staleDelayMs: 2000,
    staleRetries: 3,
  });
  assert.equal(calls.length, 3);
  assert.equal(calls[0], "https://example.test/v1/shops");
  assert.deepEqual(slept, [2000, 2000]);
  assert.equal(result.staleRetries, 2);
  assert.equal(result.shops.seed.nextRestockAtIso, "2026-08-16T05:35:00.000Z");
});

test("fetchPlatformShops: gives up after staleRetries and returns the last snapshot", async () => {
  const { fetchImpl, calls } = fakeFetchSequence([SHOPS_PAYLOAD]);
  const result = await fetchPlatformShops("https://example.test/v1", {
    fetchImpl,
    now: () => T_0530 + 200,
    sleep: async () => {},
    staleRetries: 2,
  });
  assert.equal(calls.length, 3); // 1 initial + 2 retries
  assert.equal(result.staleRetries, 2);
  assert.equal(isPreRestockStale(result.shops, T_0530 + 200), true);
});

test("fetchPlatformShops: throws on non-2xx", async () => {
  const fetchImpl = async () => ({ ok: false, status: 503, json: async () => ({}) });
  await assert.rejects(() => fetchPlatformShops("https://example.test/v1", { fetchImpl }), /503/);
});

test("fetchPlatformWeather: null body => Sunny; object => extracted; unknown => null with raw kept", async () => {
  let r = await fetchPlatformWeather("https://example.test/v1", { fetchImpl: fakeFetchSequence([null]).fetchImpl });
  assert.deepEqual(r, { raw: null, weatherId: "Sunny" });
  r = await fetchPlatformWeather("https://example.test/v1", { fetchImpl: fakeFetchSequence([{ weather: "Rain" }]).fetchImpl });
  assert.equal(r.weatherId, "Rain");
  r = await fetchPlatformWeather("https://example.test/v1", { fetchImpl: fakeFetchSequence([{ foo: "bar" }]).fetchImpl });
  assert.equal(r.weatherId, null);
  assert.deepEqual(r.raw, { foo: "bar" });
});
