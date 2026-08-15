import assert from "node:assert/strict";
import test from "node:test";
import { RecentDarwinEventCache } from "../lib/recent-events.js";

test("recent event cache keeps the latest event per formation location", () => {
  let now = new Date("2026-08-15T08:00:00.000Z");
  const cache = new RecentDarwinEventCache({ ttlSeconds: 7_200, maxEvents: 10, now: () => now });
  cache.add({ type: "loading", rid: "rid-1", formationId: "fid", tiploc: "AAA", coaches: [{ percentage: 10 }] });
  now = new Date("2026-08-15T08:01:00.000Z");
  cache.add({ type: "loading", rid: "rid-1", formationId: "fid", tiploc: "AAA", coaches: [{ percentage: 20 }] });
  cache.add({ type: "formation", rid: "rid-1", formationId: "fid", coaches: [{ number: "A1" }] });

  const events = cache.eventsForRid("rid-1");
  assert.equal(events.length, 2);
  assert.equal(events.find((event) => event.type === "loading").coaches[0].percentage, 20);
});

test("recent event cache expires old entries and enforces its size limit", () => {
  let now = new Date("2026-08-15T08:00:00.000Z");
  const cache = new RecentDarwinEventCache({ ttlSeconds: 60, maxEvents: 2, now: () => now });
  cache.add({ type: "formation", rid: "old", formationId: "1" });
  cache.add({ type: "formation", rid: "kept", formationId: "2" });
  cache.add({ type: "formation", rid: "newest", formationId: "3" });
  assert.equal(cache.size(), 2);
  assert.deepEqual(cache.eventsForRid("old"), []);

  now = new Date("2026-08-15T08:01:01.000Z");
  assert.equal(cache.size(), 0);
});
