import path from 'node:path';

import {
    isSupportedBackgroundImage,
    parseUnsplashImageFilename,
} from './unsplash-filename.mjs';

function isPotentialUnsplashImage(filename) {
    return isSupportedBackgroundImage(filename)
        && path.parse(filename).name.toLowerCase().includes('-unsplash');
}

export function isAffirmativeResponse(answer) {
    return ['y', 'yes'].includes(answer.trim().toLowerCase());
}

export function planDownloadsImport(downloadFilenames, destinationFilenames) {
    const destinationNames = new Set(destinationFilenames);
    const knownPhotoIDs = new Map();

    for (const filename of destinationFilenames) {
        const photo = parseUnsplashImageFilename(filename);
        if (photo && !knownPhotoIDs.has(photo.photoID)) {
            knownPhotoIDs.set(photo.photoID, filename);
        }
    }

    const candidates = [];
    const skipped = [];
    const sortedDownloads = [...downloadFilenames].sort((left, right) => left.localeCompare(right));

    for (const filename of sortedDownloads) {
        const photo = parseUnsplashImageFilename(filename);
        if (!photo) {
            if (isPotentialUnsplashImage(filename)) {
                skipped.push({ filename, reason: 'filename does not match the required format' });
            }
            continue;
        }

        if (destinationNames.has(filename)) {
            skipped.push({ filename, reason: 'a file with this name already exists' });
            continue;
        }

        const existingFilename = knownPhotoIDs.get(photo.photoID);
        if (existingFilename) {
            skipped.push({
                filename,
                reason: `photo ID ${photo.photoID} is already used by ${existingFilename}`,
            });
            continue;
        }

        candidates.push({ filename, photoID: photo.photoID });
        knownPhotoIDs.set(photo.photoID, filename);
    }

    return { candidates, skipped };
}
