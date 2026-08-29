# Railway backgrounds

The background library is driven exclusively by image files in `resources/background_images/`. There is no hand-maintained photo manifest: the publisher derives attribution from each filename and generates the server catalogue.

## Filename contract

Every image must use:

```text
<artist-name>-<11-character-unsplash-photo-id>-unsplash.<extension>
```

For example:

```text
diane-picchiottino-sKsNVoa_NsY-unsplash.jpg
```

This produces:

- Artist: `Diane Picchiottino`
- Attribution: `Image courtesy of Diane Picchiottino, Unsplash`
- Link: `https://unsplash.com/photos/sKsNVoa_NsY`

Supported source extensions are HEIC, HEIF, JPEG, PNG, and WebP. The final 11 characters before `-unsplash` are always treated as the Unsplash photo ID, including IDs that begin with a hyphen. Publishing fails on a malformed image filename or duplicate photo ID so an uncredited image cannot enter the app accidentally.

## Publishing and optimisation

Generate the catalogue and optimized server bundle with:

```bash
node tools/railway-backgrounds/publish.mjs
```

The publisher:

- auto-orients and strips image metadata;
- constrains the longest edge to 2,560 pixels for iPhone and iPad display;
- encodes WebP at quality 72 using the highest-effort encoder;
- enforces a 1 MB ceiling per delivered image;
- generates immutable content-hashed asset URLs and the rotating catalogue.

`tools/railway-backgrounds/published/` is generated and ignored by Git. The app downloads only the selected daily image and caches it on device. Its full-screen viewer displays the filename-derived attribution as a small centered link at the bottom.

The normal API deployment runs the publisher through the shared asset-bundle configuration:

```bash
/Users/mwagstaff/dev/server-tooling/deploy/node_project.zsh
```

Adding or removing a convention-compliant source image therefore requires an API deployment, but no app release.

In a DEBUG app build, Profile → Background Photo POC can refresh the catalogue and advance through every image.

Run focused tooling tests with:

```bash
node --test tools/railway-backgrounds/test/*.test.mjs
```
