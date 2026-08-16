#!/usr/bin/env python3
"""Build and validate a routable Great Britain railway graph from OpenStreetMap."""

from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime as dt
import heapq
import json
import math
import re
from pathlib import Path
from typing import Any, Iterable, Sequence

try:
    import osmium
except ImportError as error:  # pragma: no cover - exercised only outside the dev environment
    raise SystemExit(
        "pyosmium is required. Install scripts/requirements-osm-routing.txt "
        "in scripts/.osm-routing-venv."
    ) from error


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = Path(__file__).resolve().parent
CACHE_DIR = SCRIPT_DIR / ".osm-routing-cache"
DEFAULT_INPUT = CACHE_DIR / "railway-great-britain.osm.pbf"
DEFAULT_STATIONS = ROOT / "api" / "train-track-api" / "resources" / "stations.json"
DEFAULT_ASSET = CACHE_DIR / "railway-routing-great-britain.json"
DEFAULT_GEOJSON = CACHE_DIR / "route-kth-vic.geojson"
DEFAULT_DIAGNOSTICS = CACHE_DIR / "osm-railway-diagnostics.json"
DEFAULT_ROUTE = ("KTH", "PNE", "SYH", "WDU", "HNH", "BRX", "VIC")
KNOWN_ROUTE_REGRESSIONS = (
    (
        "Southern Victoria to Brighton",
        ("VIC", "CLJ", "SRS", "ECR", "PUR", "HOR", "GTW", "TBD", "HHE", "BTN"),
        (80_000, 84_000),
        {("VIC", "CLJ"): 4_600, ("CLJ", "SRS"): 11_500},
    ),
    (
        "Thameslink Bedford to Brighton",
        (
            "BDM", "FLT", "HLN", "LEA", "LUT", "LTN", "HPD", "SAC", "RDT",
            "ELS", "MIL", "HEN", "BCZ", "CRI", "WHP", "KTN", "STP", "BFR",
            "ECR", "PUR", "HOR", "GTW", "TBD", "HHE", "BTN",
        ),
        (163_000, 168_000),
        {("KTN", "STP"): 2_500, ("STP", "BFR"): 4_000},
    ),
)

EARTH_RADIUS_METRES = 6_371_008.8
ANCHOR_ENDPOINT_TOLERANCE_METRES = 0.5
ANCHOR_GROUP_TOLERANCE_METRES = 0.5
CONTINUITY_TOLERANCE_METRES = 0.75
DIAGNOSTIC_TAGS = (
    "railway",
    "usage",
    "service",
    "operator",
    "electrified",
    "tracks",
)
SERVICE_FACTORS = {
    "crossover": 1.15,
    "spur": 1.35,
    "siding": 2.0,
    "yard": 3.0,
}
DISCOURAGED_ANCHOR_SERVICES = frozenset(SERVICE_FACTORS)
ADJACENT_BACKTRACK_FACTOR = 4.0
BACKTRACK_WARNING_METRES = 100.0
USAGE_FACTORS = {
    "tourism": 2.0,
    "industrial": 3.0,
    "military": 3.0,
}

Coordinate = tuple[float, float]
Bounds = tuple[float, float, float, float]


@dataclasses.dataclass(frozen=True)
class OSMWay:
    osm_id: int
    node_ids: tuple[int, ...]
    tags: dict[str, str]


@dataclasses.dataclass(frozen=True)
class StationFeature:
    osm_type: str
    osm_id: int
    coordinate: Coordinate
    tags: dict[str, str]


@dataclasses.dataclass(frozen=True)
class PendingStationRelation:
    osm_id: int
    members: tuple[tuple[str, int], ...]
    tags: dict[str, str]


@dataclasses.dataclass(frozen=True)
class BaseEdge:
    edge_id: int
    way_id: int
    start_osm_node: int
    end_osm_node: int
    length: float
    coordinates: tuple[Coordinate, ...]
    tags: dict[str, str]
    route_relations: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class SegmentReference:
    edge_id: int
    segment_index: int
    start_measure: float
    end_measure: float


@dataclasses.dataclass(frozen=True)
class Projection:
    edge_id: int
    measure: float
    coordinate: Coordinate
    distance: float


@dataclasses.dataclass
class AnchorCandidate:
    crs: str
    edge_id: int
    measure: float
    coordinate: Coordinate
    snap_distance: float
    match_method: str
    station_osm_type: str | None
    station_osm_id: int | None
    graph_node: int | None = None


@dataclasses.dataclass(frozen=True)
class StationMatch:
    crs: str
    name: str
    catalogue_coordinate: Coordinate
    matching_coordinate: Coordinate
    match_method: str
    station_osm_type: str | None
    station_osm_id: int | None
    station_feature_distance: float | None


@dataclasses.dataclass(frozen=True)
class GraphEdge:
    start: int
    end: int
    length: float
    weight: float
    coordinates: tuple[Coordinate, ...]
    way_id: int
    tags: dict[str, str]
    route_relations: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class Traversal:
    edge: int
    start: int
    end: int


@dataclasses.dataclass(frozen=True)
class GraphPath:
    length: float
    cost: float
    traversals: tuple[Traversal, ...]

    def reversed(self) -> "GraphPath":
        return GraphPath(
            length=self.length,
            cost=self.cost,
            traversals=tuple(
                Traversal(edge=value.edge, start=value.end, end=value.start)
                for value in reversed(self.traversals)
            ),
        )


@dataclasses.dataclass
class RailwayGraph:
    nodes: list[Coordinate]
    edges: list[GraphEdge]
    adjacency: list[list[tuple[int, int]]]
    station_anchors: dict[str, list[AnchorCandidate]]
    station_matches: dict[str, StationMatch]
    components: list[int]


@dataclasses.dataclass(frozen=True)
class RouteChoice:
    score: float
    previous_candidate: int | None
    incoming_path: GraphPath | None


@dataclasses.dataclass(frozen=True)
class RouteResult:
    calling_points: tuple[str, ...]
    coordinates: tuple[Coordinate, ...]
    cumulative_distances: tuple[float, ...]
    station_coordinate_indices: tuple[int, ...]
    selected_anchors: tuple[AnchorCandidate, ...]
    segment_paths: tuple[GraphPath, ...]

    @property
    def total_length(self) -> float:
        return self.cumulative_distances[-1] if self.cumulative_distances else 0


