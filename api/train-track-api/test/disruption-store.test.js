import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { MongoClient } from 'mongodb';
import { DisruptionStore } from '../lib/disruptions/store.js';
import { profileJob } from '../lib/disruptions/model.js';
import { COLLECTIONS } from '../lib/mongo-client.js';

test('Mongo persistence shares profiles, leases work, preserves edits and deduplicates notification delivery',
    { skip: !process.env.DISRUPTION_TEST_MONGODB_URI }, async () => {
        const client = new MongoClient(process.env.DISRUPTION_TEST_MONGODB_URI, { serverSelectionTimeoutMS: 2000 });
        await client.connect();
        const db = client.db(`train_track_disruption_test_${randomUUID().replaceAll('-', '')}`);
        const store = new DisruptionStore({ getCollection: async name => db.collection(name) });
        try {
            const now = Date.parse('2026-09-19T12:00:00Z');
            const input = { deviceId: 'isolated-device', monitors: [{ id: 'route', enabled: true, stations: ['KTH', 'VIC'] }] };
            let device = await store.saveDevice(input, now);
            assert.equal(device.pushToken, null);
            assert.equal(await store.saveState(device, { monitors: [], advisories: [] }), true);
            device = await store.saveDevice({ ...input, pushToken: 'a'.repeat(64) }, now + 1);
            assert.equal(device.stateRevision, device.revision, 'token rotation retains current in-app advisories');
            assert.equal((await Array.fromAsync(store.devices())).length, 1);
            const edited = await store.saveDevice({ ...input, monitors: [] }, now + 2);
            assert.equal(await store.saveState(device, { stale: true }), false, 'old scan cannot overwrite edited preferences');
            assert.equal((await Array.fromAsync(store.devices())).length, 0);
            assert.notEqual(device.revision, edited.revision);
            await store.clearPushToken(device, now + 3);
            assert.equal((await store.getDevice(input.deviceId)).revision, edited.revision,
                'a late bad-token result cannot overwrite newer preferences');
            assert.equal((await store.getDevice(input.deviceId)).pushToken, 'a'.repeat(64));
            await store.clearPushToken(edited, now + 4);
            assert.equal((await store.getDevice(input.deviceId)).pushToken, null);
            assert.deepEqual((await store.getDevice(input.deviceId)).monitors, []);

            const window = { date: '2026-09-20', startMinutes: 420, endMinutes: 480 };
            const job = profileJob(['KTH', 'VIC'], window, 'version-a', now, 2);
            await store.enqueue([job, job], now);
            await store.enqueue([job], now);
            assert.equal(await db.collection(COLLECTIONS.disruptionProfiles).countDocuments(), 1);
            const [first, second] = await Promise.all([store.claim('version-a', now), store.claim('version-a', now)]);
            const claimed = first ?? second;
            assert.ok(claimed); assert.equal(Boolean(first) && Boolean(second), false);
            await store.defer(claimed, now, 'deferred');
            assert.equal(await store.claim('version-a', now + 10000), null);
            const retried = await store.claim('version-a', now + 30000);
            assert.equal(retried.attempts, 1);
            assert.equal(retried.failures ?? 0, 0, 'user demand does not spend the failure budget');
            await store.defer(retried, now + 30000, 'unavailable');
            assert.equal(await store.claim('version-a', now + 60000), null);
            const afterFailure = await store.claim('version-a', now + 330000);
            assert.equal(afterFailure.attempts, 2);
            assert.equal(afterFailure.failures, 1);
            const profile = { ...window, complete: true, datasetVersion: 'version-a', sourceGenerationDate: '2026-09-19' };
            await store.complete(afterFailure, profile, now + 330001);
            await store.defer(claimed, now + 330002, 'late_old_lease');
            assert.equal((await store.profiles([job._id]))[0].status, 'complete');
            const history = await store.historicalProfiles(['KTH', 'VIC'], [window], 'version-b');
            assert.equal(history.length, 1);
            assert.equal(history[0].profile.datasetVersion, 'version-a');
            assert.equal(profileJob(['KTH', 'VIC'], history[0], 'version-b', now)._id,
                profileJob(['KTH', 'VIC'], window, 'version-b', now)._id);
            assert.equal((await store.historicalProfiles(['VIC', 'KTH'], [window], 'version-b')).length, 0);

            const advisory = { id: 'notice', monitorId: 'route', endAt: '2026-09-21T00:00:00Z' };
            const receipt = await store.claimDelivery(device, advisory, 'changed', now);
            assert.ok(receipt);
            assert.equal(await store.claimDelivery(device, advisory, 'changed', now), null);
            await store.finishDelivery(receipt, 'changed', true, now);
            assert.equal(await store.claimDelivery(device, advisory, 'changed', now), null);
            const revision = await store.claimDelivery(device, advisory, 'important-update', now + 1);
            assert.ok(revision);
            await store.finishDelivery(revision, 'important-update', false, now + 1);
            assert.equal(await store.claimDelivery(device, advisory, 'important-update', now + 60000), null);
            assert.ok(await store.claimDelivery(device, advisory, 'important-update', now + 300001));
            assert.deepEqual(await store.stats(now), { pending: 0, oldestAgeSeconds: 0 });
        } finally { await db.dropDatabase(); await client.close(); }
    });
