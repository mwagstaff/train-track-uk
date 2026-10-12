# How TrainTrack UK route maps work

*Implementation reviewed: 12 October 2026.*

TrainTrack UK combines mapped railway tracks with a train’s ordered calling points to calculate a plausible geographical route. It draws that route over an Apple map and adds station markers, timing information and an estimated train position.

The result follows railway curves and junctions rather than drawing straight lines between stations. It is an inferred route through the railway network: the app does not receive a confirmed, track-by-track operational path for every train.

This document describes the current iOS railway maps. Replacement buses use a separate presentation, described briefly below.

## 1. The data sources

| Layer | Source | Purpose |
| --- | --- | --- |
| Railway geometry and connectivity | [OpenStreetMap](https://www.openstreetmap.org), downloaded as a [Geofabrik Great Britain extract](https://download.geofabrik.de/europe/great-britain.html) | Track coordinates, junction connections, station features and track classifications. |
| Station catalogue | The project’s station catalogue, credited in the app to [davwheat/uk-railway-stations](https://github.com/davwheat/uk-railway-stations) | Station names, three-letter CRS codes and approximate coordinates. |
| Calling points and live timings | TrainTrack UK’s API; the public service-details integration uses National Rail LDBWS through [Rail Data Marketplace](https://raildata.org.uk/) | The order of stations served, scheduled and estimated times, actual reports, cancellations and available platform information. The backend also supports staff-derived service details. |
| Background map | Apple MapKit | The geographical context beneath the app’s railway overlays, plus map interaction and rendering. |
| Onboard location, when supplied | The user’s device location | An optional refinement of the displayed position after checks against the route. |

The routing graph is bundled with the app. The current checked-in asset contains:

- **107,919 graph nodes** and **118,484 track edges**.
- Anchors for **2,606 station CRS codes**.
- Approximately **26.0 MB** of JSON.
- A recorded OSM source timestamp of **14 August 2026, 20:21:03 UTC**.

These are measurements of the bundled asset, not of the latest Geofabrik download. Coverage is Great Britain—England, Scotland and Wales. Geofabrik’s Great Britain extract excludes Ireland, including Northern Ireland. [Geofabrik coverage details](https://download.geofabrik.de/europe/great-britain.html).

The repository also contains an earlier Ordnance Survey NGD London prototype. The current runtime loader uses the Great Britain OSM asset; the OS/OSM selector described in the older build notes is historical.

## 2. Turning railway mapping into a routable network

Most of the data preparation happens ahead of release, on a development machine. The phone receives the prepared graph rather than processing the original country-wide OSM download.

```text
Geofabrik OSM extract + station catalogue
                   |
          Offline graph builder
                   |
      Bundled railway routing graph
                   |
       Service's ordered CRS codes
                   |
       On-device route calculation
                   |
    Track-shaped line + station markers
                   |
      Apple map + live presentation
```

### Preserve both shape and connectivity

The builder retains full-size tracks tagged `railway=rail`, together with relevant station features and railway route relations. A track is represented by an OSM *way*: an ordered list of coordinate-bearing nodes.

The builder splits ways at their ends and at shared nodes. Each resulting section becomes a graph **edge**, with its endpoint nodes identifying where travel can continue onto another edge. It retains the intermediate coordinates as a **polyline**, preserving the shape of bends and approaches.

This distinction matters at bridges and tunnels: two lines crossing on the map do not automatically become a junction. Connectivity follows shared OSM nodes rather than visual intersections.

Edges store two separate values:

- **Length:** physical distance in metres, calculated along the mapped geometry using great-circle distance calculations.
- **Cost:** a routing preference used to choose a plausible path.

The generated graph is bidirectional. It represents geographical connections, without modelling every railway direction restriction, signal or operating rule.

### Prefer ordinary running lines

Choosing the shortest physical route alone can produce implausible trips through yards or sidings. The builder therefore increases the cost of certain tracks while retaining them as possible connections.

| OSM track classification | Cost multiplier |
| --- | ---: |
| Ordinary track without a penalty classification | 1.00 |
| Crossover | 1.15 |
| Spur | 1.35 |
| Siding | 2.00 |
| Yard | 3.00 |
| Tourism usage | 2.00 |
| Industrial or military usage | 3.00 |

For a section with both service and usage classifications, the builder takes the larger multiplier. A 100-metre yard section therefore contributes 300 cost units while still counting as 100 metres of physical distance.

These are practical heuristics, not measured travel times or probabilities.

## 3. Connecting stations to the correct tracks

A station’s catalogue coordinate may be near an entrance or the centre of a large site. Simply choosing its nearest track can attach it to the wrong platform group or railway corridor.

The builder first looks for an OSM station feature using its **CRS code** (`ref:crs`), then a normalised station name. It ranks candidate features to favour National Rail stations over Underground or tram features. If no suitable match exists, it uses the catalogue coordinate; a selected feature more than two kilometres away is also rejected.

It then projects the station location onto nearby track segments. Where OSM and catalogue coordinates differ, both are used to find candidates. The default settings search within **1,000 metres** and retain up to **four anchors per station**.

Crucially, it tries to retain candidates from different railway corridors before adding more parallel tracks from the same corridor. Corridor grouping uses available track references, names, infrastructure relations or usage tags. This helps at places such as Clapham Junction and St Pancras, where the nearest group of tracks may not serve the train being mapped.

Each anchor is inserted into the graph by splitting its track edge at the projected point. Station markers can therefore sit on the selected railway alignment, even when the station catalogue coordinate is offset from it.

## 4. Calculating the service’s route

The runtime input is an ordered list of calling-point CRS codes. For example:

```text
Kent House → Penge East → Sydenham Hill → West Dulwich
           → Herne Hill → Brixton → London Victoria
```

Using all available calls constrains the route much more strongly than using only the origin and destination.

### A* search between candidate anchors

For each relevant pair of anchors at consecutive stations, the app searches the graph using **A\***. It prioritises nodes using:

```text
priority = cost accumulated so far + straight-line distance to destination
```

The straight-line term guides exploration towards the destination, while the accumulated cost includes the track penalties. A binary minimum heap efficiently selects the next node to explore.

If that search returns no path, the code retries with the heuristic disabled—equivalent to **Dijkstra’s algorithm**. It also labels connected components in advance, allowing it to reject pairs in disconnected parts of the network without running a full search.

### Choose anchors across the calling pattern

The app does not independently select the nearest anchor at every station. It uses a layered, dynamic-programming-style calculation: one layer per station, with candidate anchors in each layer.

For each candidate, it retains the best accumulated choice from the previous station. The score adds:

```text
previous score
+ path cost to the next anchor
+ 2 × next anchor's station snap distance
+ 4 × track length shared with the preceding leg
```

The first station also contributes twice its anchor snap distance. The overlap penalty discourages adjacent legs from retracing the same graph edges, reducing artificial detours into the wrong station approach and back out again.

The app then works backwards through the retained choices to recover the selected path. This is a practical heuristic: because it keeps one best history per anchor and calculates pairwise paths separately, it does not exhaustively optimise every possible whole-service path with every possible backtracking history.

### Assemble the geometry

The chosen edges are joined in travel order, reversing edge coordinates when necessary and avoiding duplicate join points. The result stores:

- The complete coordinate sequence.
- Cumulative distance along that sequence.
- The coordinate index corresponding to each calling point.

This supports drawing individual station-to-station sections and locating a point at a particular distance along the route.

## 5. Displaying the route

The app supplies the calculated coordinates to Apple’s [`MapPolyline`](https://sosumi.ai/documentation/mapkit/mappolyline), over a flat, muted standard map. MapKit renders the supplied geometry; TrainTrack UK calculates the railway path itself.

A wider, subdued line provides the route outline, with narrower coloured sections above it. In the live service view:

| Appearance | Meaning |
| --- | --- |
| Grey behind the displayed train | Completed portion of the route. |
| App accent colour ahead | No positive delay detected for the section. |
| Yellow ahead | Positive delay below five minutes. |
| Red ahead | Delay of at least five minutes, a cancelled endpoint call, or an explicit “Delayed”/“Cancelled” timing state. |

Section delay uses the larger delay at its two endpoint calls. Colour is therefore a presentation of calling-point information, rather than an independent measurement of conditions on each track section.

The completed portion can end partway between stations. Historical maps highlight the selected travelled sections. Additional branches can be drawn for split services, and planner maps reuse the railway routing service for rail legs.

Station annotations provide names and timing/platform details. To reduce clutter, the app detects overlapping label rectangles and hides secondary labels while preserving priority labels such as the first and last station, the user’s origin and transfer stations. The camera can frame the full route or centre on the estimated train position.

## 6. Estimating where the train is

The railway line and the train marker answer different questions. The line estimates **which tracks connect the calls**; the marker estimates **how far the train has progressed**.

The timing estimator starts from the latest non-cancelled call with an actual-time report, including an “On time” actual status, and finds the next non-cancelled call. It calculates a time fraction between departure and the next effective arrival time:

```text
progress fraction = elapsed time since departure / expected leg duration
```

The route converts that fraction into distance along its polyline. Binary search over cumulative distances finds the relevant coordinate segment, then interpolation produces the marker position. Thus the marker follows railway bends rather than moving directly across the landscape between station centres.

The estimator handles midnight rollover and applies a **30-second safety interval after scheduled departure** before moving away from a station. Without an actual report it stays at the first valid call; unusable timing information can also cause it to hold at a station.

This movement assumes progress proportional to time over the leg. It does not model acceleration, speed limits, signal stops or dwell times precisely, so the marker is labelled **Estimated location**.

### Optional onboard GPS refinement

When an onboard device location is supplied, the map can use it after validation. Current checks require:

- Reported horizontal accuracy between 0 and **200 metres**.
- A timestamp no more than **two minutes old**, allowing up to 30 seconds of future clock skew.
- Proximity to the route within `max(250 metres, reported accuracy + 100 metres)`.
- Separation no greater than **10 kilometres** from the timing-derived position, when that position exists.

An accepted location is projected onto the closest route segment. Its distance along the route drives both the marker and completed-route styling. If validation fails, the map continues using the timing-based estimate.

This is a lightweight nearest-segment projection, not a full probabilistic map-matching system. Parallel tracks, loops and repeated visits to the same location can remain ambiguous.

## 7. Performance, updates and failure behaviour

The expensive OSM parsing, station matching and graph construction happen offline. The download pipeline verifies Geofabrik’s MD5 checksum and records SHA-256 hashes for provenance.

On the phone, the graph loads when needed and is retained by a shared routing service. Concurrent requests share a graph-load task. Successful paths are cached in both directions; unreachable pairs are also remembered. Routing checks for cancellation so obsolete requests can stop when the displayed service changes.

Bundling makes railway path calculation independent of an online routing service. Live service information and uncached background map content still depend on connectivity. The bundled graph does not automatically acquire later OSM edits: refreshing it requires rebuilding and distributing an updated asset.

If the full service cannot be routed, the service map tries the user’s selected station range when that is a smaller, valid portion. If that also fails, it displays an unavailable state. Failed additional branches can be omitted while the primary route remains visible.

## 8. What “reasonably accurate” means

Accuracy comes from combining real track geometry, real network connections, multiple station-anchor candidates, the ordered calling pattern and penalties against implausible infrastructure choices.

It does **not** establish that every displayed track is the one the train actually uses. Important limits include:

- **Alternative routes:** two lines can connect the same calls; an express with few calls provides less evidence for choosing between them.
- **Diversions:** live delay or cancellation information does not by itself describe a diversion’s track geometry.
- **Operational constraints:** the graph is bidirectional and does not enforce signalling, electrification compatibility, rolling-stock restrictions or temporary engineering possessions.
- **Platforms:** a plausible station anchor is not proof of the operational platform. Displayed platform text comes from service data and is not an input to this geometric router.
- **Source quality and age:** missing connections, imperfect classifications, station offsets and changes since the bundled snapshot can affect the result.
- **Position:** timing-based movement is an estimate, while onboard GPS is subject to reception and matching ambiguity.

The implementation includes regression tests for representative routes across Britain, geometry reversal and continuity, distance plausibility, and difficult approaches at Clapham Junction and St Pancras. These are useful safeguards, not a measured nationwide accuracy percentage.

Replacement buses use station coordinates and a separate map presentation. They do not use this railway graph, and their displayed line should not be interpreted as a verified road itinerary or live bus location.

## 9. Attribution and implementation references

The graph records **© OpenStreetMap contributors** and **ODbL-1.0**. The app links the OSM attribution from the railway map and includes a credit in shared map images. See [OpenStreetMap copyright and licence information](https://www.openstreetmap.org/copyright).

The following source links are pinned to the reviewed repository revision so this explanation remains traceable. Repository access may be required.

| Reference | What it covers |
| --- | --- |
| [OSM download pipeline](https://github.com/mwagstaff/train-track-uk/blob/978cb734cee54dd7a831c06a1d9308bb6fa7110d/scripts/get_osm_railway_data.py) | Download, filtering, checksums and provenance. |
| [Graph builder](https://github.com/mwagstaff/train-track-uk/blob/978cb734cee54dd7a831c06a1d9308bb6fa7110d/scripts/build_osm_railway_routing.py) | Track topology, anchor matching, corridor diversity and cost multipliers. |
| [On-device railway routing](https://github.com/mwagstaff/train-track-uk/blob/978cb734cee54dd7a831c06a1d9308bb6fa7110d/ios/TrainTrack%20UK/TrainTrack%20UK/RailwayRouting.swift) | Graph loading, A*, candidate selection, caching and distance interpolation. |
| [Railway map presentation](https://github.com/mwagstaff/train-track-uk/blob/978cb734cee54dd7a831c06a1d9308bb6fa7110d/ios/TrainTrack%20UK/TrainTrack%20UK/ServiceRailwayMapView.swift) | Polylines, colours, labels, GPS projection and map sharing. |
| [Service map integration](https://github.com/mwagstaff/train-track-uk/blob/978cb734cee54dd7a831c06a1d9308bb6fa7110d/ios/TrainTrack%20UK/TrainTrack%20UK/ServiceMapView.swift) | Service calling patterns, branch routing and selected-range fallback. |
| [Progress estimator](https://github.com/mwagstaff/train-track-uk/blob/978cb734cee54dd7a831c06a1d9308bb6fa7110d/ios/TrainTrack%20UK/TrainTrack%20UK/ServiceProgressEstimator.swift) | Timing-based movement, departure safety interval and midnight handling. |
| [Service-details integration](https://github.com/mwagstaff/train-track-uk/blob/978cb734cee54dd7a831c06a1d9308bb6fa7110d/api/train-track-api/lib/service-details.js) | Public LDBWS and staff-derived details. |
| [Routing regression tests](https://github.com/mwagstaff/train-track-uk/blob/978cb734cee54dd7a831c06a1d9308bb6fa7110d/ios/TrainTrack%20UK/TrainTrack%20UKTests/RailwayRoutingTests.swift) | Coverage examples, difficult station approaches and presentation checks. |

