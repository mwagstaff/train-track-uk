import test from "node:test";
import assert from "node:assert/strict";
import { HealthMonitor } from "../lib/health.js";

test("readiness transitions expose a stalled feed without logging every poll or raw errors", async () => {
  let healthy = true;
  const changes = [];
  const health = new HealthMonitor({ store: { ping: async () => {}, activeInterestCount: () => 0 },
    stomp: { isHealthy: () => healthy, status: () => ({ state: "subscribed", messageAgeSeconds: healthy ? 0 : 400, lastError: "secret upstream text" }) },
    metrics: {}, onChange: value => changes.push(value) });
  await health.checkMongo(); await health.checkMongo();
  healthy = false; await health.checkMongo(); await health.checkMongo();
  healthy = true; await health.checkMongo();
  assert.deepEqual(changes.map(value => value.ready), [true, false, true]);
  assert.equal(changes[1].mongoHealthy, true);
  assert.equal(changes[1].state, "subscribed");
  assert.ok(changes.every(value => Number.isFinite(Date.parse(value.checkedAt))));
  assert.ok(!JSON.stringify(changes).includes("secret"));
});
