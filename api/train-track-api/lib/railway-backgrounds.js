import fs from 'node:fs';
import path from 'node:path';

const SCHEMA_VERSION = 1;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const ASSET_ID_PATTERN = /^[a-z0-9][a-z0-9-]{1,79}$/;
const UNSPLASH_PHOTO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/;
const SERVER_DELIVERY = 'server';

export class RailwayBackgroundCatalogError extends Error {
    constructor(message) {
        super(message);
        this.name = 'RailwayBackgroundCatalogError';
    }
}

function validatedURL(value, hostname, description) {
    let url;
    try {
        url = new URL(value);
    } catch {
        throw new RailwayBackgroundCatalogError(`invalid ${description}`);
    }
    if (url.protocol !== 'https:' || url.hostname !== hostname) {
        throw new RailwayBackgroundCatalogError(`invalid ${description}`);
    }
    return url;
}

export function validateRailwayBackgroundCatalog(value, rootDirectory, options = {}) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
        throw new RailwayBackgroundCatalogError('catalog must be an object');
    }
    if (value.schema_version !== SCHEMA_VERSION) {
        throw new RailwayBackgroundCatalogError('unsupported schema_version');
    }
    if (!SHA256_PATTERN.test(String(value.catalog_version || ''))) {
        throw new RailwayBackgroundCatalogError('catalog_version must be a SHA-256 value');
    }
    const rotation = value.rotation;
    if (!rotation || rotation.time_zone !== 'Europe/London' || !/^\d{4}-\d{2}-\d{2}$/.test(rotation.epoch_date || '')) {
        throw new RailwayBackgroundCatalogError('invalid rotation configuration');
    }
    if (!Array.isArray(rotation.asset_ids) || !Array.isArray(value.assets) || value.assets.length < 2) {
        throw new RailwayBackgroundCatalogError('catalog must contain a rotation and at least two assets');
    }

    const assetIDs = new Set();
    for (const asset of value.assets) {
        const assetID = String(asset?.id || '');
        const hash = String(asset?.sha256 || '');
        if (!ASSET_ID_PATTERN.test(assetID)) {
            throw new RailwayBackgroundCatalogError(`invalid asset id: ${assetID || '<empty>'}`);
        }
        if (assetIDs.has(assetID)) {
            throw new RailwayBackgroundCatalogError(`duplicate asset id: ${assetID}`);
        }
        assetIDs.add(assetID);
        if (!String(asset.title || '').trim() || !String(asset.location || '').trim()) {
            throw new RailwayBackgroundCatalogError(`asset ${assetID} is missing display metadata`);
        }
        if (!SHA256_PATTERN.test(hash)) throw new RailwayBackgroundCatalogError(`asset ${assetID} has an invalid cache key`);
        const delivery = asset.delivery || SERVER_DELIVERY;
        if (delivery !== SERVER_DELIVERY) {
            throw new RailwayBackgroundCatalogError(`asset ${assetID} must use server delivery`);
        }
        if (asset.asset_path !== `assets/${hash}.webp`) {
            throw new RailwayBackgroundCatalogError(`asset ${assetID} has an invalid immutable path`);
        }
        if (asset.content_type !== 'image/webp' || !Number.isInteger(asset.byte_size) || asset.byte_size < 1) {
            throw new RailwayBackgroundCatalogError(`asset ${assetID} has invalid file metadata`);
        }
        const photoID = String(asset.provider_asset_id || '');
        const sourceFilename = String(asset.source_filename || '');
        const sourceExtension = path.extname(sourceFilename).toLowerCase();
        const sourceStem = path.basename(sourceFilename, sourceExtension);
        if (!UNSPLASH_PHOTO_ID_PATTERN.test(photoID)
            || !['.heic', '.heif', '.jpeg', '.jpg', '.png', '.webp'].includes(sourceExtension)
            || !sourceStem.toLowerCase().endsWith(`-${photoID.toLowerCase()}-unsplash`)) {
            throw new RailwayBackgroundCatalogError(`asset ${assetID} has invalid filename-derived Unsplash metadata`);
        }
        const sourceURL = validatedURL(asset.credit?.source_page, 'unsplash.com', `source URL for ${assetID}`);
        if (sourceURL.pathname !== `/photos/${photoID}`
            || asset.credit?.source !== 'Unsplash'
            || !String(asset.credit?.photographer || '').trim()
            || asset.credit?.license !== 'Unsplash License') {
            throw new RailwayBackgroundCatalogError(`asset ${assetID} is missing Unsplash attribution`);
        }
        if (![asset.width, asset.height].every((number) => Number.isInteger(number) && number > 1)) {
            throw new RailwayBackgroundCatalogError(`asset ${assetID} has invalid dimensions`);
        }
        const focalPoint = asset.focal_point;
        if (!focalPoint || ![focalPoint.x, focalPoint.y].every((number) => Number.isFinite(number) && number >= 0 && number <= 1)) {
            throw new RailwayBackgroundCatalogError(`asset ${assetID} has an invalid focal point`);
        }
        if (!Number.isFinite(asset.scrim_opacity) || asset.scrim_opacity < 0 || asset.scrim_opacity > 1) {
            throw new RailwayBackgroundCatalogError(`asset ${assetID} has invalid scrim opacity`);
        }
        if (options.verifyFiles !== false) {
            const filePath = path.join(rootDirectory, asset.asset_path);
            const stat = fs.statSync(filePath, { throwIfNoEntry: false });
            if (!stat?.isFile() || stat.size !== asset.byte_size) {
                throw new RailwayBackgroundCatalogError(`missing or incorrectly sized image for ${assetID}`);
            }
        }
    }
    if (rotation.asset_ids.length !== assetIDs.size
        || new Set(rotation.asset_ids).size !== assetIDs.size
        || rotation.asset_ids.some((assetID) => !assetIDs.has(assetID))) {
        throw new RailwayBackgroundCatalogError('rotation asset_ids must contain every asset exactly once');
    }
    return value;
}

