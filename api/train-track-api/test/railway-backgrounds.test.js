import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import express from 'express';
import {
    RailwayBackgroundCatalogError,
    createRailwayBackgroundCatalogLoader,
    registerRailwayBackgroundRoutes,
    validateRailwayBackgroundCatalog
} from '../lib/railway-backgrounds.js';

function fixture() {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'railway-backgrounds-'));
    const assetsDirectory = path.join(root, 'assets');
    fs.mkdirSync(assetsDirectory);
    const assets = [
        { id: 'first', photoID: 'first-id001' },
        { id: 'second', photoID: 'second-id01' }
    ].map(({ id, photoID }) => {
        const bytes = Buffer.from(`webp-${id}`);
        const hash = crypto.createHash('sha256').update(bytes).digest('hex');
        fs.writeFileSync(path.join(assetsDirectory, `${hash}.webp`), bytes);
        return {
            id,
            title: id,
            location: 'Test station',
            caption: null,
            focal_point: { x: 0.5, y: 0.5 },
            scrim_opacity: 0.3,
            delivery: 'server',
            provider_asset_id: photoID,
            source_filename: `alex-example-${photoID}-unsplash.jpg`,
            sha256: hash,
            asset_path: `assets/${hash}.webp`,
            asset_url: `/api/v2/railway-backgrounds/assets/${hash}.webp`,
            content_type: 'image/webp',
            byte_size: bytes.length,
            width: 640,
            height: 480,
            credit: {
                photographer: 'Alex Example',
                source: 'Unsplash',
                source_page: `https://unsplash.com/photos/${photoID}`,
                license: 'Unsplash License',
                license_url: 'https://unsplash.com/license'
            }
        };
    });
    const catalog = {
        schema_version: 1,
        catalog_version: 'a'.repeat(64),
        generated_at: '2026-08-27T00:00:00Z',
        rotation: {
            time_zone: 'Europe/London',
            epoch_date: '2026-01-01',
            asset_ids: assets.map((asset) => asset.id)
        },
        assets
    };
    fs.writeFileSync(path.join(root, 'catalog.json'), `${JSON.stringify(catalog)}\n`);
    return { root, catalog, assets };
}

async function withServer(root, body, options = {}) {
    const app = express();
    registerRailwayBackgroundRoutes(app, { rootDirectory: root, ...options });
    const server = http.createServer(app);
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    try {
        return await body(`http://127.0.0.1:${server.address().port}`);
    } finally {
        await new Promise((resolve) => server.close(resolve));
    }
}

test('catalog supports conditional requests and immutable assets', async () => {
    const item = fixture();
    try {
        await withServer(item.root, async (origin) => {
            const response = await fetch(`${origin}/api/v2/railway-backgrounds/catalog`);
            assert.equal(response.status, 200);
            assert.equal(response.headers.get('etag'), `"${item.catalog.catalog_version}"`);
            const payload = await response.json();
            assert.equal(payload.assets[0].asset_url, `/api/v2/railway-backgrounds/assets/${item.assets[0].sha256}.webp`);

            const notModified = await fetch(`${origin}/api/v2/railway-backgrounds/catalog`, {
                headers: { 'If-None-Match': `"${item.catalog.catalog_version}"` }
            });
            assert.equal(notModified.status, 304);

            const asset = await fetch(`${origin}${payload.assets[0].asset_url}`);
            assert.equal(asset.status, 200);
            assert.equal(asset.headers.get('cache-control'), 'public, max-age=31536000, immutable');
        });
    } finally {
        fs.rmSync(item.root, { recursive: true, force: true });
    }
});

test('asset route rejects invalid and missing hashes', async () => {
    const item = fixture();
    try {
        const unlistedBytes = Buffer.from('unlisted-webp');
        const unlistedHash = crypto.createHash('sha256').update(unlistedBytes).digest('hex');
        fs.writeFileSync(path.join(item.root, 'assets', `${unlistedHash}.webp`), unlistedBytes);
        await withServer(item.root, async (origin) => {
            assert.equal((await fetch(`${origin}/api/v2/railway-backgrounds/assets/nope.webp`)).status, 400);
            assert.equal((await fetch(`${origin}/api/v2/railway-backgrounds/assets/${'b'.repeat(64)}.webp`)).status, 404);
            assert.equal((await fetch(`${origin}/api/v2/railway-backgrounds/assets/${unlistedHash}.webp`)).status, 404);
        });
    } finally {
        fs.rmSync(item.root, { recursive: true, force: true });
    }
});

test('loader keeps the last valid catalog after an invalid replacement', () => {
    const item = fixture();
    try {
        const loader = createRailwayBackgroundCatalogLoader(item.root);
        const first = loader.load();
        fs.writeFileSync(path.join(item.root, 'catalog.json'), '{invalid');
        assert.equal(loader.load().value.catalog_version, first.value.catalog_version);
    } finally {
        fs.rmSync(item.root, { recursive: true, force: true });
    }
});

test('validation rejects incomplete rotation pools', () => {
    const item = fixture();
    try {
        item.catalog.rotation.asset_ids = [item.assets[0].id];
        assert.throws(
            () => validateRailwayBackgroundCatalog(item.catalog, item.root),
            RailwayBackgroundCatalogError
        );
    } finally {
        fs.rmSync(item.root, { recursive: true, force: true });
    }
});

test('validation rejects non-Unsplash and hotlinked catalogue assets', () => {
    const item = fixture();
    try {
        item.catalog.assets[0].credit.source = 'Other';
        assert.throws(
            () => validateRailwayBackgroundCatalog(item.catalog, item.root),
            RailwayBackgroundCatalogError
        );

        item.catalog.assets[0].credit.source = 'Unsplash';
        item.catalog.assets[0].delivery = 'unsplash_hotlink';
        assert.throws(
            () => validateRailwayBackgroundCatalog(item.catalog, item.root),
            RailwayBackgroundCatalogError
        );
    } finally {
        fs.rmSync(item.root, { recursive: true, force: true });
    }
});
