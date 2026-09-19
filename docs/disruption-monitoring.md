# Advance saved-journey disruption monitoring

The API and iOS app support automatic monitoring of saved directions in
Favourites and My Journeys. The API is deployed on `sky` in shadow mode with the
subscribed engineering feed connected. An iOS release and repair of the missing
timetable amendment chain remain separate rollout steps.

## Behaviour

- All saved routes are registered once, with ordered intermediate stations and
  separate outward/return directions. Existing unambiguous notification schedules
  seed the initial travel hours; otherwise every day, 00:00–24:00 is selected.
- Users can disable a direction, change weekdays/common or per-day hours, and
  optionally enable pushes. Registering a monitor needs no push permission,
  location access, or Live Activity permission. Up to 100 distinct saved
  directions can be registered per installation; larger snapshots are rejected
  explicitly, never silently truncated.
- Detailed checks cover today and the next six London calendar dates, retaining
  the ongoing part of an overnight window that started yesterday. Selected
  windows are split into exact intervals of at most one hour. One-off dates
  outside that horizon wait until they enter it.
- Official engineering notices can appear up to 84 days ahead, restricted to
  the user's chosen travel dates/hours. Repeated validity periods of one
  incident produce one advisory with distinct affected periods and one push.
- Required replacement buses can produce a warning without a baseline.
  Missing direct trains and longer journeys require two complete comparable
  weekdays/windows, initially seven and fourteen days earlier. Known UK bank
  holidays and comparisons across the May/December timetable change are
  excluded. The official GOV.UK bank-holiday calendar must be available for
  these comparisons. Existing complete historical profiles are reused across
  source versions; missing ones are checked in the background.
- Longer journeys qualify at **15 additional minutes**, or **25% longer with
  at least five additional minutes**. Empty, ambiguous, truncated or failed
  checks remain unknown. Timetable comparisons never invent a line closure or
  engineering-work cause. Known timetable coverage exclusions remain explicit.
- Pushes are optional, suppressed in Holiday Mode and 22:00–07:00 London quiet
  hours. Persistent receipts suppress repeated sends and survive restart.
  Changes to affected periods, notice titles, or duration in five-minute bands
  can update a warning; copy-only changes do not repeat a push. APNs collapse
  identifiers merge retries, and expiry headers bound late delivery. APNs
  remains best effort; receipts record acceptance, not proof of user receipt.
- Notification taps open the affected saved direction's warning detail and
  alternative-journey search. Advance warnings bypass today's live journey
  arrival/mute/geofence processing.

## Scheduling and storage

`DisruptionMonitor` owns a durable Mongo backlog outside the interactive search
queue. Profiles are shared by ordered stations, London date, exact time window
and timetable version; no device identifier enters a shared profile. Preference
records and delivery receipts remain device-specific and are removed by the
existing authenticated device-data deletion operation. In-flight writes and
delivery attempts are drained before that deletion completes. The app retains
an explicit suspension when it receives HTTP 410, and retries failed edits or
deletions on the next foreground sync.

One maintenance job runs at a time, only when there is no interactive or visible
saved-board work and host headroom permits it. Maintenance never ages ahead of
user demand, does not consume their admission quota, and yields on new demand.
With two workers it uses only the second, preserving the first worker's hot
graph. A noncooperative calculation is stopped after a 100 ms cancellation
grace period. Work is timetable-only: it makes no live rail or TfL calls.

Today/nearest dates have priority, with their baseline work ahead of later
dates. Completed jobs survive restart; leases recover abandoned jobs. Up to
three retries follow transient failures before a window stays unknown for that
version. Profiles expire 45 days after their travel date, and delivery receipts
seven days after the affected period. Identical completed calculations are not
repeated on every timer tick. Multiple installations reuse shared work.

Admission checks use free memory and load average, not OS-enforced isolation.
Index preparation and routing still consume CPU and memory. Pure spare-capacity
execution cannot guarantee completion by a deadline during sustained demand.
The performance report records actual measurements and their limits:
[disruption-monitor-performance.md](disruption-monitor-performance.md).

## Data readiness and rollout

`DISRUPTION_MONITOR_MODE` defaults to `shadow`. In this mode the backend evaluates
and persists results, but returns no user advisories and sends no pushes. The
app explains that monitoring is being prepared. `off` stops background work;
`active` exposes advisories and permits explicitly opted-in pushes.

Confident timetable comparison requires all of:

