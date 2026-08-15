import { createApp } from "./lib/app.js";
import { loadConfig, validateConfig } from "./lib/config.js";
import { decodeDarwinBody, messageType, parseDarwinMessage } from "./lib/darwin.js";
import { HealthMonitor } from "./lib/health.js";
import { createMetrics } from "./lib/metrics.js";
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
});
await store.init();

const staffClient = new StaffDepartureBoardClient({
  ...config.staff,
  onRequest: (result) => metrics.onStaffRequest(result),
});
const resolver = new LoadingResolver({
  store,
  staffClient,
  staleSeconds: config.loadingStaleSeconds,
  onResolution: (result) => metrics.onResolution(result),
});

let processChain = Promise.resolve();
const processFrame = async (frame) => {
  const type = messageType(frame.headers);
  metrics.onStompMessage(type);
  if (type && !["SC", "SF", "LO"].includes(type)) return;
  const interestedRids = store.interestedRids();
  if (interestedRids.length === 0) return;
  const xml = decodeDarwinBody(frame.body);
  if (!interestedRids.some((rid) => xml.includes(rid))) return;
  for (const event of parseDarwinMessage(xml, frame.headers)) {
    const stored = await store.applyEvent(event);
    metrics.onEvent(event.type, stored);
  }
};

const stomp = new DarwinStompClient({
  ...config.darwin,
  onMessage: (frame) => {
    processChain = processChain
      .then(() => processFrame(frame))
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
  console.log(`Train loading service listening on port ${config.port}; TTL=${config.ttlSeconds}s`);
});

const pruneTimer = setInterval(() => {
  store.pruneInterests();
  metrics.setInterests(store.activeInterestCount());
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