class RailwayDataHandler(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.node_coordinates: dict[int, Coordinate] = {}
        self.ways: list[OSMWay] = []
        self.way_centroids: dict[int, Coordinate] = {}
        self.station_features: list[StationFeature] = []
        self.pending_station_relations: list[PendingStationRelation] = []
        self.way_relations: dict[int, list[str]] = collections.defaultdict(list)
        self.tag_counts: dict[str, collections.Counter[str]] = {
            key: collections.Counter() for key in DIAGNOSTIC_TAGS
        }
        self.invalid_railway_ways = 0

    def node(self, node: Any) -> None:
        if not node.location.valid():
            return
        coordinate = (node.location.lon, node.location.lat)
        self.node_coordinates[node.id] = coordinate
        tags = dict(node.tags)
        if is_station_feature(tags):
            self.station_features.append(
                StationFeature("node", node.id, coordinate, tags)
            )

    def way(self, way: Any) -> None:
        tags = dict(way.tags)
        node_ids = tuple(reference.ref for reference in way.nodes)
        coordinates = tuple(
            self.node_coordinates[node_id]
            for node_id in node_ids
            if node_id in self.node_coordinates
        )
        if coordinates:
            self.way_centroids[way.id] = mean_coordinate(coordinates)

        if tags.get("railway") == "rail":
            if len(node_ids) < 2 or len(coordinates) != len(node_ids):
                self.invalid_railway_ways += 1
            else:
                self.ways.append(OSMWay(way.id, node_ids, tags))
                for key in DIAGNOSTIC_TAGS:
                    self.tag_counts[key][tags.get(key, "(missing)")] += 1

        if is_station_feature(tags) and coordinates:
            self.station_features.append(
                StationFeature("way", way.id, mean_coordinate(coordinates), tags)
            )

    def relation(self, relation: Any) -> None:
        tags = dict(relation.tags)
        members = tuple((member.type, member.ref) for member in relation.members)
        if is_station_feature(tags):
            self.pending_station_relations.append(
                PendingStationRelation(relation.id, members, tags)
            )

        route_type = tags.get("route")
        if tags.get("type") == "route" and route_type in {"train", "railway", "tracks"}:
            label = f"{route_type}:{relation.id}"
            for member_type, member_id in members:
                if member_type == "w":
                    self.way_relations[member_id].append(label)

    def resolve_station_relations(self) -> None:
        for relation in self.pending_station_relations:
            coordinates: list[Coordinate] = []
            for member_type, member_id in relation.members:
                if member_type == "n" and member_id in self.node_coordinates:
                    coordinates.append(self.node_coordinates[member_id])
                elif member_type == "w" and member_id in self.way_centroids:
                    coordinates.append(self.way_centroids[member_id])
            if coordinates:
                self.station_features.append(
                    StationFeature(
                        "relation",
                        relation.osm_id,
                        mean_coordinate(coordinates),
                        relation.tags,
                    )
                )


class SegmentSpatialIndex:
    def __init__(self, edges: Sequence[BaseEdge], cell_size: float = 0.01) -> None:
        self.edges = edges
        self.cell_size = cell_size
        self.cells: dict[tuple[int, int], list[SegmentReference]] = collections.defaultdict(list)
        for edge in edges:
            measure = 0.0
            for segment_index in range(len(edge.coordinates) - 1):
                start = edge.coordinates[segment_index]
                end = edge.coordinates[segment_index + 1]
                segment_length = distance_metres(start, end)
                reference = SegmentReference(
                    edge_id=edge.edge_id,
                    segment_index=segment_index,
                    start_measure=measure,
                    end_measure=measure + segment_length,
                )
                measure += segment_length
                for cell in self._cells_for_bounds(start, end):
                    self.cells[cell].append(reference)

    def nearest(
        self,
        coordinate: Coordinate,
        maximum_distance: float,
    ) -> list[Projection]:
        longitude, latitude = coordinate
        latitude_radius = maximum_distance / 110_574
        longitude_scale = max(20_000, 111_320 * math.cos(math.radians(latitude)))
        longitude_radius = maximum_distance / longitude_scale
        minimum = (longitude - longitude_radius, latitude - latitude_radius)
        maximum = (longitude + longitude_radius, latitude + latitude_radius)

        references: set[SegmentReference] = set()
        for cell in self._cells_for_bounds(minimum, maximum):
            references.update(self.cells.get(cell, ()))

        nearest_by_edge: dict[int, Projection] = {}
        for reference in references:
            edge = self.edges[reference.edge_id]
            start = edge.coordinates[reference.segment_index]
            end = edge.coordinates[reference.segment_index + 1]
            projected, fraction, distance = project_onto_segment(coordinate, start, end)
            if distance > maximum_distance:
                continue
            measure = reference.start_measure + (
                (reference.end_measure - reference.start_measure) * fraction
            )
            candidate = Projection(reference.edge_id, measure, projected, distance)
            current = nearest_by_edge.get(reference.edge_id)
            if current is None or candidate.distance < current.distance:
                nearest_by_edge[reference.edge_id] = candidate
        return sorted(nearest_by_edge.values(), key=lambda value: value.distance)

    def _cells_for_bounds(
        self,
        first: Coordinate,
        second: Coordinate,
    ) -> Iterable[tuple[int, int]]:
        minimum_longitude, maximum_longitude = sorted((first[0], second[0]))
        minimum_latitude, maximum_latitude = sorted((first[1], second[1]))
        minimum_x = math.floor(minimum_longitude / self.cell_size)
        maximum_x = math.floor(maximum_longitude / self.cell_size)
        minimum_y = math.floor(minimum_latitude / self.cell_size)
        maximum_y = math.floor(maximum_latitude / self.cell_size)
        for x in range(minimum_x, maximum_x + 1):
            for y in range(minimum_y, maximum_y + 1):
                yield x, y


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a compact OSM railway graph and route a calling pattern."
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--stations", type=Path, default=DEFAULT_STATIONS)
    parser.add_argument("--asset-output", type=Path, default=DEFAULT_ASSET)
    parser.add_argument(
        "--asset-bounds",
        type=float,
        nargs=4,
        metavar=("WEST", "SOUTH", "EAST", "NORTH"),
        help="Limit the generated asset to edges intersecting these bounds.",
    )
    parser.add_argument(
        "--asset-region",
        default="Great Britain",
        help="Human-readable region stored in the generated asset metadata.",
    )
    parser.add_argument("--geojson-output", type=Path, default=DEFAULT_GEOJSON)
    parser.add_argument("--diagnostics-output", type=Path, default=DEFAULT_DIAGNOSTICS)
    parser.add_argument(
        "--route",
        default=",".join(DEFAULT_ROUTE),
        help="Comma-separated CRS calling pattern.",
    )
    parser.add_argument("--anchors-per-station", type=int, default=4)
    parser.add_argument("--max-anchor-distance", type=float, default=1_000)
    parser.add_argument("--location-index", default="flex_mem")
    parser.add_argument(
        "--skip-asset",
        action="store_true",
        help="Run routing diagnostics without writing the full compact graph.",
    )
    return parser.parse_args()


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z")


def distance_metres(first: Coordinate, second: Coordinate) -> float:
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


def polyline_length(coordinates: Sequence[Coordinate]) -> float:
    return sum(
        distance_metres(coordinates[index - 1], coordinates[index])
        for index in range(1, len(coordinates))
    )


def mean_coordinate(coordinates: Sequence[Coordinate]) -> Coordinate:
    return (
        sum(value[0] for value in coordinates) / len(coordinates),
        sum(value[1] for value in coordinates) / len(coordinates),
    )


def project_onto_segment(
    point: Coordinate,
    start: Coordinate,
    end: Coordinate,
) -> tuple[Coordinate, float, float]:
    longitude_scale = 111_320 * math.cos(math.radians(point[1]))
    latitude_scale = 110_574
    start_x = (start[0] - point[0]) * longitude_scale
    start_y = (start[1] - point[1]) * latitude_scale
    end_x = (end[0] - point[0]) * longitude_scale
    end_y = (end[1] - point[1]) * latitude_scale
    delta_x = end_x - start_x
    delta_y = end_y - start_y
    denominator = (delta_x * delta_x) + (delta_y * delta_y)
    fraction = 0.0 if denominator == 0 else -(start_x * delta_x + start_y * delta_y) / denominator
    fraction = min(max(fraction, 0.0), 1.0)
    projected = (
        start[0] + ((end[0] - start[0]) * fraction),
        start[1] + ((end[1] - start[1]) * fraction),
    )
    return projected, fraction, distance_metres(point, projected)


def coordinate_at_measure(
    coordinates: Sequence[Coordinate],
    measure: float,
) -> Coordinate:
    if measure <= 0:
        return coordinates[0]
    total = polyline_length(coordinates)
    if measure >= total:
        return coordinates[-1]
    current = 0.0
    for index in range(1, len(coordinates)):
        start = coordinates[index - 1]
        end = coordinates[index]
        length = distance_metres(start, end)
        if current + length >= measure:
            fraction = 0.0 if length == 0 else (measure - current) / length
            return (
                start[0] + ((end[0] - start[0]) * fraction),
                start[1] + ((end[1] - start[1]) * fraction),
            )
        current += length
    return coordinates[-1]


def polyline_slice(
    coordinates: Sequence[Coordinate],
    start_measure: float,
    end_measure: float,
) -> tuple[Coordinate, ...]:
    if end_measure <= start_measure:
        return ()
    start_coordinate = coordinate_at_measure(coordinates, start_measure)
    end_coordinate = coordinate_at_measure(coordinates, end_measure)
    output = [start_coordinate]
    current = 0.0
    for index in range(1, len(coordinates)):
        current += distance_metres(coordinates[index - 1], coordinates[index])
        if start_measure + 0.001 < current < end_measure - 0.001:
            if distance_metres(output[-1], coordinates[index]) > 0.001:
                output.append(coordinates[index])
    if distance_metres(output[-1], end_coordinate) > 0.001:
        output.append(end_coordinate)
    return tuple(output)


def is_station_feature(tags: dict[str, str]) -> bool:
    return (
        tags.get("railway") in {"station", "halt"}
        or tags.get("public_transport") in {"station", "stop_area"}
    )


def normalize_name(value: str) -> str:
    return " ".join(re.findall(r"[a-z0-9]+", value.casefold()))


def crs_codes(tags: dict[str, str]) -> set[str]:
    raw = tags.get("ref:crs", "")
    return {
        value.upper()
        for value in re.split(r"[^A-Za-z0-9]+", raw)
        if len(value) == 3
    }


def station_coordinate(station: dict[str, Any]) -> Coordinate | None:
    try:
        longitudes = re.split(r"[,;\n]+", station["longitude"])
        latitudes = re.split(r"[,;\n]+", station["latitude"])
        for longitude, latitude in zip(longitudes, latitudes):
            coordinate = (float(longitude.strip()), float(latitude.strip()))
            if coordinate != (0.0, 0.0):
                return coordinate
    except (KeyError, TypeError, ValueError):
        return None
    return None


def edge_weight_factor(tags: dict[str, str]) -> float:
    return max(
        SERVICE_FACTORS.get(tags.get("service", ""), 1.0),
        USAGE_FACTORS.get(tags.get("usage", ""), 1.0),
    )


def read_header_timestamp(path: Path) -> str | None:
    with osmium.io.Reader(str(path), osmium.osm.NOTHING) as reader:
        value = reader.header().get("osmosis_replication_timestamp")
    return value or None


def read_osm(path: Path, location_index: str) -> RailwayDataHandler:
    if not path.is_file():
        raise FileNotFoundError(f"Filtered OSM input is unavailable: {path}")
    handler = RailwayDataHandler()
    print(f"Reading {path}")
    handler.apply_file(str(path), locations=True, idx=location_index)
    handler.resolve_station_relations()
    print(
        f"Read {len(handler.ways):,} railway ways, "
        f"{len(handler.node_coordinates):,} referenced nodes, and "
        f"{len(handler.station_features):,} station features"
    )
    return handler


def build_base_edges(handler: RailwayDataHandler) -> list[BaseEdge]:
    node_usage = collections.Counter(
        node_id for way in handler.ways for node_id in way.node_ids
    )
    edges: list[BaseEdge] = []
    for way in sorted(handler.ways, key=lambda value: value.osm_id):
        breakpoints = [0]
        breakpoints.extend(
            index
            for index in range(1, len(way.node_ids) - 1)
            if node_usage[way.node_ids[index]] > 1
        )
        breakpoints.append(len(way.node_ids) - 1)
        for start_index, end_index in zip(breakpoints, breakpoints[1:]):
            if end_index <= start_index:
                continue
            node_ids = way.node_ids[start_index : end_index + 1]
            coordinates = tuple(handler.node_coordinates[node_id] for node_id in node_ids)
            length = polyline_length(coordinates)
            if length <= 0:
                continue
            edges.append(
                BaseEdge(
                    edge_id=len(edges),
                    way_id=way.osm_id,
                    start_osm_node=node_ids[0],
                    end_osm_node=node_ids[-1],
                    length=length,
                    coordinates=coordinates,
                    tags=way.tags,
                    route_relations=tuple(handler.way_relations.get(way.osm_id, ())),
                )
            )
    print(f"Built {len(edges):,} topology-preserving base edges")
    return edges


def load_station_catalogue(path: Path) -> list[dict[str, Any]]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, list):
        raise ValueError("Station catalogue must be a JSON array")
    return [station for station in value if isinstance(station, dict)]


