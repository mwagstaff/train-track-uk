import assert from 'node:assert/strict';
import test from 'node:test';
import { createAdminUrl } from '../lib/admin-url.js';

test('admin URLs preserve an unknown proxy prefix from every page depth', () => {
    const requestPaths = [
        '/admin', '/admin/', '/admin/journey-planner', '/admin/journey-planner/',
        '/admin/devices/device%2Fone', '/admin/devices/device%2Fone/',
        '/admin/live-activity-payloads/payload%2Fone/replay',
        '/admin/live-activity-payloads/payload%2Fone/replay/',
        '/admin/test-harness/departures/service%2Fone/clear'
    ];
    const destinations = [
        '/admin', '/admin/', '/admin/devices', '/admin/journey-planner?range=7d&sort=durationMs#history',
        '/admin/devices/device%2Fone', '/admin/live-activity-payloads/payload%2Fone/replay',
        '/admin/test-harness?message=cleared', '/api/v2/notifications/debug/subscriptions'
    ];
    for (const prefix of ['', '/train-track', '/services/train-track']) {
        for (const requestPath of requestPaths) {
            const url = createAdminUrl(requestPath);
            for (const destination of destinations) {
                const actual = new URL(url(destination), `https://example.test${prefix}${requestPath}?old=1`);
                assert.equal(actual.href, `https://example.test${prefix}${destination}`, `${requestPath} → ${destination}`);
            }
        }
    }
});

test('same-directory destinations retain their exact trailing-slash semantics', () => {
    const url = createAdminUrl('/admin/devices/example');
    assert.equal(new URL(url('/admin/devices'), 'https://example.test/train-track/admin/devices/example').pathname, '/train-track/admin/devices');
    assert.equal(new URL(url('/admin/devices/'), 'https://example.test/train-track/admin/devices/example').pathname, '/train-track/admin/devices/');
});

test('query-only, fragment, relative and external destinations are left alone', () => {
    const url = createAdminUrl();
    for (const destination of ['', '?page=2', '#history', 'devices', '../admin', 'https://example.test/path', '//example.test/path', 'mailto:admin@example.test']) {
        assert.equal(url(destination), destination);
    }
});

test('encoded IDs and query values survive without being decoded or re-encoded', () => {
    const destination = '/admin/devices/device%2Fone%26two?target=%2Ftest%3Fa%3D1%26b%3D2#details';
    const url = createAdminUrl('/admin/live-activity-payloads/a%2Fb/replay?ignored=1');
    assert.equal(new URL(url(destination), 'https://example.test/train-track/admin/live-activity-payloads/a%2Fb/replay').href, `https://example.test/train-track${destination}`);
});
