# TrainTrack UK -- Railway Routing Engine (OS NGD)

## Goal

Implement a railway routing engine that renders the **actual railway
alignment** on an Apple Map, animates the train along the route, and
supports future live progress.

The project will use the downloaded OS NGD datasets:

-   `railway-links-all.json`
-   `railway-nodes-all.json`

These have already been validated:

-   \~7,747 railway links
-   \~7,263 railway nodes
-   \~99.5% link→node referential integrity
-   GeoJSON LineStrings and Points
-   Links contain:
    -   startnode
    -   endnode
    -   geometry
    -   geometry_length_m
    -   railwayuse
    -   description
    -   direction
    -   operationalstatus
-   Nodes include:
    -   Station
    -   Junction
    -   Pseudo Node
    -   Network Terminal Node

Ignore links whose start/end node cannot be resolved.

------------------------------------------------------------------------

# Phase 1 -- Graph Loader

Create:

``` swift
struct RailwayNode {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let type: NodeType
    var edges: [RailwayEdge]
}

struct RailwayEdge {
    let id: String
    let startNode: String
    let endNode: String
    let polyline: [CLLocationCoordinate2D]
    let length: Double
    let railwayUse: RailwayUse
    let description: String
    let direction: Direction
}
```

Requirements:

-   Load all nodes.
-   Load all links.
-   Resolve start/end node IDs.
-   Build adjacency lists.
-   Skip broken links.

------------------------------------------------------------------------

# Phase 2 -- Graph Validation

Produce diagnostics:

-   Node count
-   Edge count
-   Orphan nodes
-   Broken references
-   Connected component count

Ensure the graph is usable.

------------------------------------------------------------------------

# Phase 3 -- Station Matching

Input:

``` text
CRS
Station Name
Latitude
Longitude
```

Match each station to the nearest railway node.

Prefer:

1.  Station node
2.  Junction
3.  Pseudo node

Store mapping:

``` swift
CRS -> RailwayNodeID
```

------------------------------------------------------------------------

# Phase 4 -- Routing

Implement A\*.

Cost:

-   geometry_length_m

Heuristic:

-   straight-line distance

Return:

``` swift
struct RailwayRoute {
    let nodeIDs: [String]
    let edges: [RailwayEdge]
    let totalLength: Double
}
```

------------------------------------------------------------------------

# Phase 5 -- Polyline

Merge edge geometries into one continuous route.

Output:

``` swift
[CLLocationCoordinate2D]
```

Suitable for:

``` swift
MapPolyline(...)
```

------------------------------------------------------------------------

# Phase 6 -- Train Progress

Input:

-   current timing point
-   next timing point
-   elapsed time
-   expected duration

Calculate:

``` text
progress = elapsed / duration
```

Walk that proportion along the merged polyline.

Return:

``` swift
CLLocationCoordinate2D
```

------------------------------------------------------------------------

# Phase 7 -- Apple Map

Render:

-   railway polyline
-   station markers
-   animated train marker

Future enhancements:

-   completed route in blue
-   remaining route in grey
-   station status:
    -   completed
    -   current
    -   upcoming

------------------------------------------------------------------------

# Filtering

Initially include only:

-   operationalstatus == Active
-   description contains Main Line
-   railwayuse contains Passenger

Exclude:

-   sidings
-   inactive
-   preserved
-   tram
-   underground (optional toggle later)

------------------------------------------------------------------------

# Deliverables

1.  RailwayGraph loader
2.  Graph validator
3.  Station matcher
4.  A\* router
5.  Polyline builder
6.  Train interpolation
7.  Apple Map demo

Success criterion:

Kent House → London Victoria should produce a continuous railway
polyline that follows the real track rather than straight lines between
stations.
