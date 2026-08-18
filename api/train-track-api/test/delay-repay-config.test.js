import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { resolveDelayRepayOperator } from '../lib/delay-repay-config.js';

test('server config covers every current National Rail passenger brand', () => {
    const config = JSON.parse(fs.readFileSync(
        new URL('../resources/delay-repay-operators.json', import.meta.url),
        'utf8'
    ));
    assert.equal(config.operators.length, 29);
    assert.equal(new Set(config.operators.map((operator) => operator.name)).size, 29);
    assert.ok(config.operators.every((operator) => operator.claim_url.startsWith('https://')));
});

test('resolves a Delay Repay operator by code', () => {
    const result = resolveDelayRepayOperator({ operatorCode: 'SE' });
    assert.equal(result?.name, 'Southeastern');
    assert.equal(result?.claim_url, 'https://delayrepay.southeasternrailway.co.uk/');
});

test('prefers the operator name when a code is shared by multiple brands', () => {
    const result = resolveDelayRepayOperator({
        operatorCode: 'LM',
        operatorName: 'West Midlands Railway'
    });
    assert.equal(result?.name, 'West Midlands Railway');
});

test('resolves operator aliases regardless of punctuation and case', () => {
    const result = resolveDelayRepayOperator({ operatorName: 'TfW Rail' });
    assert.equal(result?.name, 'Transport for Wales');
});

test('returns null for an unknown operator', () => {
    assert.equal(resolveDelayRepayOperator({ operatorName: 'Unknown Rail' }), null);
});
