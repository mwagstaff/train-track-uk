# Train Track API

API for the [TrainTrack UK](https://apps.apple.com/gb/app/traintrack-uk/id6504205950) app.

## Live National Rail disruptions

`GET /api/v2/disruptions/live` returns published, currently active, unplanned
incidents nationwide. No device ID or saved journey is required. Optional
`?operator=SE` filters by a two-character uppercase TOC code, including incidents
affecting all operators. Unknown valid codes can return an empty list; malformed,
repeated or unsupported query parameters return HTTP 400.

After deployment:

```sh
curl https://api.skynolimit.dev/train-track/api/v2/disruptions/live
curl 'https://api.skynolimit.dev/train-track/api/v2/disruptions/live?operator=SE'
```

Example response (illustrative incident):

```json
{
  "status": "available",
  "checkedAt": "2026-10-06T12:00:00.000Z",
  "lastAttemptAt": "2026-10-06T12:00:00.000Z",
  "ageSeconds": 0,
  "stale": false,
  "reason": null,
  "incidents": [{
    "id": "example-incident",
    "title": "Signal failure",
    "body": "Trains are delayed.",
    "sourceURL": "https://www.nationalrail.co.uk/status-and-disruptions/",
    "operators": [{ "code": "SE", "name": "Southeastern" }],
    "allOperators": false,
    "routesAffected": "Between London and Kent",
    "priority": 1,
    "updatedAt": "2026-10-06T11:30:00.000Z",
    "startAt": "2026-10-06T11:00:00.000Z",
    "endAt": null
  }]
}
```

`status` is `available`, `partial` (some records were rejected), or `unavailable`.
Usable snapshots return HTTP 200; unavailable snapshots return HTTP 503 with
`Retry-After: 60`. `checkedAt` is the last usable fetch time, not an incident's
publication time; `lastAttemptAt` is the last completed fetch attempt. Both are
UTC ISO timestamps; `checkedAt` and `ageSeconds` are null before the first usable
fetch. Incident times respect the offsets supplied by National Rail. A null
`endAt` means the end is unknown. Priority is the source's 0–2 value (0 first),
or null when unknown, not an inferred severity. Results sort by priority, then
most recently updated, then ID.

The API uses the existing `TRAIN_TRACK_UK_DISRUPTIONS_API_KEY` and feed overrides.
One in-memory provider per API process supplies both live incidents and planned
engineering notices. It refreshes in the background even with automatic journey
monitoring off. `DISRUPTION_NOTICE_REFRESH_SECONDS` defaults to 60 and accepts
60–300 seconds; configure it to match the subscribed product's polling allowance.
Concurrent requests share a fetch. Warm live requests use the cache immediately
while an overdue refresh runs. Responses use `Cache-Control: no-store` so clients
see current freshness metadata; polling once per minute is sufficient.

During an outage, the last usable snapshot remains available with `stale: true`
for at most ten minutes from its fetch, then the endpoint returns HTTP 503.
Expired incidents are still filtered on every read. An unavailable or partial
empty response must never be described as an all-clear. Partial feeds contain
only successfully validated incidents and may omit rejected records. The cache
is not persisted across restarts. No timetable search or notification is triggered.

This is a feed of published incidents, not every individual delayed or cancelled
train. Planned work remains at `/api/v2/disruptions/future?stations=CLK,LBG`.
Affected routes are source prose, not guaranteed station or journey coverage.
Render `body` and `routesAffected` as text; link to `sourceURL` for official advice.

Metrics: `disruption_feed_refreshes_total{outcome="complete|partial|unavailable"}`
and `disruption_feed_last_success_timestamp_seconds`. Use
`time() - disruption_feed_last_success_timestamp_seconds` for feed age;
the existing HTTP metrics cover endpoint latency and errors.

## Station-wide live departures (TubeTrack)

`GET /api/v2/departures/from/:fromStation` returns upcoming departures across
all operators and destinations. The existing V1 URL is an alias with the same
response. Supply a three-letter CRS code; lowercase is accepted and malformed
codes return HTTP 400. No destination is required.

After deployment, for Kent House:

```sh
curl https://api.skynolimit.dev/train-track/api/v2/departures/from/KTH
```

The response is an object containing `departures`, `dataStatus` (`live`, `partial`,
`stale` or `unavailable`) and `lastSuccessfulUpdate` (ISO timestamp or null).
Each train includes `serviceID`, `operator`, `operatorCode`, `departure_time`
(`scheduled` and `estimated`), `destination` (`crs`, `locationName`), plus platform
and cancellation fields when supplied. Dividing trains can have a destination
array. Estimates can contain status text such as `Delayed` or `Cancelled`.
Times are UK local `HH:mm`; clients must handle midnight when calculating minutes
until departure. Missing platforms should be displayed as unknown.

TubeTrack can group trains by `operator`/`operatorCode`, or exclude Thameslink
using `operatorCode === "TL"` (falling back to the operator name when absent).
Replacement buses can also appear; inspect `serviceType` if displaying trains only.
Sort the displayed departures by departure time and retain cancellation indicators.
An unavailable response must not be displayed as “no trains”; use `dataStatus`
and `lastSuccessfulUpdate` to communicate freshness.

Boards use the existing 30-second fresh cache and stale fallback. Polling every
30 seconds while the station is visible is sufficient. Two upstream windows,
starting now and at +119 minutes, cover approximately the next four hours.
Each query requests up to 149 rows; busy stations and upstream restrictions can
limit coverage. This is an upcoming board, not an exhaustive full-day timetable.
Staff boards are preferred, with public boards as fallback. Station requests
do not populate the journey-pair recent-departures store.

## Staff-first departures

When `LIVE_DEPARTURE_BOARD_STAFF_VERSION_API_KEY` (or `STAFF_DEPARTURES_API_KEY`)
is configured, saved-journey departure boards use the staff `GetDepBoardWithDetails`
product first. Train and replacement-bus queries run together. Calling points are
cached for 30 seconds, so a subsequent map lookup normally needs no upstream call.
References contain the RID, boarding station, dated scheduled departure and mode;
they can be refreshed directly from a staff board after a restart or cache eviction.

Public boards remain the fallback when staff data is unavailable, truncated or
contains dividing/joining services that require the existing public branch resolver.
Both windows of a journey snapshot use the same provider to avoid duplicate rows
under different IDs. Existing public service references still use the public detail
endpoint. The separate journey planner's provider is unchanged.

`filterLocationCancelled`, `filterCRS` and `filterLocationName` describe cancellation
at the requested destination independently of `isCancelled` at the boarding station.
Clients must not infer cancellation from a different train terminus alone. Staff
platform suppression is retained as `platformIsHidden`; cached platforms must not
override it. Unknown staff forecasts remain unknown rather than becoming on time.

The current subscription supplies onward calling points, not the full service route
before boarding. Full staff service-detail access is not assumed. Numeric staff
reason codes are not exposed as passenger-facing reason text; only supplied text is
used. Staff data is filtered to exclude passing, operational and suppressed calls.

`/api/v2/service_details/...` keeps legacy empty-object errors by default. Clients
requesting `?includeStatus=true` receive `{error, unavailable}` for failed entries.
`unavailable: true` stops automatic map retries; generic provider failures, including
HTTP 500, are not classified as permanent expiry. The iOS map makes at most three
attempts before leaving a manual refresh action.

Regression fixtures for the Brighton short terminations are in
`test/fixtures/brighton-short-terminations.json`. For the iOS visual check, run
`node "ios/TrainTrack UK/TrainTrack UKUITests/staff_departures_ui_fixture.mjs"` from
the repository root, then run
`JourneyPlannerUITests/testStaffDestinationCancellationsAndUnavailableMapInLightAndLargeDarkText`.

## Railway Background Photos

See [Add or update background photos](../../BACKGROUND_PHOTOS.md) for the step-by-step image optimisation and deployment process.

## Live Activity Pushes

- Register a Live Activity push token and get the next 3 departures: `POST /api/v2/live_activities` with JSON body `{ "device_id": "...", "activity_id": "...", "live_activity_push_token": "...", "from": "EUS", "to": "WFJ" }`
- Poll interval defaults to 20s and can be tuned with `LIVE_ACTIVITY_POLL_INTERVAL_SECONDS`
- APNs settings: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_AUTH_KEY` (inline) or `APNS_AUTH_KEY_PATH` (defaults to `certs/APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8`), `APNS_LIVE_ACTIVITY_TOPIC` (defaults to `dev.skynolimit.traintrack.push-type.liveactivity`), `APNS_LIVE_ACTIVITY_ATTRIBUTES_TYPE` (defaults to `JourneyActivityAttributes`), `APNS_USE_SANDBOX` (default `false`; set to `true` to target sandbox)
- Persistent push state is stored in MongoDB via `MONGODB_URI_TRAIN_TRACK_UK` (defaults to `mongodb://localhost:27017/train_track_uk` for local development). Collections and indexes are created automatically on startup.
- Debug helpers for manual testing: `GET /api/v2/live_activities/debug/subscriptions` and `POST /api/v2/live_activities/debug/trigger` with `{ "device_id": "...", "activity_id": "...", "dry_run": true }`
- Live activities auto-end with a final push (event `end`, dismissal-date 0 for immediate dismissal) after `LIVE_ACTIVITY_END_AFTER_SECONDS` (default 7200s / 2 hours)

## Device Data Deletion

Delete all app-managed server data associated with an app installation:

```http
DELETE /api/v2/device_data
Authorization: Bearer <admin-deletion-key>
Content-Type: application/json

{ "device_id": "<installation-id>" }
```

Set `DEVICE_DATA_DELETION_API_KEY` on the server and keep it restricted to authorised support operators. The endpoint fails closed when the key is unset and never treats the user-visible installation ID as authentication. The response contains deletion counts but does not echo the installation ID. The operation removes app-managed MongoDB records, active and rotated subscription audit log entries, in-memory notification/Live Activity/journey-tracking state, holiday mode state, and the recent-device metrics entry.

Deletion coordination is process-local. The current deployment must remain a single Node.js service process while this endpoint is in use; add a distributed deletion lock before horizontally scaling the API.

## Prometheus Metrics

- Endpoint: `GET /metrics` (Prometheus exposition format)
- Includes Node.js runtime/process metrics from `prom-client` default collectors
- All exported metrics are labeled with `service_name`, `instance_id`, and `pid` so Grafana can target the active Train Track API process on shared hosts
- Includes custom metrics for:
  - Inbound API request throughput/latency
  - Upstream Rail API call throughput/latency/retries, including per-method URL/status counters
  - Push notification delivery throughput/latency/retries
  - Push token registrations and active push subscriptions
  - Unique users and recent notification activity windows

## Retry Behavior

External API calls now automatically retry retryable responses (`429`, `500`, `503`) and transient transport errors using exponential backoff with jitter.

When an upstream call is rate limited (`429`), the API now emits a structured warning log with the method, full URL, explicit ISO timestamp, retry metadata, and backoff timing.

- Upstream Rail API tuning:
  - `UPSTREAM_API_TIMEOUT_MS` (default `8000`)
  - `UPSTREAM_API_MAX_RETRIES` (default `3`)
  - `UPSTREAM_API_RETRY_BASE_DELAY_MS` (default `300`)
  - `UPSTREAM_API_RETRY_MAX_DELAY_MS` (default `15000`)
- APNs push tuning:
  - `APNS_PUSH_MAX_RETRIES` (default `3`)
  - `APNS_PUSH_RETRY_BASE_DELAY_MS` (default `400`)
  - `APNS_PUSH_RETRY_MAX_DELAY_MS` (default `12000`)

## Grafana Dashboards

Dashboard JSON files are available in:

- `observability/grafana/dashboards` (default path expected by `deploy/node_project.zsh`)
- `grafana/dashboards` (local convenience copy)

Files:

- `node-runtime-health.json`
- `api-calls.json`
- `request-overview.json`
- `push-notifications.json`