1. An available snapshot with a known publication date no more than 48 hours old.
2. A readable, enabled ingestion state, no import in progress and no update gap.
3. Successful validation and matching active dataset version/publication.
4. A successful ingestion check within the previous six hours.

A new import timestamp or a successful unchanged bucket check cannot make an
old publication fresh. These checks are intentionally stricter than the
interactive planner's monthly-feed stale-data tolerance.

The 18 September ingestion investigation found missing daily deliveries
940–961 after full package 939 (25 August). Obtain a complete current baseline or
the contiguous missing chain before enabling timetable-based warnings. See
[planner-s3-ingestion.md](planner-s3-ingestion.md). Official notices can work
independently while timetable readiness is unavailable.

The engineering provider follows National Rail Incidents v5. That feed contains
free-text `RoutesAffected`, not structured station CRS data. Matching requires
all selected journey stations in the same affected-service clause, using exact,
unambiguous station catalogue names. An explicitly named whole-station closure
at a selected station also qualifies, including a station list immediately
following an explicit closure heading. A shared terminal, operator name,
separate route clauses, profile station unions, ticket acceptance and alternative
travel advice do not establish relevance. Manual browsing, automatic warnings
and baseline exclusions use the same rule. `Progress=closed` means a cleared
incident, not a closed railway.

This deliberately conservative rule can omit relevant notices that name only
the ends of a line, rather than a selected station. Reliable corridor/service
mapping would be needed to include those notices without bringing back warnings
for unrelated branches. **May affect your journey** remains appropriate; this
version cannot claim exhaustive national disruption coverage.

