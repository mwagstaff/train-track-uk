import assert from 'node:assert/strict';
import test from 'node:test';

import { JourneyTrackingManager } from '../lib/journey-tracking-manager.js';

test('journey tracking registration validates required identifiers', () => {
    const manager = new JourneyTrackingManager({ pushClient: pushRecorder() });

    assert.throws(
        () => manager.upsertSession({ journeyId: 'journey-1' }),
        /Missing required journey tracking fields/
    );
});

test('journey tracking sends silent station progress only when it changes', async () => {
    const pushClient = pushRecorder();
    const manager = managerWithDetails({
        pushClient,
        details: serviceDetails({
            callingPoints: [
                callingPoint('Clapham Junction', 'CLJ', '10:10', '10:11'),
                callingPoint('London Victoria', 'VIC', '10:20')
            ]
        })
    });
    const session = manager.upsertSession(registration());

    const first = await manager.pollSession(session.id);
    const second = await manager.pollSession(session.id);

    assert.equal(first.status, 'updated');
    assert.equal(second.status, 'unchanged');
    assert.equal(pushClient.payloads.length, 1);
    assert.deepEqual(pushClient.payloads[0].aps, { 'content-available': 1 });
    assert.equal(pushClient.payloads[0].journey_event, 'station_departed');
    assert.equal(pushClient.payloads[0].station_crs, 'CLJ');
    assert.equal(pushClient.payloads[0].operator, 'Southern');
});

test('confirmed destination actual time completes and removes a tracking session', async () => {
    const pushClient = pushRecorder();
    const manager = managerWithDetails({
        pushClient,
        details: serviceDetails({
            callingPoints: [
                callingPoint('Clapham Junction', 'CLJ', '10:10', '10:11'),
                callingPoint('London Victoria', 'VIC', '10:20', '10:36')
            ]
        })
    });
    const session = manager.upsertSession(registration());

    const result = await manager.pollSession(session.id);

    assert.equal(result.status, 'completed');
    assert.equal(pushClient.payloads[0].journey_event, 'service_completed');
    assert.equal(pushClient.payloads[0].scheduled_arrival, '10:20');
    assert.equal(pushClient.payloads[0].actual_arrival, '10:36');
    assert.deepEqual(manager.listSessions('device-1'), []);
});

test('confirmed destination arrival reconciles notification subscriptions before completing', async () => {
    const completions = [];
    const manager = new JourneyTrackingManager({
        pushClient: pushRecorder(),
        getDetails: async () => serviceDetails({
            callingPoints: [callingPoint('London Victoria', 'VIC', '10:20', '10:36')]
        }),
        onJourneyCompleted: async (completion) => completions.push(completion),
        now: () => new Date('2026-08-17T10:00:00Z')
    });
    const session = manager.upsertSession(registration());

    const result = await manager.pollSession(session.id);

    assert.equal(result.status, 'completed');
    assert.deepEqual(completions, [{
        deviceId: 'device-1',
        subscriptionId: 'subscription-1',
        from: 'ECR',
        to: 'VIC',
        journeyId: 'journey-1',
        serviceId: 'service-1',
        actualArrival: '10:36'
    }]);
});

test('failed completion reconciliation remains eligible for retry', async () => {
    let attempts = 0;
    const manager = new JourneyTrackingManager({
        pushClient: pushRecorder(),
        getDetails: async () => serviceDetails({
            callingPoints: [callingPoint('London Victoria', 'VIC', '10:20', '10:36')]
        }),
        onJourneyCompleted: async () => {
            attempts += 1;
            if (attempts === 1) throw new Error('temporary cleanup failure');
        },
        now: () => new Date('2026-08-17T10:00:00Z')
    });
    const session = manager.upsertSession(registration());

    assert.equal((await manager.pollSession(session.id)).status, 'completion_reconciliation_failed');
    assert.equal(manager.listSessions('device-1').length, 1);
    assert.equal((await manager.pollSession(session.id)).status, 'completed');
    assert.equal(manager.listSessions('device-1').length, 0);
});

test('confirmed arrival reconciliation does not depend on push delivery', async () => {
    let reconciled = false;
    const manager = new JourneyTrackingManager({
        pushClient: {
            async sendNotification() {
                return { status: 503, isBadToken: false };
            }
        },
        getDetails: async () => serviceDetails({
            callingPoints: [callingPoint('London Victoria', 'VIC', '10:20', '10:36')]
        }),
        onJourneyCompleted: async () => {
            reconciled = true;
        },
        now: () => new Date('2026-08-17T10:00:00Z')
    });
    const session = manager.upsertSession(registration());

    const result = await manager.pollSession(session.id);

    assert.equal(result.status, 'push_failed');
    assert.equal(reconciled, true);
    assert.equal(manager.listSessions('device-1').length, 1);
});

