import test from 'node:test';
import assert from 'node:assert/strict';
import { liveScheduleIdentity } from '../lib/planner/live-schedule-identity.js';
const departure = Date.parse('2026-11-17T17:28:00Z');
const calls = [{ station: 'BFR', departure }, { station: 'HER', arrival: departure + 10 * 60000 },
    { station: 'KTH', arrival: departure + 22 * 60000 }];
const service = { id: 'dated', uid: 'A12345', originDate: '2026-11-17', operator: 'SE', mode: 'rail', calls };
const leg = { from: { crs: 'BFR' }, to: { crs: 'KTH' }, operator: 'SE',
    scheduledDeparture: new Date(departure).toISOString(), scheduledArrival: new Date(calls[2].arrival).toISOString(),
    serviceCallingPoints: calls.map(c => ({ station: { crs: c.station },
        departure: c.departure ? new Date(c.departure).toISOString() : null,
        arrival: c.arrival ? new Date(c.arrival).toISOString() : null })) };
test('matches exact dated live train and rejects ambiguity, operator, day, time and calling-pattern mismatches', () => {
    assert.equal(liveScheduleIdentity(leg, [service]), service);
    assert.equal(liveScheduleIdentity(leg, [service, { ...service, id: 'other', uid: 'OTHER' }]), null);
    for (const different of [
        { ...service, operator: 'SN' },
        { ...service, uid: undefined },
        { ...service, calls: calls.map(c => ({ ...c, arrival: c.arrival && c.arrival + 86400000, departure: c.departure && c.departure + 86400000 })) },
        { ...service, calls: [calls[0], { ...calls[1], station: 'OTHER' }, calls[2]] },
        { ...service, calls: [calls[0], { ...calls[1], arrival: calls[1].arrival + 60000 }, calls[2]] }
    ]) assert.equal(liveScheduleIdentity(leg, [different]), null);
});
