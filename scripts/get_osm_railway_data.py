#!/usr/bin/env python3
"""Download and filter a reproducible Geofabrik Great Britain OSM snapshot."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import shutil
import subprocess
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CACHE = SCRIPT_DIR / ".osm-routing-cache"
DEFAULT_SOURCE_URL = (
    "https://download.geofabrik.de/europe/great-britain-latest.osm.pbf"
)
DEFAULT_FILTER = SCRIPT_DIR / "osm-railway-filter.txt"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download the Geofabrik Great Britain PBF and retain railway data."
    )
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--source-url", default=DEFAULT_SOURCE_URL)
    parser.add_argument("--filter", type=Path, default=DEFAULT_FILTER)
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="Download the current snapshot even when a cached source exists.",
    )
    parser.add_argument(
        "--refilter",
        action="store_true",
        help="Rebuild the railway PBF even when its inputs are unchanged.",
    )
    return parser.parse_args()


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z")


def digest(path: Path, algorithm: str) -> str:
    hasher = hashlib.new(algorithm)
    with path.open("rb") as source:
        while chunk := source.read(8 * 1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def write_json(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def recorded_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(ROOT))
    except ValueError:
        return str(resolved)


def require_command(name: str) -> str:
    command = shutil.which(name)
    if command is None:
        raise RuntimeError(f"Required command is unavailable: {name}")
    return command


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def download(url: str, destination: Path, refresh: bool) -> None:
    if destination.exists() and not refresh:
        print(f"Reusing {destination} ({destination.stat().st_size / 1_000_000_000:.2f} GB)")
        return

    partial = destination.with_suffix(destination.suffix + ".partial")
    if refresh and partial.exists():
        partial.unlink()
    print(f"Downloading {url}")
    run(
        [
            require_command("curl"),
            "--fail",
            "--location",
            "--retry",
            "4",
            "--retry-delay",
            "5",
            "--continue-at",
            "-",
            "--output",
            str(partial),
            url,
        ]
    )
    partial.replace(destination)


def expected_md5(source_url: str, cache_dir: Path, refresh: bool) -> str:
    checksum_path = cache_dir / "great-britain-latest.osm.pbf.md5"
    if refresh or not checksum_path.exists():
        run(
            [
                require_command("curl"),
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--output",
                str(checksum_path),
                source_url + ".md5",
            ]
        )
    fields = checksum_path.read_text(encoding="utf-8").split()
    if not fields or len(fields[0]) != 32:
        raise RuntimeError("Geofabrik MD5 response is invalid")
    return fields[0].lower()


def main() -> None:
    args = parse_args()
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    if not args.filter.is_file():
        raise RuntimeError(f"Filter expression file is unavailable: {args.filter}")

    source = args.cache_dir / "great-britain-latest.osm.pbf"
    filtered = args.cache_dir / "railway-great-britain.osm.pbf"
    metadata_path = filtered.with_suffix(filtered.suffix + ".metadata.json")

    download(args.source_url, source, args.refresh)
    remote_md5 = expected_md5(args.source_url, args.cache_dir, args.refresh)
    local_md5 = digest(source, "md5")
    if local_md5 != remote_md5:
        raise RuntimeError(
            f"Source checksum mismatch: expected {remote_md5}, calculated {local_md5}"
        )

    source_sha256 = digest(source, "sha256")
    filter_sha256 = digest(args.filter, "sha256")
    previous_metadata = load_json(metadata_path)
    inputs_unchanged = (
        previous_metadata.get("source", {}).get("sha256") == source_sha256
        and previous_metadata.get("filter", {}).get("sha256") == filter_sha256
    )

    output_checksum_matches = (
        filtered.exists()
        and previous_metadata.get("output", {}).get("sha256")
        == digest(filtered, "sha256")
    )
    if output_checksum_matches and inputs_unchanged and not args.refilter:
        print(f"Reusing {filtered} ({filtered.stat().st_size / 1_000_000:.2f} MB)")
        return

    osmium = require_command("osmium")
    temporary = filtered.with_suffix(filtered.suffix + ".tmp")
    if temporary.exists():
        temporary.unlink()
    print("Filtering railway tracks, station features, and route relations")
    run(
        [
            osmium,
            "tags-filter",
            "--remove-tags",
            f"--expressions={args.filter}",
            "--output-format=pbf",
            "--output",
            str(temporary),
            str(source),
        ]
    )
    temporary.replace(filtered)

    metadata = {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "source": {
            "provider": "Geofabrik",
            "url": args.source_url,
            "license": "ODbL-1.0",
            "attribution": "© OpenStreetMap contributors",
            "md5": local_md5,
            "sha256": source_sha256,
            "bytes": source.stat().st_size,
        },
        "filter": {
            "path": recorded_path(args.filter),
            "sha256": filter_sha256,
        },
        "output": {
            "path": recorded_path(filtered),
            "sha256": digest(filtered, "sha256"),
            "bytes": filtered.stat().st_size,
        },
        "osmiumVersion": subprocess.run(
            [osmium, "--version"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()[0],
    }
    write_json(metadata_path, metadata)
    print(f"Wrote {filtered} ({filtered.stat().st_size / 1_000_000:.2f} MB)")
    print(f"Wrote {metadata_path}")


if __name__ == "__main__":
    main()
