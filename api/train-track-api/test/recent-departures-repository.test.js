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
    const { repository, documents } = memoryRepository('2026-08-23T10:00:00Z');

    const count = await repository.recordDepartures('kth', 'vic', [
        departure('service-recent', '10:55', '11:02'),
        departure('service-too-far', '11:30', null)
    ]);

    assert.equal(count, 1);
    const stored = [...documents.values()][0];
    assert.equal(stored.fromCRS, 'KTH');
    assert.equal(stored.toCRS, 'VIC');
    assert.equal(stored.actualDepartureAt.toISOString(), '2026-08-23T10:02:00.000Z');
    assert.equal(stored.expiresAt.toISOString(), '2026-08-23T12:02:00.000Z');
    assert.equal(stored.platform, '2');
});

test('provider evidence retains its timestamp when received again later', async () => {
    const { repository, documents } = memoryRepository('2026-09-16T16:30:00Z');
    await repository.recordDepartures('VIC', 'KTH', [observedDeparture('17:27', '2026-09-16T16:26:00Z')]);
    const stored = [...documents.values()][0];
    assert.equal(stored.providerObservedAt.toISOString(), '2026-09-16T16:26:00.000Z');
    assert.equal(stored.lastObservedAt.toISOString(), '2026-09-16T16:30:00.000Z');
    const [response] = await repository.recentDepartures('VIC', 'KTH');
    assert.equal(response.providerObservedAt, '2026-09-16T16:26:00.000Z');
    assert.equal(response.lastObservedAt, '2026-09-16T16:30:00.000Z');
});

test('out-of-order boards cannot roll back a newer estimate or cancellation', async () => {
    const newer = observedDeparture('17:35', '2026-09-16T16:26:00Z', { isCancelled: true });
    const older = observedDeparture('17:27', '2026-09-16T16:17:00Z');
    for (const observations of [[newer, older], [older, newer]]) {
        const { repository, documents, setNow } = memoryRepository('2026-09-16T16:30:00Z');
        for (const [index, observation] of observations.entries()) {
            setNow(`2026-09-16T16:3${index}:00Z`);
            await repository.recordDepartures('VIC', 'KTH', [observation]);
        }
        const stored = [...documents.values()][0];
        assert.equal(stored.estimatedDeparture, '17:35');
        assert.equal(stored.isCancelled, true);
        assert.equal(stored.providerObservedAt.toISOString(), '2026-09-16T16:26:00.000Z');
        assert.equal(stored.lastObservedAt.toISOString(), '2026-09-16T16:31:00.000Z');
    }
});

test('legacy receipt timestamps cannot override known provider evidence', async () => {
    const { repository, documents, setNow } = memoryRepository('2026-09-16T16:30:00Z');
    await repository.recordDepartures('VIC', 'KTH', [departure('caught', '17:27')]);
    await repository.recordDepartures('VIC', 'KTH', [observedDeparture('17:35', '2026-09-16T16:26:00Z')]);
    setNow('2026-09-16T16:31:00Z');
    await repository.recordDepartures('VIC', 'KTH', [departure('caught', '17:27')]);
    const stored = [...documents.values()][0];
    assert.equal(stored.estimatedDeparture, '17:35');
    assert.equal(stored.providerObservedAt.toISOString(), '2026-09-16T16:26:00.000Z');
    assert.equal(stored.lastObservedAt.toISOString(), '2026-09-16T16:31:00.000Z');
});

test('legacy observations remain compatible and receipt ordering is monotonic', async () => {
    const { repository, documents, setNow } = memoryRepository('2026-09-16T16:31:00Z');
    const latest = departure('caught', '17:27');
    latest.departure_time.estimated = '17:35';
    await repository.recordDepartures('VIC', 'KTH', [latest]);
    setNow('2026-09-16T16:30:00Z');
    await repository.recordDepartures('VIC', 'KTH', [departure('caught', '17:27')]);
    const stored = [...documents.values()][0];
    assert.equal(stored.estimatedDeparture, '17:35');
    assert.equal(stored.providerObservedAt, null);
    assert.equal(stored.lastObservedAt.toISOString(), '2026-09-16T16:31:00.000Z');
});

