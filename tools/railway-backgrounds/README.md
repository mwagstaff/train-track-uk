# Railway backgrounds

The POC catalogue is defined in `catalog-source.json`; original photographs live in `sources/`.

Publish the validated, optimised WebP bundle with:

```bash
node tools/railway-backgrounds/publish.mjs
```

The normal API deployment invokes this command automatically through the shared `asset_bundle` configuration. `published/` is generated and intentionally ignored by Git.

The current photographs and incomplete credits are for internal POC use only. Before distribution, add confirmed source pages, photographer links, licence links, and attribution details to every active entry.
