# Add or update background photos

Use this guide whenever you want to add, replace, or remove a background photo in TrainTrack UK.

## 1. Put the source images in the correct folder

Use this folder:

```text
/Users/mwagstaff/dev/train-track-uk/resources/background_images/
```

- **Add a photo:** copy the new image into this folder.
- **Update the same Unsplash photo:** replace the file and keep its filename unchanged.
- **Use a different photo:** add the new file with its own Unsplash filename, then delete the old file.
- **Remove a photo:** delete the file from this folder.

Do not add a manifest file. The catalogue and attribution metadata are generated automatically.

### Move valid downloads into this folder automatically

If the images are currently in the top level of your Downloads folder, run:

```bash
cd /Users/mwagstaff/dev/train-track-uk
node tools/railway-backgrounds/import-downloads.mjs
```

The importer lists the valid images it found and asks once before moving them. It leaves unrelated files, invalid names such as `photo-unsplash (1).jpg`, existing filenames, and duplicate Unsplash photo IDs untouched. Pressing Return at the prompt cancels the move. After a successful move, it prints the exact command to optimise and validate the images.

## 2. Check every filename

Only Unsplash images are supported. Each filename must use this format:

```text
<photographer-name>-<11-character-unsplash-photo-id>-unsplash.<extension>
```

Example:

```text
diane-picchiottino-sKsNVoa_NsY-unsplash.jpg
```

This filename creates the photographer credit and the link to:

```text
https://unsplash.com/photos/sKsNVoa_NsY
```

Supported source files are HEIC, HEIF, JPEG, PNG, and WebP.

## 3. Optimise and validate the images

From Terminal, run:

```bash
cd /Users/mwagstaff/dev/train-track-uk
node tools/railway-backgrounds/publish.mjs
```

A successful run ends with a message similar to:

```text
[railway-backgrounds] Published <number> filename-derived Unsplash assets (...)
```

The command:

- resizes each image for iPhone and iPad;
- removes embedded metadata;
- converts each image to WebP;
- checks that each delivered image is no larger than 1 MB;
- generates the API catalogue and attribution metadata.

The generated files are written to:

```text
/Users/mwagstaff/dev/train-track-uk/tools/railway-backgrounds/published/
```

Do not edit anything in `published/` by hand. Run the publisher again whenever a source image changes.

While processing, the publisher displays the current filename on one updating Terminal line. If a source file cannot be processed, it is moved out of the source folder into a uniquely named directory under `/tmp`. At the end, the publisher lists every moved file, the reason, and its temporary location so you can inspect, rename, or recover it.

If Terminal reports that `magick` is missing, install ImageMagick once with:

```bash
brew install imagemagick
```

## 4. Run the publisher tests

```bash
cd /Users/mwagstaff/dev/train-track-uk
node --test tools/railway-backgrounds/test/*.test.mjs
```

Continue only when the tests pass.

## 5. Deploy the API

For a photo-only change, deploy the static asset bundle without restarting the API:

```bash
/Users/mwagstaff/dev/server-tooling/deploy/node_project.zsh train-track-api sky --assets-only --skip-asset-prepare
```

The `--skip-asset-prepare` option reuses the bundle created in step 3 instead of optimising every image again. The deployment uploads the generated catalogue and images, validates them on the server, and then activates the new catalogue atomically. It does not sync application code, install dependencies, change environment settings, or restart the API, so regular API calls remain available.

Only use `--skip-asset-prepare` immediately after `publish.mjs` completes successfully. If you have not run the publisher, omit that option; `--assets-only` will prepare the bundle before uploading it.

Use the normal deployment command without `--assets-only` when API code or configuration has also changed.

An app release is not required.

## 6. Check the deployed catalogue

```bash
curl -fsS https://api.skynolimit.dev/train-track/api/v2/railway-backgrounds/catalog \
  | jq -r '.assets[].source_filename'
```

Confirm that the expected filenames appear. In a DEBUG app build, you can then use:

**Profile → Background Photo POC → Refresh and show next Unsplash photo**

Tap repeatedly to review every deployed image in the app.

For implementation details and tooling limits, see the
[railway-backgrounds technical README](tools/railway-backgrounds/README.md).

## Quick checklist

- [ ] Source images are in `resources/background_images/`.
- [ ] Every filename follows the Unsplash naming format.
- [ ] `node tools/railway-backgrounds/publish.mjs` succeeds.
- [ ] The publisher tests pass.
- [ ] The `train-track-api` static asset deployment succeeds.
- [ ] The deployed catalogue contains the expected filenames.