def station_feature_score(feature: StationFeature) -> int:
    network = feature.tags.get("network", "").casefold()
    operator = feature.tags.get("operator", "").casefold()
    score = 0
    if "national rail" in network:
        score += 100
    if feature.tags.get("railway") == "station":
        score += 25
    if feature.tags.get("public_transport") == "station":
        score += 10
    if "underground" in network or "tram" in network or "metro" in network:
        score -= 100
    if "underground" in operator or "tram" in operator:
        score -= 50
    return score


def select_station_feature(
    station: dict[str, Any],
    coordinate: Coordinate,
    features_by_crs: dict[str, list[StationFeature]],
    features_by_name: dict[str, list[StationFeature]],
) -> tuple[StationFeature | None, str, float | None]:
    crs = str(station.get("crs", "")).upper()
    exact = features_by_crs.get(crs, [])
    method = "ref:crs"
    candidates = exact
    if not candidates:
        method = "name"
        candidates = features_by_name.get(normalize_name(str(station.get("name", ""))), [])
    if not candidates:
        return None, "catalogue-coordinate", None

    ranked = sorted(
        candidates,
        key=lambda feature: (
            -station_feature_score(feature),
            distance_metres(coordinate, feature.coordinate),
            feature.osm_type,
            feature.osm_id,
        ),
    )
    selected = ranked[0]
    separation = distance_metres(coordinate, selected.coordinate)
    if separation > 2_000:
        return None, "catalogue-coordinate", separation
    return selected, method, separation


