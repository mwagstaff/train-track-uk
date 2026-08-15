#!/usr/bin/env python3
"""Validate OS NGD London railway data and build the compact iOS routing asset."""

from __future__ import annotations

import argparse
import heapq
import json
import math
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LINKS = ROOT / "scripts" / "railway-links-all.json"
DEFAULT_NODES = ROOT / "scripts" / "railway-nodes-all.json"
DEFAULT_STATIONS = ROOT / "api" / "train-track-api" / "resources" / "stations.json"
DEFAULT_OUTPUT = (
    ROOT
    / "ios"
    / "TrainTrack UK"
    / "TrainTrack UK"
    / "Resources"
    / "railway-routing-london.json"
)

EARTH_RADIUS_METRES = 6_371_008.8
MAX_ANCHOR_DISTANCE_METRES = 1_000
ANCHORS_PER_STATION = 4


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--links", type=Path, default=DEFAULT_LINKS)
    parser.add_argument("--nodes", type=Path, default=DEFAULT_NODES)
    parser.add_argument("--stations", type=Path, default=DEFAULT_STATIONS)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as file:
        return json.load(file)


def distance_metres(first: list[float] | tuple[float, float], second: list[float] | tuple[float, float]) -> float:
    longitude1, latitude1 = map(math.radians, first)
    longitude2, latitude2 = map(math.radians, second)
    latitude_delta = latitude2 - latitude1
    longitude_delta = longitude2 - longitude1
    haversine = (
        math.sin(latitude_delta / 2) ** 2
        + math.cos(latitude1)
        * math.cos(latitude2)
        * math.sin(longitude_delta / 2) ** 2
    )
    return 2 * EARTH_RADIUS_METRES * math.asin(math.sqrt(haversine))


def station_coordinate(station: dict[str, str]) -> tuple[float, float] | None:
    try:
        longitude = station["longitude"].replace(";", ",").split(",", 1)[0].splitlines()[0]
        latitude = station["latitude"].replace(";", ",").split(",", 1)[0].splitlines()[0]
        return float(longitude), float(latitude)
    except (KeyError, TypeError, ValueError, IndexError):
        return None


def validate_feature_collection(document: Any, geometry_type: str, label: str) -> list[dict[str, Any]]:
    if not isinstance(document, dict) or document.get("type") != "FeatureCollection":
        raise ValueError(f"{label} is not a GeoJSON FeatureCollection")
    features = document.get("features")
    if not isinstance(features, list):
        raise ValueError(f"{label} has no features array")

    identifiers: set[str] = set()
    for feature in features:
        identifier = feature.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise ValueError(f"{label} contains a feature without an ID")
        if identifier in identifiers:
            raise ValueError(f"{label} contains duplicate ID {identifier}")
        identifiers.add(identifier)
        if feature.get("properties", {}).get("osid") != identifier:
            raise ValueError(f"{label} feature {identifier} has a mismatched OSID")
        if feature.get("geometry", {}).get("type") != geometry_type:
            raise ValueError(f"{label} feature {identifier} is not a {geometry_type}")
    return features


def link_is_in_scope(feature: dict[str, Any]) -> bool:
    properties = feature["properties"]
    return (
        properties.get("operationalstatus") == "Active"
        and properties.get("description") == "Main Line"
        and "Passenger" in (properties.get("railwayuse") or "")
    )


def connected_component_sizes(node_count: int, edges: list[dict[str, Any]]) -> list[int]:
    adjacency: list[list[int]] = [[] for _ in range(node_count)]
    for edge in edges:
        start = edge["s"]
        end = edge["e"]
        adjacency[start].append(end)
        adjacency[end].append(start)

    seen: set[int] = set()
    sizes: list[int] = []
    for node in range(node_count):
        if node in seen:
            continue
        seen.add(node)
        stack = [node]
        size = 0
        while stack:
            current = stack.pop()
            size += 1
            for neighbour in adjacency[current]:
                if neighbour not in seen:
                    seen.add(neighbour)
                    stack.append(neighbour)
        sizes.append(size)
    return sorted(sizes, reverse=True)


def shortest_distance(
    node_count: int,
    edges: list[dict[str, Any]],
    start: int,
    end: int,
) -> float | None:
    adjacency: list[list[tuple[int, float]]] = [[] for _ in range(node_count)]
    for edge in edges:
        adjacency[edge["s"]].append((edge["e"], edge["l"]))
        adjacency[edge["e"]].append((edge["s"], edge["l"]))

    distances = {start: 0.0}
    queue = [(0.0, start)]
    while queue:
        distance, node = heapq.heappop(queue)
        if distance != distances[node]:
            continue
        if node == end:
            return distance
        for neighbour, edge_length in adjacency[node]:
            candidate = distance + edge_length
            if candidate < distances.get(neighbour, math.inf):
                distances[neighbour] = candidate
                heapq.heappush(queue, (candidate, neighbour))
    return None