export function createRailwayBackgroundCatalogLoader(rootDirectory) {
    const catalogPath = path.join(rootDirectory, 'catalog.json');
    let cachedSignature = null;
    let lastValid = null;

    function load() {
        const stat = fs.statSync(catalogPath, { throwIfNoEntry: false });
        if (!stat?.isFile()) return lastValid;
        const signature = `${stat.mtimeMs}:${stat.size}`;
        if (lastValid && cachedSignature === signature) return lastValid;

        try {
            const value = validateRailwayBackgroundCatalog(
                JSON.parse(fs.readFileSync(catalogPath, 'utf8')),
                rootDirectory
            );
            const publicAssets = value.assets.map((asset) => ({
                ...asset,
                delivery: SERVER_DELIVERY,
                asset_url: `/api/v2/railway-backgrounds/assets/${asset.sha256}.webp`
            }));
            lastValid = {
                value: {
                    ...value,
                    assets: publicAssets
                },
                etag: `"${value.catalog_version}"`,
                lastModified: stat.mtime
            };
            cachedSignature = signature;
        } catch (error) {
            if (!lastValid) throw error;
            console.warn('[railway-backgrounds] Ignoring invalid replacement catalog:', error?.message || error);
        }
        return lastValid;
    }

    return { load, catalogPath };
}

function requestIsNotModified(req, catalog) {
    const ifNoneMatch = String(req.get('If-None-Match') || '').trim();
    if (ifNoneMatch.split(',').map((value) => value.trim()).includes(catalog.etag)) return true;
    const ifModifiedSince = Date.parse(String(req.get('If-Modified-Since') || ''));
    return Number.isFinite(ifModifiedSince)
        && Math.floor(catalog.lastModified.getTime() / 1000) <= Math.floor(ifModifiedSince / 1000);
}

export function registerRailwayBackgroundRoutes(app, options = {}) {
    const rootDirectory = path.resolve(
        options.rootDirectory
        || process.env.RAILWAY_BACKGROUNDS_ROOT
        || path.join(process.cwd(), 'railway-backgrounds')
    );
    const loader = options.loader || createRailwayBackgroundCatalogLoader(rootDirectory);

    app.get('/api/v2/railway-backgrounds/catalog', (req, res) => {
        let catalog;
        try {
            catalog = loader.load();
        } catch (error) {
            console.warn('[railway-backgrounds] Catalog unavailable:', error?.message || error);
            return res.status(503).json({ error: 'Railway background catalog is unavailable.' });
        }
        if (!catalog) return res.status(503).json({ error: 'Railway background catalog is unavailable.' });

        res.set('Cache-Control', 'public, max-age=14400, must-revalidate');
        res.set('ETag', catalog.etag);
        res.set('Last-Modified', catalog.lastModified.toUTCString());
        if (requestIsNotModified(req, catalog)) return res.status(304).end();
        return res.status(200).json(catalog.value);
    });

    app.get('/api/v2/railway-backgrounds/assets/:hash.webp', (req, res) => {
        const hash = String(req.params.hash || '').toLowerCase();
        if (!SHA256_PATTERN.test(hash)) {
            return res.status(400).json({ error: 'Invalid railway background identifier.' });
        }
        let catalog;
        try {
            catalog = loader.load();
        } catch (error) {
            console.warn('[railway-backgrounds] Catalog unavailable:', error?.message || error);
            return res.status(503).json({ error: 'Railway background catalog is unavailable.' });
        }
        if (!catalog?.value.assets.some((asset) => asset.sha256 === hash && asset.delivery === SERVER_DELIVERY)) {
            return res.status(404).json({ error: 'Railway background was not found.' });
        }
        const filePath = path.join(rootDirectory, 'assets', `${hash}.webp`);
        if (!fs.statSync(filePath, { throwIfNoEntry: false })?.isFile()) {
            return res.status(404).json({ error: 'Railway background was not found.' });
        }
        res.set('Cache-Control', 'public, max-age=31536000, immutable');
        res.set('Content-Type', 'image/webp');
        res.set('ETag', `"${hash}"`);
        return res.sendFile(filePath);
    });

    return { rootDirectory, loader };
}
