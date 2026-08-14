import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';

import { getWithRetry } from '../lib/upstream-api-client.js';

async function startServer(handler) {
    const server = http.createServer(handler);
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    return {
        server,
        url: `http://127.0.0.1:${address.port}`
    };
}

async function stopServer(server) {
    await new Promise((resolve, reject) => {
        server.close((error) => error ? reject(error) : resolve());
    });
}

test('a request can disable retries for a fail-fast endpoint', async () => {
    let requestCount = 0;
    const { server, url } = await startServer((_req, res) => {
        requestCount += 1;
        res.writeHead(500).end();
    });

    try {
        await assert.rejects(getWithRetry({
            api: 'test',
            operation: 'fail_fast',
            url,
            maxRetries: 0,
            timeoutMs: 1000
        }));
        assert.equal(requestCount, 1);
    } finally {
        await stopServer(server);
    }
});

test('a request can use a shorter timeout than the shared client default', async () => {
    const { server, url } = await startServer(() => {});
    const startedAt = Date.now();

    try {
        await assert.rejects(getWithRetry({
            api: 'test',
            operation: 'short_timeout',
            url,
            maxRetries: 0,
            timeoutMs: 50
        }), (error) => error?.code === 'ECONNABORTED');
        assert.ok(Date.now() - startedAt < 1000);
    } finally {
        await stopServer(server);
    }
});
