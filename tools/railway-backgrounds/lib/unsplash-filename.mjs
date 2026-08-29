import path from 'node:path';

const photoIDLength = 11;
const sourceSuffix = '-unsplash';
const supportedExtensions = new Set(['.heic', '.heif', '.jpeg', '.jpg', '.png', '.webp']);

export function isSupportedBackgroundImage(filename) {
    return supportedExtensions.has(path.extname(filename).toLowerCase());
}

export function parseUnsplashImageFilename(filename) {
    if (!isSupportedBackgroundImage(filename)) return null;
    const stem = path.parse(filename).name;
    if (!stem.endsWith(sourceSuffix)) return null;

    const attributionStem = stem.slice(0, -sourceSuffix.length);
    const photoID = attributionStem.slice(-photoIDLength);
    const authorAndSeparator = attributionStem.slice(0, -photoIDLength);
    if (photoID.length !== photoIDLength
        || !/^[A-Za-z0-9_-]+$/.test(photoID)
        || !authorAndSeparator.endsWith('-')) {
        return null;
    }

    const authorSlug = authorAndSeparator.slice(0, -1);
    if (!/^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/.test(authorSlug)) return null;
    const artistName = authorSlug.split('-').map((part) => (
        `${part[0].toUpperCase()}${part.slice(1).toLowerCase()}`
    )).join(' ');

    return {
        artistName,
        photoID,
        sourceURL: `https://unsplash.com/photos/${photoID}`,
    };
}
