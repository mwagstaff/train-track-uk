# TrainTrack UK – OSM Railway Routing Prototype Plan

## Objective

Prototype a Great Britain railway route-mapping system for TrainTrack UK using **OpenStreetMap railway data** instead of OS NGD. Northern Ireland and Ireland are out of scope for the current implementation.

The goal is to prove that we can:

1. Download Great Britain railway data from OpenStreetMap.
2. Build a routable railway graph.
3. Match TrainTrack/Darwin stations to the OSM railway network.
4. Route between consecutive calling points.
5. Merge those route segments into one continuous railway polyline.
6. Render the route in Apple MapKit.
7. Estimate and display the train's current position along that polyline.

This is an MVP/proof-of-concept first. Prefer simplicity and observability over premature optimisation.

## Preferred Architecture

```text
Geofabrik Great Britain OSM extract (.osm.pbf)
                    |
                    v
           Railway extraction
                    |
                    v
            Railway graph
                    |
                    v
      Station matching / snapping
                    |
                    v
     Route between calling points
                    |
                    v
       Continuous route polyline
                    |
                    v
      Train position interpolation
                    |
                    v
             Apple MapKit
```

Use Darwin / existing TrainTrack service data for calling points, station CRS/TIPLOC identifiers, scheduled times, estimated/actual arrival/departure times, and train progress.

Use OSM only for railway geometry, graph topology, station/platform locations, and railway metadata.

## Phase 1 – Download OSM Data

Use a Geofabrik Great Britain extract:

```text
great-britain-latest.osm.pbf
```

Do not use the public Overpass API for whole-country ingestion.

Keep the PBF file outside the iOS app bundle. This preprocessing step should run server-side or as a local build/import process.

Suggested tools:

- `osmium`
- `pyosmium`
- another proven OSM parser

Codex should choose whichever gives the cleanest implementation in the existing project environment.

## Phase 2 – Extract Railway Features

Extract railway ways relevant to National Rail first.

Primary inclusion:

```text
railway=rail
```

Initially include main line railway, branch line railway, passenger railway, and freight-and-passenger railway.

Prefer excluding:

```text
railway=tram
railway=subway
railway=light_rail
railway=monorail
railway=narrow_gauge
```

Also exclude service infrastructure where practical:

```text
service=siding
service=yard
service=spur
service=crossover
```

Do not hard-code too aggressively at first. Create diagnostics showing counts by `railway`, `usage`, `service`, `operator`, `electrified`, and `tracks`.

## Phase 3 – Build Railway Graph

Unlike OS NGD, OSM does not expose explicit `startnode` / `endnode` fields per railway segment. Instead, build graph connectivity from shared OSM node IDs.

Conceptually:

```text
OSM Way
  node 100
  node 101
  node 102
  node 103
```

becomes:

```text
100 <-> 101 <-> 102 <-> 103
```

Each consecutive OSM node pair becomes a graph edge.

Suggested model:

```swift
struct RailwayGraphNode {
    let osmNodeID: Int64
    let coordinate: CLLocationCoordinate2D
    var edges: [RailwayGraphEdge]
}

struct RailwayGraphEdge {
    let wayID: Int64
    let fromNodeID: Int64
    let toNodeID: Int64
    let lengthMetres: Double
    let geometry: [CLLocationCoordinate2D]
    let tags: [String: String]
}
```

The server-side implementation does not need to use Swift if the existing backend is Node/Python. Preserve the original OSM Way ID and useful railway tags for debugging.

## Phase 4 – Handle OSM Directionality

Most railway ways may be routable in both directions. Preserve and inspect relevant directional tags such as:

```text
oneway
railway:preferred_direction
```

For the MVP, if no reliable directional tag exists, assume bidirectional routing. Do not invent railway directionality from track orientation alone.

## Phase 5 – Station Extraction

Extract candidate OSM station features including:

```text
railway=station
railway=halt
public_transport=station
```

Where available, retain:

```text
name
ref
nat_ref
uic_ref
operator
network
```

Also inspect platform features:

```text
railway=platform
public_transport=platform
```

The station object may not lie directly on a railway graph node, so station matching must support snapping.

## Phase 6 – Match TrainTrack Stations to OSM

TrainTrack already knows station identifiers and coordinates.

Input:

```text
CRS
TIPLOC (if available)
station name
latitude
longitude
```

