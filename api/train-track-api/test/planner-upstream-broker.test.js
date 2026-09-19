import test from 'node:test';
import assert from 'node:assert/strict';
import { PlannerUpstreamBroker } from '../lib/planner/upstream-broker.js';

const turn = () => new Promise(resolve => setImmediate(resolve));
const options = (name = 'board', extra = {}) => ({ api: 'rail_departure_board', operation: 'get_board',
    url: `https://example.invalid/${name}`, headers: { 'x-apikey': 'test', accept: 'application/json' },
    timeoutMs: 3000, maxRetries: 0, ...extra });
function fixture() {
    const calls = [];
    const broker = new PlannerUpstreamBroker({ request: request => new Promise((resolve, reject) => {
        calls.push({ request, resolve, reject });
    }) });
    return { calls, broker };
}

test('broker limits physical work to two requests and coalesces equivalent queued and active options', async () => {
    const { calls, broker } = fixture();
    const a = broker.request(options('a'));
    const shared = broker.request({ maxRetries: 0, timeoutMs: 3000,
        headers: { accept: 'application/json', 'x-apikey': 'test' },
        url: 'https://example.invalid/a', operation: 'get_board', api: 'rail_departure_board' });
    const b = broker.request(options('b'));
    const c = broker.request(options('c'));
    const queued = broker.request(options('c'));
    assert.equal(calls.length, 2);
    calls[0].resolve({ data: { value: 'a' } });
    assert.deepEqual(await a, { data: { value: 'a' } });
    assert.deepEqual(await shared, { data: { value: 'a' } });
    assert.equal(calls.length, 3);
    assert.equal(calls[2].request.url, 'https://example.invalid/c');
    calls[1].resolve({ data: 'b' });
    calls[2].resolve({ data: 'c' });
    assert.deepEqual(await Promise.all([b, c, queued]), [{ data: 'b' }, { data: 'c' }, { data: 'c' }]);
    const fresh = broker.request(options('a'));
    assert.equal(calls.length, 4, 'Completed responses must remain solely in worker caches');
    calls[3].resolve({ data: 'fresh' });
    assert.deepEqual(await fresh, { data: 'fresh' });
    broker.close();
});

test('headers, retry policy, timeout and observation metadata remain distinct requests', async () => {
    const { calls, broker } = fixture();
    const requests = [options(), options('board', { headers: { 'x-apikey': 'different' } }),
        options('board', { timeoutMs: 2000 }), options('board', { maxRetries: 1 }),
        options('board', { operation: 'other_operation' })].map(value => broker.request(value));
    for (let index = 0; index < requests.length; index++) {
        assert.ok(calls[index]);
        calls[index].resolve({ data: index });
        assert.deepEqual(await requests[index], { data: index });
    }
    assert.equal(calls.length, 5);
    broker.close();
});

test('one cancelled consumer cannot abort shared work needed by another worker', async () => {
    const { calls, broker } = fixture();
    const controller = new AbortController();
    const first = broker.request(options(), { signal: controller.signal });
    const rejected = assert.rejects(first, { name: 'AbortError', code: 'ERR_CANCELED' });
    const second = broker.request(options());
    controller.abort();
    await rejected;
    assert.equal(calls[0].request.signal.aborted, false);
    calls[0].resolve({ data: 'shared' });
    assert.deepEqual(await second, { data: 'shared' });
    broker.close();
});

test('last-consumer cancellation removes queued work and holds active slots until physical settlement', async () => {
    const { calls, broker } = fixture();
    const activeController = new AbortController(), queuedController = new AbortController();
    const a = broker.request(options('a'), { signal: activeController.signal });
    const aRejected = assert.rejects(a, { code: 'ERR_CANCELED' });
    const b = broker.request(options('b'));
    const c = broker.request(options('c'), { signal: queuedController.signal });
    const cRejected = assert.rejects(c, { code: 'ERR_CANCELED' });
    const d = broker.request(options('d'));
    queuedController.abort();
    activeController.abort();
    await Promise.all([aRejected, cRejected]);
    assert.equal(calls[0].request.signal.aborted, true);
    assert.equal(calls.length, 2, 'Aborting must not temporarily increase physical concurrency');
    const retry = broker.request(options('a'));
    calls[0].reject(Object.assign(new Error('Transport aborted'), { code: 'ERR_CANCELED' }));
    await turn();
    assert.equal(calls.length, 3);
    assert.equal(calls[2].request.url, 'https://example.invalid/d');
    calls[1].resolve({ data: 'b' });
    assert.deepEqual(await b, { data: 'b' });
    assert.equal(calls[3].request.url, 'https://example.invalid/a');
    calls[2].resolve({ data: 'd' });
    calls[3].resolve({ data: 'retry' });
    assert.deepEqual(await Promise.all([d, retry]), [{ data: 'd' }, { data: 'retry' }]);
    broker.close();
});

test('upstream errors fan out unchanged, release capacity and permit fresh retries', async () => {
    const { calls, broker } = fixture();
    const first = broker.request(options()), second = broker.request(options());
    const error = Object.assign(new Error('Unavailable'), { code: 'UPSTREAM', response: { status: 429 } });
    const rejected = [first, second].map(promise => assert.rejects(promise, value => value === error));
    calls[0].reject(error);
    await Promise.all(rejected);
    const retry = broker.request(options());
    assert.equal(calls.length, 2);
    calls[1].resolve({ data: 'retry' });
    assert.deepEqual(await retry, { data: 'retry' });
    broker.close();
    const synchronous = new PlannerUpstreamBroker({ request: () => { throw error; } });
    await assert.rejects(synchronous.request(options()), value => value === error);
    assert.equal(synchronous.active.size, 0);
    synchronous.close();
});

test('close rejects every active and queued consumer, aborts transport and rejects future requests', async () => {
    const { calls, broker } = fixture();
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(broker.request(options(), { signal: controller.signal }), { code: 'ERR_CANCELED' });
    assert.equal(calls.length, 0);
    const waiting = ['a', 'a', 'b', 'c'].map(name => broker.request(options(name)));
    const rejected = waiting.map(promise => assert.rejects(promise, { code: 'ERR_CANCELED' }));
    broker.close();
    broker.close();
    await Promise.all(rejected);
    assert.equal(calls.length, 2);
    assert.equal(calls.every(call => call.request.signal.aborted), true);
    assert.equal(broker.inflight.size, 0);
    assert.equal(broker.queue.length, 0);
    await assert.rejects(broker.request(options()), { code: 'ERR_CANCELED' });
    for (const call of calls) call.resolve({ data: 'late' });
    await turn();
    assert.equal(calls.length, 2);
    assert.equal(broker.active.size, 0);
});