def select_diverse_projections(
    projections: Sequence[Projection],
    edges: Sequence[BaseEdge],
    count: int,
) -> list[Projection]:
    if count <= 0:
        return []

    passenger_projections = [
        projection
        for projection in projections
        if edges[projection.edge_id].tags.get("service", "")
        not in DISCOURAGED_ANCHOR_SERVICES
    ]
    preferred = passenger_projections or list(projections)
    grouped: dict[tuple[str, str], list[Projection]] = collections.defaultdict(list)
    for projection in preferred:
        grouped[projection_corridor_key(projection, edges)].append(projection)
    groups = sorted(
        (
            sorted(values, key=lambda value: value.distance)
            for values in grouped.values()
        ),
        key=lambda values: values[0].distance,
    )

    selected: list[Projection] = []
    candidate_index = 0
    while len(selected) < count:
        added = False
        for values in groups:
            if candidate_index >= len(values):
                continue
            selected.append(values[candidate_index])
            added = True
            if len(selected) == count:
                return selected
        if not added:
            break
        candidate_index += 1

    selected_edges = {value.edge_id for value in selected}
    for projection in projections:
        if projection.edge_id in selected_edges:
            continue
        selected.append(projection)
        selected_edges.add(projection.edge_id)
        if len(selected) == count:
            break
    return selected


def projection_corridor_key(
    projection: Projection,
    edges: Sequence[BaseEdge],
) -> tuple[str, str]:
    edge = edges[projection.edge_id]
    reference = edge.tags.get("ref", "").strip().upper()
    if reference:
        return ("ref", reference)
    name = normalize_name(edge.tags.get("name", ""))
    if name:
        return ("name", name)
    infrastructure_relations = sorted(
        relation
        for relation in edge.route_relations
        if relation.startswith(("railway:", "tracks:"))
    )
    if infrastructure_relations:
        return ("relation", infrastructure_relations[0])
    return ("unclassified", edge.tags.get("usage", ""))


def merge_nearest_projections(
    projection_groups: Iterable[Sequence[Projection]],
) -> list[Projection]:
    nearest_by_edge: dict[int, Projection] = {}
    for projections in projection_groups:
        for projection in projections:
            current = nearest_by_edge.get(projection.edge_id)
            if current is None or projection.distance < current.distance:
                nearest_by_edge[projection.edge_id] = projection
    return sorted(nearest_by_edge.values(), key=lambda value: value.distance)


def build_station_anchors(
    stations: Sequence[dict[str, Any]],
    features: Sequence[StationFeature],
    edges: Sequence[BaseEdge],
    anchors_per_station: int,
    maximum_distance: float,
) -> tuple[dict[str, list[AnchorCandidate]], dict[str, StationMatch]]:
    features_by_crs: dict[str, list[StationFeature]] = collections.defaultdict(list)
    features_by_name: dict[str, list[StationFeature]] = collections.defaultdict(list)
    for feature in features:
        for crs in crs_codes(feature.tags):
            features_by_crs[crs].append(feature)
        name = normalize_name(feature.tags.get("name", ""))
        if name:
            features_by_name[name].append(feature)

    print("Building railway segment spatial index")
    spatial_index = SegmentSpatialIndex(edges)
    anchors: dict[str, list[AnchorCandidate]] = {}
    matches: dict[str, StationMatch] = {}
    for station in stations:
        crs = str(station.get("crs", "")).strip().upper()
        name = str(station.get("name", crs)).strip()
        catalogue_coordinate = station_coordinate(station)
        if not crs or catalogue_coordinate is None:
            continue
        feature, match_method, feature_distance = select_station_feature(
            station,
            catalogue_coordinate,
            features_by_crs,
            features_by_name,
        )
        matching_coordinate = feature.coordinate if feature else catalogue_coordinate
        projection_origins = (matching_coordinate,)
        if catalogue_coordinate != matching_coordinate:
            projection_origins += (catalogue_coordinate,)
        projections = merge_nearest_projections(
            spatial_index.nearest(coordinate, maximum_distance)
            for coordinate in projection_origins
        )
        selected = select_diverse_projections(projections, edges, anchors_per_station)
        if not selected:
            continue
        if feature is not None and matching_coordinate != catalogue_coordinate:
            match_method = f"{match_method}+catalogue-coordinate"
        anchors[crs] = [
            AnchorCandidate(
                crs=crs,
                edge_id=projection.edge_id,
                measure=projection.measure,
                coordinate=projection.coordinate,
                snap_distance=projection.distance,
                match_method=match_method,
                station_osm_type=feature.osm_type if feature else None,
                station_osm_id=feature.osm_id if feature else None,
            )
            for projection in selected
        ]
        matches[crs] = StationMatch(
            crs=crs,
            name=name,
            catalogue_coordinate=catalogue_coordinate,
            matching_coordinate=matching_coordinate,
            match_method=match_method,
            station_osm_type=feature.osm_type if feature else None,
            station_osm_id=feature.osm_id if feature else None,
            station_feature_distance=feature_distance,
        )
    print(f"Anchored {len(anchors):,} of {len(stations):,} catalogue stations")
    return anchors, matches


