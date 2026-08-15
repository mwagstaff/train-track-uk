function eventKey(event) {
  if (event.type === "formation") return `${event.rid}:formation:${event.formationId}`;
  if (event.type === "loading") {
    return `${event.rid}:loading:${event.formationId}:${event.tiploc ?? "unknown"}`;
  }
  return null;
}

export class RecentDarwinEventCache {
  constructor({ ttlSeconds, maxEvents, now = () => new Date() }) {
    this.ttlMs = ttlSeconds * 1_000;
    this.maxEvents = maxEvents;
    this.now = now;
    this.events = new Map();
  }

  add(event) {
    const key = eventKey(event);
    if (!key) return false;
    this.prune();
    this.events.delete(key);
    this.events.set(key, { event, cachedAt: this.now().getTime() });
    while (this.events.size > this.maxEvents) {
      this.events.delete(this.events.keys().next().value);
    }
    return true;
  }

  eventsForRid(rid) {
    this.prune();
    return [...this.events.values()]
      .filter((entry) => entry.event.rid === rid)
      .sort((left, right) => left.cachedAt - right.cachedAt)
      .map((entry) => entry.event);
  }

  deleteRid(rid) {
    for (const [key, entry] of this.events) {
      if (entry.event.rid === rid) this.events.delete(key);
    }
  }

  prune() {
    const cutoff = this.now().getTime() - this.ttlMs;
    for (const [key, entry] of this.events) {
      if (entry.cachedAt <= cutoff) this.events.delete(key);
    }
  }

  size() {
    this.prune();
    return this.events.size;
  }
}
