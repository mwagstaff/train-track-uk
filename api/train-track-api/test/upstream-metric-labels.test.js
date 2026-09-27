import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeUpstreamUrl } from '../lib/upstream-metric-labels.js';

test('upstream metric labels remain bounded across stations, times and service IDs', () => {
    const labels = new Set();
    for (let i = 0; i < 10000; i++) {
        for (const operation of ['GetDepartureBoard', 'GetDepBoardWithDetails', 'GetServiceDetails']) {
            labels.add(normalizeUpstreamUrl(`https://example.com/api/20220120/${operation}/${i}?filterCRS=${i}&services=${i}&time=${i}&token=secret`));
        }
    }
    assert.deepEqual([...labels].sort(), [
        '/GetDepBoardWithDetails/:station', '/GetDepartureBoard/:station', '/GetServiceDetails/:serviceId'
    ].sort());
});

test('unrecognized or malformed URLs never leak into metric labels', () => {
    assert.equal(normalizeUpstreamUrl('https://example.com/variable-id?token=secret'), 'other');
    assert.equal(normalizeUpstreamUrl('secret-invalid-url'), 'unknown');
    assert.equal(normalizeUpstreamUrl(undefined), 'unknown');
});
