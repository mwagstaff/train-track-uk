import assert from "node:assert/strict";
import test from "node:test";
import { DarwinStompClient } from "../lib/stomp.js";

function client(overrides = {}) {
  return new DarwinStompClient({
    connectTimeoutMs: 15_000,
    transportStaleMs: 45_000,
    messageStaleMs: 300_000,
    ...overrides,
  });
}

test("feed health requires a subscribed, recently active transport", () => {
  const stomp = client();
  const now = Date.now();
  stomp.health.state = "subscribed";
  stomp.health.connectedAt = now - 1_000;
  stomp.health.lastDataAt = now - 1_000;
  assert.equal(stomp.isHealthy(now), true);

  stomp.health.lastDataAt = now - 45_001;
  assert.equal(stomp.isHealthy(now), false);
});

test("feed health becomes stale when MESSAGE frames stop", () => {
  const stomp = client();
  const now = Date.now();
  stomp.health.state = "subscribed";
  stomp.health.connectedAt = now - 301_000;
  stomp.health.lastDataAt = now;
  stomp.health.lastMessageAt = now - 300_001;
  assert.equal(stomp.isHealthy(now), false);
});

test("sequence tracking handles wraparound and reports gaps", () => {
  const gaps = [];
  const stomp = client({ onSequenceGap: (gap) => gaps.push(gap) });
  stomp.trackSequence({ SequenceNumber: "9999999" });
  stomp.trackSequence({ SequenceNumber: "0" });
  stomp.trackSequence({ SequenceNumber: "2" });
  assert.equal(stomp.health.sequenceGaps, 1);
  assert.deepEqual(gaps, [{ previous: 0, expected: 1, received: 2 }]);
});