def grouped_anchor_measures(
    candidates: Sequence[AnchorCandidate],
) -> list[tuple[float, list[AnchorCandidate]]]:
    groups: list[tuple[float, list[AnchorCandidate]]] = []
    for candidate in sorted(candidates, key=lambda value: value.measure):
        if groups and candidate.measure - groups[-1][0] <= ANCHOR_GROUP_TOLERANCE_METRES:
            measure, values = groups[-1]
            values.append(candidate)
            groups[-1] = (
                sum(value.measure for value in values) / len(values),
                values,
            )
        else:
            groups.append((candidate.measure, [candidate]))
    return groups


def connected_components(
    nodes: Sequence[Coordinate],
    adjacency: Sequence[Sequence[tuple[int, int]]],
) -> list[int]:
    components = [-1] * len(nodes)
    component = 0
    for start in range(len(nodes)):
        if components[start] != -1:
            continue
        components[start] = component
        stack = [start]
        while stack:
            node = stack.pop()
            for neighbour, _ in adjacency[node]:
                if components[neighbour] == -1:
                    components[neighbour] = component
                    stack.append(neighbour)
        component += 1
    return components


def build_graph(
    base_edges: Sequence[BaseEdge],
    station_anchors: dict[str, list[AnchorCandidate]],
    station_matches: dict[str, StationMatch],
) -> RailwayGraph:
    base_node_ids = sorted(
        {
            node_id
            for edge in base_edges
            for node_id in (edge.start_osm_node, edge.end_osm_node)
        }
    )
    base_coordinate_by_id: dict[int, Coordinate] = {}
    for edge in base_edges:
        base_coordinate_by_id[edge.start_osm_node] = edge.coordinates[0]
        base_coordinate_by_id[edge.end_osm_node] = edge.coordinates[-1]
    nodes = [base_coordinate_by_id[node_id] for node_id in base_node_ids]
    node_index = {node_id: index for index, node_id in enumerate(base_node_ids)}

    anchors_by_edge: dict[int, list[AnchorCandidate]] = collections.defaultdict(list)
    for candidates in station_anchors.values():
        for candidate in candidates:
            anchors_by_edge[candidate.edge_id].append(candidate)

    graph_edges: list[GraphEdge] = []
    for base_edge in base_edges:
        start_node = node_index[base_edge.start_osm_node]
        end_node = node_index[base_edge.end_osm_node]
        boundaries: list[tuple[float, int]] = [(0.0, start_node)]
        for measure, candidates in grouped_anchor_measures(
            anchors_by_edge.get(base_edge.edge_id, ())
        ):
            if measure <= ANCHOR_ENDPOINT_TOLERANCE_METRES:
                anchor_node = start_node
                measure = 0.0
            elif base_edge.length - measure <= ANCHOR_ENDPOINT_TOLERANCE_METRES:
                anchor_node = end_node
                measure = base_edge.length
            else:
                coordinate = coordinate_at_measure(base_edge.coordinates, measure)
                anchor_node = len(nodes)
                nodes.append(coordinate)
                boundaries.append((measure, anchor_node))
            for candidate in candidates:
                candidate.graph_node = anchor_node
        boundaries.append((base_edge.length, end_node))
        boundaries = sorted(set(boundaries), key=lambda value: value[0])

        factor = edge_weight_factor(base_edge.tags)
        for (start_measure, split_start), (end_measure, split_end) in zip(
            boundaries, boundaries[1:]
        ):
            length = end_measure - start_measure
            if length <= 0.001:
                continue
            coordinates = polyline_slice(
                base_edge.coordinates,
                start_measure,
                end_measure,
            )
            if len(coordinates) < 2:
                continue
            graph_edges.append(
                GraphEdge(
                    start=split_start,
                    end=split_end,
                    length=length,
                    weight=length * factor,
                    coordinates=coordinates,
                    way_id=base_edge.way_id,
                    tags=base_edge.tags,
                    route_relations=base_edge.route_relations,
                )
            )

    adjacency: list[list[tuple[int, int]]] = [[] for _ in nodes]
    for edge_index, edge in enumerate(graph_edges):
        adjacency[edge.start].append((edge.end, edge_index))
        adjacency[edge.end].append((edge.start, edge_index))
    components = connected_components(nodes, adjacency)
    print(
        f"Built graph with {len(nodes):,} nodes, {len(graph_edges):,} edges, "
        f"and {len(set(components)):,} connected components"
    )
    return RailwayGraph(
        nodes=nodes,
        edges=graph_edges,
        adjacency=adjacency,
        station_anchors=station_anchors,
        station_matches=station_matches,
        components=components,
    )