The subscribed Rail Delivery Group product is
[Knowledgebase Incidents data](https://raildata.org.uk/dashboard/dataProduct/P-cf16832d-d971-46e7-8883-4fca2101d3fa/overview)
(Marketplace version 1.0, Incidents v5 XML). Its endpoint is
`https://api1.raildata.org.uk/1010-knowlegebase-incidents-xml-feed1_0/incidents.xml`.
Supply its API key through the Bitwarden-backed server environment variable
`TRAIN_TRACK_UK_DISRUPTIONS_API_KEY`. When this key is set and
`DISRUPTION_NOTICE_URL` is absent, the API selects that endpoint and sends the key
as `x-apikey`; no separate URL or header configuration is needed.

`DISRUPTION_NOTICE_URL` remains an explicit override. The implicit Marketplace
key is attached only to the exact HTTPS endpoint above, including when that URL
is explicitly configured. It is never automatically forwarded to a different
host, path or query. Custom endpoints must supply their own explicit headers or
authorization settings. An explicit `x-apikey` in
`DISRUPTION_NOTICE_HEADERS_JSON` takes precedence regardless of header casing.
Existing Authorization and Basic authentication settings continue to work;
the complete Authorization setting takes precedence over Basic credentials.
Keep credentials in server deployment configuration, not the repository.

Transport is HTTPS, refuses redirects, has a 10-second
deadline and a 5 MiB decoded-body limit, and refreshes at most every five minutes.
Missing access, invalid XML or upstream failure is unavailable, not an empty
healthy feed. Previous unexpired warnings verified under the current relevance
rule remain visible with their original check time while a source is unavailable.
Legacy warnings created by the broader station-overlap matcher are hidden and
discarded, including during source failures, and cannot be pushed. Official
source links are restricted to National Rail.

Individual incidents with invalid data, such as an end time before their start,
are quarantined without discarding other valid notices. A partial snapshot
retains previous unexpired warnings for those incident IDs; if a broken record
has no usable ID, all previous unexpired official warnings are retained. Valid
notices can still be published and unrelated resolved incidents cleared. An
invalid envelope or a feed with no surviving planned notices after quarantine
remains unavailable. The strict standalone parser continues to reject invalid
records; this partial-feed policy applies to the background provider.

| Setting | Default / purpose |
| --- | --- |
| `DISRUPTION_MONITOR_MODE` | `shadow`; `active` or `off` |
| `DISRUPTION_CHECK_INTERVAL_SECONDS` | 1; delay between bounded work iterations |
| `DISRUPTION_DEMAND_REFRESH_SECONDS` | 300; source and demand refresh interval |
| `DISRUPTION_MAX_SOURCE_AGE_HOURS` | 48 |
| `TRAIN_TRACK_UK_DISRUPTIONS_API_KEY` | Bitwarden-backed Knowledgebase Incidents data key; selects the endpoint above and supplies `x-apikey` |
| `DISRUPTION_NOTICE_URL` | Optional endpoint override; defaults to the subscribed XML endpoint when the Marketplace key is set |
| `DISRUPTION_NOTICE_AUTHORIZATION` | Optional complete Authorization header |
| `DISRUPTION_NOTICE_USERNAME`, `DISRUPTION_NOTICE_PASSWORD` | Optional Basic credentials |
| `DISRUPTION_NOTICE_HEADERS_JSON` | Optional JSON object of provider headers; explicit `x-apikey` overrides the Marketplace key |
| `PLANNER_MAINTENANCE_TIMEOUT_MS` | 10000; maximum 30000 |
| `PLANNER_MAINTENANCE_MAX_OPERATIONS` | 10000000 |
| `PLANNER_MAINTENANCE_MIN_FREE_MEMORY_MB` | 512 |
| `PLANNER_MAINTENANCE_MAX_LOAD_PER_CPU` | 0.8 |

Recommended activation sequence: repair/verify source delivery and provision
the official feed; deploy in shadow mode; measure foreground p95/p99 latency,
RSS, backlog age and known-work detection on the actual host; then enable
in-app warnings and test an explicitly opted-in physical device before wider
push rollout. API deployment and an updated iOS build are both required.

### Feed connection verified on 19 September 2026

The Bitwarden-backed key was present in the running `sky` service. An
authenticated request to the subscribed endpoint returned HTTP 200 and valid
XML containing 1,035 incidents, including 997 marked planned. The parser
accepted 994 planned incidents; 979 had at least one unambiguous station-name
match. Three incidents had reversed or zero-length date ranges and were
quarantined without discarding the valid notices. These are snapshot counts,
not a guarantee of route coverage or a count of upcoming warnings.

The configuration and partial-feed handling were deployed with the standard
quick deployer, preserving the existing Bitwarden environment. Afterwards,
the running service reported `disruption_notices_available=1` and
`disruption_timetable_ready=0`; public health and disruption endpoints returned
HTTP 200 and the latter confirmed `mode=shadow`. The active timetable was still
published on 25 August. No user alerts were enabled. Validation passed 880 API
tests, including real Mongo persistence, with five existing optional skips.

## API and operations

- `PUT /api/v2/disruptions/monitors` replaces one installation's saved monitor
  snapshot. Fields: `device_id`, `monitors`, optional `push_token` and
  `use_sandbox`. Each monitor has `id`, ordered `stations`, `name`, `enabled`,
  ISO `days` (Monday=1), `window_start`, `window_end`, optional `day_windows`,
  optional `travel_date`, and `push_enabled`. JSON is limited to 64 KiB.
- `GET /api/v2/disruptions?device_id=...` returns mode, seven-day horizon,
  per-monitor status/last-check/reason, and active advisories. These endpoints
  read/write preferences and cached state; neither starts a journey search.
- `GET /api/v2/disruptions/future?stations=CLK,LBG` browses published engineering
  notices for an ordered direction (including any selected intermediate station
  codes). It is independent of automatic monitoring, notification permission,
  saved travel hours and shadow mode. All unexpired published periods are
  included, without the seven-day or 84-day monitoring limits. Incidents are
  grouped once and sorted by their earliest remaining period, including ongoing
  work. This reads the shared feed cache and never starts a timetable search.
  The response distinguishes `available`, `partial` and `unavailable`; an empty
  result is not a promise that the route is clear.
- `affectedWindows` preserves disjoint periods. Bounding `startAt`/`endAt`
  remain for older clients; updated clients present the distinct periods.
- The existing anonymous-installation identity model is retained. Device data
  deletion continues to require the existing admin authorization.
- `/metrics` exposes `disruption_timetable_ready`,
  `disruption_notices_available`, `disruption_pending_profiles`,
  `disruption_oldest_pending_seconds`, and bounded
  `disruption_checks_total{outcome}`. No route or device labels are added.

## Validating the feed and timetable import

The engineering XML feed is cached in the API process for five minutes. It is
**not imported into a Mongo collection**. An empty `disruption_monitors`,
`disruption_profiles` or `disruption_deliveries` collection does not establish
whether the engineering feed is working:

| Collection | When records appear |
| --- | --- |
| `disruption_monitors` | An updated app registers its saved directions and monitoring preferences. Each installation has one document. |
| `disruption_profiles` | A registered route needs timetable checks and the timetable passes the publication/ingestion readiness gates. These are shared timetable calculations, not engineering notices. |
| `disruption_deliveries` | An active, opted-in monitor attempts a push. Shadow mode creates no delivery receipts. |

For a route-specific check, open
[Clock House → London Bridge future disruptions](https://api.skynolimit.dev/train-track/api/v2/disruptions/future?stations=CLK,LBG).
Check `status`, `checkedAt` and `notices`. `partial` means valid notices are
available but some source records were rejected; `unavailable` must not be
interpreted as no disruptions. The app's **View future disruptions** screen
uses this same endpoint and displays the last check and any source limitation.

For a fresh, read-only feed validation on `sky`:

```sh
rtk proxy ssh sky 'cd /home/mwagstaff/dev/train-track-api && source .static-config-train-track-api.env.sh && source .bw-secrets.env.sh && /home/mwagstaff/.local/share/train-track-api/runtime/node24/bin/node scripts/disruptions.js validate --stations CLK,LBG'
```

This reports HTTP status, accepted/remaining/quarantined incident counts, route
matches and the first five notices. It prints no credentials, registers no
devices, writes no database records, performs no journey searches and sends no
pushes. Exit status is 0 for a complete feed, 2 for a usable partial feed and 1
for unavailable/invalid input. It makes one fresh feed request per invocation;
use the cached endpoint for routine browsing.

Timetable import is separate. Its read-only checks are the existing
[planner status endpoint](https://api.skynolimit.dev/train-track/api/v3/journey-planner/status)
and `/home/mwagstaff/.local/share/train-track-api/planner/ingestion-state.json`
on the server. Check the actual `sourceGenerationDate`, successful validation,
matching active version, `pendingGap: null` and a recent
`lastSuccessfulCheckAt`. A recent check or import timestamp alone is not fresh
source data. On 19 September, the feed check succeeded but timetable ingestion
still reported `expectedSequence: "940"`, `actualSequence: "962"`,
`missingCount: 22`, and source publication 25 August. The monitor correctly
reported `disruption_notices_available=1` and `disruption_timetable_ready=0`.

The first manual-browsing version used station overlap, returning 39 notices for
`CLK,LBG` and 72 for `KTH,VIC`; those counts included unrelated services sharing
a London terminal and are not useful coverage measures. The relevance fix was
checked against the same 19 September feed. `CLK,LBG` and its reverse each match
two explicit Clock House closure notices: replacement buses between Lewisham
and Hayes on 19–20 September and 6 December. The Southern/Norwood Junction and
Cannon Street/Greenwich examples are excluded. `KTH,VIC` matches the 27 September
Denmark Hill–Bromley South notice, which explicitly closes Kent House. These are
snapshot results, not a guarantee that every relevant work item has been matched.

The corrected matcher was deployed to `sky` on 19 September. Public endpoint
checks confirmed those results in both Clock House directions, chronological
ordering, HTTP 200 health and unchanged shadow mode. The full API suite passed
898 tests with five existing optional skips; the iOS build and 20 focused tests
also passed. The server-side matching fix works with the existing app build;
close and reopen the future-disruptions screen to discard its in-memory list.

The validation command reported HTTP 200, 994 accepted planned incidents and
three quarantined records, so `partial` and command exit status 2 were expected.
Reading the list does not create Mongo monitoring records.
The iOS build passed 20 focused unit/store tests and two HTTP-backed UI tests,
including both saved tabs, light mode, largest-text dark mode, and feed outages.
Manual browsing preserves previously loaded notices with an explicit stale-data
message during an outage. Install an updated iOS build to use the new menu.

Tests cover the policy, feed schema, queue preemption, exact intervals,
overnight/DST boundaries, persistence, restart, duplicate alerts, quiet hours,
opt-out/deletion races, missing baselines and feed outages. The optional real
Mongo test uses a unique temporary database and drops it on completion:

```sh
rtk proxy env DISRUPTION_TEST_MONGODB_URI=mongodb://127.0.0.1:27017 node --test test/disruption-store.test.js
```

App tests cover automatic defaults, schedule seeding, offline updates/deletions,
permission separation, disjoint periods, source URLs and cached warnings.
Simulator checks cover both saved tabs, light/dark appearances and the largest
Dynamic Type size. The entitled live engineering feed was verified as recorded
above. Physical-device APNs remains a release check and has not been exercised.
