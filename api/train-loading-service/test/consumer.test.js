import assert from "node:assert/strict";
import test from "node:test";
import { processDarwinFrame } from "../lib/consumer.js";
import { RecentDarwinEventCache } from "../lib/recent-events.js";

const loadingXml = `<Pport ts="2026-08-15T08:00:00+01:00"><uR>
  <formationLoading rid="rid-1" fid="fid-1" tpl="VICTRIE" ptd="08:01">
    <loading coachNumber="A1">42</loading>
  </formationLoading>
</uR></Pport>`;

test("unmatched loading events enter the recent cache and are counted as ignored", async () => {
  const outcomes = [];
  const cache = new RecentDarwinEventCache({ ttlSeconds: 7_200, maxEvents: 10 });
  await processDarwinFrame({
    frame: { headers: { MessageType: "LO" }, body: Buffer.from(loadingXml) },
    store: { hasInterest: () => false },
    recentEvents: cache,
    metrics: {
      onStompMessage: () => {},
      onEvent: (type, matched) => outcomes.push([type, matched]),
      setRecentCacheEvents: () => {},
    },
  });

  assert.equal(cache.eventsForRid("rid-1").length, 1);
  assert.deepEqual(outcomes, [["loading", false]]);
});

test("matched loading events are stored without entering the recent cache", async () => {
  const applied = [];
  const cache = new RecentDarwinEventCache({ ttlSeconds: 7_200, maxEvents: 10 });
  await processDarwinFrame({
    frame: { headers: { MessageType: "LO" }, body: Buffer.from(loadingXml) },
    store: {
      hasInterest: () => true,
      applyEvent: async (event) => applied.push(event),
    },
    recentEvents: cache,
    metrics: { onStompMessage: () => {}, onEvent: () => {}, setRecentCacheEvents: () => {} },
  });

  assert.equal(applied.length, 1);
  assert.equal(cache.size(), 0);
});
