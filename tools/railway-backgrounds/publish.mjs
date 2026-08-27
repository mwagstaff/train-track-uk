#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const toolRoot = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(toolRoot, '..', '..');
const sourcePath = path.join(toolRoot, 'catalog-source.json');
const publishedRoot = path.join(toolRoot, 'published');
const assetsRoot = path.join(publishedRoot, 'assets');
const assetIDPattern = /^[a-z0-9][a-z0-9-]{1,79}$/;

function fail(message) {
    throw new Error(`[railway-backgrounds] ${message}`);
}

function sha256(data) {
    return createHash('sha256').update(data).digest('hex');
}

function validateSource(source) {
    if (source?.schema_version !== 1 || !Array.isArray(source.assets) || source.assets.length < 2) {
        fail('catalog-source.json must contain schema_version 1 and at least two assets');
    }
    if (source.rotation?.time_zone !== 'Europe/London' || !/^\d{4}-\d{2}-\d{2}$/.test(source.rotation?.epoch_date || '')) {
        fail('rotation must use Europe/London and a YYYY-MM-DD epoch_date');
    }
    const ids = new Set();
    for (const asset of source.assets) {
        if (!assetIDPattern.test(asset.id || '')) fail(`invalid asset id: ${asset.id || '<empty>'}`);
        if (ids.has(asset.id)) fail(`duplicate asset id: ${asset.id}`);
        ids.add(asset.id);
        for (const field of ['file', 'title', 'location']) {
            if (!String(asset[field] || '').trim()) fail(`asset ${asset.id} is missing ${field}`);
        }
        const focal = asset.focal_point;
        if (!focal || ![focal.x, focal.y].every((value) => Number.isFinite(value) && value >= 0 && value <= 1)) {
            fail(`asset ${asset.id} has an invalid focal_point`);
        }
        if (!Number.isFinite(asset.scrim_opacity) || asset.scrim_opacity < 0.15 || asset.scrim_opacity > 0.65) {
            fail(`asset ${asset.id} has an invalid scrim_opacity`);
        }
    }
}

function optimiseAsset(asset) {
    const input = path.resolve(toolRoot, asset.file);
    if (!fs.statSync(input, { throwIfNoEntry: false })?.isFile()) fail(`missing source image: ${asset.file}`);

    const temporary = path.join(assetsRoot, `.${asset.id}.tmp.webp`);
    execFileSync('magick', [
        input,
        '-auto-orient',
        '-strip',
        '-colorspace', 'sRGB',
        '-resize', '2400x2400>',
        '-define', 'webp:method=6',
        '-quality', '78',
        temporary,
    ], { stdio: 'inherit' });

    const data = fs.readFileSync(temporary);
    const hash = sha256(data);
    const filename = `${hash}.webp`;
    const destination = path.join(assetsRoot, filename);
    if (!fs.existsSync(destination)) fs.renameSync(temporary, destination);
    else fs.rmSync(temporary);

    const dimensions = execFileSync('magick', ['identify', '-format', '%w %h', destination], { encoding: 'utf8' })
        .trim().split(/\s+/).map(Number);
    if (dimensions.length !== 2 || dimensions.some((value) => !Number.isInteger(value) || value < 2)) {
        fail(`could not determine dimensions for ${asset.id}`);
    }
    if (data.length > 1_500_000) fail(`optimised asset ${asset.id} exceeds 1.5 MB`);

    return {
        id: asset.id,
        title: asset.title,
        location: asset.location,
        caption: asset.caption || null,
        focal_point: asset.focal_point,
        scrim_opacity: asset.scrim_opacity,
        sha256: hash,
        asset_path: `assets/${filename}`,
        content_type: 'image/webp',
        byte_size: data.length,
        width: dimensions[0],
        height: dimensions[1],
        credit: {
            photographer: asset.credit?.photographer || null,
            photographer_url: asset.credit?.photographer_url || null,
            source: asset.credit?.source || null,
            source_page: asset.credit?.source_page || null,
            license: asset.credit?.license || null,
            license_url: asset.credit?.license_url || null,
        },
    };
}

const source = JSON.parse(fs.readFileSync(sourcePath, 'utf8'));
validateSource(source);
fs.mkdirSync(assetsRoot, { recursive: true });

const assets = source.assets.map(optimiseAsset);
const activeAssetFiles = new Set(assets.map((asset) => path.basename(asset.asset_path)));
for (const filename of fs.readdirSync(assetsRoot)) {
    if (filename.endsWith('.webp') && !activeAssetFiles.has(filename)) {
        fs.rmSync(path.join(assetsRoot, filename));
    }
}
const versionedContent = {
    schema_version: 1,
    rotation: {
        ...source.rotation,
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
console.log(`[railway-backgrounds] Published ${assets.length} assets (${Math.round(totalBytes / 1024)} KB) from ${repositoryRoot}`);
