import test from 'node:test';
import assert from 'node:assert/strict';
import { parseFixedLink } from '../lib/planner/parser.js';
import { createConnectionIndex, resolveConnection, validateFixedLink, CONNECTION_POLICY } from '../lib/planner/connections.js';
import { findJourneys, validateJourney } from '../lib/planner/router.js';

const MINUTE = 60_000;
const instant = value => Date.parse(`2026-09-15T${value}:00+01:00`);
const iso = value => new Date(value).toISOString();

// Independently transcribed RJTTF939ALF rows. Raw O/D order is retained by import.
const tube = () => parseFixedLink('M=TUBE,O=EUS,D=VIC,T=14,S=1901,E=2359,P=4,R=1111110', { member: 'ALF', line: 1295 });
const walk = () => parseFixedLink('M=WALK,O=KGX,D=STP,T=1,S=0001,E=2359,P=4,R=1111110', { member: 'ALF', line: 1601 });
function network(links, services = [], allowances = {}) {
    const codes = new Set([...links.flatMap(link => [link.origin, link.destination]),
        ...services.flatMap(service => service.calls.map(call => call.station))]);
    return { services, rules: { links, tsi: [] },
        stations: new Map([...codes].map(crs => [crs, { crs, name: crs, minimumChangeMinutes: allowances[crs] ?? 15 }])) };
}

test('source ALF pairs create both index orientations with one unchanged source identity', () => {
    const rule = tube();
    Object.freeze(rule.sourceRef);
    Object.freeze(rule);
    const index = createConnectionIndex(network([rule]));
    const forward = index.pairs.get('EUS|VIC')[0];
    const reverse = index.pairs.get('VIC|EUS')[0];
    assert.equal(forward, rule);
    assert.deepEqual(reverse, { ...rule, origin: 'VIC', destination: 'EUS' });
    assert.equal(reverse.id, 'ALF:1295');
    assert.equal(reverse.sourceRef, rule.sourceRef);
    assert.deepEqual([...index.outgoing.get('VIC')], ['EUS']);
    assert.deepEqual([...index.incoming.get('EUS')], ['VIC']);
    assert.equal(rule.origin, 'EUS');
    assert.equal(rule.destination, 'VIC');

    // A source-like id alone does not assign ALF semantics to another provider.
    for (const sourceRef of [undefined, { member: 'OTHER', line: 1295 }]) {
        const directed = createConnectionIndex(network([{ ...rule, sourceRef }]));
        assert.equal(directed.pairs.has('VIC|EUS'), false);
        assert.equal(resolveConnection(directed, { from: 'VIC', to: 'EUS', arrival: instant('20:00') }), null);
    }
});

test('reverse ALF traversal uses reversed endpoint allowances, one buffer, and exact timing', () => {
    const index = createConnectionIndex(network([walk()], [], { KGX: 7, STP: 3 }));
    const arrival = instant('20:00');
    const ready = arrival + 13 * MINUTE; // STP 3 + walk 1 + KGX 7 + extra 2.
    const connection = resolveConnection(index, { from: 'STP', to: 'KGX', arrival, departure: ready, extraConnectionMinutes: 2 });
    assert.equal(connection.ruleId, 'ALF:1601');
    assert.equal(connection.policy, CONNECTION_POLICY);
    assert.equal(connection.minutes, 13);
    assert.deepEqual(connection.breakdown, { exitMinutes: 3, travelMinutes: 1, entryMinutes: 7, extraMinutes: 2, waitingMinutes: 0 });
    assert.equal(connection.movementStart, arrival + 3 * MINUTE);
    assert.equal(connection.movementEnd, arrival + 4 * MINUTE);
    assert.equal(validateFixedLink(index, connection, 2), true);
    assert.equal(validateFixedLink(index, { ...connection, end: ready - 1 }, 2), false);
    assert.equal(resolveConnection(index, { from: 'STP', to: 'KGX', arrival, departure: ready - 1, extraConnectionMinutes: 2 }), null);
    const backwards = resolveConnection(index, { from: 'STP', to: 'KGX', arrival, departure: ready, extraConnectionMinutes: 2, direction: 'latest' });
    assert.equal(backwards.start, arrival);
    assert.equal(validateFixedLink(index, backwards, 2), true);
});