def shortest_path(
    graph: RailwayGraph,
    start: int,
    end: int,
    cache: dict[tuple[int, int], GraphPath | None],
) -> GraphPath | None:
    if start == end:
        return GraphPath(0.0, 0.0, ())
    key = (start, end)
    if key in cache:
        return cache[key]
    if graph.components[start] != graph.components[end]:
        cache[key] = None
        return None

    costs = {start: 0.0}
    previous: dict[int, tuple[int, int]] = {}
    queue = [(distance_metres(graph.nodes[start], graph.nodes[end]), start)]
    while queue:
        priority, node = heapq.heappop(queue)
        expected = costs[node] + distance_metres(graph.nodes[node], graph.nodes[end])
        if priority > expected + 0.001:
            continue
        if node == end:
            break
        for neighbour, edge_index in graph.adjacency[node]:
            edge = graph.edges[edge_index]
            candidate = costs[node] + edge.weight
            if candidate < costs.get(neighbour, math.inf):
                costs[neighbour] = candidate
                previous[neighbour] = (node, edge_index)
                heapq.heappush(
                    queue,
                    (
                        candidate
                        + distance_metres(graph.nodes[neighbour], graph.nodes[end]),
                        neighbour,
                    ),
                )
    if end not in costs:
        cache[key] = None
        return None

    traversals: list[Traversal] = []
    current = end
    length = 0.0
    while current != start:
        previous_node, edge_index = previous[current]
        traversals.append(Traversal(edge_index, previous_node, current))
        length += graph.edges[edge_index].length
        current = previous_node
    traversals.reverse()
    result = GraphPath(length, costs[end], tuple(traversals))
    cache[key] = result
    cache[(end, start)] = result.reversed()
    return result


def shared_path_length(
    graph: RailwayGraph,
    first: GraphPath | None,
    second: GraphPath,
) -> float:
    if first is None:
        return 0.0
    first_edges = {value.edge for value in first.traversals}
    second_edges = {value.edge for value in second.traversals}
    return sum(graph.edges[index].length for index in first_edges & second_edges)


def merge_route(
    graph: RailwayGraph,
    calling_points: Sequence[str],
    selected_anchors: Sequence[AnchorCandidate],
    paths: Sequence[GraphPath],
) -> RouteResult:
    first_node = selected_anchors[0].graph_node
    if first_node is None:
        raise ValueError("Selected station anchor has no graph node")
    coordinates = [graph.nodes[first_node]]
    station_indices = [0]
    for path in paths:
        for traversal in path.traversals:
            edge = graph.edges[traversal.edge]
            if traversal.start == edge.start and traversal.end == edge.end:
                incoming = edge.coordinates
            elif traversal.start == edge.end and traversal.end == edge.start:
                incoming = tuple(reversed(edge.coordinates))
            else:
                raise ValueError("Route traversal does not match its graph edge")
            if distance_metres(coordinates[-1], incoming[0]) > CONTINUITY_TOLERANCE_METRES:
                raise ValueError("Routed edge geometries are not continuous")
            coordinates.extend(incoming[1:])
        station_indices.append(len(coordinates) - 1)

    cumulative = [0.0]
    for index in range(1, len(coordinates)):
        cumulative.append(
            cumulative[-1] + distance_metres(coordinates[index - 1], coordinates[index])
        )
    return RouteResult(
        calling_points=tuple(calling_points),
        coordinates=tuple(coordinates),
        cumulative_distances=tuple(cumulative),
        station_coordinate_indices=tuple(station_indices),
        selected_anchors=tuple(selected_anchors),
        segment_paths=tuple(paths),
    )


def route_calling_pattern(
    graph: RailwayGraph,
    calling_points: Sequence[str],
) -> RouteResult:
    normalized = tuple(value.strip().upper() for value in calling_points if value.strip())
    if len(normalized) < 2:
        raise ValueError("At least two calling points are required")
    candidate_layers: list[list[AnchorCandidate]] = []
    for crs in normalized:
        candidates = [
            candidate
            for candidate in graph.station_anchors.get(crs, ())
            if candidate.graph_node is not None
        ]
        if not candidates:
            raise ValueError(f"Station {crs} has no railway anchor")
        candidate_layers.append(candidates)

    route_layers: list[list[RouteChoice | None]] = [
        [RouteChoice(candidate.snap_distance * 2, None, None) for candidate in candidate_layers[0]]
    ]
    path_cache: dict[tuple[int, int], GraphPath | None] = {}
    for station_index in range(1, len(candidate_layers)):
        choices: list[RouteChoice | None] = [None] * len(candidate_layers[station_index])
        for next_index, next_candidate in enumerate(candidate_layers[station_index]):
            best: RouteChoice | None = None
            for previous_index, previous_candidate in enumerate(
                candidate_layers[station_index - 1]
            ):
                previous_choice = route_layers[station_index - 1][previous_index]
                if previous_choice is None:
                    continue
                path = shortest_path(
                    graph,
                    int(previous_candidate.graph_node),
                    int(next_candidate.graph_node),
                    path_cache,
                )
                if path is None:
                    continue
                backtrack = shared_path_length(
                    graph,
                    previous_choice.incoming_path,
                    path,
                )
                score = (
                    previous_choice.score
                    + path.cost
                    + (next_candidate.snap_distance * 2)
                    + (backtrack * ADJACENT_BACKTRACK_FACTOR)
                )
                if best is None or score < best.score:
                    best = RouteChoice(score, previous_index, path)
            choices[next_index] = best
        if not any(choice is not None for choice in choices):
            raise ValueError(
                f"No route is available from {normalized[station_index - 1]} "
                f"to {normalized[station_index]}"
            )
        route_layers.append(choices)

    final_index, _ = min(
        (
            (index, choice)
            for index, choice in enumerate(route_layers[-1])
            if choice is not None
        ),
        key=lambda value: value[1].score,
    )
    selected: list[AnchorCandidate | None] = [None] * len(normalized)
    paths: list[GraphPath | None] = [None] * (len(normalized) - 1)
    candidate_index = final_index
    selected[-1] = candidate_layers[-1][candidate_index]
    for station_index in range(len(normalized) - 1, 0, -1):
        choice = route_layers[station_index][candidate_index]
        if choice is None or choice.previous_candidate is None or choice.incoming_path is None:
            raise ValueError("Route candidate backtracking failed")
        paths[station_index - 1] = choice.incoming_path
        candidate_index = choice.previous_candidate
        selected[station_index - 1] = candidate_layers[station_index - 1][candidate_index]
    return merge_route(
        graph,
        normalized,
        [value for value in selected if value is not None],
        [value for value in paths if value is not None],
    )


def rounded_coordinate(value: Coordinate) -> list[float]:
    return [round(value[0], 7), round(value[1], 7)]


def edge_intersects_bounds(edge: GraphEdge, bounds: Bounds) -> bool:
    west, south, east, north = bounds
    longitudes = [coordinate[0] for coordinate in edge.coordinates]
    latitudes = [coordinate[1] for coordinate in edge.coordinates]
    return not (
        max(longitudes) < west
        or min(longitudes) > east
        or max(latitudes) < south
        or min(latitudes) > north
    )


