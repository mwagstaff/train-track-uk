import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { metricsMiddleware, getMetrics } from '../lib/metrics.js';

test('HTTP metrics support route arrays and regular expressions without breaking responses', async t => {
    const app = express();
    app.use(metricsMiddleware);
    const aliases = ['/api/v1/departures/from/:fromStation', '/api/v2/departures/from/:fromStation'];
    app.get(aliases, (_req, res) => res.json({ departures: [] }));
    app.get(/^\/regex\/[^/]+$/, (_req, res) => res.json({ ok: true }));
    app.get('/api/v2/plain/:id', (_req, res) => res.json({ ok: true }));
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => {
        server.closeAllConnections();
        server.close(resolve);
    }));
    const base = `http://127.0.0.1:${server.address().port}`;
    for (const path of ['/api/v1/departures/from/KTH', '/api/v2/departures/from/KTH', '/regex/example', '/api/v2/plain/example']) {
        const response = await fetch(`${base}${path}`, { signal: AbortSignal.timeout(3000) });
        assert.equal(response.status, 200, path);
        await response.json();
    }
    const metrics = await getMetrics();
    const requests = metrics.split('\n').filter(line => line.startsWith('http_requests_total{'));
    for (const version of ['v1', 'v2']) {
        assert.ok(requests.some(line => line.includes(`path="${aliases.join('|')}"`)
            && line.includes(`api_version="${version}"`)), `${version} alias is counted correctly`);
    }
    assert.ok(requests.some(line => line.includes('path="/api/v2/plain/:id"')));
    assert.ok(requests.every(line => !line.includes('KTH') && !line.includes('example')));
});
