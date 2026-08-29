import assert from 'node:assert/strict';
import test from 'node:test';
import { parseUnsplashImageFilename } from '../lib/unsplash-filename.mjs';

test('extracts the artist and Unsplash photo ID from a conventional filename', () => {
    assert.deepEqual(
        parseUnsplashImageFilename('diane-picchiottino-sKsNVoa_NsY-unsplash.jpg'),
        {
            artistName: 'Diane Picchiottino',
            photoID: 'sKsNVoa_NsY',
            sourceURL: 'https://unsplash.com/photos/sKsNVoa_NsY',
        }
    );
});

test('supports an Unsplash ID beginning with a hyphen', () => {
    assert.deepEqual(
        parseUnsplashImageFilename('connor-herrington--nHoxqLW6js-unsplash.jpg'),
        {
            artistName: 'Connor Herrington',
            photoID: '-nHoxqLW6js',
            sourceURL: 'https://unsplash.com/photos/-nHoxqLW6js',
        }
    );
});

test('rejects non-Unsplash and malformed filenames', () => {
    assert.equal(parseUnsplashImageFilename('station-golden-hour.png'), null);
    assert.equal(parseUnsplashImageFilename('diane-picchiottino-short-unsplash.jpg'), null);
    assert.equal(parseUnsplashImageFilename('diane_picchiottino-sKsNVoa_NsY-unsplash.jpg'), null);
    assert.equal(parseUnsplashImageFilename('diane-picchiottino-sKsNVoa_NsY-unsplash.txt'), null);
});
