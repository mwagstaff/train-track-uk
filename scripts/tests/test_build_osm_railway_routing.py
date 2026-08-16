from __future__ import annotations

import unittest

from scripts.build_osm_railway_routing import (
    AnchorCandidate,
    BaseEdge,
    GraphPath,
    GraphEdge,
    RailwayDataHandler,
    RailwayGraph,
    OSMWay,
    Projection,
    StationMatch,
    Traversal,
    build_base_edges,
    build_graph,
    edge_intersects_bounds,
    merge_route,
    project_onto_segment,
    select_diverse_projections,
    shared_path_length,
    shortest_path,
)


def anchor(crs: str, edge_id: int, measure: float) -> AnchorCandidate:
    return AnchorCandidate(
        crs=crs,
        edge_id=edge_id,
        measure=measure,
        coordinate=(0.0, 0.0),
        snap_distance=0.0,
        match_method="test",
        station_osm_type=None,
        station_osm_id=None,
    )


class GeometryTests(unittest.TestCase):
    def test_projection_is_clamped_to_segment(self) -> None:
        projected, fraction, distance = project_onto_segment(
            (0.002, 0.0),
            (0.0, 0.0),
            (0.001, 0.0),
        )

        self.assertEqual(projected, (0.001, 0.0))
        self.assertEqual(fraction, 1.0)
        self.assertGreater(distance, 100)

    def test_bounds_include_crossing_edges_and_exclude_remote_edges(self) -> None:
        crossing = GraphEdge(
            0,
            1,
            100,
            100,
            ((-0.3, 51.5), (0.1, 51.5)),
            1,
            {},
            (),
        )
        remote = GraphEdge(
            0,
            1,
            100,
            100,
            ((1.0, 52.0), (1.1, 52.1)),
            2,
            {},
            (),
        )
        bounds = (-0.27, 51.33, 0.07, 51.57)

        self.assertTrue(edge_intersects_bounds(crossing, bounds))
        self.assertFalse(edge_intersects_bounds(remote, bounds))

    def test_station_projections_cover_distinct_corridors(self) -> None:
        edges = [
            BaseEdge(
                edge_id=index,
                way_id=100 + index,
                start_osm_node=index * 2,
                end_osm_node=(index * 2) + 1,
                length=100,
                coordinates=((0.0, 0.0), (0.001, 0.0)),
                tags=tags,
                route_relations=(),
            )
            for index, tags in enumerate([
                {"railway": "rail", "ref": "TRL1"},
                {"railway": "rail", "ref": "TRL1"},
                {"railway": "rail", "ref": "SPC1"},
                {"railway": "rail", "service": "yard"},
                {"railway": "rail", "ref": "MCL"},
            ])
        ]
        projections = [
            Projection(edge_id=index, measure=50, coordinate=(0.0, 0.0), distance=distance)
            for index, distance in enumerate((5, 6, 20, 25, 50))
        ]

        selected = select_diverse_projections(projections, edges, 3)

        self.assertEqual(
            [edges[value.edge_id].tags.get("ref") for value in selected],
            ["TRL1", "SPC1", "MCL"],
        )

    def test_station_projections_keep_parallel_tracks_for_one_corridor(self) -> None:
        edges = [
            BaseEdge(
                edge_id=index,
                way_id=100 + index,
                start_osm_node=index * 2,
                end_osm_node=(index * 2) + 1,
                length=100,
                coordinates=((0.0, 0.0), (0.001, 0.0)),
                tags={"railway": "rail", "ref": "VTB1"},
                route_relations=(),
            )
            for index in range(4)
        ]
        projections = [
            Projection(edge_id=index, measure=50, coordinate=(0.0, 0.0), distance=index + 1)
            for index in range(4)
        ]

        selected = select_diverse_projections(projections, edges, 4)

        self.assertEqual([value.edge_id for value in selected], [0, 1, 2, 3])