test('ALF reverse entries retain priority, mode permission, calendar and full traversal boundaries', () => {
    const rule = { ...walk(), startTime: '2000', endTime: '2010', startDate: '2026-09-15', endDate: '2026-09-15' };
    const index = createConnectionIndex(network([rule], [], { KGX: 0, STP: 0 }));
    const connect = (arrival, extra = {}) => resolveConnection(index, { from: 'STP', to: 'KGX', arrival, ...extra });
    assert.equal(connect(instant('20:09')).end, instant('20:10'));
    assert.equal(connect(instant('20:09') + 1), null);
    assert.equal(connect(Date.parse('2026-09-16T20:00:00+01:00')), null);
    assert.equal(connect(instant('20:00'), { allowedModes: ['rail'] }), null);
    const sunday = createConnectionIndex(network([{ ...rule, days: '0000001' }], [], { KGX: 0, STP: 0 }));
    assert.equal(resolveConnection(sunday, { from: 'STP', to: 'KGX', arrival: instant('20:00') }), null);

    const high = { ...rule, id: 'ALF:2', minutes: 2, priority: 5, sourceRef: { member: 'ALF', line: 2 } };
    const priority = createConnectionIndex(network([rule, high], [], { KGX: 0, STP: 0 }));
    const selected = resolveConnection(priority, { from: 'STP', to: 'KGX', arrival: instant('20:00') });
    assert.equal(selected.ruleId, 'ALF:2');
    assert.equal(selected.minutes, 2);
    assert.equal(validateFixedLink(priority, selected), true);
    const unavailableMode = createConnectionIndex(network([rule, { ...high, mode: 'tubeTransfer' }], [], { KGX: 0, STP: 0 }));
    assert.equal(resolveConnection(unavailableMode, { from: 'STP', to: 'KGX', arrival: instant('20:00'), allowedModes: ['walk'] }), null);
    const conflict = createConnectionIndex(network([high, { ...high, id: 'ALF:3', minutes: 3 }], [], { KGX: 0, STP: 0 }));
    assert.equal(resolveConnection(conflict, { from: 'STP', to: 'KGX', arrival: instant('20:00') }), null);
});

test('ALF pair interpretation does not reverse ordered TOC interchange rules', () => {
    const net = network([walk()]);
    net.rules.tsi.push({ id: 'TSI:1', station: 'KGX', arrivingOperator: 'AA', departingOperator: 'BB', minutes: 3 });
    const index = createConnectionIndex(net);
    const connection = operators => resolveConnection(index, { from: 'KGX', to: 'KGX', arrival: instant('20:00'), ...operators });
    assert.equal(connection({ arrivingOperator: 'AA', departingOperator: 'BB' }).minutes, 3);
    assert.equal(connection({ arrivingOperator: 'BB', departingOperator: 'AA' }).minutes, 15);
});

function train(id, from, to, departure, arrival) {
    return { id, uid: id, variantId: id, source: 'MCA', originDate: '2026-09-15', mode: 'rail', operator: 'OP',
        calls: [
            { station: from, sequence: 0, departure, arrival: null, canBoard: true, canAlight: false },
            { station: to, sequence: 1, departure: null, arrival, canBoard: false, canAlight: true }
        ] };
}

test('forward and arrive-by journeys reconstruct and validate a reverse-oriented ALF transfer', () => {
    const net = network([tube()], [
        train('feeder', 'AAA', 'VIC', instant('20:00'), instant('20:10')),
        train('onward', 'EUS', 'DDD', instant('20:54'), instant('21:30'))
    ]);
    for (const timeType of ['departAfter', 'arriveBy']) {
        const request = { origin: 'AAA', destination: 'DDD', timeType,
            time: iso(instant(timeType === 'departAfter' ? '20:00' : '21:30')),
            maxChanges: 2, windowMinutes: 120, limit: 5 };
        const result = findJourneys(request, net);
        assert.equal(result.journeys.length, 1);
        const journey = result.journeys[0];
        assert.equal(journey.changes, 2);
        assert.equal(journey.legs[1].from.crs, 'VIC');
        assert.equal(journey.legs[1].to.crs, 'EUS');
        assert.equal(journey.legs[1].ruleId, 'ALF:1295');
        assert.equal(journey.legs[1].minutes, 44);
        assert.equal(validateJourney(journey, net, request), true);
        assert.equal(findJourneys({ ...request, extraConnectionMinutes: 1 }, net).journeys.length, 0);
        assert.equal(findJourneys({ ...request, allowedModes: ['rail', 'walk'] }, net).journeys.length, 0);
        assert.equal(findJourneys({ ...request, maxChanges: 1 }, net).journeys.length, 0);
    }
});
