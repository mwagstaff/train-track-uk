#!/usr/bin/env python3
"""Incrementally download OS NGD railway links and nodes around London.

Each expansion downloads only the rectangular bands outside the coverage already
recorded in the manifest. Completed bands and partial pages are cached so a run
can safely be interrupted or stopped by its request budget and then resumed.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
BASE_URL = "https://api.os.uk/features/ngd/ofa/v1"
PAGE_LIMIT = 100
PRICE_PER_REQUEST_GBP = 0.19
INITIAL_LONDON_BBOX = (-0.25, 51.35, 0.05, 51.55)

REGIONS: dict[str, tuple[float, float, float, float]] = {
    "london-core": INITIAL_LONDON_BBOX,
    "greater-london": (-0.55, 51.25, 0.35, 51.75),
    "london-commuter": (-1.25, 50.65, 1.25, 52.25),
    "south-east": (-2.00, 50.50, 2.00, 52.50),
}

COLLECTIONS = {
    "links": "trn-ntwk-railwaylink-1",
    "nodes": "trn-ntwk-railwaynode-1",
}


@dataclass(frozen=True)
class Bounds:
    minimum_longitude: float
    minimum_latitude: float
    maximum_longitude: float
    maximum_latitude: float

    @classmethod
    def parse(cls, raw: str) -> "Bounds":
        try:
            values = tuple(float(value.strip()) for value in raw.split(","))
        except ValueError as error:
            raise argparse.ArgumentTypeError("bbox values must be numbers") from error
        if len(values) != 4:
            raise argparse.ArgumentTypeError("bbox must be minLon,minLat,maxLon,maxLat")
        bounds = cls(*values)
        try:
            bounds.validate()
        except ValueError as error:
            raise argparse.ArgumentTypeError(str(error)) from error
        return bounds

    @classmethod
    def from_values(cls, values: list[float] | tuple[float, ...]) -> "Bounds":
        if len(values) != 4:
            raise ValueError("coverage manifest contains an invalid bbox")
        bounds = cls(*(float(value) for value in values))
        bounds.validate()
        return bounds

    def validate(self) -> None:
        if not all(math.isfinite(value) for value in self.values):
            raise ValueError("bbox values must be finite")
        if not -180 <= self.minimum_longitude < self.maximum_longitude <= 180:
            raise ValueError("bbox longitudes are invalid")
        if not -90 <= self.minimum_latitude < self.maximum_latitude <= 90:
            raise ValueError("bbox latitudes are invalid")

    @property
    def values(self) -> tuple[float, float, float, float]:
        return (
            self.minimum_longitude,
            self.minimum_latitude,
            self.maximum_longitude,
            self.maximum_latitude,
        )

    def contains(self, other: "Bounds") -> bool:
        return (
            self.minimum_longitude <= other.minimum_longitude
            and self.minimum_latitude <= other.minimum_latitude
            and self.maximum_longitude >= other.maximum_longitude
            and self.maximum_latitude >= other.maximum_latitude
        )

    def api_value(self) -> str:
        return ",".join(format(value, ".10g") for value in self.values)

    def cache_key(self) -> str:
        return self.api_value().replace("-", "m").replace(".", "p").replace(",", "_")


class RequestBudgetExceeded(RuntimeError):
    pass


class RequestBudget:
    def __init__(self, maximum: int, requests_per_minute: int) -> None:
        self.maximum = maximum
        self.minimum_interval = 60 / requests_per_minute
        self.count = 0
        self.last_request_at: float | None = None

    def claim(self) -> None:
        if self.maximum > 0 and self.count >= self.maximum:
            raise RequestBudgetExceeded(
                f"Stopped after {self.count} API requests (the configured per-run limit)."
            )
        if self.last_request_at is not None:
            remaining = self.minimum_interval - (time.monotonic() - self.last_request_at)
            if remaining > 0:
                time.sleep(remaining)
        self.count += 1
        self.last_request_at = time.monotonic()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Incrementally expand cached OS NGD railway coverage around London."
    )
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--region", choices=sorted(REGIONS), default="greater-london")
    target.add_argument("--bbox", type=Bounds.parse, help="minLon,minLat,maxLon,maxLat")
    parser.add_argument("--list-regions", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="show the expansion without using the API")
    parser.add_argument(
        "--max-requests",
        type=int,
        default=1_000,
        help="maximum new API requests in this run; 0 disables the ceiling (default: 1000)",
    )
    parser.add_argument(
        "--requests-per-minute",
        type=int,
        default=45,
        help="client-side throttle (default: 45, safe for development-mode projects)",
    )
    parser.add_argument("--output-dir", type=Path, default=SCRIPT_DIR)
    parser.add_argument("--cache-dir", type=Path, default=SCRIPT_DIR / ".railway-data-cache")
    args = parser.parse_args()
    if args.max_requests < 0:
        parser.error("--max-requests cannot be negative")
    if args.requests_per_minute <= 0:
        parser.error("--requests-per-minute must be positive")
    return args


def expansion_rectangles(existing: Bounds | None, requested: Bounds) -> list[Bounds]:
    if existing is None:
        return [requested]
    if not requested.contains(existing):
        raise ValueError(
            "The requested bbox must contain the existing coverage. "
            "This downloader expands coverage; it does not shrink or move it."
        )
    rectangles: list[Bounds] = []
    if requested.minimum_longitude < existing.minimum_longitude:
        rectangles.append(Bounds(
            requested.minimum_longitude,
            requested.minimum_latitude,
            existing.minimum_longitude,
            requested.maximum_latitude,
        ))
    if existing.maximum_longitude < requested.maximum_longitude:
        rectangles.append(Bounds(
            existing.maximum_longitude,
            requested.minimum_latitude,
            requested.maximum_longitude,
            requested.maximum_latitude,
        ))
    if requested.minimum_latitude < existing.minimum_latitude:
        rectangles.append(Bounds(
            existing.minimum_longitude,
            requested.minimum_latitude,
            existing.maximum_longitude,
            existing.minimum_latitude,
        ))
    if existing.maximum_latitude < requested.maximum_latitude:
        rectangles.append(Bounds(
            existing.minimum_longitude,
            existing.maximum_latitude,
            existing.maximum_longitude,
            requested.maximum_latitude,
        ))
    return rectangles


def output_paths(output_dir: Path) -> dict[str, Path]:
    return {
        "links": output_dir / "railway-links-all.json",
        "nodes": output_dir / "railway-nodes-all.json",
    }


def load_feature_collection(path: Path) -> list[dict[str, Any]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"Cannot read valid JSON from {path}") from error
    if document.get("type") != "FeatureCollection" or not isinstance(document.get("features"), list):
        raise ValueError(f"{path} is not a GeoJSON FeatureCollection")
    features = document["features"]
    for feature in features:
        if not isinstance(feature, dict) or not isinstance(feature.get("id"), str):
            raise ValueError(f"{path} contains a feature without a string ID")
    return features


def load_existing_coverage(cache_dir: Path, outputs: dict[str, Path]) -> tuple[Bounds | None, bool]:
    manifest_path = cache_dir / "coverage.json"
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if manifest.get("schemaVersion") != 1:
                raise ValueError("unsupported manifest schema")
            recorded_outputs = manifest.get("outputs")
            if recorded_outputs != {label: str(path) for label, path in outputs.items()}:
                raise ValueError("manifest belongs to a different output directory")
            for path in outputs.values():
                load_feature_collection(path)
            return Bounds.from_values(manifest["coveredBBox"]), False
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise ValueError(f"Invalid coverage manifest at {manifest_path}") from error

    existing_outputs = [path.exists() for path in outputs.values()]
    if any(existing_outputs) and not all(existing_outputs):
        raise ValueError("Only one existing railway dataset was found; both links and nodes are required")
    if all(existing_outputs):
        for path in outputs.values():
            load_feature_collection(path)
        return Bounds(*INITIAL_LONDON_BBOX), True
    return None, False


def atomic_write_json(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(document, separators=(",", ":"), ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def fetch_page(
    collection: str,
    bounds: Bounds,
    offset: int,
    api_key: str,
    budget: RequestBudget,
) -> dict[str, Any]:
    query = urllib.parse.urlencode({
        "bbox": bounds.api_value(),
        "limit": PAGE_LIMIT,
        "offset": offset,
    })
    url = f"{BASE_URL}/collections/{collection}/items?{query}"
    retry_delay = 1.0
    for attempt in range(5):
        budget.claim()
        request = urllib.request.Request(
            url,
            headers={
                "key": api_key,
                "Accept": "application/geo+json, application/json",
                "User-Agent": "TrainTrackUK-RailwayDataBuilder/1.0",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                document = json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 429 or 500 <= error.code < 600:
                retry_after = error.headers.get("Retry-After")
                delay = float(retry_after) if retry_after and retry_after.isdigit() else retry_delay
                print(f"HTTP {error.code}; retrying in {delay:.0f}s", file=sys.stderr)
                time.sleep(delay)
                retry_delay = min(retry_delay * 2, 16)
                continue
            raise RuntimeError(f"OS API returned HTTP {error.code}") from error
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            if attempt == 4:
                raise RuntimeError(f"OS API request failed: {error}") from error
            print(f"Request failed; retrying in {retry_delay:.0f}s", file=sys.stderr)
            time.sleep(retry_delay)
            retry_delay = min(retry_delay * 2, 16)
            continue

        if document.get("type") != "FeatureCollection" or not isinstance(document.get("features"), list):
            detail = document.get("detail") or document.get("description") or document.get("title")
            raise RuntimeError(f"OS API returned an invalid response{f': {detail}' if detail else ''}")
        return document
    raise RuntimeError("OS API request failed after retries")


def download_rectangle(
    label: str,
    collection: str,
    bounds: Bounds,
    cache_dir: Path,
    api_key: str,
    budget: RequestBudget,
) -> Path:
    collection_dir = cache_dir / collection
    completed_path = collection_dir / f"{bounds.cache_key()}.json"
    partial_path = collection_dir / f"{bounds.cache_key()}.partial.json"
    if completed_path.exists():
        load_feature_collection(completed_path)
        print(f"  {label}: cached {bounds.api_value()}")
        return completed_path

    features: list[dict[str, Any]] = []
    offset = 0
    if partial_path.exists():
        try:
            partial = json.loads(partial_path.read_text(encoding="utf-8"))
            if partial.get("bbox") != list(bounds.values):
                raise ValueError("partial bbox mismatch")
            offset = int(partial["offset"])
            features = partial["features"]
            if not isinstance(features, list):
                raise ValueError("partial features are invalid")
            print(f"  {label}: resuming at offset {offset}")
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise ValueError(f"Invalid partial download at {partial_path}") from error
    else:
        print(f"  {label}: downloading {bounds.api_value()}")

    seen_ids = {feature.get("id") for feature in features}
    while True:
        page = fetch_page(collection, bounds, offset, api_key, budget)
        page_features = page["features"]
        for feature in page_features:
            identifier = feature.get("id")
            if not isinstance(identifier, str) or not identifier:
                raise RuntimeError("OS API returned a feature without a string ID")
            if identifier not in seen_ids:
                features.append(feature)
                seen_ids.add(identifier)
        offset += len(page_features)
        atomic_write_json(partial_path, {
            "bbox": list(bounds.values),
            "offset": offset,
            "features": features,
        })
        print(f"    offset {offset}; {len(features)} unique features; {budget.count} requests this run")

        number_matched = page.get("numberMatched")
        if len(page_features) < PAGE_LIMIT or (
            isinstance(number_matched, int) and offset >= number_matched
        ):
            break

    atomic_write_json(completed_path, {"type": "FeatureCollection", "features": features})
    partial_path.unlink(missing_ok=True)
    return completed_path


def merge_collection(output: Path, additions: list[Path]) -> tuple[int, int]:
    by_identifier: dict[str, dict[str, Any]] = {}
    input_count = 0
    if output.exists():
        existing = load_feature_collection(output)
        input_count += len(existing)
        by_identifier.update((feature["id"], feature) for feature in existing)
    for addition in additions:
        features = load_feature_collection(addition)
        input_count += len(features)
        by_identifier.update((feature["id"], feature) for feature in features)
    merged = [by_identifier[identifier] for identifier in sorted(by_identifier)]
    atomic_write_json(output, {"type": "FeatureCollection", "features": merged})
    return len(merged), input_count - len(merged)


def print_plan(existing: Bounds | None, requested: Bounds, rectangles: list[Bounds], bootstrapped: bool) -> None:
    if existing:
        suffix = " (inferred from the original London files)" if bootstrapped else ""
        print(f"Existing coverage: {existing.api_value()}{suffix}")
    else:
        print("Existing coverage: none")
    print(f"Requested coverage: {requested.api_value()}")
    if not rectangles:
        print("No expansion is required.")
        return
    print(f"New rectangular bands: {len(rectangles)}")
    for index, rectangle in enumerate(rectangles, start=1):
        print(f"  {index}. {rectangle.api_value()}")
    minimum_requests = len(rectangles) * len(COLLECTIONS)
    print(
        f"Minimum new requests: {minimum_requests}; actual requests depend on feature counts "
        f"(100 features/request, £{PRICE_PER_REQUEST_GBP:.2f} list price)."
    )


def main() -> int:
    args = parse_args()
    if args.list_regions:
        for name, values in REGIONS.items():
            print(f"{name:18} {Bounds(*values).api_value()}")
        return 0

    requested = args.bbox or Bounds(*REGIONS[args.region])
    outputs = output_paths(args.output_dir.resolve())
    cache_dir = args.cache_dir.resolve()
    try:
        existing, bootstrapped = load_existing_coverage(cache_dir, outputs)
        rectangles = expansion_rectangles(existing, requested)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1

    print_plan(existing, requested, rectangles, bootstrapped)
    if args.dry_run:
        return 0

    if not rectangles:
        if bootstrapped:
            atomic_write_json(cache_dir / "coverage.json", {
                "schemaVersion": 1,
                "coveredBBox": list(requested.values),
                "updatedAt": datetime.now(timezone.utc).isoformat(),
                "outputs": {label: str(path) for label, path in outputs.items()},
            })
        return 0

    api_key = os.environ.get("OS_API_KEY", "").strip()
    if not api_key:
        print("Error: OS_API_KEY environment variable is not set.", file=sys.stderr)
        return 1

    budget = RequestBudget(args.max_requests, args.requests_per_minute)
    downloaded: dict[str, list[Path]] = {label: [] for label in COLLECTIONS}
    try:
        for label, collection in COLLECTIONS.items():
            print(f"Downloading {label} ({collection})")
            for rectangle in rectangles:
                downloaded[label].append(download_rectangle(
                    label,
                    collection,
                    rectangle,
                    cache_dir,
                    api_key,
                    budget,
                ))
    except RequestBudgetExceeded as error:
        print(f"\n{error}", file=sys.stderr)
        print("Partial progress was cached. Run the same command again to resume.", file=sys.stderr)
        return 2
    except (RuntimeError, ValueError) as error:
        print(f"\nError: {error}", file=sys.stderr)
        print("Partial progress was cached where possible.", file=sys.stderr)
        return 1

    for label, output in outputs.items():
        count, duplicates = merge_collection(output, downloaded[label])
        print(f"Wrote {output}: {count} features ({duplicates} duplicate occurrences removed)")

    atomic_write_json(cache_dir / "coverage.json", {
        "schemaVersion": 1,
        "coveredBBox": list(requested.values),
        "updatedAt": datetime.now(timezone.utc).isoformat(),
        "outputs": {label: str(path) for label, path in outputs.items()},
    })
    print(
        f"Completed with {budget.count} new API requests "
        f"(£{budget.count * PRICE_PER_REQUEST_GBP:.2f} list-price equivalent)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