def source_metadata(input_path: Path) -> dict[str, Any]:
    metadata_path = input_path.with_suffix(input_path.suffix + ".metadata.json")
    if not metadata_path.exists():
        return {}
    value = json.loads(metadata_path.read_text(encoding="utf-8"))
    return value if isinstance(value, dict) else {}


def graph_asset(
    graph: RailwayGraph,
    input_path: Path,
    region: str = "Great Britain",
    bounds: Bounds | None = None,
) -> dict[str, Any]:
    metadata = source_metadata(input_path)
    selected_edges = (
        graph.edges
        if bounds is None
        else [edge for edge in graph.edges if edge_intersects_bounds(edge, bounds)]
    )
    if bounds is None:
        selected_node_ids = list(range(len(graph.nodes)))
    else:
        selected_node_ids = sorted(
            {
                node
                for edge in selected_edges
                for node in (edge.start, edge.end)
            }
        )
    node_index = {
        source_node: output_node
        for output_node, source_node in enumerate(selected_node_ids)
    }
    asset_metadata: dict[str, Any] = {
        "schemaVersion": 1,
        "region": region,
        "source": "OpenStreetMap",
        "sourceVersionMax": read_header_timestamp(input_path)
        or metadata.get("generatedAt"),
        "license": "ODbL-1.0",
        "attribution": "© OpenStreetMap contributors",
        "sourceMetadata": metadata,
        "filter": {
            "railway": "rail",
            "directionality": "bidirectional MVP",
            "serviceTracks": "retained with routing penalties",
            "stationAnchors": (
                "corridor-diverse passenger tracks near both OSM and catalogue coordinates"
            ),
            "adjacentBacktracking": "penalized during calling-pattern routing",
        },
    }
    if bounds is not None:
        asset_metadata["coverageBounds"] = list(bounds)
    return {
        "metadata": asset_metadata,
        "nodes": [rounded_coordinate(graph.nodes[index]) for index in selected_node_ids],
        "edges": [
            {
                "s": node_index[edge.start],
                "e": node_index[edge.end],
                "l": round(edge.length, 3),
                "c": round(edge.weight, 3),
                "p": [rounded_coordinate(value) for value in edge.coordinates],
            }
            for edge in selected_edges
        ],
        "stationAnchors": {
            crs: [
                {
                    "n": node_index[int(candidate.graph_node)],
                    "d": round(candidate.snap_distance, 3),
                }
                for candidate in candidates
                if candidate.graph_node is not None
                and candidate.graph_node in node_index
            ]
            for crs, candidates in sorted(graph.station_anchors.items())
            if any(
                candidate.graph_node is not None
                and candidate.graph_node in node_index
                for candidate in candidates
            )
        },
    }


def route_geojson(graph: RailwayGraph, route: RouteResult) -> dict[str, Any]:
    features: list[dict[str, Any]] = [
        {
            "type": "Feature",
            "id": "route",
            "properties": {
                "callingPattern": list(route.calling_points),
                "totalDistanceMetres": round(route.total_length, 3),
                "estimated": True,
                "source": "OpenStreetMap",
                "attribution": "© OpenStreetMap contributors",
            },
            "geometry": {
                "type": "LineString",
                "coordinates": [rounded_coordinate(value) for value in route.coordinates],
            },
        }
    ]
    for index, (crs, anchor, coordinate_index) in enumerate(
        zip(
            route.calling_points,
            route.selected_anchors,
            route.station_coordinate_indices,
        )
    ):
        match = graph.station_matches[crs]
        features.append(
            {
                "type": "Feature",
                "id": f"station-{index}-{crs}",
                "properties": {
                    "index": index,
                    "crs": crs,
                    "name": match.name,
                    "distanceAlongRouteMetres": round(
                        route.cumulative_distances[coordinate_index], 3
                    ),
                    "snapDistanceMetres": round(anchor.snap_distance, 3),
                    "matchMethod": anchor.match_method,
                    "osmStationType": anchor.station_osm_type,
                    "osmStationID": anchor.station_osm_id,
                },
                "geometry": {
                    "type": "Point",
                    "coordinates": rounded_coordinate(route.coordinates[coordinate_index]),
                },
            }
        )
    return {"type": "FeatureCollection", "features": features}


def segment_diagnostics(
    graph: RailwayGraph,
    route: RouteResult,
) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for index, path in enumerate(route.segment_paths):
        edges = [graph.edges[value.edge] for value in path.traversals]
        previous_path = route.segment_paths[index - 1] if index > 0 else None
        service_counts = collections.Counter(
            edge.tags.get("service", "(missing)") for edge in edges
        )
        usage_counts = collections.Counter(
            edge.tags.get("usage", "(missing)") for edge in edges
        )
        output.append(
            {
                "from": route.calling_points[index],
                "to": route.calling_points[index + 1],
                "distanceMetres": round(path.length, 3),
                "weightedCost": round(path.cost, 3),
                "graphEdges": len(path.traversals),
                "osmWays": len({edge.way_id for edge in edges}),
                "service": dict(sorted(service_counts.items())),
                "usage": dict(sorted(usage_counts.items())),
                "routeRelationEdges": sum(bool(edge.route_relations) for edge in edges),
                "overlapWithPreviousMetres": round(
                    shared_path_length(graph, previous_path, path),
                    3,
                ),
            }
        )
    return output


