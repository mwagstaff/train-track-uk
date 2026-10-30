# Train loading service

Standalone Darwin Push Port consumer and read-only API for TrainTrack UK. It is
deployed independently from `train-track-api`, so it can be disabled or rolled
back without changing departure or service-detail requests.

## What is retained

The service consumes the nationwide Darwin feed, but stores formation/loading
events in MongoDB only for a `rid` requested by a user through this API. Service
interests remain active until the scheduled departure plus
`TRAIN_LOADING_INTEREST_SECONDS` (two hours by default). Mongo records are kept
independently for `TRAIN_LOADING_TTL_SECONDS` (24 hours by default), then removed
by TTL indexes. Mongo's TTL monitor is asynchronous, so physical deletion can
occur a short time after the deadline.

The Staff departure board resolves the existing opaque LDB `serviceID` to
Darwin's `rid`. A Staff response seeds coach order immediately. Because live
loading is a delta stream, unmatched formation and loading events are held in a
bounded in-process cache for two hours by default. Registering an interest
immediately replays any cached events for that RID before returning. The cache
is intentionally not durable, so a service may still initially report
`formation_only` or `waiting_for_update` after a process restart or when Darwin
has not published loading for that train.

No TOC filter is applied. Southeastern is useful test data, but every operator
with Darwin formation/loading data is supported.

All nationwide `SF` and `LO` messages are parsed so they can populate the recent
event cache. `SC` schedule messages retain the RID prefilter and are parsed only
when they mention an active interest, keeping the much larger schedule stream
cheap to process.

## Run locally

```bash
cd api/train-loading-service
npm install
cp .env.example .env
# export the values in .env, then:
npm start
```

Required secrets:

- `DARWIN_USERNAME`
- `DARWIN_PASSWORD`
- `STAFF_DEPARTURES_API_KEY`
- `MONGODB_URI_TRAIN_LOADING`

Use separate production credentials/database permissions from the existing API.

## API

Register and query several services:

```http
POST /api/v1/loading_details/batch
Content-Type: application/json

{
  "services": [{
    "serviceID": "7711474ECROYDN_",
    "from": "KTH",
    "to": "VIC",
    "scheduledDeparture": "2026-08-14T22:12:00+01:00",
    "destinationCRS": "VIC",
    "length": 8
  }]
}
```

Other endpoints:

- `GET /api/v1/loading_details/:serviceID?from=KTH&to=VIC&scheduledDeparture=...`
- `GET /api/v1/loading_details/:serviceID` after the mapping has been cached
- `GET /api/v1/loading_details/rid/:rid` for feed diagnostics

## Admin view

`GET /admin` serves an unauthenticated, read-only operations table. It lists
only services represented by the current in-process active RID interests and
refreshes every 15 seconds. Expired MongoDB documents that are no longer active
interests are deliberately excluded.

The page reads `GET /api/v1/admin/services`, which returns service mapping,
formation/loading data, and the most recent Darwin update time sorted by
scheduled departure time, latest first. Departures outside the current UK
calendar day include their date and day offset for the admin display.

## Health and robustness

- `GET /health/live` proves the HTTP process/event loop is serving requests.
- `GET /health/ready` independently checks MongoDB and the Darwin transport.
- `GET /health/feed` exposes connection state, last broker traffic, last data
  message, sequence number/gap count, and reconnect count.
- `GET /metrics` provides Prometheus metrics, including matched versus ignored
  Darwin events, replay outcomes, and the current recent-cache size.

STOMP heartbeats prove the broker transport is alive even when no relevant RID
updates are being stored. A watchdog destroys and reconnects a socket that has
no broker traffic for 45 seconds; a separate connection timer also breaks a
stalled TCP handshake after 15 seconds. Reconnects use bounded exponential backoff.
For sequence-gap detection, leave `DARWIN_SELECTOR` blank so every sequence
header is observed; non-SC/SF/LO message bodies are discarded without parsing.
Optional durable-subscription settings are available in `.env.example`.

