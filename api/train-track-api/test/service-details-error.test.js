import test from 'node:test';
import assert from 'node:assert/strict';

import { isUnavailableServiceDetailsError } from '../lib/service-details.js';

test('expired service detail responses are treated as unavailable', () => {
    assert.equal(isUnavailableServiceDetailsError({ response: { status: 400 } }), true);
    assert.equal(isUnavailableServiceDetailsError({ response: { status: 500 } }), true);
});

test('transport and other upstream failures remain operational errors', () => {
    assert.equal(isUnavailableServiceDetailsError({ response: { status: 503 } }), false);
    assert.equal(isUnavailableServiceDetailsError({ code: 'ETIMEDOUT' }), false);
});
