# Kent House arrival welcome and upstream route map, 29 September 2026

## Evidence (British Summer Time)

Read-only production queries for the matching KTH–VIC device/route found:

- 07:32:13: approach region entered.
- 07:35:14: outer station region entered.
- 07:36:24: tight arrival region entered.
- 07:36:24.967: Live Activity update accepted with phase `at_start`.
- No welcome alert was sent at arrival. The origin-arrival implementation only
  captured departures and updated the Live Activity; it did not schedule a greeting.
- 07:44:47: station exit recorded.
- 07:44:49.921: boarding greeting accepted by APNs, identifying the delayed 07:42
  to London Victoria. The user independently confirmed receiving it.

Arrival detection and subsequent tracking worked. This was a missing notification
step, not a failure to detect the station or a recurrence of the phase-reset bug.

The user clarified that the missing grey map stations are those **before Kent
House**, not stations passed after boarding. The staff-first departure migration
(`1e02d5f`) populated service details from `GetDepBoardWithDetails`. A read-only
request for today's exact RID `202609298086990` confirmed that the Kent House
response supplies subsequent locations but no previous locations. The existing
map combines previous/current/subsequent calling points, so those absent stations
cannot appear. Separately, live railway segments were all coloured by delay and
non-origin dots were white, with no styling for the section before boarding.

## Local corrections

- The first confirmed origin arrival schedules a separate local welcome, using
  the existing departure snapshot. It names the next usable train and its known
  platform; delays remain explicit. Missing data produces a welcome without an
  invented time/platform. Cancelled and already-departed services are excluded.
- The persisted origin-arrival guard prevents repeat handling, including repeated
  callbacks and same-route subscription replacement. Explicit boarding does not
  create a late welcome. Replayed arrivals older than two minutes are suppressed.
- Tapping the welcome opens In Progress without muting the journey.
- The API obtains the missing earlier calls on demand from the origin board,
  matching RID and the full dated boarding departure. Today's exact-service
  fixture recovers Orpington, Petts Wood, Bickley, Bromley South, Shortlands and
  Beckenham Junction before Kent House. Successful recovery survives subsequent
  boarding-board refreshes; concurrent detail requests share the lookup.
- Following the styling clarification, only geometry behind the displayed train
  position renders grey, including the travelled portion between stations.
  Unreached sections retain blue/yellow/red delay colouring, even before the
  passenger’s boarding station. Passed station dots also turn grey; the boarding
  marker remains orange until passed. Historical-route highlighting is unchanged.
  Missing train progress does not cause any live section to be greyed.

The extra origin lookup has a three-second timeout and a two-hour lookback,
filtered to the boarding station. It is best effort: origin journeys longer than
that window, provider row limits, missing/ambiguous identities, unavailable data
or branch associations can still leave earlier stations absent. Failures retain
onward live data and are throttled for 30 seconds. This does not reconstruct a
route from a different train. The separately tried staff arrival/departure and
RID-detail endpoints were not routed by the licensed provider product.

## Validation

All 22 selected backend tests and 51 selected iOS simulator tests passed.
Targeted backend regression tests cover today's
captured public train data, refresh retention, concurrency, wrong train/date,
ambiguous/truncated responses, lookup failure and midnight boundaries. iOS tests
cover the welcome text/selection, pre-boarding map styling and existing route,
boarding-evidence and geofence concurrency behaviour, including rendered MapKit
annotation tests. Physical-device notification delivery has not yet been tested.

The subsequent train-progress styling revision passed all 35 railway routing
tests, including partial-segment geometry, skipped calls, unavailable progress,
delay colours and historical highlights.

No production code, subscriptions or notification settings were changed. The
fix requires an API deployment and an updated iOS build.

Reference: [National Rail staff API specification](https://realtime.nationalrail.co.uk/LDBSVWS/static/ldbsvws.json)
and [Apple local notification API via Sosumi](https://sosumi.ai/documentation/usernotifications/unusernotificationcenter/add(_:withcompletionhandler:)).


## Follow-up: map stops moving before Kent House

The 09:08 screenshot shows the 09:12 service still at Bromley South. Both
mini and full maps use `ServiceMapView`, which requests fresh service details
every 20 seconds and recalculates displayed progress every five seconds.
`DeparturesStore.ensureServiceDetails(force: true)` bypasses its local freshness
check and installs returned detail updates.

The earlier route-recovery change introduced a backend cache bug:
`restorePreviousCallingPoints` returned immediately whenever previous calling
points already existed. Their station names and geometry were retained, but so
were their forecasts and actual times. A newer Kent House board refreshed the
response timestamp without refreshing those earlier live observations. That can
freeze both maps at the last known station before Kent House.

Removed the existence-based early return. Earlier calling-point timings now
refresh using their independent 30-second freshness window, even when regular
boarding-board polling keeps the rest of the service details fresh. Concurrent
requests still share a lookup; failed refreshes retain the last good route and
retry after the freshness window.

Regression tests first reproduced the freeze and missing retry, then passed with
the fix. All 24 selected backend tests passed, including advancing a Shortlands
forecast to an actual departure while the Kent House board remains fresh,
concurrent requests, and failure/recovery without losing earlier stations.
This follow-up changes backend code only and requires an API deployment; no
additional iOS rebuild is needed for this refresh correction. It has not been
deployed by this task.
