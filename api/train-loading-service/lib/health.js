export class HealthMonitor {
  constructor({ store, stomp, metrics, checkIntervalMs = 10_000, onChange = () => {} }) {
    this.onChange = onChange;
    this.previousState = null;
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
    const status = this.status();
    const key = JSON.stringify([status.ready, status.mongo.healthy, status.feed.healthy, status.feed.state]);
    if (key !== this.previousState) {
      this.previousState = key;
      // Bounded state only: do not copy arbitrary broker/database error text.
      this.onChange({ checkedAt: status.checkedAt, ready: status.ready, mongoHealthy: status.mongo.healthy,
        feedHealthy: status.feed.healthy, state: status.feed.state, lastMessageAt: status.feed.lastMessageAt,
        messageAgeSeconds: status.feed.messageAgeSeconds, transportAgeSeconds: status.feed.transportAgeSeconds });
    }
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