def build_asset(args: argparse.Namespace) -> tuple[dict[str, Any], dict[str, Any]]:
    source_links = validate_feature_collection(load_json(args.links), "LineString", "Railway links")
    source_nodes = validate_feature_collection(load_json(args.nodes), "Point", "Railway nodes")
    stations = load_json(args.stations)
    if not isinstance(stations, list):
        raise ValueError("Station catalogue is not an array")

    node_by_id = {node["id"]: node for node in source_nodes}
    filtered_links = [link for link in source_links if link_is_in_scope(link)]
    broken_links = [
        link
        for link in filtered_links
        if link["properties"]["startnode"] not in node_by_id
        or link["properties"]["endnode"] not in node_by_id
    ]
    valid_links = [link for link in filtered_links if link not in broken_links]

    incident_ids = {
        identifier
        for link in valid_links
        for identifier in (
            link["properties"]["startnode"],
            link["properties"]["endnode"],
        )
    }
    ordered_node_ids = sorted(incident_ids)
    node_index = {identifier: index for index, identifier in enumerate(ordered_node_ids)}
    compact_nodes = [node_by_id[identifier]["geometry"]["coordinates"] for identifier in ordered_node_ids]

    compact_edges: list[dict[str, Any]] = []
    for link in sorted(valid_links, key=lambda feature: feature["id"]):
        properties = link["properties"]
        coordinates = link["geometry"]["coordinates"]
        if len(coordinates) < 2:
            raise ValueError(f"Railway link {link['id']} has fewer than two coordinates")
        length = properties.get("geometry_length_m")
        if not isinstance(length, (int, float)) or not math.isfinite(length) or length <= 0:
            raise ValueError(f"Railway link {link['id']} has an invalid length")

        start_coordinate = node_by_id[properties["startnode"]]["geometry"]["coordinates"]
        end_coordinate = node_by_id[properties["endnode"]]["geometry"]["coordinates"]
        if distance_metres(coordinates[0], start_coordinate) > 0.1:
            raise ValueError(f"Railway link {link['id']} does not start at its start node")
        if distance_metres(coordinates[-1], end_coordinate) > 0.1:
            raise ValueError(f"Railway link {link['id']} does not end at its end node")

        compact_edges.append(
            {
                "s": node_index[properties["startnode"]],
                "e": node_index[properties["endnode"]],
                "l": length,
                "p": coordinates,
            }
        )

    station_anchors: dict[str, list[dict[str, float | int]]] = {}
    for station in stations:
        coordinate = station_coordinate(station)
        crs = station.get("crs")
        if coordinate is None or not isinstance(crs, str) or not crs:
            continue
        nearest = sorted(
            (
                distance_metres(coordinate, compact_nodes[index]),
                index,
            )
            for index in range(len(compact_nodes))
        )
        eligible = [candidate for candidate in nearest if candidate[0] <= MAX_ANCHOR_DISTANCE_METRES]
        if eligible:
            station_anchors[crs.upper()] = [
                {"n": index, "d": round(distance, 3)}
                for distance, index in eligible[:ANCHORS_PER_STATION]
            ]

    version_dates = [
        feature["properties"].get("versiondate")
        for feature in source_links + source_nodes
        if feature["properties"].get("versiondate")
    ]
    component_sizes = connected_component_sizes(len(compact_nodes), compact_edges)
    asset = {
        "metadata": {
            "schemaVersion": 1,
            "region": "Greater London POC",
            "sourceVersionMax": max(version_dates),
            "filter": {
                "operationalstatus": "Active",
                "description": "Main Line",
                "railwayuseContains": "Passenger",
            },
        },
        "nodes": compact_nodes,
        "edges": compact_edges,
        "stationAnchors": station_anchors,
    }

    acceptance_distance = None
    if "KTH" in station_anchors and "VIC" in station_anchors:
        acceptance_distance = shortest_distance(
            len(compact_nodes),
            compact_edges,
            int(station_anchors["KTH"][0]["n"]),
            int(station_anchors["VIC"][0]["n"]),
        )
    if acceptance_distance is None or not 10_000 <= acceptance_distance <= 15_000:
        raise ValueError("Kent House to London Victoria acceptance route is unavailable or implausible")

    diagnostics = {
        "sourceLinks": len(source_links),
        "sourceNodes": len(source_nodes),
        "filteredLinks": len(filtered_links),
        "brokenFilteredLinks": len(broken_links),
        "outputEdges": len(compact_edges),
        "outputNodes": len(compact_nodes),
        "stationAnchors": len(station_anchors),
        "connectedComponents": len(component_sizes),
        "largestComponentNodes": component_sizes[0],
        "kentHouseToVictoriaKm": round(acceptance_distance / 1_000, 3),
    }
    return asset, diagnostics


def main() -> None:
    args = parse_args()
    asset, diagnostics = build_asset(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as file:
        json.dump(asset, file, separators=(",", ":"), ensure_ascii=False)
        file.write("\n")
    print(json.dumps(diagnostics, indent=2, sort_keys=True))
    print(f"Wrote {args.output} ({args.output.stat().st_size / 1_000_000:.2f} MB)")


if __name__ == "__main__":
    main()
