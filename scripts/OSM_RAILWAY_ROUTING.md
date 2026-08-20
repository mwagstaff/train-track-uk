# OSM railway routing data

This toolchain builds a topology-preserving Great Britain railway graph from
OpenStreetMap and validates it with Kent House to Victoria, Southern Victoria
to Brighton, and Thameslink Bedford to Brighton calling patterns.
Generated downloads and assets are development artifacts under
`scripts/.osm-routing-cache/`; they are intentionally excluded from Git.

## Setup

The scripts require `osmium-tool`, Python 3.12, and the pinned Python dependency:

```sh
brew install osmium-tool
python3.12 -m venv scripts/.osm-routing-venv
scripts/.osm-routing-venv/bin/pip install -r scripts/requirements-osm-routing.txt
```

## Build and validate

```sh
scripts/get_osm_railway_data.sh
scripts/build_osm_railway_routing.sh
```

To rebuild the Great Britain asset bundled by the iOS app:

```sh
scripts/build_osm_railway_routing.sh \
  --asset-region "Great Britain" \
  --asset-output "ios/TrainTrack UK/TrainTrack UK/Resources/railway-routing-great-britain-osm.json"
```

The build writes:

- `railway-routing-great-britain.json`: compact schema-v1 iOS routing asset.
- `route-kth-vic.geojson`: inspectable proof-of-concept route and calling points.
- `osm-railway-diagnostics.json`: source, graph, station matching, and route metrics.

For a quick visual check against OpenStreetMap tiles, serve the repository and
open the development-only preview:

```sh
python3 -m http.server 8765
open http://localhost:8765/scripts/osm_route_preview.html
```

The default preview route is `KTH,PNE,SYH,WDU,HNH,BRX,VIC`. A different calling
pattern can be checked with `--route CRS,CRS,...`. Every build also runs the two
complex-station regressions. They reject excessive detours, yard/siding
excursions, and material backtracking around Clapham Junction and St Pancras.

## Source and attribution

The source snapshot is the Great Britain extract supplied by Geofabrik. The
download script verifies Geofabrik’s checksum and records source, filter, and
output SHA-256 hashes. The generated graph and GeoJSON carry the attribution
`© OpenStreetMap contributors` and identify the source licence as ODbL 1.0.

When an OSM-derived asset is shipped, expose the recorded attribution in the
map UI and retain the build metadata alongside the release.

## August 2026 proof-of-concept result

The 14 August 2026 OSM snapshot produced 89,820 rail ways, 107,915 graph nodes,
118,480 graph edges, and anchors for all 2,605 catalogue stations. The seven-stop
Kent House to Victoria route was continuous and 12.519 km long. All seven stops
matched OSM `ref:crs` values. It used no siding or yard edges; two crossover
edges were used on the final approach to Victoria.

Station anchors combine the OSM station point and catalogue coordinate, then
choose nearby passenger tracks from distinct railway corridors before adding
parallel tracks from the same corridor. This prevents a large station's nearest
platform family from crowding the correct service corridor out of the compact
asset. Calling-pattern routing also penalizes immediately retracing an incoming
graph edge.

On the development machine, preprocessing the 23.41 MB filtered PBF took about
18 seconds and peaked just under 1 GB of memory. The compact whole-country JSON
with routing costs is about 26 MB. Accordingly, preprocessing runs offline rather than on the
production API server. The generated graph is loaded by the iOS app only
when an OSM map route is requested.

## In-app OS/OSM comparison

The app bundles a Great Britain OSM routing asset alongside the existing
OS-backed London asset. Open a train service, select **Map**, then use **Railway
map data → OS / OSM** to reroute the same calling pattern against either source.
OS remains the default and the last selection is retained locally. The OSM map
shows a linked `© OpenStreetMap contributors` attribution.

The OSM asset covers England, Scotland, and Wales. Northern Ireland and Ireland
are deliberately out of scope. It contains 107,915 nodes, 118,480 edges, and
anchors for all 2,605 stations in the Great Britain station catalogue. Its
optional edge-cost field preserves preprocessing penalties for sidings, yards,
spurs, and crossovers while route distances remain physical metres. The current
OS schema remains compatible because missing costs default to edge length.

Coverage QA routes span Penzance to Plymouth, Cardiff to Swansea, Crewe to
Holyhead, London to Edinburgh, Edinburgh to Inverness, Inverness to Wick, and
Birmingham to Aberystwyth. These are exercised by the iOS routing tests using
plausible distance bounds. Exact regressions also cover Victoria–Clapham
Junction–Selhurst and Kentish Town–St Pancras–Blackfriars.
