export class HealthMonitor {
  constructor({ store, stomp, metrics, checkIntervalMs = 10_000 }) {
    this.store = store;
    this.stomp = stomp;
    this.metrics = metrics;
    this.checkIntervalMs = checkIntervalMs;
    this.mongoHealthy = false;
    this.lastMongoCheckAt = null;
    this.lastMongoError = null;
    this.timer = null;
  }

  async start() {
    await this.checkMongo();
    this.timer = setInterval(() => {
      void this.checkMongo();
      this.metrics.setInterests(this.store.activeInterestCount());
      this.metrics.onStompState(this.stomp.status());
    }, this.checkIntervalMs);
    this.timer.unref?.();
  }

  async checkMongo() {
    try {
      await this.store.ping();
      this.mongoHealthy = true;
      this.lastMongoError = null;
    } catch (error) {
      this.mongoHealthy = false;
      this.lastMongoError = error.message;
    }
    this.lastMongoCheckAt = new Date().toISOString();
  }

  status() {
    const feed = this.stomp.status();
    const feedHealthy = this.stomp.isHealthy();
    return {
      ready: this.mongoHealthy && feedHealthy,
      mongo: {
        healthy: this.mongoHealthy,
        checkedAt: this.lastMongoCheckAt,
        error: this.lastMongoError,
      },
      feed: {
        healthy: feedHealthy,
        ...feed,
      },
      activeInterests: this.store.activeInterestCount(),
      checkedAt: new Date().toISOString(),
    };
  }

  stop() {
    clearInterval(this.timer);
  }
}
