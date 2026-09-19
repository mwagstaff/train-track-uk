import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { registerDisruptionRoutes } from '../lib/disruptions/routes.js';
import { MonitorError, normalizeMonitors, deviceIdentifier } from '../lib/disruptions/model.js';

async function server(t, monitor) {
    const app = express(); registerDisruptionRoutes(app, monitor);
    // The monitor's parser must precede the legacy parser, as in index.js.
    app.use(express.json({ limit: '1mb' }));
    const handle = app.listen(0, '127.0.0.1');
    await new Promise(resolve => handle.once('listening', resolve));
    t.after(() => { handle.closeAllConnections(); handle.close(); });
    return `http://127.0.0.1:${handle.address().port}/api/v2/disruptions`;
}

test('registration works without a push token and reads never start searches', async t => {
    let stored;
    const base = await server(t, {
        async synchronize(body) { stored = normalizeMonitors(body); return { mode: 'shadow', horizonDays: 7, monitors: stored.monitors, advisories: [] }; },
        async get(device) { assert.equal(deviceIdentifier(device), stored.deviceId); return { monitors: stored.monitors }; }
    });
    const response = await fetch(`${base}/monitors`, { method: 'PUT', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ device_id: 'test-device', monitors: [{ id: 'route', stations: ['KTH', 'VIC'] }] }) });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(stored.pushToken, undefined);
    assert.equal((await (await fetch(`${base}?device_id=test-device`)).json()).monitors.length, 1);
});

test('malformed input is bounded and provider errors do not leak internal data', async t => {
    const base = await server(t, { async synchronize() { throw new Error('secret provider credential'); },
        async get(device) { deviceIdentifier(device); throw new MonitorError('Monitoring stopped.', 410, 'DEVICE_DELETED'); } });
    assert.equal((await fetch(`${base}/monitors`, { method: 'PUT', body: 'text' })).status, 415);
    assert.equal((await fetch(`${base}/monitors`, { method: 'PUT', headers: { 'content-type': 'application/json' }, body: '{' })).status, 400);
    assert.equal((await fetch(`${base}/monitors`, { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ huge: 'x'.repeat(66000) }) })).status, 413);
    const failure = await fetch(`${base}/monitors`, { method: 'PUT', headers: { 'content-type': 'application/json' }, body: '{}' });
    assert.equal(failure.status, 503); assert.equal((await failure.text()).includes('credential'), false);
    assert.equal((await fetch(base)).status, 400);
    assert.equal((await fetch(`${base}?device_id=deleted`)).status, 410);
});
