import fs from 'node:fs';
import path from 'node:path';

const quarantinePrefix = '/tmp/train-track-railway-backgrounds-rejected-';

export function createQuarantineDirectory() {
    return fs.mkdtempSync(quarantinePrefix);
}

export function moveFileToQuarantine(input, quarantineDirectory) {
    const destination = path.join(quarantineDirectory, path.basename(input));
    try {
        fs.renameSync(input, destination);
    } catch (error) {
        if (error?.code !== 'EXDEV') throw error;
        fs.copyFileSync(input, destination, fs.constants.COPYFILE_EXCL);
        try {
            fs.unlinkSync(input);
        } catch (unlinkError) {
            fs.rmSync(destination, { force: true });
            throw unlinkError;
        }
    }
    return destination;
}
