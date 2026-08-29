#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import readline from 'node:readline/promises';
import { fileURLToPath } from 'node:url';

import {
    isAffirmativeResponse,
    planDownloadsImport,
} from './lib/download-import.mjs';

const toolDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(toolDirectory, '..', '..');
const downloadsDirectory = path.join(os.homedir(), 'Downloads');
const destinationDirectory = path.join(repositoryRoot, 'resources', 'background_images');

function regularFilenames(directory) {
    return fs.readdirSync(directory, { withFileTypes: true })
        .filter((entry) => entry.isFile())
        .map((entry) => entry.name);
}

function moveWithoutOverwriting(sourcePath, destinationPath) {
    fs.copyFileSync(sourcePath, destinationPath, fs.constants.COPYFILE_EXCL);
    try {
        fs.unlinkSync(sourcePath);
    } catch (error) {
        try {
            fs.unlinkSync(destinationPath);
        } catch {
            // Keep the original error, which best explains why the move failed.
        }
        throw error;
    }
}

async function confirmMove(count) {
    if (!process.stdin.isTTY || !process.stdout.isTTY) {
        throw new Error('confirmation requires an interactive Terminal; no files were moved');
    }

    const prompt = readline.createInterface({ input: process.stdin, output: process.stdout });
    try {
        const answer = await prompt.question(`Move ${count} photo${count === 1 ? '' : 's'}? [y/N] `);
        return isAffirmativeResponse(answer);
    } finally {
        prompt.close();
    }
}

async function main() {
    if (!fs.existsSync(downloadsDirectory)) {
        throw new Error(`Downloads directory does not exist: ${downloadsDirectory}`);
    }
    if (!fs.existsSync(destinationDirectory)) {
        throw new Error(`destination directory does not exist: ${destinationDirectory}`);
    }

    const plan = planDownloadsImport(
        regularFilenames(downloadsDirectory),
        regularFilenames(destinationDirectory),
    );

    console.log(`Source:      ${downloadsDirectory}`);
    console.log(`Destination: ${destinationDirectory}`);

    if (plan.skipped.length > 0) {
        console.log('\nLeft untouched:');
        for (const item of plan.skipped) {
            console.log(`- ${item.filename} (${item.reason})`);
        }
    }

    if (plan.candidates.length === 0) {
        console.log('\nNo new, valid Unsplash photos were found.');
        return;
    }

    console.log('\nReady to move:');
    for (const item of plan.candidates) {
        console.log(`- ${item.filename}`);
    }
    console.log('');

    if (!await confirmMove(plan.candidates.length)) {
        console.log('Cancelled. No files were moved.');
        return;
    }

    let movedCount = 0;
    let failedCount = 0;
    for (const item of plan.candidates) {
        const sourcePath = path.join(downloadsDirectory, item.filename);
        const destinationPath = path.join(destinationDirectory, item.filename);
        try {
            moveWithoutOverwriting(sourcePath, destinationPath);
            movedCount += 1;
            console.log(`Moved: ${item.filename}`);
        } catch (error) {
            failedCount += 1;
            console.error(`Could not move ${item.filename}: ${error.message}`);
        }
    }

    console.log(`\nMoved ${movedCount} photo${movedCount === 1 ? '' : 's'}.`);
    if (failedCount > 0) {
        throw new Error(`${failedCount} photo${failedCount === 1 ? '' : 's'} could not be moved`);
    }

    console.log('\nNext, optimise and validate the images with:');
    console.log(`cd ${repositoryRoot} && node tools/railway-backgrounds/publish.mjs`);
}

main().catch((error) => {
    console.error(`[railway-backgrounds] ${error.message}`);
    process.exitCode = 1;
});