For each station:

1. Find OSM station features nearby.
2. Prefer a name match.
3. Prefer National Rail / railway features over Underground/Tram where multiple matches exist.
4. Snap the station to the nearest eligible railway graph node or track edge.

Store:

```text
CRS -> graph anchor
```

Example:

```json
{
  "KTH": {
    "osmStationID": 123456,
    "graphNodeID": 987654,
    "distanceMetres": 12.4
  }
}
```

Create a reusable station mapping cache.

## Phase 7 – Do NOT Route End-to-End First

For the initial implementation, do not simply route Kent House -> London Victoria across the entire railway graph.

Instead use the Darwin calling pattern.

Example:

```text
Kent House
Penge East
Sydenham Hill
West Dulwich
Herne Hill
Brixton
London Victoria
```

Route between each consecutive pair:

```text
KTH -> PNE
PNE -> SYH
SYH -> WDU
WDU -> HNH
HNH -> BRX
BRX -> VIC
```

Then concatenate. This constrains route-finding and greatly reduces the chance of choosing a plausible but operationally incorrect railway path.

## Phase 8 – Routing Algorithm

Start with A*.

Cost:

```text
edge length in metres
```

Heuristic:

```text
straight-line geographic distance to destination
```

Return:

```swift
struct RailwayRouteSegment {
    let fromStation: String
    let toStation: String
    let nodeIDs: [Int64]
    let edges: [RailwayGraphEdge]
    let totalLengthMetres: Double
}
```

Add optional penalties for sidings/service tracks, freight-only tracks, leaving main/branch railway, and route relation mismatch. Do not add these penalties until basic routing works.

## Phase 9 – Route Relations

Investigate OSM relations with:

```text
type=route
route=railway
```

Do not make them mandatory for MVP routing. Treat them as a secondary signal that may later help bias A* to remain on the same railway relation, reduce accidental detours, identify named corridors, and improve route validation.

## Phase 10 – Polyline Construction

For every routed edge:

- preserve traversal direction
- reverse geometry when traversing an edge backwards
- append geometry in order
- avoid duplicate adjoining coordinates

Return:

```text
[
  [lon, lat],
  [lon, lat],
  ...
]
```

The final output must form one continuous polyline suitable for MapKit.

## Phase 11 – Route Validation

For each generated route, validate:

1. Every route segment is connected.
2. Calling points occur in expected order.
3. No large geographic jumps exist.
4. Total route distance is plausible.
5. No tram/subway/light-rail tracks are used accidentally.
6. No sidings are used unless necessary.
7. Route does not pass through obviously incorrect branches.

Produce verbose debug output.

Example:

```text
KTH -> PNE
distance: 1.8 km
graph nodes: 47
OSM ways: 12
main railway: 100%
sidings: 0
result: PASS
```

## Phase 12 – Route Caching

Cache generated geometry using the complete calling pattern, not just origin/destination.

Example key:

```text
KTH>PNE>SYH>WDU>HNH>BRX>VIC
```

Cache segment edge IDs, merged geometry, total distance, station distances along route, generated timestamp, and OSM extract version.

## Phase 13 – Distances Along Route

For each calling point, calculate its cumulative distance along the final polyline.

Example:

```json
{
  "KTH": 0,
  "PNE": 1843.4,
  "SYH": 4139.7,
  "WDU": 5788.3,
  "HNH": 7611.9,
  "BRX": 9050.2,
  "VIC": 11364.7
}
```

This is essential for train progress interpolation.

## Phase 14 – Train Position Estimation

Given the last known timing point, next timing point, actual/estimated departure time, expected arrival time, and current time, calculate:

```text
progress = elapsedTime / expectedSegmentDuration
```

Clamp to `0.0 ... 1.0`.

Then interpolate by **distance along the routed polyline segment**, not linearly between station coordinates.

Return:

```text
latitude
longitude
bearing
estimated = true
```

## Phase 15 – MapKit UI

Render using Apple MapKit.

Display:

- full railway route polyline
- calling point markers
- train marker
- completed route
- remaining route
- current/next station

Suggested styles:

```text
completed: blue
remaining: neutral grey
train: prominent custom annotation
```

Do not require Google Maps. The MapKit view should consume precomputed route geometry from the backend rather than calculating railway routing on-device.

