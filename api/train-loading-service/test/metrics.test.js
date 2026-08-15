import assert from "node:assert/strict";
import test from "node:test";
import { createMetrics } from "../lib/metrics.js";

test("metrics distinguish matched and ignored loading events", async () => {
  const metrics = createMetrics();
  metrics.onEvent("loading", true);
  metrics.onEvent("loading", false);
  metrics.onReplay("loading", true);
  metrics.setRecentCacheEvents(7);

  const output = await metrics.registry.metrics();
  assert.match(output, /train_loading_events_total\{event_type="loading",result="matched"\} 1/);
  assert.match(output, /train_loading_events_total\{event_type="loading",result="ignored"\} 1/);
  assert.match(output, /train_loading_replayed_events_total\{event_type="loading",result="stored"\} 1/);
  assert.match(output, /train_loading_recent_cache_events 7/);
});