test('actual departure survives forecast-only refreshes and can enrich an older observation', async () => {
    const { repository, documents } = memoryRepository('2026-09-16T16:35:00Z');
    await repository.recordDepartures('VIC', 'KTH', [observedDeparture('17:40', '2026-09-16T16:34:00Z')]);
    const actual = observedDeparture('17:27', '2026-09-16T16:28:00Z');
    actual.departure_time.actual = '17:27';
    await repository.recordDepartures('VIC', 'KTH', [actual]);
    await repository.recordDepartures('VIC', 'KTH', [observedDeparture('17:45', '2026-09-16T16:35:00Z')]);
    const stored = [...documents.values()][0];
    assert.equal(stored.actualDeparture, '17:27');
    assert.equal(stored.actualDepartureAt.toISOString(), '2026-09-16T16:27:00.000Z');
    assert.equal(stored.estimatedDeparture, '17:45');
    assert.equal(stored.providerObservedAt.toISOString(), '2026-09-16T16:35:00.000Z');
});

test('an indefinite delay clears the obsolete parsed estimate', async () => {
    const { repository, documents } = memoryRepository('2026-09-16T16:30:00Z');
    await repository.recordDepartures('VIC', 'KTH', [observedDeparture('17:35', '2026-09-16T16:20:00Z')]);
    await repository.recordDepartures('VIC', 'KTH', [observedDeparture('Delayed', '2026-09-16T16:26:00Z')]);
    const stored = [...documents.values()][0];
    assert.equal(stored.estimatedDeparture, 'Delayed');
    assert.equal(stored.estimatedDepartureAt, null);
});

test('provider dates prevent yesterday\'s cached train from becoming today\'s service', async () => {
    const { repository, documents } = memoryRepository('2026-09-16T16:30:00Z');
    const count = await repository.recordDepartures('VIC', 'KTH', [
        observedDeparture('17:27', '2026-09-15T16:26:00Z')
    ]);
    assert.equal(count, 0);
    assert.equal(documents.size, 0);
});

test('legacy provider timestamps work and invalid dates fall back to SIRI evidence', async () => {
    for (const timestamp of ['2026-09-16T16:25:00Z', 'invalid']) {
        const { repository, documents } = memoryRepository('2026-09-16T16:30:00Z');
        const observation = observedDeparture('17:27', '2026-09-16T16:26:00Z', { timestamp });
        await repository.recordDepartures('VIC', 'KTH', [observation]);
        const stored = [...documents.values()][0];
        assert.equal(stored.providerObservedAt.toISOString(), timestamp === 'invalid'
            ? '2026-09-16T16:26:00.000Z' : '2026-09-16T16:25:00.000Z');
    }
});

function observedDeparture(estimated, providerObservedAt, extra = {}) {
    const value = departure('caught', '17:27');
    value.departure_time.estimated = estimated;
    return { ...value, siri: { providerObservedAt }, ...extra };
}

// An in-memory collection executes the Mongo expression subset used by these
// updates, so tests assert stored observations rather than update syntax.
function memoryRepository(initialNow) {
    let now = new Date(initialNow);
    const documents = new Map();
    const collection = {
        async bulkWrite(operations) {
            for (const { updateOne } of operations) {
                const id = updateOne.filter._id;
                let document = documents.get(id) || { _id: id };
                for (const stage of updateOne.update) {
                    document = { ...document, ...Object.fromEntries(Object.entries(stage.$set)
                        .map(([key, value]) => [key, evaluate(value, document)])) };
                }
                documents.set(id, document);
            }
        },
        find() {
            return { sort() { return this; }, limit() { return this; }, async toArray() { return [...documents.values()]; } };
        }
    };
    return {
        repository: new RecentDeparturesRepository({ now: () => now, getCollection: async () => collection }),
        documents,
        setNow: (value) => { now = new Date(value); }
    };
}

function evaluate(expression, document) {
    if (expression instanceof Date || expression === null) return expression;
    if (typeof expression === 'string') return expression.startsWith('$') ? document[expression.slice(1)] : expression;
    if (typeof expression !== 'object') return expression;
    const [[operator, arguments_]] = Object.entries(expression);
    if (operator === '$literal') return arguments_;
    const values = arguments_.map((argument) => evaluate(argument, document));
    switch (operator) {
    case '$ifNull': return values[0] ?? values[1];
    case '$cond': return values[0] ? values[1] : values[2];
    case '$eq': return values[0] === values[1];
    case '$gte': return values[0] >= values[1];
    case '$or': return values.some(Boolean);
    case '$and': return values.every(Boolean);
    case '$max': return values.reduce((left, right) => left > right ? left : right);
    default: throw new Error(`Unsupported Mongo expression ${operator}`);
    }
}

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
