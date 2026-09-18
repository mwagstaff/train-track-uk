# TubeTrack London journey integration

The planner uses TubeTrack to resolve National Rail `TUBE` fixed links before
ranking journeys and checking onward connections. Searches still use existing
National Rail stations; no Tube-only stations were added to the station picker.
National Rail vehicle legs and walking recommendations remain authoritative.
In particular, St Pancras–King’s Cross stays a walk and makes no TubeTrack request.

## Mapping and regeneration

`api/train-track-api/resources/london-tfl-stations.json` maps 165 existing London
CRS codes to TfL stop IDs or multi-stop hubs. It retains all associated stop IDs,
the selected routing ID, matching evidence and explicit unmapped dispositions.
Paddington uses its hub so the planner can consider its different TfL services.
All existing London stations used by the supplied ALF Tube links are mapped;
the remaining 22 audited endpoints are four outside London and 18 absent from
the existing station catalogue. The coverage audit box is not a London boundary.

Matching requires a name/alias match corroborated by location, or a reviewed
override. The generator does not choose the nearest station. Reviewed adjacent
interchanges include:

| National Rail station | TfL access | Additional access walk |
| --- | --- | --- |
| Fenchurch Street | Tower Hill | 3 minutes, from [c2c’s station guidance](https://www.c2c-online.co.uk/stations/london-fenchurch-street-station/) |
| City Thameslink | Blackfriars | 5 minutes, from the supplied National Rail ALF walking link |
| Waterloo East | Southwark | Direct interchange confirmed by [Southeastern](https://www.southeasternrailway.co.uk/travel-information/station-information/stations/london-waterloo-east); existing station allowance retained |

Access walks are added to the existing station allowance and explained in
journey notes. A 10-minute endpoint allowance is used only when no station
allowance is available; it is not added again to a known allowance.

Run from `api/train-track-api` to refresh the committed station and colour files:

```sh
rtk proxy node scripts/generate-tfl-stations.js
```

For deterministic regeneration, retain complete JSON responses from `/stations`
and `/line-colours`, use the same National Rail station catalogue and ALF input,
then run:

```sh
rtk proxy node scripts/generate-tfl-stations.js --stations-file /absolute/path/stations-response.json --colours-file /absolute/path/line-colours-response.json
```

Identical inputs generate byte-identical output. Review mapping, palette and
audit changes before release, especially changed aliases and new hub IDs. The
optional `--alf-file` selects a particular local ALF; without local ALF data the
fixed-link audit is empty. `--output-dir` can write into an existing review folder.

## Routing, timing and presentation

Supported journey steps are Underground, Elizabeth line, DLR, Overground and
walking. An itinerary containing an unsupported mode is excluded as a whole;
its legs are never silently removed. Requests use explicit zoned instants and
`departAt` or `arriveBy`. Station access, internal waits and changes, the user’s
connection buffer and disruption contingency all enter connection validation.
TfL vehicle boardings count towards the total changes and maximum-change filter,
including a change between two services with the same line name.

Selection is automatic. The details screen replaces the generic Tube operator
pill with named line pills and shows ordered directions, change stations,
estimated/adjusted timings, transfer allowances, warnings and decision notes.
TfL IDs remain separate from National Rail CRS identities. `/line-colours`
provides background and text colours; the provider retains bundled/last-good
colours on failure and uses a neutral named pill for an unknown line.

Disruption policy:

- Minor delays add five minutes per affected London transfer. A note explains
  the contingency, and onward trains must still be reachable. Arrive-by searches
  also reserve this allowance when seeking an earlier TfL option.
- Major disruption favours a feasible less-disrupted option, with a note naming
  the reason for the alternative. If only a disrupted usable option is returned,
  the warning remains visible.
- Confirmed applicable closures exclude the affected connection. National Rail
  fallback cannot restore a connection when all known options are closed.
- Broad partial-closure messages do not prove every section is closed. Precise
  exclusion needs a full closure or explicit leg applicability. Missing/stale
  disruption coverage is uncertainty, not confirmation of an unaffected route.

The API’s disruption score is not interpreted as minutes. Validity periods and
structured journey/leg issues are preserved, and duplicate warning text is
removed. An unaffected future option can report no planned disruption; that is
not a promise about conditions on the day. Refresh is driven by searches and
existing refresh requests, with no new background monitoring or push updates.

## Availability and operating limits

The worker-scoped provider shares identical requests, allows two active HTTP
requests, allows up to 12 journey lookups per search and stops starting uncached
lookups after eight seconds spent looking up routes. A final request may run up
to its four-second deadline. Searches share their budget across routing passes;
board refreshes have an absolute cap of 32 lookups and the same elapsed limit.
Cached results remain usable within their expiry. Cancellation stops unused requests. Journey cache validity is at most 30 seconds and
never exceeds the upstream `expiresAt`; stale responses are not fresh directions.
The selected TfL expiry also constrains planner/board freshness. The palette is
refreshed daily, with a brief retry delay following failure.

Pages within one search retain the same ranked alternatives until their TfL
information expires, then require a fresh search. Selected journey details keep
the original directions and check time, with an expiry warning. Stored saved-route
templates contain National Rail link allowances; refresh obtains current TfL
directions and disruption notes instead of replaying stored forecasts.

During an API outage or unmapped lookup, the National Rail transfer estimate
remains available with a clear warning. A bounded memory of recent station-pair
observations retains disruption evidence for nearby refresh times only while
explicit validity periods apply. It keeps unaffected alternatives too, so an
outage does not falsely imply every route is closed. This evidence never supplies
old journey timings as current directions. Successful empty API results mean no
returned supported option, not an API outage.

The integration cannot invent alternatives the API did not return. Structured
affected-section/stop IDs would improve handling of broad partial closures.
Timings and source coverage remain estimates; the existing planner search and
resource limits still apply.

## Validation and release

From `api/train-track-api`:

```sh
rtk proxy node --test test/planner-tube-*.test.js
rtk npm run test:planner
```

iOS coverage is in `JourneyPlannerTests` and the two `testTubeTrackDirections…`
cases in `JourneyPlannerUITests`, using the local `journey_planner_ui_fixture.py`
server on port 3014. Run the unit suite and those UI cases on an available iOS
simulator; the latter cover disruption notes, line pills and large text/dark mode.

Release requires the updated API and rebuilt iOS app; these local changes do
not deploy either. No new API credential, timetable import or database migration
is required. Set `PLANNER_TUBETRACK_ENABLED=false` in the API service environment
and restart it to disable TubeTrack and return to National Rail transfer routing.
The default is enabled. Existing clients tolerate the additive journey fields.
