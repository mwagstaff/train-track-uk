import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
    createQuarantineDirectory,
    moveFileToQuarantine,
} from '../lib/file-quarantine.mjs';

test('moves a rejected source into a unique directory under /tmp', () => {
    const sourceDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'railway-background-source-'));
    const quarantineDirectory = createQuarantineDirectory();
    const source = path.join(sourceDirectory, 'invalid-unsplash (1).jpg');
    fs.writeFileSync(source, 'image data');

    try {
        const destination = moveFileToQuarantine(source, quarantineDirectory);
        assert.match(quarantineDirectory, /^\/tmp\/train-track-railway-backgrounds-rejected-/);
        assert.equal(destination, path.join(quarantineDirectory, path.basename(source)));
        assert.equal(fs.existsSync(source), false);
        assert.equal(fs.readFileSync(destination, 'utf8'), 'image data');
    } finally {
        fs.rmSync(sourceDirectory, { recursive: true, force: true });
        fs.rmSync(quarantineDirectory, { recursive: true, force: true });
    }
});
