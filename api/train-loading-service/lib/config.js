const integer = (value, fallback) => {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
};

export function loadConfig(env = process.env) {
  return {
    port: integer(env.PORT, 3001),
    mongodbUri: env.MONGODB_URI_TRAIN_LOADING ?? "mongodb://localhost:27017/train_loading",
    mongodbDatabase: env.MONGODB_DATABASE_TRAIN_LOADING,
    ttlSeconds: integer(env.TRAIN_LOADING_TTL_SECONDS, 24 * 60 * 60),
    interestSeconds: integer(env.TRAIN_LOADING_INTEREST_SECONDS, 2 * 60 * 60),
    recentCacheSeconds: integer(env.TRAIN_LOADING_RECENT_CACHE_SECONDS, 2 * 60 * 60),
    recentCacheMaxEvents: integer(env.TRAIN_LOADING_RECENT_CACHE_MAX_EVENTS, 10_000),
    loadingStaleSeconds: integer(env.TRAIN_LOADING_STALE_SECONDS, 10 * 60),
    maxBatchSize: integer(env.TRAIN_LOADING_MAX_BATCH_SIZE, 50),
    staff: {
      apiKey: env.STAFF_DEPARTURES_API_KEY,
      baseUrl: env.STAFF_DEPARTURES_BASE_URL
        ?? "https://api1.raildata.org.uk/1010-live-departure-board---staff-version1_0/LDBSVWS/api/20220120",
      timeoutMs: integer(env.STAFF_DEPARTURES_TIMEOUT_MS, 6_000),
      cacheTtlMs: integer(env.STAFF_DEPARTURES_CACHE_TTL_MS, 30_000),
    },
    darwin: {
      host: env.DARWIN_HOST ?? "darwin-dist-44ae45.nationalrail.co.uk",
      port: integer(env.DARWIN_PORT, 61_613),
      username: env.DARWIN_USERNAME,
      password: env.DARWIN_PASSWORD,
      destination: env.DARWIN_TOPIC ?? "/topic/darwin.pushport-v16",
      selector: env.DARWIN_SELECTOR?.trim() || undefined,
      clientId: env.DARWIN_CLIENT_ID?.trim() || undefined,
      subscriptionName: env.DARWIN_SUBSCRIPTION_NAME?.trim() || undefined,
      heartbeatMs: integer(env.DARWIN_HEARTBEAT_MS, 10_000),
      connectTimeoutMs: integer(env.DARWIN_CONNECT_TIMEOUT_MS, 15_000),
      transportStaleMs: integer(env.DARWIN_TRANSPORT_STALE_MS, 45_000),
      messageStaleMs: integer(env.DARWIN_MESSAGE_STALE_MS, 5 * 60_000),
      reconnectMaxMs: integer(env.DARWIN_RECONNECT_MAX_MS, 30_000),
    },
  };
}

export function validateConfig(config) {
  const missing = [];
  if (!config.darwin.username) missing.push("DARWIN_USERNAME");
  if (!config.darwin.password) missing.push("DARWIN_PASSWORD");
  if (!config.staff.apiKey) missing.push("STAFF_DEPARTURES_API_KEY");
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(", ")}`);
  }
}
