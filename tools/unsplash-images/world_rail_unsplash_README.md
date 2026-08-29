# World Rail Unsplash POC — 200 curated subjects

This bundle is designed for a TrainTrack-style proof of concept.

## Files

- `world_rail_unsplash_200_seed_queries.csv` — exactly 200 curated railway/train/station searches from around the world.
- `fetch_unsplash_rail_photos.py` — resolves every search to a specific Unsplash photo using the official Unsplash API.
- Running the script creates:
  - `world_rail_unsplash_200.csv`
  - `world_rail_unsplash_200.json`

Each resolved entry contains:
- canonical Unsplash photo URL
- photographer
- photographer profile URL
- Unsplash photo ID
- image URL
- licence
- country/location label
- descriptive title/search subject

## Run

```bash
export UNSPLASH_ACCESS_KEY="YOUR_KEY"
python fetch_unsplash_rail_photos.py
```

The script deliberately creates a manifest rather than bulk-downloading files. That keeps the source/attribution data attached to each image and is safer for an API-driven POC.

Before shipping in production, re-check the current Unsplash licence and API guidelines.
