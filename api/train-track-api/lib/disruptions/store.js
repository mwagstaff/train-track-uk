import { randomUUID } from 'node:crypto';
import { COLLECTIONS, getMongoCollection } from '../mongo-client.js';
import { hash } from './model.js';

// Device preferences and delivery receipts are separate from shared public
// timetable profiles. The latter never contain installation identifiers.
export class DisruptionStore {
    constructor({ getCollection = getMongoCollection } = {}) { this.getCollection = getCollection; }
    collection(key) { return this.getCollection(COLLECTIONS[key]); }
    async getDevice(deviceId) { return (await this.collection('disruptionMonitors')).findOne({ _id: deviceId }); }
    async saveDevice(input, now) {
        const collection = await this.collection('disruptionMonitors');
        const previous = await collection.findOne({ _id: input.deviceId });
        const pushToken = input.pushToken === undefined ? previous?.pushToken ?? null : input.pushToken;
        const useSandbox = input.useSandbox ?? previous?.useSandbox ?? false;
        const revision = hash([input.monitors, pushToken, useSandbox]);
        await collection.updateOne({ _id: input.deviceId }, {
            $set: { ...input, pushToken, useSandbox, revision, updatedAt: new Date(now),
                ...(hash(previous?.monitors) === hash(input.monitors) && previous?.stateRevision === previous?.revision
                    ? { stateRevision: revision } : {}) },
            $setOnInsert: { createdAt: new Date(now) }
        }, { upsert: true });
        return collection.findOne({ _id: input.deviceId });
    }
    async *devices() {
        const collection = await this.collection('disruptionMonitors');
        for await (const device of collection.find({ 'monitors.enabled': true }).batchSize(25)) yield device;
    }
    async saveState(device, state) {
        const result = await (await this.collection('disruptionMonitors')).updateOne(
            { _id: device.deviceId, revision: device.revision }, { $set: { state, stateRevision: device.revision } });
        return result.matchedCount === 1;
    }
    async clearPushToken(device, now) {
        const revision = hash([device.monitors, null, device.useSandbox ?? false]);
        await (await this.collection('disruptionMonitors')).updateOne(
            { _id: device.deviceId, revision: device.revision, pushToken: device.pushToken },
            { $set: { pushToken: null, revision, updatedAt: new Date(now),
                ...(device.stateRevision === device.revision ? { stateRevision: revision } : {}) } });
    }
    async enqueue(jobs, now) {
        if (!jobs.length) return;
        const unique = [...new Map(jobs.map(job => [job._id, job])).values()];
        await (await this.collection('disruptionProfiles')).bulkWrite(unique.map(job => {
            const { demandedUntil, priority, ...record } = job;
            return { updateOne: { filter: { _id: job._id }, update: { $setOnInsert: record,
                $set: { demandedUntil: new Date(now + 3600000), priority } }, upsert: true } };
        }), { ordered: false });
    }
    async profiles(ids) {
        if (!ids.length) return [];
        return (await this.collection('disruptionProfiles')).find({ _id: { $in: [...new Set(ids)] } }).toArray();
    }
    async historicalProfiles(stations, chunks, currentVersion) {
        if (!chunks.length) return [];
        const wanted = new Set(chunks.map(chunk => `${chunk.date}:${chunk.startMinutes}:${chunk.endMinutes}`));
        const rows = new Map();
        const collection = await this.collection('disruptionProfiles');
        // Completed historical observations are immutable public evidence. A
        // new publication need not reroute the previous fortnight each day.
        const cursor = collection.find({ routeKey: hash(stations), date: { $in: [...new Set(chunks.map(chunk => chunk.date))] },
            datasetVersion: { $ne: currentVersion }, status: 'complete', 'profile.complete': true }).sort({ checkedAt: -1 }).batchSize(100);
        try {
            for await (const row of cursor) {
                const key = `${row.date}:${row.startMinutes}:${row.endMinutes}`;
                if (wanted.has(key) && !rows.has(key)) rows.set(key, row);
                if (rows.size === wanted.size) break;
            }
        } finally { await cursor.close(); }
        return [...rows.values()];
    }
    async claim(version, now) {
        return (await this.collection('disruptionProfiles')).findOneAndUpdate({ datasetVersion: version,
            demandedUntil: { $gt: new Date(now) }, retryAt: { $lte: new Date(now) },
            $or: [{ status: 'pending' }, { status: 'running', leaseUntil: { $lt: new Date(now) } }] },
        { $set: { status: 'running', lease: randomUUID(), leaseUntil: new Date(now + 120000) } },
        { sort: { priority: 1, date: 1, startMinutes: 1, createdAt: 1 }, returnDocument: 'after' });
    }
    async complete(job, profile, now) {
        await (await this.collection('disruptionProfiles')).updateOne({ _id: job._id, lease: job.lease },
            { $set: { status: 'complete', profile, checkedAt: new Date(now) }, $unset: { lease: '', leaseUntil: '' } });
    }
    async defer(job, now, reason) {
        await (await this.collection('disruptionProfiles')).updateOne({ _id: job._id, lease: job.lease },
            { $set: { status: 'pending', retryAt: new Date(now + (reason === 'deferred' ? 30000 : 300000)), reason },
                $inc: { attempts: 1, ...(reason === 'deferred' ? {} : { failures: 1 }) }, $unset: { lease: '', leaseUntil: '' } });
    }
    async claimDelivery(device, advisory, fingerprint, now) {
        const id = hash([device.deviceId, advisory.monitorId, advisory.id]);
        const collection = await this.collection('disruptionDeliveries');
        await collection.updateOne({ _id: id }, { $setOnInsert: { deviceId: device.deviceId, monitorId: advisory.monitorId,
            sentFingerprint: null, retryAt: new Date(0), expiresAt: new Date(Date.parse(advisory.endAt) + 7 * 86400000) } }, { upsert: true });
        return collection.findOneAndUpdate({ _id: id, sentFingerprint: { $ne: fingerprint }, retryAt: { $lte: new Date(now) },
            $or: [{ leaseUntil: { $exists: false } }, { leaseUntil: { $lt: new Date(now) } }] },
        { $set: { lease: randomUUID(), leaseUntil: new Date(now + 120000) } }, { returnDocument: 'after' });
    }
    async finishDelivery(receipt, fingerprint, sent, now) {
        await (await this.collection('disruptionDeliveries')).updateOne({ _id: receipt._id, lease: receipt.lease },
            { $set: sent ? { sentFingerprint: fingerprint, sentAt: new Date(now), retryAt: new Date(now) }
                : { retryAt: new Date(now + 300000) }, $unset: { lease: '', leaseUntil: '' } });
    }
    async stats(now) {
        const collection = await this.collection('disruptionProfiles');
        const filter = { demandedUntil: { $gt: new Date(now) }, status: { $in: ['pending', 'running'] } };
        const [pending, oldest] = await Promise.all([collection.countDocuments(filter), collection.findOne(filter, { sort: { createdAt: 1 } })]);
        return { pending, oldestAgeSeconds: oldest ? Math.max(0, (now - oldest.createdAt.getTime()) / 1000) : 0 };
    }
}
