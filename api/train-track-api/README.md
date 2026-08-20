# Train Track API

API for the [TrainTrack UK](https://apps.apple.com/gb/app/traintrack-uk/id6504205950) app.

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