def diagnostics_document(
    handler: RailwayDataHandler,
    base_edges: Sequence[BaseEdge],
    graph: RailwayGraph,
    station_count: int,
    route: RouteResult,
    input_path: Path,
) -> dict[str, Any]:
    component_sizes = collections.Counter(graph.components)
    warnings = []
    for crs, anchor in zip(route.calling_points, route.selected_anchors):
        if anchor.snap_distance > 200:
            warnings.append(
                f"{crs} snapped {anchor.snap_distance:.1f}m from its matching coordinate"
            )
    segments = segment_diagnostics(graph, route)
    for segment in segments:
        discouraged = {
            key: count
            for key, count in segment["service"].items()
            if key in {"siding", "yard"} and count
        }
        if discouraged:
            warnings.append(
                f"{segment['from']}->{segment['to']} uses service tracks: {discouraged}"
            )
        if segment["overlapWithPreviousMetres"] > BACKTRACK_WARNING_METRES:
            warnings.append(
                f"{segment['from']}->{segment['to']} backtracks over "
                f"{segment['overlapWithPreviousMetres']:.1f}m from the previous segment"
            )
    return {
        "schemaVersion": 1,
        "generatedAt": utc_now(),
        "source": {
            "path": str(input_path),
            "snapshotTimestamp": read_header_timestamp(input_path),
            "license": "ODbL-1.0",
            "attribution": "© OpenStreetMap contributors",
        },
        "extraction": {
            "railwayWays": len(handler.ways),
            "invalidRailwayWays": handler.invalid_railway_ways,
            "referencedNodes": len(handler.node_coordinates),
            "stationFeatures": len(handler.station_features),
            "tagCounts": {
                key: dict(sorted(values.items()))
                for key, values in handler.tag_counts.items()
            },
        },
        "graph": {
            "baseEdges": len(base_edges),
            "nodes": len(graph.nodes),
            "edges": len(graph.edges),
            "connectedComponents": len(component_sizes),
            "largestComponentNodes": max(component_sizes.values(), default=0),
        },
        "stationMapping": {
            "catalogueStations": station_count,
            "anchoredStations": len(graph.station_anchors),
            "routeStations": [
                {
                    "crs": crs,
                    "name": graph.station_matches[crs].name,
                    "matchMethod": anchor.match_method,
                    "osmStationType": anchor.station_osm_type,
                    "osmStationID": anchor.station_osm_id,
                    "anchorNode": anchor.graph_node,
                    "snapDistanceMetres": round(anchor.snap_distance, 3),
                }
                for crs, anchor in zip(route.calling_points, route.selected_anchors)
            ],
        },
        "route": {
            "callingPattern": list(route.calling_points),
            "totalDistanceMetres": round(route.total_length, 3),
            "coordinateCount": len(route.coordinates),
            "segments": segments,
        },
        "warnings": warnings,
    }


def write_json(path: Path, value: Any, compact: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        if compact:
            json.dump(value, output, separators=(",", ":"), ensure_ascii=False)
        else:
            json.dump(value, output, indent=2, sort_keys=True, ensure_ascii=False)
        output.write("\n")
    temporary.replace(path)


def validate_poc(route: RouteResult) -> None:
    if route.calling_points == DEFAULT_ROUTE and not 10_000 <= route.total_length <= 15_000:
        raise ValueError(
            f"Kent House to London Victoria route is implausible: {route.total_length:.1f}m"
        )
    if len(route.station_coordinate_indices) != len(route.calling_points):
        raise ValueError("Route does not contain an index for every calling point")
    if any(
        later < earlier
        for earlier, later in zip(
            route.station_coordinate_indices,
            route.station_coordinate_indices[1:],
        )
    ):
        raise ValueError("Calling points are not ordered along the route")


def validate_known_route_regressions(graph: RailwayGraph) -> None:
    for name, calling_points, length_range, segment_limits in KNOWN_ROUTE_REGRESSIONS:
        if not all(graph.station_anchors.get(crs) for crs in calling_points):
            continue
        route = route_calling_pattern(graph, calling_points)
        if not length_range[0] <= route.total_length <= length_range[1]:
            raise ValueError(
                f"{name} route is implausible: {route.total_length:.1f}m"
            )
        paths = {
            (route.calling_points[index], route.calling_points[index + 1]): path
            for index, path in enumerate(route.segment_paths)
        }
        for pair, maximum_length in segment_limits.items():
            path = paths[pair]
            if path.length > maximum_length:
                raise ValueError(
                    f"{name} segment {pair[0]}->{pair[1]} is implausible: "
                    f"{path.length:.1f}m"
                )
            discouraged = {
                graph.edges[traversal.edge].tags.get("service", "")
                for traversal in path.traversals
            } & {"yard", "siding", "spur"}
            if discouraged:
                raise ValueError(
                    f"{name} segment {pair[0]}->{pair[1]} uses service tracks: "
                    f"{sorted(discouraged)}"
                )
        for index, (previous, current) in enumerate(
            zip(route.segment_paths, route.segment_paths[1:]),
            start=1,
        ):
            overlap = shared_path_length(graph, previous, current)
            if overlap > BACKTRACK_WARNING_METRES:
                raise ValueError(
                    f"{name} route backtracks over {overlap:.1f}m around "
                    f"{route.calling_points[index]}"
                )
        print(f"Validated {name}: {route.total_length / 1_000:.3f}km")


def main() -> None:
    args = parse_args()
    calling_points = tuple(
        value.strip().upper() for value in args.route.split(",") if value.strip()
    )
    if args.anchors_per_station < 1:
        raise ValueError("At least one anchor candidate is required")
    handler = read_osm(args.input, args.location_index)
    base_edges = build_base_edges(handler)
    stations = load_station_catalogue(args.stations)
    station_anchors, station_matches = build_station_anchors(
        stations,
        handler.station_features,
        base_edges,
        args.anchors_per_station,
        args.max_anchor_distance,
    )
    graph = build_graph(base_edges, station_anchors, station_matches)
    validate_known_route_regressions(graph)
    print(f"Routing {' > '.join(calling_points)}")
    route = route_calling_pattern(graph, calling_points)
    validate_poc(route)
    diagnostics = diagnostics_document(
        handler,
        base_edges,
        graph,
        len(stations),
        route,
        args.input,
    )

    if not args.skip_asset:
        print(f"Writing compact routing asset to {args.asset_output}")
        bounds = tuple(args.asset_bounds) if args.asset_bounds is not None else None
        write_json(
            args.asset_output,
            graph_asset(graph, args.input, args.asset_region, bounds),
            compact=True,
        )
    write_json(args.geojson_output, route_geojson(graph, route))
    write_json(args.diagnostics_output, diagnostics)

    print(json.dumps(diagnostics["route"], indent=2, sort_keys=True))
    if diagnostics["warnings"]:
        print("Warnings:")
        for warning in diagnostics["warnings"]:
            print(f"- {warning}")
    if not args.skip_asset:
        print(
            f"Wrote {args.asset_output} "
            f"({args.asset_output.stat().st_size / 1_000_000:.2f} MB)"
        )
    print(f"Wrote {args.geojson_output}")
    print(f"Wrote {args.diagnostics_output}")


if __name__ == "__main__":
    main()
