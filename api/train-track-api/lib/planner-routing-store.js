import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { COLLECTIONS, getMongoCollection } from './mongo-client.js';
import { decodeCursor, PlannerError } from './planner/contract.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const JOURNEY = /^[a-f0-9]{64}\.[a-f0-9]{32}$/;
const DEFAULT_TTLS = Object.freeze({ idempotency: 12 * 60 * 60 * 1000, job: 2 * 60 * 60 * 1000,
    journey: 2 * 60 * 60 * 1000, cursor: 7 * 24 * 60 * 60 * 1000 });

const collection = () => getMongoCollection(COLLECTIONS.plannerRoutingOwnership);
const digestBody = body => createHash('sha256').update(body ?? '').digest('hex');

/** Stores only opaque HMAC digests and routing metadata, never searches or results. */
export class PlannerRoutingStore {
    constructor({ getCollection = collection, secret, now = Date.now, ttls = {}, maxCache = 5000,
        legacyTargetId = 'sky' } = {}) {
        if (typeof secret !== 'string' || secret.length < 16) {
            throw new Error('PLANNER_ROUTING_SECRET must contain at least 16 characters.');
        }
        Object.assign(this, { getCollection, secret, now, maxCache, legacyTargetId });
        this.ttls = { ...DEFAULT_TTLS, ...ttls };
        this.cache = new Map();
    }

    digest(type, value) {
        return createHmac('sha256', this.secret).update(`${type}\0${value}`).digest('hex');
    }

    cacheSet(key, value) {
        this.cache.delete(key);
        this.cache.set(key, value);
        while (this.cache.size > this.maxCache) this.cache.delete(this.cache.keys().next().value);
    }

    async find(type, value) {
        if (!value) return null;
        const key = `${type}:${this.digest(type, value)}`;
        const cached = this.cache.get(key);
        if (cached && cached.expiresAt > this.now()) return cached;
        this.cache.delete(key);
        const row = await (await this.getCollection()).findOne({ _id: key }, { timeoutMS: 2000 });
        if (!row || new Date(row.expiresAt).getTime() <= this.now()) return null;
        const result = { targetIds: row.targetIds ?? [row.targetId].filter(Boolean),
            requestFingerprint: row.requestFingerprint ?? null, expiresAt: new Date(row.expiresAt).getTime() };
        this.cacheSet(key, result);
        return result;
    }

    async owner(type, value) {
        return (await this.find(type, value))?.targetIds?.[0] ?? null;
    }

    async remember(type, value, targetId) {
        if (!value || !targetId || !this.ttls[type]) return;
        const key = `${type}:${this.digest(type, value)}`;
        const now = new Date(this.now()), expiresAt = new Date(this.now() + this.ttls[type]);
        const db = await this.getCollection();
        await db.updateOne({ _id: key }, { $set: { type, updatedAt: now, expiresAt },
            $addToSet: { targetIds: targetId } }, { upsert: true, timeoutMS: 2000 });
        const existing = this.cache.get(key);
        this.cacheSet(key, { targetIds: [...new Set([...(existing?.targetIds ?? []), targetId])],
            requestFingerprint: existing?.requestFingerprint ?? null, expiresAt: expiresAt.getTime() });
    }

    async bindSubmission({ caller, idempotencyKey, requestBody, targetId }) {
        if (!idempotencyKey) return targetId;
        const identity = `${caller}\0${idempotencyKey}`;
        const key = `idempotency:${this.digest('idempotency', identity)}`;
        const requestFingerprint = digestBody(requestBody);
        const existing = await this.find('idempotency', identity);
        if (existing) {
            if (!safeEqual(existing.requestFingerprint, requestFingerprint)) {
                throw new PlannerError('IDEMPOTENCY_CONFLICT', 'This idempotency key was already used for a different search.', 409);
            }
            return existing.targetIds[0];
        }
        const now = new Date(this.now()), expiresAt = new Date(this.now() + this.ttls.idempotency);
        try {
            await (await this.getCollection()).insertOne({ _id: key, type: 'idempotency', targetIds: [targetId],
                requestFingerprint, updatedAt: now, expiresAt }, { timeoutMS: 2000 });
            this.cacheSet(key, { targetIds: [targetId], requestFingerprint, expiresAt: expiresAt.getTime() });
            return targetId;
        } catch (error) {
            if (error?.code !== 11000) throw error;
            const raced = await this.find('idempotency', identity);
            if (!raced || !safeEqual(raced.requestFingerprint, requestFingerprint)) {
                throw new PlannerError('IDEMPOTENCY_CONFLICT', 'This idempotency key was already used for a different search.', 409);
            }
            return raced.targetIds[0];
        }
    }

    async rememberResponse(targetId, operation, payload) {
        const artifacts = responseArtifacts(operation, payload);
        await Promise.all([...artifacts.values()].map(([type, value]) => this.remember(type, value, targetId)));
    }

    async targetFor({ operation, artifact, cursor, caller, idempotencyKey, requestBody, selectedTargetId }) {
        if (artifact) {
            const owner = await this.owner(operation === 'job' ? 'job' : 'journey', artifact);
            return owner ?? this.legacyTargetId;
        }
        if (cursor) {
            const owner = await this.owner('cursor', cursor);
            return owner ?? this.legacyTargetId;
        }
        if (operation === 'job-submit' && idempotencyKey) {
            return this.bindSubmission({ caller, idempotencyKey, requestBody, targetId: selectedTargetId });
        }
        return selectedTargetId;
    }
}

export function responseArtifacts(operation, payload) {
    const artifacts = new Map();
    const add = (type, value) => { if (value) artifacts.set(`${type}:${value}`, [type, value]); };
    if (operation === 'job-submit' && UUID.test(payload?.id ?? '')) add('job', payload.id);
    const visit = (value, key = '') => {
        if (typeof value === 'string') {
            if (JOURNEY.test(value) && (key === 'id' || /journey/i.test(key))) add('journey', value);
            if (/cursor|earlier|later|more/i.test(key)) {
                try { decodeCursor(value); add('cursor', value); } catch { /* Not a planner cursor. */ }
            }
            return;
        }
        if (Array.isArray(value)) { for (const item of value) visit(item, key); return; }
        if (!value || typeof value !== 'object') return;
        for (const [childKey, child] of Object.entries(value)) visit(child, childKey);
    };
    visit(payload);
    return artifacts;
}

export function requestFingerprint(body) { return digestBody(body); }

function safeEqual(left, right) {
    if (typeof left !== 'string' || typeof right !== 'string') return false;
    const a = Buffer.from(left), b = Buffer.from(right);
    return a.length === b.length && timingSafeEqual(a, b);
}
