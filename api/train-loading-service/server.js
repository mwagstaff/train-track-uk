import { createApp } from "./lib/app.js";
import { loadConfig, validateConfig } from "./lib/config.js";
import { processDarwinFrame } from "./lib/consumer.js";
import { HealthMonitor } from "./lib/health.js";
import { createMetrics } from "./lib/metrics.js";
import { RecentDarwinEventCache } from "./lib/recent-events.js";
import { LoadingResolver } from "./lib/resolver.js";
import { StaffDepartureBoardClient } from "./lib/staff-board.js";
import { MongoLoadingStore } from "./lib/store.js";
import { DarwinStompClient } from "./lib/stomp.js";

const config = loadConfig();
validateConfig(config);
const metrics = createMetrics();

const store = new MongoLoadingStore({
  uri: config.mongodbUri,
  databaseName: config.mongodbDatabase,
  ttlSeconds: config.ttlSeconds,
  interestSeconds: config.interestSeconds,
});
await store.init();

const recentEvents = new RecentDarwinEventCache({
  ttlSeconds: config.recentCacheSeconds,
  maxEvents: config.recentCacheMaxEvents,
});

const staffClient = new StaffDepartureBoardClient({
  ...config.staff,
  onRequest: (result) => metrics.onStaffRequest(result),
});
const resolver = new LoadingResolver({
  store,
  staffClient,
  staleSeconds: config.loadingStaleSeconds,
  recentEvents,
  onResolution: (result) => metrics.onResolution(result),
  onReplay: (type, stored) => metrics.onReplay(type, stored),
});

let processChain = Promise.resolve();

const stomp = new DarwinStompClient({
  ...config.darwin,
  onMessage: (frame) => {
    processChain = processChain
      .then(() => processDarwinFrame({ frame, store, recentEvents, metrics }))
      .catch((error) => console.error("[darwin] message processing failed", error?.message ?? error));
  },
  onState: (status) => {
    metrics.onStompState(status);
    console.log(`[darwin] state=${status.state}`);
  },
  onSequenceGap: ({ expected, received }) => {
    metrics.onSequenceGap();
    console.error(`[darwin] sequence gap: expected=${expected} received=${received}`);
  },
  onError: (error) => console.error("[darwin]", error.message),
});

const health = new HealthMonitor({ store, stomp, metrics });
await health.start();
stomp.start();

const app = createApp({ resolver, health, metrics, maxBatchSize: config.maxBatchSize });
const server = app.listen(config.port, () => {
  console.log(
    `Train loading service listening on port ${config.port}; `
    + `interest=${config.interestSeconds}s cache=${config.recentCacheSeconds}s TTL=${config.ttlSeconds}s`,
  );
});

const pruneTimer = setInterval(() => {
  store.pruneInterests();
  recentEvents.prune();
  metrics.setInterests(store.activeInterestCount());
  metrics.setRecentCacheEvents(recentEvents.size());
}, 60_000);
pruneTimer.unref?.();

async function shutdown(signal) {
  console.log(`[shutdown] ${signal}`);
  clearInterval(pruneTimer);
  health.stop();
  stomp.stop();
  server.close();
  await processChain.catch(() => {});
  await store.close();
  process.exit(0);
}

process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));
