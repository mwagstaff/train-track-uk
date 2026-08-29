#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { clearLine, cursorTo } from 'node:readline';
import { fileURLToPath } from 'node:url';
import {
    createQuarantineDirectory,
    moveFileToQuarantine,
} from './lib/file-quarantine.mjs';
import { parseUnsplashImageFilename } from './lib/unsplash-filename.mjs';

const toolRoot = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(toolRoot, '..', '..');
const deployScript = path.resolve(repositoryRoot, '..', 'server-tooling', 'deploy', 'node_project.zsh');
const sourcesRoot = path.join(repositoryRoot, 'resources', 'background_images');
const publishedRoot = path.join(toolRoot, 'published');
const assetsRoot = path.join(publishedRoot, 'assets');
const maximumPixelDimension = 2_560;
const webPQuality = 72;
const maximumAssetBytes = 1_000_000;
const quarantinedFiles = [];
let quarantineDirectory;
let progressVisible = false;

function fail(message) {
    throw new Error(`[railway-backgrounds] ${message}`);
}

function errorReason(error) {
    const stderr = Buffer.isBuffer(error?.stderr) ? error.stderr.toString('utf8').trim() : '';
    return String(stderr || error?.message || error).replace(/^\[railway-backgrounds\]\s*/, '');
}

function updateProgress(filename, index, total) {
    if (!process.stdout.isTTY) return;
    const message = `[railway-backgrounds] Optimising ${index}/${total}: ${filename}`;
    const maximumLength = Math.max(20, (process.stdout.columns || 120) - 1);
    const visibleMessage = message.length > maximumLength
        ? `${message.slice(0, maximumLength - 1)}…`
        : message;
    clearLine(process.stdout, 0);
    cursorTo(process.stdout, 0);
    process.stdout.write(visibleMessage);
    progressVisible = true;
}

function clearProgress() {
    if (!progressVisible) return;
    clearLine(process.stdout, 0);
    cursorTo(process.stdout, 0);
    progressVisible = false;
}

function quarantineSource(sourceFilename, input, reason) {
    quarantineDirectory ??= createQuarantineDirectory();
    let destination;
    try {
        destination = moveFileToQuarantine(input, quarantineDirectory);
    } catch (error) {
        fail(`could not move ${sourceFilename} to ${quarantineDirectory}: ${errorReason(error)}`);
    }
    quarantinedFiles.push({ sourceFilename, destination, reason });
}

function printQuarantineSummary() {
    if (quarantinedFiles.length === 0) return;
    console.log(
        `\n[railway-backgrounds] Moved ${quarantinedFiles.length} unprocessable `
        + `file${quarantinedFiles.length === 1 ? '' : 's'} to ${quarantineDirectory}:`
    );
    for (const item of quarantinedFiles) {
        console.log(`- ${item.sourceFilename}`);
        console.log(`  Reason: ${item.reason}`);
        console.log(`  Temporary location: ${item.destination}`);
    }
}

function sha256(data) {
    return createHash('sha256').update(data).digest('hex');
}

function assetID(photoID) {
    const suffix = photoID.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
    if (!suffix) fail(`could not create an asset ID for Unsplash photo ${photoID}`);
    return `unsplash-${suffix}`;
}

async function sourceAssets() {
    if (!fs.statSync(sourcesRoot, { throwIfNoEntry: false })?.isDirectory()) {
        fail(`source directory not found: ${sourcesRoot}`);
    }
    const assets = [];
    const photoIDs = new Set();
    const assetIDs = new Set();
    for (const entry of fs.readdirSync(sourcesRoot, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
        if (!entry.isFile()) continue;
        if (entry.name === '.DS_Store') continue;
        const input = path.join(sourcesRoot, entry.name);
        const attribution = parseUnsplashImageFilename(entry.name);
        if (!attribution) {
            quarantineSource(
                entry.name,
                input,
                'the filename must match <artist>-<11-character-photo-id>-unsplash.<extension>'
            );
            continue;
        }
        let id;
        try {
            id = assetID(attribution.photoID);
        } catch (error) {
            quarantineSource(entry.name, input, errorReason(error));
            continue;
        }
        if (photoIDs.has(attribution.photoID) || assetIDs.has(id)) {
            quarantineSource(
                entry.name,
                input,
                `Unsplash photo ID ${attribution.photoID} is already present in another source file`
            );
            continue;
        }
        photoIDs.add(attribution.photoID);
        assetIDs.add(id);
        assets.push({
            id,
            input,
            sourceFilename: entry.name,
            ...attribution,
        });
    }
    if (assets.length < 2) fail('at least two convention-compliant Unsplash images are required');
    return assets;
}

function optimiseAsset(source) {
    const temporary = path.join(assetsRoot, `.${source.id}.tmp.webp`);
    try {
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
        ], { stdio: ['ignore', 'ignore', 'pipe'] });

        const data = fs.readFileSync(temporary);
        if (data.length > maximumAssetBytes) {
            fail(`optimised image exceeds ${Math.round(maximumAssetBytes / 1_000)} KB`);
        }
        const hash = sha256(data);
        const filename = `${hash}.webp`;
        const destination = path.join(assetsRoot, filename);
        if (!fs.existsSync(destination)) fs.renameSync(temporary, destination);
        else fs.rmSync(temporary);

        const dimensions = execFileSync('magick', ['identify', '-format', '%w %h', destination], { encoding: 'utf8' })
            .trim().split(/\s+/).map(Number);
        if (dimensions.length !== 2 || dimensions.some((value) => !Number.isInteger(value) || value < 2)) {
            fail('could not determine the optimised image dimensions');
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
    } finally {
        fs.rmSync(temporary, { force: true });
    }
}

async function optimiseAssets(sources) {
    const assets = [];
    for (const [index, source] of sources.entries()) {
        updateProgress(source.sourceFilename, index + 1, sources.length);
        try {
            assets.push(optimiseAsset(source));
        } catch (error) {
            if (error?.code === 'ENOENT') {
                fail('ImageMagick is required. Install it with: brew install imagemagick');
            }
            quarantineSource(
                source.sourceFilename,
                source.input,
                errorReason(error)
            );
        }
    }
    clearProgress();
    if (assets.length < 2) fail('at least two processable Unsplash images are required');
    return assets;
}

async function main() {
    fs.mkdirSync(assetsRoot, { recursive: true });
    const assets = await optimiseAssets(await sourceAssets());
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
    console.log('\nNext, deploy the static assets without restarting the API:');
    console.log(`${deployScript} train-track-api sky --assets-only --skip-asset-prepare`);
}

try {
    await main();
} catch (error) {
    clearProgress();
    console.error(`\n[railway-backgrounds] ${errorReason(error)}`);
    process.exitCode = 1;
} finally {
    clearProgress();
    printQuarantineSummary();
}
