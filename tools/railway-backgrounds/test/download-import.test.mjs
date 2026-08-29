import assert from 'node:assert/strict';
import test from 'node:test';

import {
    isAffirmativeResponse,
    planDownloadsImport,
} from '../lib/download-import.mjs';

test('plans only strictly named Unsplash image files', () => {
    const plan = planDownloadsImport([
        'notes.txt',
        'holiday.jpg',
        'diane-picchiottino-sKsNVoa_NsY-unsplash.jpg',
        'umair-dingmar-lGHtVlyiv5I-unsplash (1).jpg',
    ], []);

    assert.deepEqual(plan.candidates, [{
        filename: 'diane-picchiottino-sKsNVoa_NsY-unsplash.jpg',
        photoID: 'sKsNVoa_NsY',
    }]);
    assert.deepEqual(plan.skipped, [{
        filename: 'umair-dingmar-lGHtVlyiv5I-unsplash (1).jpg',
        reason: 'filename does not match the required format',
    }]);
});

test('does not overwrite an existing filename', () => {
    const filename = 'diane-picchiottino-sKsNVoa_NsY-unsplash.jpg';
    const plan = planDownloadsImport([filename], [filename]);

    assert.equal(plan.candidates.length, 0);
    assert.match(plan.skipped[0].reason, /already exists/);
});

test('does not import a photo ID already present under another filename', () => {
    const plan = planDownloadsImport(
        ['new-name-sKsNVoa_NsY-unsplash.png'],
        ['original-name-sKsNVoa_NsY-unsplash.jpg'],
    );

    assert.equal(plan.candidates.length, 0);
    assert.match(plan.skipped[0].reason, /photo ID sKsNVoa_NsY is already used/);
});

test('imports only the first of multiple downloads with the same photo ID', () => {
    const plan = planDownloadsImport([
        'zeta-name-sKsNVoa_NsY-unsplash.png',
        'alpha-name-sKsNVoa_NsY-unsplash.jpg',
    ], []);

    assert.deepEqual(plan.candidates.map((item) => item.filename), [
        'alpha-name-sKsNVoa_NsY-unsplash.jpg',
    ]);
    assert.match(plan.skipped[0].reason, /already used by alpha-name/);
});

test('accepts only explicit yes confirmation', () => {
    assert.equal(isAffirmativeResponse('y'), true);
    assert.equal(isAffirmativeResponse(' YES '), true);
    assert.equal(isAffirmativeResponse(''), false);
    assert.equal(isAffirmativeResponse('no'), false);
});
