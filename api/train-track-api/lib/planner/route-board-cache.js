import { getMongoCollection } from '../mongo-client.js';

const COLLECTION = 'planner_route_profiles_v1';
const MAX_RECORD_BYTES = 4 * 1024 * 1024;

// Only dated scheduled profiles live here. Provider IDs, forecasts and caller
// identities never enter this shared cache. Whole profiles last two hours;
// immutable hourly fragments survive until overlapping profiles stop using them.
export class RouteBoardCache {
    constructor({ collection = () => getMongoCollection(COLLECTION), now = Date.now,
        maxEntries = 256, maxBytes = 32 * 1024 * 1024, deadlineMs = 750, ensureIndex = false } = {}) {
        Object.assign(this, { collection, now, maxEntries, maxBytes, deadlineMs, ensureIndex });
        this.memory = new Map();
        this.bytes = 0;
        this.database = null;
        this.retryAfter = 0;
        this.write = null;
        this.read = null;
    }

    async db() {
        if (!this.collection) return null;
        if (this.now() < this.retryAfter) return null;
        if (!this.database) {
            this.database = Promise.resolve().then(this.collection).then(async value => {
                if (this.ensureIndex) await value.createIndex({ expiresAt: 1 }, { expireAfterSeconds: 0, name: 'expires_at_ttl', timeoutMS: 500 });
                return value;
            }).catch(() => { this.database = null; this.retryAfter = this.now() + 60000; return null; });
        }
        return this.database;
    }

    async bounded(work) {
        let timer;
        try {
            return await Promise.race([Promise.resolve().then(work), new Promise(resolve => {
                timer = setTimeout(() => resolve(null), this.deadlineMs);
            })]);
        } catch { return null; }
        finally { clearTimeout(timer); }
    }

    remember(key, record) {
        const bytes = Buffer.byteLength(JSON.stringify(record));
        if (bytes > MAX_RECORD_BYTES || bytes > this.maxBytes) return false;
        this.forget(key);
        this.memory.set(key, { record, bytes });
        this.bytes += bytes;
        while (this.memory.size > this.maxEntries || this.bytes > this.maxBytes) this.forget(this.memory.keys().next().value);
        return true;
    }

    forget(key) {
        const value = this.memory.get(key);
        if (value) this.bytes -= value.bytes;
        this.memory.delete(key);
    }

    async get(key) {
        const local = this.memory.get(key);
        if (local && local.record.expiresAt > this.now()) {
            this.memory.delete(key);
            this.memory.set(key, local);
            return local.record;
        }
        this.forget(key);
        if (this.read) return null;
        const started = performance.now();
        this.read = Promise.resolve().then(async () => {
            const db = await this.db();
            if (performance.now() - started >= this.deadlineMs) return null;
            return db?.findOne({ _id: key, expiresAt: { $gt: new Date(this.now()) } }, { maxTimeMS: 500, timeoutMS: 500 });
        }).catch(() => null).finally(() => { this.read = null; });
        const stored = await this.bounded(() => this.read);
        if (!stored || Number(new Date(stored.expiresAt)) <= this.now()) return null;
        const record = { profile: stored.profile, computedAt: stored.computedAt,
            expiresAt: Number(new Date(stored.expiresAt)) };
        return this.remember(key, record) ? record : null;
    }

    async set(key, record) {
        if (!this.remember(key, record)) return false;
        // A response deadline does not cancel a Mongo promise. Keep the actual
        // operation in flight, dropping additional persistence work while busy;
        // the bounded memory cache still serves every accepted record.
        if (this.write) return true;
        const started = performance.now();
        this.write = Promise.resolve().then(async () => {
            const db = await this.db();
            if (!db || performance.now() - started >= this.deadlineMs || record.expiresAt <= this.now()) return;
            await db.replaceOne({ _id: key }, { _id: key, ...record, expiresAt: new Date(record.expiresAt) }, { upsert: true, timeoutMS: 500 });
            const excess = await db.find({}, { projection: { _id: 1 }, timeoutMS: 500, timeoutMode: 'cursorLifetime' })
                .sort({ expiresAt: -1 }).skip(this.maxEntries).toArray();
            if (excess.length) await db.deleteMany({ _id: { $in: excess.map(value => value._id) } }, { timeoutMS: 500 });
        }).catch(() => null).finally(() => { this.write = null; });
        await this.bounded(() => this.write);
        return true;
    }
}
