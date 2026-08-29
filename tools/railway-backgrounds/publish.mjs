#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseUnsplashImageFilename } from './lib/unsplash-filename.mjs';

const toolRoot = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(toolRoot, '..', '..');
const sourcesRoot = path.join(repositoryRoot, 'resources', 'background_images');
const publishedRoot = path.join(toolRoot, 'published');
const assetsRoot = path.join(publishedRoot, 'assets');
const maximumPixelDimension = 2_560;
const webPQuality = 72;
const maximumAssetBytes = 1_000_000;

function fail(message) {
    throw new Error(`[railway-backgrounds] ${message}`);
}

function sha256(data) {
    return createHash('sha256').update(data).digest('hex');
}

function assetID(photoID) {
    const suffix = photoID.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
    if (!suffix) fail(`could not create an asset ID for Unsplash photo ${photoID}`);
    return `unsplash-${suffix}`;
}

function sourceAssets() {
    if (!fs.statSync(sourcesRoot, { throwIfNoEntry: false })?.isDirectory()) {
        fail(`source directory not found: ${sourcesRoot}`);
    }
    const assets = [];
    const photoIDs = new Set();
    const assetIDs = new Set();
    for (const entry of fs.readdirSync(sourcesRoot, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
        if (!entry.isFile()) continue;
        if (entry.name === '.DS_Store') continue;
        const attribution = parseUnsplashImageFilename(entry.name);
        if (!attribution) {
            fail(`source file does not follow <artist>-<11-character-photo-id>-unsplash naming: ${entry.name}`);
        }
        if (photoIDs.has(attribution.photoID)) fail(`duplicate Unsplash photo ID: ${attribution.photoID}`);
        const id = assetID(attribution.photoID);
        if (assetIDs.has(id)) fail(`duplicate generated asset ID: ${id}`);
        photoIDs.add(attribution.photoID);
        assetIDs.add(id);
        assets.push({
            id,
            input: path.join(sourcesRoot, entry.name),
            sourceFilename: entry.name,
            ...attribution,
        });
    }
    if (assets.length < 2) fail('at least two convention-compliant Unsplash images are required');
    return assets;
}

function optimiseAsset(source) {
    const temporary = path.join(assetsRoot, `.${source.id}.tmp.webp`);
    execFileSync('magick', [
        source.input,
        '-auto-orient',
        '-strip',
        '-colorspace', 'sRGB',
        '-resize', `${maximumPixelDimension}x${maximumPixelDimension}>`,
        '-define', 'webp:method=6',
        '-define', 'webp:use-sharp-yuv=1',
        '-quality', String(webPQuality),
        temporary,
    ], { stdio: 'inherit' });

    const data = fs.readFileSync(temporary);
    if (data.length > maximumAssetBytes) {
        fs.rmSync(temporary);
        fail(`optimised asset ${source.sourceFilename} exceeds ${Math.round(maximumAssetBytes / 1_000)} KB`);
    }
    const hash = sha256(data);
    const filename = `${hash}.webp`;
    const destination = path.join(assetsRoot, filename);
    if (!fs.existsSync(destination)) fs.renameSync(temporary, destination);
    else fs.rmSync(temporary);

    const dimensions = execFileSync('magick', ['identify', '-format', '%w %h', destination], { encoding: 'utf8' })
        .trim().split(/\s+/).map(Number);
    if (dimensions.length !== 2 || dimensions.some((value) => !Number.isInteger(value) || value < 2)) {
        fail(`could not determine dimensions for ${source.sourceFilename}`);
    }

    return {
        id: source.id,
        title: `Railway photograph by ${source.artistName}`,
        location: 'Unsplash',
        caption: null,
        focal_point: { x: 0.5, y: 0.5 },
        scrim_opacity: 0.3,
        delivery: 'server',
        provider_asset_id: source.photoID,
        source_filename: source.sourceFilename,
        sha256: hash,
        asset_path: `assets/${filename}`,
        asset_url: `/api/v2/railway-backgrounds/assets/${hash}.webp`,
        content_type: 'image/webp',
        byte_size: data.length,
        width: dimensions[0],
        height: dimensions[1],
        credit: {
            photographer: source.artistName,
            photographer_url: null,
            source: 'Unsplash',
            source_page: source.sourceURL,
            license: 'Unsplash License',
            license_url: 'https://unsplash.com/license',
        },
    };
}

fs.mkdirSync(assetsRoot, { recursive: true });
const assets = sourceAssets().map(optimiseAsset);
const activeAssetFiles = new Set(assets.map((asset) => path.basename(asset.asset_path)));
for (const filename of fs.readdirSync(assetsRoot)) {
    if (filename.endsWith('.webp') && !activeAssetFiles.has(filename)) {
        fs.rmSync(path.join(assetsRoot, filename));
    }
}

const versionedContent = {
    schema_version: 1,
    rotation: {
        time_zone: 'Europe/London',
        epoch_date: '2026-01-01',
        asset_ids: assets.map((asset) => asset.id),
    },
    assets,
};
const catalog = {
    ...versionedContent,
    catalog_version: sha256(JSON.stringify(versionedContent)),
    generated_at: new Date().toISOString(),
};
fs.mkdirSync(publishedRoot, { recursive: true });
fs.writeFileSync(path.join(publishedRoot, 'catalog.json'), `${JSON.stringify(catalog, null, 2)}\n`);

const totalBytes = assets.reduce((total, asset) => total + asset.byte_size, 0);
const largestBytes = Math.max(...assets.map((asset) => asset.byte_size));
console.log(
    `[railway-backgrounds] Published ${assets.length} filename-derived Unsplash assets `
    + `(${Math.round(totalBytes / 1024)} KB total, ${Math.round(largestBytes / 1024)} KB largest)`
);