The shared `sky` deployer checks `/health/ready` after each full deployment. The
normal API does not depend on this service, and the iOS client treats missing
loading data as a neutral/unknown carriage state.

## Verify

```bash
npm test
```

## Deployment and rollback

The shared `sky` deployer registers this project as `train-loading-service`,
running on port 3017. Bitwarden items must use that exact value in their `Apps`
field. After saving or changing secrets, deploy with:

```bash
zsh /Users/mwagstaff/dev/server-tooling/deploy/node_project.zsh \
  train-loading-service sky --bw --force-bitwarden-sync
```

The Caddy route `/train-track-loading*` must proxy to `127.0.0.1:3017` before
the broader `/train-track*` matcher. The server-tooling Caddy setup script
contains that route. The externally routed API remains:

```text
https://api.skynolimit.dev/train-track-loading/api/v1
```

Rollback consists of stopping only the loading service; existing
`/train-track/api/v2` traffic is unaffected.

## Darwin readiness incident runbook

Registered service `train-loading-service` runs on Sky, systemd user unit
`com.train-loading-service.api.service`, port 3017; Mini owns its monitoring and
AIOps incidents. Logs are `~/dev/train-loading-service/train-loading-service.log`
and `.error.log`. Public readiness is
`https://api.skynolimit.dev/train-track-loading/health/ready`.

On a readiness 503, retain the JSON body: `mongo.healthy` and `feed.healthy`
identify the failing dependency. Compare `checkedAt`, `lastMessageAt`, transport
and message ages, state, reconnect count and lastError with the alert window.
A subscribed socket and heartbeats do not prove fresh MESSAGE delivery. The
message freshness default is five minutes; the transport watchdog is 45 seconds.
The existing public availability alert persists for two minutes. AIOps now
collects this structured body even on 503, plus liveness and Darwin metrics.
Darwin state/error logs carry UTC event times; health changes are logged once per
transition, including a stale feed while still subscribed. No new recovery
authority or more aggressive polling/reconnection is introduced.

If the process and Mongo are healthy but messages are stale or the broker refuses
connections, allow the existing reconnect/backoff and escalate persistent upstream
failure. Do not restart the service, clear Mongo, or treat connected status alone
as recovery. For genuine process/Mongo failures investigate those independently;
automated recovery remains subject to the registered approval policy. Verify fresh
messages, Mongo, local/public readiness and source resolution after recovery.
Existing loading records can remain stale/unknown; restored feed health does not
prove that every missed update was replayed.

28 October 2026, incident `INC-d1f1aaab-20261028T1246Z`: historical metrics show
MESSAGE delivery stopping around 12:39 UTC, readiness failing around 12:44,
and recovery around 13:03. Collected-time logs record broker ECONNREFUSED during
12:59 and subscription restoration at 13:00; readiness reports connectedAt
13:00:09.959Z. The process remained running with zero restarts. This establishes
an interrupted feed and refused connections, not the provider's internal cause.
AIOps originally discarded the 503 body and had no fresh timestamped application
logs at first investigation. The new darwin-feed runbook and bounded readiness
collector address that evidence gap.

Verification: deployed timestamp/health-transition logging to Sky and AIOps
collectors/runbooks to both responders. Mini's restricted peer collection returns
current readiness, liveness and timestamped events. An isolated in-memory replay
of the original incident confirms source clearance and no quality gaps, without
sending duplicate notifications or executing recovery. Public readiness returned
HTTP 200 using the monitoring user agent, and no loading-service alert remained.
38 loading tests, 23 AIOps Python tests and all 18 focused AIOps lesson tests pass;
the full Node suite has 86 passes and one existing infrastructure coverage failure
for MongoBackupStale/MongoRestoreTestStale (outside this change). TypeScript and
diff checks pass. The shared Service logs dashboard now uses a 24-column,
24-row panel on Mini and Sky; Mini was visually checked in the browser.