class TopologyTests(unittest.TestCase):
    def test_base_edges_split_at_a_shared_internal_node(self) -> None:
        handler = RailwayDataHandler()
        handler.node_coordinates = {
            1: (0.0, 0.0),
            2: (0.001, 0.0),
            3: (0.002, 0.0),
            4: (0.001, 0.001),
        }
        handler.ways = [
            OSMWay(10, (1, 2, 3), {"railway": "rail"}),
            OSMWay(11, (2, 4), {"railway": "rail"}),
        ]

        edges = build_base_edges(handler)

        self.assertEqual(len(edges), 3)
        self.assertEqual(
            {(edge.start_osm_node, edge.end_osm_node) for edge in edges},
            {(1, 2), (2, 3), (2, 4)},
        )

    def test_station_anchor_splits_an_edge(self) -> None:
        base_edge = BaseEdge(
            edge_id=0,
            way_id=10,
            start_osm_node=1,
            end_osm_node=2,
            length=200.0,
            coordinates=((0.0, 0.0), (0.002, 0.0)),
            tags={"railway": "rail"},
            route_relations=(),
        )
        station_anchor = anchor("AAA", 0, 100.0)
        station_match = StationMatch(
            crs="AAA",
            name="Alpha",
            catalogue_coordinate=(0.001, 0.0),
            matching_coordinate=(0.001, 0.0),
            match_method="test",
            station_osm_type=None,
            station_osm_id=None,
            station_feature_distance=None,
        )

        graph = build_graph(
            [base_edge],
            {"AAA": [station_anchor]},
            {"AAA": station_match},
        )

        self.assertEqual(len(graph.nodes), 3)
        self.assertEqual(len(graph.edges), 2)
        self.assertEqual(station_anchor.graph_node, 2)
        self.assertAlmostEqual(sum(edge.length for edge in graph.edges), 200.0)


class RoutingTests(unittest.TestCase):
    def setUp(self) -> None:
        nodes = [
            (0.0, 0.0),
            (0.001, 0.0),
            (0.0, 0.001),
            (0.001, 0.001),
        ]
        edges = [
            GraphEdge(0, 1, 100, 300, (nodes[0], nodes[1]), 1, {"service": "yard"}, ()),
            GraphEdge(1, 3, 100, 300, (nodes[1], nodes[3]), 2, {"service": "yard"}, ()),
            GraphEdge(0, 2, 150, 150, (nodes[0], nodes[2]), 3, {"usage": "main"}, ()),
            GraphEdge(2, 3, 150, 150, (nodes[2], nodes[3]), 4, {"usage": "main"}, ()),
        ]
        adjacency = [[] for _ in nodes]
        for edge_index, edge in enumerate(edges):
            adjacency[edge.start].append((edge.end, edge_index))
            adjacency[edge.end].append((edge.start, edge_index))
        self.graph = RailwayGraph(nodes, edges, adjacency, {}, {}, [0, 0, 0, 0])

    def test_shortest_path_avoids_a_shorter_yard_route(self) -> None:
        path = shortest_path(self.graph, 0, 3, {})

        self.assertIsNotNone(path)
        assert path is not None
        self.assertEqual([value.edge for value in path.traversals], [2, 3])
        self.assertEqual(path.length, 300)
        self.assertEqual(path.cost, 300)

    def test_route_merge_reverses_edge_geometry(self) -> None:
        path = shortest_path(self.graph, 3, 0, {})
        start = anchor("BBB", 0, 0)
        start.graph_node = 3
        end = anchor("AAA", 0, 0)
        end.graph_node = 0

        self.assertIsNotNone(path)
        assert path is not None
        route = merge_route(self.graph, ("BBB", "AAA"), (start, end), (path,))

        self.assertEqual(route.coordinates[0], self.graph.nodes[3])
        self.assertEqual(route.coordinates[-1], self.graph.nodes[0])
        self.assertEqual(route.station_coordinate_indices, (0, 2))
        self.assertAlmostEqual(route.total_length, 222.39, places=1)

    def test_shared_path_length_detects_adjacent_backtracking(self) -> None:
        incoming = GraphPath(
            length=200,
            cost=200,
            traversals=(Traversal(0, 0, 1), Traversal(1, 1, 3)),
        )
        outgoing = GraphPath(
            length=200,
            cost=200,
            traversals=(Traversal(1, 3, 1), Traversal(2, 1, 2)),
        )

        self.assertEqual(shared_path_length(self.graph, incoming, outgoing), 100)


if __name__ == "__main__":
    unittest.main()