## Phase 16 – Suggested Backend API

Add something similar to:

```text
GET /api/v2/service/{rid}/route
```

Suggested response:

```json
{
  "serviceId": "...",
  "callingPattern": [
    "KTH",
    "PNE",
    "SYH",
    "WDU",
    "HNH",
    "BRX",
    "VIC"
  ],
  "route": {
    "coordinates": [],
    "totalDistanceMetres": 11364.7
  },
  "stations": [
    {
      "crs": "KTH",
      "distanceAlongRouteMetres": 0
    }
  ],
  "position": {
    "latitude": 51.42,
    "longitude": -0.06,
    "bearing": 318,
    "estimated": true
  }
}
```

## Phase 17 – MVP Success Criteria

The first proof-of-concept is successful if it can take a real TrainTrack service with a known calling pattern, for example:

```text
Kent House
Penge East
Sydenham Hill
West Dulwich
Herne Hill
Brixton
London Victoria
```

and produce:

1. A continuous railway route.
2. Geometry that visibly follows real railway tracks.
3. No straight-line station-to-station shortcuts.
4. Correct station order.
5. No Tube / tram / DLR contamination.
6. A MapKit polyline that looks geographically correct.
7. A train marker that can be placed anywhere along the route by percentage/distance.

## Phase 18 – Diagnostics Required From Codex

Do not silently hide routing problems.

Add CLI or debug tooling capable of printing:

```text
Station mapping:
KTH -> OSM node ...
PNE -> OSM node ...

Route:
KTH -> PNE
distance ...
ways ...
nodes ...

Warnings:
- station snapped 183m away
- siding used
- disconnected segment
- route relation mismatch
```

Save route debug output where practical.

## Phase 19 – Performance

For MVP:

- loading/parsing PBF offline is fine
- preprocessing time is not critical
- runtime route lookup should be fast

Eventually:

- preprocess graph into compact binary/SQLite/Postgres representation
- spatially index stations/nodes
- cache route patterns
- avoid parsing the full PBF at application startup

## Phase 20 – Do Not Over-Engineer Yet

For the first pass:

- no live OSM updates
- no daily diffs
- no GraphHopper deployment unless clearly beneficial
- no raw PBF parsing or graph construction on the client; the app may consume a compact, prebuilt Great Britain graph after app-size and runtime validation
- no timetable-based pathfinding
- no platform-level track assignment
- no attempt to infer exact physical track in multi-track corridors

A representative centreline is sufficient.

## Optional GraphHopper Investigation

If building the graph/router manually becomes cumbersome, investigate GraphHopper as a second approach.

Questions to answer:

1. Can GraphHopper import `railway=rail` as a custom vehicle/profile?
2. Can it exclude road routing entirely?
3. Can it retain route geometry at sufficient fidelity?
4. Can we configure penalties for sidings/freight-only tracks?
5. Can the resulting deployment remain lightweight enough for TrainTrack UK?

Do not block the MVP on GraphHopper. A small custom A* railway graph is acceptable and may ultimately be simpler.

## Licensing

OSM data is licensed under ODbL.

Ensure the application includes suitable attribution, such as:

```text
© OpenStreetMap contributors
```

Keep the railway graph generation pipeline reproducible from the original OSM extract.

## Recommended First Coding Task

Implement a standalone proof-of-concept script before integrating into the TrainTrack backend.

Input:

```text
great-britain-latest.osm.pbf
KTH coordinates
PNE coordinates
SYH coordinates
WDU coordinates
HNH coordinates
BRX coordinates
VIC coordinates
```

Output:

```text
route-kth-vic.geojson
```

The GeoJSON should contain the final route LineString, station Points, and optional graph debug information.

Open the resulting GeoJSON in a GIS/map viewer and visually confirm that the route follows the correct railway.

Only after that should the implementation be moved into the production backend.

## Final Desired Architecture

```text
                    Darwin
                      |
                      v
              Calling pattern
                      |
                      v
OSM PBF -> Railway graph -> Route cache
                      |
                      v
              Route geometry
                      |
                      +------> Train interpolation
                      |
                      v
                TrainTrack API
                      |
                      v
                  MapKit
```

The core principle is:

> Darwin tells us **which places the train passes through and when**.
>
> OpenStreetMap tells us **where the railway physically runs**.
>
> TrainTrack combines the two.
