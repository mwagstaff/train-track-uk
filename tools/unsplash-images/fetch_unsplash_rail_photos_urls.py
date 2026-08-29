#!/usr/bin/env python3
import csv
import json
import os
from pathlib import Path

import requests

HERE = Path(__file__).resolve().parent
SEEDS = HERE / "world_rail_unsplash_200_seed_queries.csv"
OUT = HERE / "world_rail_unsplash_results.jsonl"

KEY = os.environ.get("UNSPLASH_ACCESS_KEY")
if not KEY:
    raise SystemExit('Set UNSPLASH_ACCESS_KEY first.')

session = requests.Session()
session.headers.update({
    "Authorization": f"Client-ID {KEY}",
    "Accept-Version": "v1",
})

# Resume from checkpoint if present.
done = set()
if OUT.exists():
    for line in OUT.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try:
                done.add(int(json.loads(line)["id"]))
            except Exception:
                pass

with SEEDS.open(encoding="utf-8") as f:
    seeds = list(csv.DictReader(f))

print(f"Results will also be appended immediately to:\n  {OUT}\n")

for seed in seeds:
    idx = int(seed["id"])
    if idx in done:
        print(f"{idx:>3}/{len(seeds)}  skipped   {seed['query']}")
        continue

    r = session.get(
        "https://api.unsplash.com/search/photos",
        params={
            "query": seed["query"],
            "page": 1,
            "per_page": 10,
            "orientation": "landscape",
        },
        timeout=30,
    )

    remaining = r.headers.get("X-Ratelimit-Remaining", "?")
    limit = r.headers.get("X-Ratelimit-Limit", "?")

    if r.status_code in (403, 429):
        print(f"\n⏸ Unsplash quota/API limit reached ({remaining}/{limit} remaining).")
        print("Everything fetched so far is already saved.")
        print("Run this script again after the quota resets; it will resume.")
        break

    r.raise_for_status()
    results = r.json().get("results", [])

    if not results:
        item = {
            "id": idx,
            "query": seed["query"],
            "country": seed["country"],
            "status": "no_result",
        }
        print(f"{idx:>3}/{len(seeds)}  no_result {seed['query']}")
    else:
        # Pick first landscape search result.
        p = results[0]
        user = p.get("user") or {}
        item = {
            "id": idx,
            "query": seed["query"],
            "country": seed["country"],
            "status": "ok",
            "photographer": user.get("name", ""),
            "photo_page_url": (p.get("links") or {}).get("html", ""),
            "image_url": (p.get("urls") or {}).get("regular", ""),
            "photo_id": p.get("id", ""),
        }

        print(f"{idx:>3}/{len(seeds)}  ok        {seed['query']}")
        print(f"      Photographer: {item['photographer']}")
        print(f"      Photo page:   {item['photo_page_url']}")
        print(f"      Image URL:    {item['image_url']}")
        print(f"      API quota:    {remaining}/{limit}")

    # Append EACH result immediately so a later 403 cannot lose anything.
    with OUT.open("a", encoding="utf-8") as f:
        f.write(json.dumps(item, ensure_ascii=False) + "\n")
