import assert from 'node:assert/strict';
import test from 'node:test';

import {
    RecentDeparturesRepository,
    railDateNear
} from '../lib/recent-departures-repository.js';

test('rail departure times resolve in Europe/London across BST and midnight', () => {
    assert.equal(
        railDateNear('11:05', new Date('2026-08-23T10:00:00Z')).toISOString(),
        '2026-08-23T10:05:00.000Z'
    );
    assert.equal(
        railDateNear('23:58', new Date('2026-08-24T00:04:00Z')).toISOString(),
        '2026-08-23T22:58:00.000Z'
    );
});

test('repository stores only the bounded recent window and anchors TTL to actual departure', async () => {
    const writes = [];
    const now = new Date('2026-08-23T10:00:00Z');
    const repository = new RecentDeparturesRepository({
        now: () => now,
        getCollection: async () => ({
            bulkWrite: async (operations) => { writes.push(...operations); }
        })
    });

    const count = await repository.recordDepartures('kth', 'vic', [
        departure('service-recent', '10:55', '11:02'),
        departure('service-too-far', '11:30', null)
    ]);

    assert.equal(count, 1);
    const operation = writes[0].updateOne;
    assert.equal(operation.update.$set.fromCRS, 'KTH');
    assert.equal(operation.update.$set.toCRS, 'VIC');
    assert.equal(operation.update.$set.actualDepartureAt.toISOString(), '2026-08-23T10:02:00.000Z');
    assert.equal(operation.update.$max.expiresAt.toISOString(), '2026-08-23T12:02:00.000Z');
    assert.equal(operation.update.$set.platform, '2');
});

function departure(serviceID, scheduled, actual) {
    return {
        serviceID,
        serviceType: 'train',
        departure_time: {
            scheduled,
            estimated: scheduled,
            ...(actual ? { actual } : {})
        },
        platform: '2',
        isCancelled: false
    };
}