test('estimated destination time is not treated as a confirmed actual arrival', async () => {
    const pushClient = pushRecorder();
    const manager = managerWithDetails({
        pushClient,
        details: serviceDetails({
            callingPoints: [{
                ...callingPoint('London Victoria', 'VIC', '10:20'),
                et: '10:36'
            }]
        })
    });
    const session = manager.upsertSession(registration());

    const result = await manager.pollSession(session.id);

    assert.equal(result.status, 'updated');
    assert.equal(pushClient.payloads[0].actual_arrival, null);
    assert.equal(manager.listSessions('device-1').length, 1);
});

test('actual time at the current origin is not mistaken for destination arrival', async () => {
    const pushClient = pushRecorder();
    const details = serviceDetails({ callingPoints: [] });
    details.sta = '09:58';
    details.ata = '09:59';
    const manager = managerWithDetails({ pushClient, details });
    const session = manager.upsertSession(registration());

    const result = await manager.pollSession(session.id);

    assert.equal(result.status, 'updated');
    assert.equal(pushClient.payloads[0].actual_arrival, null);
    assert.equal(manager.listSessions('device-1').length, 1);
});

test('failed progress pushes remain eligible for retry', async () => {
    let attempts = 0;
    const pushClient = {
        async sendNotification() {
            attempts += 1;
            return attempts === 1 ? { status: 503 } : { status: 200 };
        }
    };
    const manager = managerWithDetails({
        pushClient,
        details: serviceDetails({
            callingPoints: [callingPoint('Clapham Junction', 'CLJ', '10:10', '10:11')]
        })
    });
    const session = manager.upsertSession(registration());

    assert.equal((await manager.pollSession(session.id)).status, 'push_failed');
    assert.equal((await manager.pollSession(session.id)).status, 'updated');
    assert.equal(attempts, 2);
});

test('journey lifecycle emits searchable audit events without push tokens', async () => {
    const audits = [];
    const manager = new JourneyTrackingManager({
        pushClient: pushRecorder(),
        getDetails: async () => serviceDetails({
            callingPoints: [callingPoint('Clapham Junction', 'CLJ', '10:10', '10:11')]
        }),
        recordAudit: async (event) => audits.push(event),
        now: () => new Date('2026-08-17T10:00:00Z')
    });
    const session = manager.upsertSession(registration());

    await manager.pollSession(session.id);
    await manager.pollSession(session.id);

    assert.deepEqual(audits.map((event) => event.action), [
        'journey_tracking_registered',
        'journey_tracking_progress_detected',
        'journey_tracking_progress_pushed'
    ]);
    assert.ok(audits.every((event) => event.device_id === 'device-1'));
    assert.ok(audits.every((event) => event.metadata.journey_id === 'journey-1'));
    assert.equal(JSON.stringify(audits).includes('push-token-1'), false);
});

function managerWithDetails({ pushClient, details }) {
    return new JourneyTrackingManager({
        pushClient,
        getDetails: async () => details,
        now: () => new Date('2026-08-17T10:00:00Z')
    });
}

function pushRecorder() {
    return {
        payloads: [],
        async sendNotification(_token, payload) {
            this.payloads.push(payload);
            return { status: 200, isBadToken: false };
        }
    };
}

function registration() {
    return {
        journeyId: 'journey-1',
        subscriptionId: 'subscription-1',
        deviceId: 'device-1',
        pushToken: 'push-token-1',
        serviceId: 'service-1',
        from: 'ECR',
        to: 'VIC',
        destinationCRS: 'VIC',
        useSandbox: true
    };
}

function serviceDetails({ callingPoints }) {
    return {
        generatedAt: '2026-08-17T10:00:00Z',
        serviceType: 'train',
        locationName: 'East Croydon',
        crs: 'ECR',
        operator: 'Southern',
        operatorCode: 'SN',
        std: '10:00',
        atd: '10:01',
        subsequentCallingPoints: [{ callingPoint: callingPoints }]
    };
}

function callingPoint(locationName, crs, st, at = null) {
    return { locationName, crs, st, et: at || 'On time', at, isCancelled: false };
}
