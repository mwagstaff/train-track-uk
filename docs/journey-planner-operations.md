# Journey planner: local prototype and operations

## Compatibility and release boundary

The planner is an additive, public API under **`/api/v3/journey-planner`**. Existing v1/v2 endpoints, response shapes, live service identifiers and `/api/v2/config` are unchanged. Timetable import and activation have no HTTP routes. Search history is available in the existing admin portal at `/admin/journey-planner`. No authentication or subscription requirement has been added to planner searches.

The iOS Debug build opens the planner from Add Journey. Release builds retain the current Add Journey screen until the local `journeyPlannerEnabled` feature flag is enabled. Debug can also use the `JOURNEY_PLANNER_ENABLED` launch environment variable. The planner always offers **Add a saved route**, which opens the existing manual route, favourites and tracking screen. A selected dated itinerary cannot yet be saved or tracked. The ten most recent successful searches are stored on the device, can be reused or removed, and preserve Depart now as an intent rather than an old timestamp.

The API deployment has a project-specific Node runtime and persistent timetable storage. The new [hourly S3 ingestion process](planner-s3-ingestion.md) downloads monthly full data, applies contiguous daily amendments, builds compact search snapshots, validates and activates them. It also provides manual `sync`, validation-only `sync --dry-run`, and a freshness/data-quality Grafana dashboard. The supplied daily CFA still needs a current full baseline or the missing update chain; see the [daily feed audit](planner-daily-feed-audit.md). The local full-import commands below remain available separately.

The [TubeTrack integration guide](tubetrack-integration.md) covers London station
mapping, disruption-aware transfer timing, line colours, fallback, validation and
release requirements. TubeTrack is enabled by default; the API service setting
`PLANNER_TUBETRACK_ENABLED=false` disables it after restart. The integration
requires an API release and rebuilt app; the implementation changes do not
deploy either.

## Runtime and storage

- The planner worker and importer require **Node 22.16 or later** with `node:sqlite` available. Tested on Node 24.21.0 and locally on Node 25.8.1. The main API imports SQLite lazily in the isolated planner worker, so an unavailable planner does not prevent existing routes from loading.
- ZIP ingestion requires the system `unzip` utility. Members are checked before streaming; no archive files are executed. Expanded input is bounded to 2 GiB. The supplied extracted directory does not require `unzip`.
- Install lockfile dependencies as usual; S3 ingestion adds `@aws-sdk/client-s3`.
- Full data is private local input and excluded from Git. Snapshots contain licensed timetable content too.
- Use an absolute `PLANNER_DATA_DIR` **outside deployed source**. The existing deployment uses deletion during synchronisation; source-tree snapshots would not be durable.
- The supplied package needs about 676.5 MB of source files. Its existing schema v1 SQLite snapshot is 1.07 GB; new compact schema v2 imports measured 275.7 MB with the same supported routing data. Existing v1 snapshots remain readable. See [search optimisation and measurements](planner-search-optimisation.md). Budget space for source, staging, active and rollback snapshots, validation and future growth. Activation does not delete old snapshots.
- Up to two workers run independent searches concurrently, each with its own read-only connection to the same immutable SQLite snapshot. A separate small worker handles station lookups and timetable metadata. Workers start lazily; queue admission stays global, and elapsed time, operation count and per-worker V8 heap are bounded. SQLite native memory and total process RSS are not capped by the V8 heap setting; measure on the deployment host before release. Set `PLANNER_WORKERS=1` for the previous single-worker capacity.

## Production deployment on `sky`

TrainTrack uses the private **Node 24.21.0 LTS** runtime at `/home/mwagstaff/.local/share/train-track-api/runtime/node24/bin/node`. The `node24` symlink targets a versioned official distribution, verified against its published SHA-256 checksum before installation. `runtime/installation.json` records the download and checksum. The system `/usr/bin/node` remains Node 20.20.2 for existing services.

The TrainTrack entry in `/Users/mwagstaff/dev/server-tooling/deploy/config/node_projects.json` persists:

- `node_binary`: the private runtime above, used for service startup and dependency installation/builds.
- `static_env.PLANNER_DATA_DIR`: `/home/mwagstaff/.local/share/train-track-api/planner`.
- `rsync_excludes`: `/resources/timetable_full/` and `/var/planner/`, preventing future code syncs from copying development data or Mac-specific active pointers.

The standard deployment command can now be used for subsequent code releases:

```sh
rtk proxy /Users/mwagstaff/dev/server-tooling/deploy/node_project.zsh train-track-api sky --quick
```

Full deployments use the same runtime pin and exclusions. A missing pinned runtime fails before deployment changes begin. Other projects retain their existing runtime selection. **With S3 credentials present, the new ingestion worker enables automatically at API startup**; set `PLANNER_INGESTION_ENABLED=false` for a controlled deployment and manual dry run first. Existing excluded source-tree copies are protected by rsync; they are not the production data source.

The supplied RJTTF939 snapshot was validated on the host and moved to `PLANNER_DATA_DIR/snapshots/3d9d573635ed619ac3808338176858077f4d35650846ba0a0e829ed53ad64f5c`, then activated with the CLI. `active.json` contains the absolute Linux path. The unit is `com.train-track-api.api.service`; its wrapper and static configuration are regenerated by the deployer.

For future monthly feeds, stage the complete delivery on `sky`, then run from `/home/mwagstaff/dev/train-track-api` using the private runtime. Replace the source and candidate paths below with the new delivery's paths:

```sh
/home/mwagstaff/.local/share/train-track-api/runtime/node24/bin/node --max-old-space-size=512 scripts/planner.js import --source /absolute/path/to/new-full-delivery --staging /home/mwagstaff/.local/share/train-track-api/planner/snapshots/NEW_CANDIDATE --mode full
/home/mwagstaff/.local/share/train-track-api/runtime/node24/bin/node scripts/planner.js query --dataset /home/mwagstaff/.local/share/train-track-api/planner/snapshots/NEW_CANDIDATE --from KTH --to VIC --depart-after FUTURE_ISO_TIMESTAMP_WITH_OFFSET
/home/mwagstaff/.local/share/train-track-api/runtime/node24/bin/node --max-old-space-size=512 scripts/planner.js activate --dataset /home/mwagstaff/.local/share/train-track-api/planner/snapshots/NEW_CANDIDATE --data-dir /home/mwagstaff/.local/share/train-track-api/planner
```

Import and activation validate the data before publishing it. Validate both time modes and connecting journeys with dates inside the new coverage before activation. Allow 120–180 seconds for administrative validation on this shared host: a complete measured validation passed in 21.80 seconds at 358.5 MiB peak RSS, while an initial run exceeded a 60-second timeout. The legacy synchronous search timeout remains 30 seconds; queued searches have a separate processing allowance described below. Activation switches the pointer atomically and does not require a code deployment or service restart.

Check planner readiness separately from the general API health check:

```sh
rtk proxy curl --fail --silent --show-error https://api.skynolimit.dev/train-track/api/v3/journey-planner/status
rtk proxy curl --fail --silent --show-error 'https://api.skynolimit.dev/train-track/api/v3/journey-planner/stations?q=kent%20h'
```

Deployment evidence and the previous wrapper/static configuration are retained privately on `sky` in `/home/mwagstaff/.local/share/train-track-api/deployment-checks/20260915T135318Z`. Timetable rollback uses the CLI below. To reverse the runtime/configuration change, restore the backed-up wrapper and static configuration and restart only the TrainTrack unit; restoring Node 20 leaves the planner unavailable, so also update the local deployment configuration before the next release if that rollback is intentional.

The 15 September deployment passed public station/search/detail checks in both time modes. KTH–VIC depart-after took 5.493 seconds; connecting KTH–BTN arrive-by took 4.118 seconds, with five untruncated results each. Existing v1/v2 departure routes returned their expected shapes, and v2 stations/config and general health matched the pre-deployment responses. Only TrainTrack restarted. The standalone two-case benchmark peaked at about 930 MiB RSS; after public searches the full API used about 881 MiB RSS with no swapped process memory and about 1.56 GiB of host memory available. These small acceptance checks do not establish production load capacity.

## Build and validate a candidate

Run from `api/train-track-api`. Each staging destination must be a new directory, or the same already-imported content for an idempotent rerun. The examples use placeholders that must be replaced with actual absolute paths.

```sh
npm run planner -- inspect --source /absolute/path/to/timetable_full
NODE_OPTIONS=--max-old-space-size=512 npm run planner -- import --source /absolute/path/to/timetable_full --staging /absolute/path/to/planner/snapshots/candidate --mode full
npm run planner -- validate --dataset /absolute/path/to/planner/snapshots/candidate
```

Use `--source /absolute/path/to/package.zip` for a ZIP. Directory input records member hashes and a deterministic content identity; it does not claim an archive checksum. `metadata.json` records the source date, package, hashes, parser version, coverage, exclusions and counts. `validation.json` includes representative dates and per-operator service counts. Raw source references are retained in SQLite for private explanation. The final candidate directory appears only after successful import and validation. Interrupting or failing an import does not change the active pointer.

The import example bounds V8 old-space to 512 MiB. The full supplied input passed with this setting in 18.21 seconds and 421.09 MiB peak process RSS on the local M5 Pro. This heap setting is not a total resident-memory limit; size the production job against measured host headroom and monitor native SQLite memory too. This setting applies to the standalone importer; the routing worker has its own 1024 MB default.

The version is derived from source content plus schema and parser versions. Reimport after a parser change; opening a snapshot from an incompatible parser fails safely. New imports use compact schema v2; schema v1 remains supported for reads/validation/rollback, but a compact reimport requires a new snapshot directory. `import` accepts only full packages; use managed `sync` for S3 full + daily amendments. `inspect` accepts daily packages, including their normal mixed C/F member names, reports update-operation inventories and labels them as requiring a baseline. Inspection is not completeness certification.

## Exercise the candidate before activation

```sh
npm run planner -- status --dataset /absolute/path/to/planner/snapshots/candidate
npm run planner -- query --dataset /absolute/path/to/planner/snapshots/candidate --from KTH --to VIC --depart-after 2026-09-08T07:00:00+01:00 --explain
npm run planner -- query --dataset /absolute/path/to/planner/snapshots/candidate --from KTH --to BTN --arrive-by 2026-09-08T10:00:00+01:00
npm run planner -- benchmark --dataset /absolute/path/to/planner/snapshots/candidate --cases test/planner-benchmark-cases.json
npm run test:planner
```

Those dates are reproducible fixtures for RJTTF939, not a future delivery's acceptance dates. Update sample dates to the candidate's coverage when validating a new feed. `--explain` emits private selected/candidate schedule variants, origin dates, source member/line references and connection rules. Do not publish that diagnostic output as the public API response.

Benchmark output reports sequential request duration (including worker/date preparation when cold), journey count, dataset, truncation, Node/platform/CPU count and process peak RSS in KiB. It is a local measurement, not a production service-level guarantee. Before release measure representative cold/warm queries, concurrency, event-loop delay and total RSS on the actual host alongside departures and push processing.

## Activate and roll back

```sh
npm run planner -- activate --dataset /absolute/path/to/planner/snapshots/candidate --data-dir /absolute/path/to/planner
npm run planner -- status --data-dir /absolute/path/to/planner
npm run planner -- rollback --version PREVIOUS_64_CHARACTER_VERSION --data-dir /absolute/path/to/planner
```

Activation revalidates the candidate and acquires a publication lock. It rejects large reductions in supported schedules/stations and significant per-operator loss on the overlapping source publication date. It writes history and atomically switches `active.json`; the previous snapshot remains available. A failed activation leaves the current pointer untouched. Investigate blocked changes before using the repository's explicit coverage-change override in controlled administration; the CLI deliberately does not expose a bypass switch.

Existing in-flight searches use their selected snapshot. Cursors keep that version until it is no longer active or previous, then return `CURSOR_EXPIRED`. Detail responses are cached for up to one hour and may expire earlier after eviction, restart or snapshot removal. Re-search in that case. Manual snapshots are not deleted. Managed S3 stores have bounded retention protecting active/immediate rollback pointers; see the ingestion runbook before requesting an older rollback.

## Local server and app

This workspace already has the validated RJTTF939 snapshot and a local active pointer. To use it without reimporting, run `npm run planner -- serve --data-dir var/planner --port 3013` from the API directory. Generated data and reports are ignored by Git.

```sh
npm run planner -- serve --dataset /absolute/path/to/planner/snapshots/candidate --port 3013
```

This binds only `127.0.0.1` and starts the planner without MongoDB or existing background workers. Status is at `http://127.0.0.1:3013/api/v3/journey-planner/status`. In the Xcode Debug scheme's launch environment, set `API_BASE=http://127.0.0.1:3013/api/v2` and `JOURNEY_PLANNER_ENABLED=1` for simulator testing; the new client derives v3 only for planner calls. This standalone server has no legacy endpoints. Use the full development API to exercise both real legacy requests and planning together.

The full API automatically registers the v3 router. Set its `PLANNER_DATA_DIR` to the activated directory, or use `PLANNER_DATASET_PATH` for an explicit candidate during development. Missing, unsupported or overly old data reports planner unavailability while existing routes continue to work. Disable the planner with `PLANNER_ENABLED=false` if needed.

## API contract

| Method and path below `/api/v3/journey-planner` | Contract |
|---|---|
| `GET /status` | Availability, API capabilities, public source age/version/coverage. Returns 200 with `available: false` for missing or stale data. |
| `GET /stations?q=kent` | Validated selectable timetable stations, canonical CRS and aliases. Optional existing display names/coordinates. Empty `q` returns the whole selectable list; other queries return up to 30 matches. |
| `POST /search` | Initial search JSON below, or `{ "cursor": "opaque-returned-value" }` alone. |
| `POST /search-jobs` | Same search/cursor JSON; returns 202 with a job ID and its current state. |
| `GET /search-jobs/:id` | Returns 200 with queued/running/completed/failed/cancelled state; completed jobs contain the unchanged search response in `result`. |
| `DELETE /search-jobs/:id` | Cancels this caller's interest in the search; idempotent 204. |
| `GET /journeys/:id` | Journey detail and pinned dataset metadata. IDs are distinct from live service IDs. |

```json
{
  "origin": "KTH",
  "destination": "BTN",
  "time": "2026-09-08T07:00:00+01:00",
  "timeType": "departAfter",
  "maxChanges": 2,
  "extraConnectionMinutes": 0,
  "allowedModes": ["rail", "replacementBus", "walk", "tubeTransfer", "genericTransfer"],
  "limit": 5,
  "windowMinutes": 120,
  "realtime": "apply"
}
```

`time` requires seconds, an explicit offset and at most three optional fractional digits (millisecond precision). `timeType` is `departAfter` or `arriveBy`. Bounds: changes 0–5 (default 5), extra connection minutes 0–60, results per page 1–10, window 15–360 minutes (default 360). Explicit lower limits, such as the example above, remain exact. The window bounds first departures for depart-after and final arrivals for arrive-by; total journey duration is capped at 24 hours. A train departing later can connect to an earlier feeder within the requested window, including a wait overnight. All public journey times include an offset (currently UTC ISO strings). The app presents Europe/London time. A window crossing a coverage boundary reports partial results and suppresses pagination into unsupported dates.

Responses contain `journeys`, `dataset`, normalised `search`, `warnings` and `pagination`. `more` continues the same time window without discarding useful alternatives; `earlier` and `later` move to adjacent windows. Cursors are opaque to callers, validate every embedded parameter, and pin the exact timestamp, modes, options, dataset and routing policy. They are not credentials. A bounded search reports truncation or a timeout rather than claiming complete results. Vehicle legs include scheduled calling points, operator code and source service identity. Transfer legs include the allowance and wait breakdown; they are not detailed Tube or street directions.

`genericTransfer` permits timetable-supplied ALF `TRANSFER` links whose transport service is unspecified, including early-morning cross-London connections. It is included in the default modes alongside rail, replacement bus, walking and Tube; an explicit mode list still controls eligibility. Link operating windows and station allowances remain enforced. iOS marks affected journeys and the specific transfer section with a warning and advises checking taxi/night-bus options if the Tube is closed. Deploy API support before the updated client, which explicitly requests this additional mode. Existing cursors retain their original mode lists; no timetable reimport is required.

Errors use `{ "error": { "code": "…", "message": "…" } }`: invalid input/station/cursor 400, oversized JSON 413, unsupported content type/encoding 415, unsupported date 422, busy 429 with Retry-After, missing/stale data 503, work timeout 504, expired cursor/detail 410. Planner JSON bodies are limited to 16 KiB. No raw records or filesystem paths are exposed.

### Live departures, cancellations and the scheduled override

`realtime` is additive and optional: **`apply`** uses matched live times and cancellations when routing; **`ignore`** routes by the timetable while retaining live annotations and warnings; omitted or **`off`** preserves the existing scheduled-only API behavior. The updated app defaults to `apply` and offers **Use live times** on the form/results. Switching it off reruns the displayed search window using `ignore`, including after Earlier/Later paging. Saved recent searches preserve the choice; old entries default to live updates.

Live observations apply to journeys starting within the next **four hours**, including Depart now and eligible arrival-deadline searches. Later parts of a long journey may still use scheduled times. This applicability window is separate from the existing six-hour search profile. Future searches outside the live window make no upstream live calls and report `live.status: outsideWindow`.

The service uses the existing public LDBWS board/detail subscriptions and API keys. It matches station-relative observations to a unique timetable occurrence using operator, station, dated scheduled times and ordered through calling points. Public LDBWS does not supply a timetable UID/origin date; numeric service-ID prefixes are not treated as those identifiers. Ambiguous, missing, stale or contradictory evidence cannot establish an on-time train or a cancellation. Previous calling-point forecasts are departures; subsequent forecasts are arrivals. An arrival forecast alone does not establish a later catchable departure.

When `STAFF_DEPARTURES_API_KEY` is present, a failed public service-detail lookup (`upstream` or `unavailable`) can use the already licensed Staff `GetDepBoardWithDetails` product. Recovery is limited to eight distinct station/departure-minute queries, with nine rows over two minutes per query. It shares the existing 64-request budget, two-request concurrency limit, three-second deadlines, cancellation and 30-second cache. The staff record must match UID, origin date, operator and the complete ordered public calling pattern, including dated scheduled arrival/departure times and TIPLOCs where supplied. Only specifically requested missing occurrences receive updates; successful public matches remain unchanged. Actual and forecast times retain their dates and seconds. Missing/unknown forecasts, ambiguous clock-change times and failed matches remain explicit gaps. Branch associations do not create through services.

The credential is the same existing `STAFF_DEPARTURES_API_KEY` used by `train-loading-service`, selected for `train-track-api` through the Bitwarden item's **Apps** field. Preserve both app names. Normal deployment with `--bw --force-bitwarden-sync` retains that mapping; quick deployments retain the existing environment but do not fetch newly assigned credentials. Do not substitute the public board key or import the loading service's entire environment. Without the optional staff key, public-feed behavior and scheduled fallback remain available. No app rebuild, timetable import or API version change is needed for this recovery.

The planner applies observations to a separate view of the timetable before rerouting. This allows a delayed train originally scheduled before the request to become catchable, removes missed connections, respects arrival deadlines, and exposes alternatives to cancelled trains. It considers the scheduled search's full useful frontier and unfiltered origin boards, then checks newly exposed boarding stations after rerouting. Detail lookups prioritise near-term trains in useful itineraries and delayed origin trains whose expected departure is still in the future; other station traffic and expired clock estimates do not consume the detail budget. Newly useful alternatives at an already checked station receive another detail pass too. This bounded discovery is **partial network coverage**, not a complete national live timetable. The visible page reports which of its near-term rail legs have confirmed times; later trains and Tube/walking transfers do not count as failed live checks.

- Two upstream calls at a time, at most 64 calls per search, eight boarding stations and three discovery rounds. Shared short-lived cache entries cost no additional upstream budget.
- Three-second upstream deadlines, no internal retry storm, a 30-second cache capped at 256 entries, and cancellation of pending lookups when the search is cancelled. Existing search queue, worker CPU duty cycle, total routing-operation allowance, execution deadline and heap guard still apply.
- Only provider timestamps within 90 seconds and no more than five seconds ahead are accepted. Snapshot expiry follows the oldest evidence used. More-results cursors pin the snapshot and mode; Earlier/Later requests fetch fresh observations. Outside-window searches also retain their scheduled result context for 90 seconds, so More cannot reorder results when the request enters the live window. An expired snapshot returns 410 for continuation; results that aged while computing show a warning and do not offer an immediately expired More cursor.
- Known cancelled boarding/alighting stops are unusable; an intermediate skipped stop does not by itself prohibit through travel. A proven non-operating section cannot be crossed. Unknown downstream disruption is conservatively excluded from the affected onward portion while safe earlier sections remain usable. The override restores scheduled routing but keeps these warnings visible.
- Changed services reuse unchanged timetable indexes, so applying updates does not create another complete national event index. The two-call limit is shared across routing workers by the parent broker, which also coalesces identical pending requests with independent cancellation; legacy live requests retain their existing throttling and shared host spacing.

Responses optionally add `live` with `mode`, `status` (`live`, `partial`, `unavailable` or `outsideWindow`), observation/expiry timestamps, `windowHours` and `warnings`. Optional `live.coverage` counts unique `nearTermRailLegs`, `confirmedRailLegs` and `scheduledLaterRailLegs` on the visible page. `live` status means that page's near-term rail legs have confirmed endpoint forecasts or known cancellation; it does not promise exhaustive live network coverage. Genuine match/retrieval/lookup-budget gaps are explained on the affected rail leg. Unrequested unrelated board services cannot produce blanket warnings. `disruptedJourneys` contains up to five affected scheduled alternatives, clearly separated from usable results in the app. Existing journey times are effective routing times in `apply` mode. Optional `scheduledDeparture`, `scheduledArrival` and `scheduledServiceId` preserve timetable identity; leg/calling-point `live` annotations describe expected times, delay minutes, cancellation extent and warnings. Cancelled calls can have null effective times; their scheduled times remain available for a labelled struck-through display. Journey-level warnings include unconfirmed or missed connections and late expected arrivals.

The app uses yellow for reported delays and red strikethrough for the selected cancelled service/stop. Cancellations elsewhere on the same train are identified without falsely marking an unaffected selected section cancelled. A card says “1 of N trains confirmed on time” when only some rail legs have complete forecasts; “All trains on time” requires every rail leg to be verified and no disruption. Generic Tube-transfer information is kept as a neutral explanation in leg details, not promoted to a journey warning. Live warnings remain visible in the scheduled override. Detail IDs pin the live context so another search cannot replace the observation/mode of a previously returned journey. Details are a snapshot of that search; start a new search to refresh them.

Provider failures fall back to scheduled results with an unavailable warning. This feature does not provide complete disruption coverage, live Tube routing, or split/join through-service continuity. It requires an API deployment and app rebuild, but no timetable reimport, schema migration, extra npm package or new API key.

Provider contracts: [National Rail public JSON specification](https://realtime.nationalrail.co.uk/LDBWS/static/ldbws.json), [OpenLDBWS field and request documentation](https://lite.realtime.nationalrail.co.uk/OpenLDBWS/documentation.aspx).

### Queued searches and resource control

Use the additive job endpoints for searches that may outlast an HTTP request. Submit with a persistent installation identifier in `X-Planner-Client` and a fresh `Idempotency-Key` per logical search. Both accept 8–128 letters, digits, underscores or hyphens; UUIDs are suitable. Repeat a lost submission with the same key and body to recover its job ID. Reusing a key for different parameters returns 409. Missing client identifiers fall back to the network address; these are fairness hints, not authentication.

Poll the returned ID using `pollAfterMs` (currently 1000). Queued states include `queuePosition`; running states may include `phase: preparing`, `searching` or `live`. Completed states include `result`; failed states include the usual `error.code` and `error.message` inside the 200 status response. Treat a job ID as a private bearer capability: another holder can read or cancel that caller's job. Responses are `no-store`. A missing or expired ID returns `SEARCH_EXPIRED` (410).

- At most **eight distinct searches** are admitted, including running work, with **one computing search at a time**. A client can hold two active jobs and a network address four. Additional submissions receive 429; the app retries briefly with backoff. The limits and bounded result store apply even when clients rotate their installation identifiers.
- Identical pending requests, including the pinned timetable version, share computation. Each caller gets an independent job ID: cancelling one leaves the others running. Initial searches pin the active dataset at admission; pagination retains its original version.
- Accepted work can wait up to **eight minutes**, then compute for up to **ten minutes** with a separate one-billion-operation ceiling. These finite bounds protect the server against pathological searches. They do not narrow the requested route/date/transfer scope.
- Queued searches run at full worker speed by default. Set `PLANNER_JOB_CPU_DUTY_CYCLE` below 1 (for example `0.5`) to throttle the routing worker with cooperative pauses on a host that must reserve CPU for other services. This is not an OS-enforced CPU or memory limit: a native SQLite call or an individual decode finishes before its next checkpoint. Node 24 measures worker CPU time; older supported runtimes use elapsed time as a fallback. Legacy synchronous requests retain their existing limits and are not duty-cycle throttled.
- Station lookups/readiness use a separate worker with a 256 MB V8 heap limit and five-second deadline. Recently returned journey details use a bounded parent cache and version checks in that worker, so routing does not hold them up.
- Polling keeps an active caller's job alive. After **two minutes without polling**, its interest expires; work stops when no callers remain. Completed/cancelled results are retained for up to ten minutes, with at most 128 caller records. Jobs live in memory and do not survive an API restart.

The updated app submits once, shows queue/search progress, polls until completion and offers cancellation for initial searches and pagination. It retries transient network/busy responses for up to 60 seconds at a time, with an overall 20-minute bound. A missing job prompts a fresh search. Keeping the app open avoids the abandoned-job expiry. Only an initial submission's 404 triggers compatibility fallback to the existing synchronous endpoint; an accepted job is never silently resubmitted as synchronous work.

Rebuild the app to enable this flow. The existing `/search` endpoint, v1/v2 routes and response shapes remain compatible. Job endpoints need no extra deployment configuration, authentication or timetable import.

## Configuration and monitoring

| Environment variable | Prototype default |
|---|---:|
| `PLANNER_ENABLED` | `true` |
| `PLANNER_DATA_DIR` | `~/.local/share/train-track-api/planner` |
| `PLANNER_DATASET_PATH` | Unset; use active pointer |
| `PLANNER_WARN_AGE_DAYS` | 35 |
| `PLANNER_MAX_STALE_DAYS` | 45 |
| `PLANNER_TIMEOUT_MS` | 30000 including queue time, synchronous requests |
| `PLANNER_MAX_QUEUE` | 8 requests across the whole routing pool, including active and suspended work |
| `PLANNER_WORKERS` | 2; accepts 1 or 2, starts workers lazily |
| `PLANNER_HEAP_MB` | 1024 per routing worker; not a process RSS limit |
| `PLANNER_DATE_CACHE_SIZE` | 6 |
| `PLANNER_MAX_OPERATIONS` | 10000000, synchronous searches |
| `PLANNER_MAX_SEARCH_JOBS` | 8 distinct queued/running searches |
| `PLANNER_JOB_QUEUE_TIMEOUT_MS` | 480000 before processing starts |
| `PLANNER_JOB_TIMEOUT_MS` | 600000 processing time |
| `PLANNER_JOB_MAX_OPERATIONS` | 1000000000 |
| `PLANNER_JOB_CPU_DUTY_CYCLE` | 1 (no throttling) |
| `PLANNER_MAX_LIVE_WAITERS` | 1 suspended live-lookup task across the pool; 0 disables I/O overlap |
| `PLANNER_PREWARM` | `true`: each started worker uses a low-priority idle task to resolve today's dates and build original/RAPTOR indexes after worker start and after each London date or timetable change |

The source generation date determines freshness; reimporting old data does not make it fresh. The 35/45-day thresholds are explicit prototype assumptions for the proposed monthly feed and need an operational decision before production. Search/cache keys include the exact instant, options, policy and version. Public metadata is refreshed even for cached results.

Existing Prometheus HTTP metrics identify v3 routes separately. `planner_requests_total` records operation/status and `planner_request_duration_ms` records HTTP durations without station/device labels, including job-submit/status/cancel operations. A successful poll can contain a failed job; HTTP metrics alone do not measure job success or total time to completion. `/status` is the separate planner-readiness check. Imports produce progress and validation diagnostics privately; no admin endpoint exposes the source or activates data.

### Search history in Mongo and the admin portal

Open **Journey Planner** in the admin portal, or `/admin/journey-planner` directly.
When using the production proxy, the public path is
`/train-track/admin/journey-planner`. Admin links, forms, redirects and the
dashboard's API action use request-relative URLs to retain the proxy prefix;
direct local access and trailing-slash URLs also work. No proxy configuration
change is required. Redeploy the API and reload any already-open admin page to
receive the corrected links; no app rebuild is needed.
The table defaults to newest searches first. All headings sort the complete
selected dataset, with server-side pagination. Period filters offer relative
presets and custom start/end dates; 24 hours is the default. Source filters distinguish manual
searches, queued searches, saved-route planning, live refreshes and replans.
Station names are displayed alongside codes; station columns sort by code.

All filters are in the address and survive refresh, sorting and pagination:

- `?q=-5m`: the last five minutes whenever the bookmark is opened.
- `?q=-2h` or `?q=-7d`: negative whole minutes (`m`), hours (`h`) or days (`d`),
  up to seven days. The old `?range=1h`, `24h` and `7d` links still work.
- `?q=custom&from=2026-09-17T09:00:00Z&to=2026-09-17T11:30:00Z`:
  a fixed interval. Explicit offsets are supported; encode `+` as `%2B` in URLs.
  Custom form fields are labelled **UTC**; table timestamps remain Europe/London.
  Both endpoints are inclusive. Dates older than retention are excluded, and
  invalid or reversed ranges show a correctable validation message.

For example, the production five-minute bookmark is
[recent searches](https://api.skynolimit.dev/train-track/admin/journey-planner?q=-5m).
Cards and rows use the same resolved time window, including custom filters.
Expand **Timing details** on a new row to see queue/resume waiting, timetable
preparation, routing and live lookup durations, measured routing/preparation CPU
time, routing counts and sampled heap/RSS maxima. First-result time records when
provisional options became available. These measurements are additive across
worker tasks; older records have no breakdown. Sampled memory is not a guaranteed
allocation peak, and overlapping live I/O can include time while another task
uses the worker. RSS includes the whole API process.

The `planner_searches` collection stores one record per synchronous search or
asynchronous caller submission. An accepted idempotent retry reuses that record;
status polling does not add records. Concurrent callers sharing a calculation
have independent records and cancellation outcomes, marked **Shared work**.
Rejected submissions are recorded as failures. A saved route's first
cache-load/profile/live-check cycle is one record; subsequent profile continuation,
live refresh and replan cycles have separate records. Polls that simply read an existing board do not
count as new searches.

- `startedAt` is admission/submission time and `finishedAt` is when a result or
  terminal outcome becomes available at the server, not when a phone receives
  its next poll. Duration includes queue waiting. Zero journeys is a successful
  result; validation/provider/worker failures remain failures. Cancellation,
  expiry, superseded work and shutdown are other outcomes. Unfinished records
  have no completion timestamp or duration; an abrupt process exit can leave
  such a record unfinished until expiry.
- Cache **Hit** means the interactive result/frontier was reused, or a saved
  route reused a scheduled profile. **Miss** means calculation was required.
  **Unknown** means no cache decision was reached. Sharing pending work and
  cached upstream departure responses do not by themselves count as result
  cache hits. Use the source filter when comparing these different workloads.
- Summary cards cover all matching records, independently of pagination. Success
  and failure percentages divide by successful plus failed searches. Average,
  maximum and p99 durations include those completed searches only. P99 uses
  the observed nearest rank, not a sampled percentile. Cache-hit percentage
  divides hits by hits plus misses, excluding unknowns. Summary snapshots are
  shared for up to 15 seconds; their timestamp appears on the page.
- Retention is fixed at **seven days from `startedAt`**, using a BSON Date TTL
  index with `expireAfterSeconds: 604800`. Completion does not extend retention.
  Queries also restrict the time range because Mongo's TTL cleanup is
  asynchronous. See [MongoDB TTL behaviour](https://www.mongodb.com/docs/manual/core/index-ttl/).
- Logged fields are limited to public station codes, ordered intermediate
  stops, requested date/time/mode, source, outcome, timing, cache evidence,
  result count, phase/resource measurements and dataset version. Device IDs, IP addresses, request headers,
  raw cursors, results and provider credentials are not stored.

Persistence runs separately from the planner, with one Mongo write batch at a
time, up to 50 records per batch and 2,000 queued record updates. Lifecycle
updates coalesce; revision guards prevent a delayed write from reverting a
completed record. Writes have a two-second driver deadline and at most three
attempts. Buffer exhaustion or a sustained Mongo outage can lose log records;
rate-limited `[planner-search-log]` diagnostics report those failures without
failing passenger searches. Admin reads are bounded separately, and return an
explicit unavailable page on database errors instead of empty success stats.

Deploy the API through the standard process. Startup creates the collection's
TTL and query indexes automatically. No app rebuild, new credential, timetable
import, manual migration or API version change is needed for search history.
The page uses the existing `/admin` access boundary; the public planner API
does not expose the log.

## Long-distance search correction — 15 September 2026

Kent House–Inverness exposed a missing reverse ALF transfer and narrow prototype defaults. The runtime now indexes ALF station pairs in both directions, accepts/defaults to five changes, and uses a six-hour default first-departure/final-arrival window. Explicit lower limits remain exact. The CLI uses the same change default. The app omits its old hard-coded two-change field, and empty results show the searched interval/limit with earlier/later actions. Rebuild the app to receive those changes; the previously installed app can already find the sleeper with its explicit two-change limit.

The routing worker excludes paths that cannot catch any onward service within the remaining boarding budget and removes dominated detours while retaining operator and departure/arrival context. The work ceiling increases from 3 million to 10 million checked operations; the timeout, queue and heap defaults remain 30 seconds, eight requests and 1024 MB. Twelve local benchmark cases, 400 comparisons with exhaustive routing, and five staged Linux/Node 24 cases passed. The Linux cold default Inverness search returned five journeys in 18.625 seconds at about 722 MiB peak RSS; general API health remained responsive during the staged search. The five-case host run peaked at about 943 MiB RSS. These are acceptance measurements, not a load-capacity guarantee.

After standard deployment, public searches for the screenshot's 15:10 departure time returned five journeys, including 15:27 → 08:26 and the 19:57 → 08:45 sleeper connection (all London time, arriving the following day). The 08:26 itinerary uses Victoria–King's Cross and the independently verified Edinburgh/Aberdeen trains; the screenshot's exact Herne Hill/St Pancras feeder is not claimed, because the supplied station allowances differ. The installed app's two-change request also succeeds. No snapshot reimport was needed: the complete Euston–Inverness sleeper and all downstream daytime trains were already present.

That correction advanced the public cursor policy to `scheduled-v2` because corrected transfers change result ordering. Previous cursors return `CURSOR_EXPIRED` (410); starting a fresh search preserves the selected stations/time. Existing v1/v2 routes and contracts are unchanged. The dataset version is unchanged because raw timetable records and snapshot format are unchanged.

Deployment and test evidence is retained privately under `/home/mwagstaff/.local/share/train-track-api/deployment-checks/inverness-20260915T142015Z`. The directory includes the prior planner library/CLI, staged candidate measurements, service PID comparisons and legacy response baselines. Roll back this correction by restoring that planner library and CLI and restarting only `com.train-track-api.api.service`; the previous version restores the original Inverness limitation. Update the source checkout before the next deployment if deliberately keeping that rollback.

## Departure-time timeout correction — 15 September 2026

A subsequent Kent House–Inverness search at 16:00 London exceeded the 10-million-operation allowance. Direct API access returned a structured `SEARCH_TIMEOUT` after 10.12 seconds; the public gateway returned a plain-text HTTP 504, which the app displayed as generic unavailability. Readiness remained healthy and the worker did not crash. This was a routing defect, not a missing deployment step or timetable import.

The router now caches temporally eligible station events and avoids repeating downstream scans of a train occurrence when an already processed boarding has an equal or better departure/arrival profile, boarding position and change count. Checks remain active on scanned events/calls. The 16:00–17:00 sample uses 2.4–3.0 million operations instead of over 10 million. Search scope, the 10-million-operation bound, 30-second timeout and 1024 MB worker heap remain unchanged.

The public cursor policy is now `scheduled-v3`: choosing among equally ranked paths can change, so old pagination expires safely with 410. Fresh searches work with the already deployed app. A further app rebuild includes clearer messages for unstructured HTTP 504 and transport timeouts; structured server errors still take precedence. No new API namespace, deployment setting or snapshot activation is required.

Verification: 179 selected backend tests passed, including 402 exhaustive routing comparisons and the supplied 16:00/16:05 regressions; the same two unrelated baseline tests remain excluded. All 17 app unit tests passed. Seven isolated Node 24 host benchmark cases passed without truncation, with 11.56 seconds for the first cold search and 2.79–6.38 seconds for subsequent cases. Peak standalone RSS was about 1048 MiB (the worker heap limit does not cap total native/process memory).

After the standard quick deployment, the public 16:00 search returned four journeys in 11.514 seconds; 16:05 returned five in 6.247 seconds, plus two on the next page. A fresh Depart now request at 16:13:59 London returned four in 4.027 seconds; arrive-by returned five in 4.587 seconds. Details matched, no searches were truncated, and the first result was the 19:57 → 08:45 next-day sleeper connection. Health/config/station responses matched their pre-deploy bytes; v1/v2 live requests each returned 17 departures. Only TrainTrack's service PID changed. The API used about 874 MiB RSS afterward, with no swapped memory.

Evidence and the previous planner library are retained under `/home/mwagstaff/.local/share/train-track-api/deployment-checks/departure-timeout-20260915T150400Z`. Restoring `previous-planner-lib` to the API's `lib/planner` and restarting only TrainTrack rolls back this correction, including its cursor policy, but restores the reported timeout. Update the source checkout as well before deliberately redeploying a rollback.

## Burnley timeout and queued-search deployment — 16 September 2026

East Croydon–Burnley Manchester Road, arrive by 18:09 on 16 and 17 September, exposed repeated rebuilding of national reachability bounds: 159 builds across 40 horizons exceeded an eight-entry cache. The router now keeps at most eight bounds and reuses a more permissive cached bound when full. Local routing fell from 23.06 to 2.69 seconds while preserving all 22 journey alternatives. This is a general cache correction, not a route-specific exception. Cursor policy remains `scheduled-v3` because the result frontier is unchanged.

The queued-search endpoints above were deployed through the standard quick script. Public checks accepted jobs in 0.11–0.13 seconds and returned five journeys for each date. The first completed in 27.43 seconds; the second waited behind it and completed in 46.93 seconds total. Both first results were 13:45 → 18:02 London time via Stevenage and Leeds. Station lookups took 0.10–0.24 seconds through the public gateway; details took about 0.11 seconds while the other search ran. Idempotent submission, shared-work cancellation and cancellation before processing all passed.

The isolated host run peaked at about 859 MiB RSS. The deployed API peaked at about 891 MiB and settled to about 588 MiB with no swapped memory after these checks. Local throttled searches used about 44% worker CPU over elapsed time. These are acceptance samples, not a production capacity guarantee. Health/config/station responses matched their prior bytes, v1/v2 live departure response shapes passed, and only TrainTrack restarted. The active snapshot and runtime configuration are unchanged.

Evidence and the previous planner library/routes are retained under `/home/mwagstaff/.local/share/train-track-api/deployment-checks/queued-search-20260915T234000Z`. Roll back by restoring `previous-planner-lib` and `previous-planner-routes.js` and restarting only TrainTrack; the updated app falls back when submission returns 404. Update the local source as well before deliberately redeploying a rollback. Restarting either version expires in-memory search jobs.

## Live-search deployment — 16 September 2026

The live planner changes were deployed to `sky` by synchronising only the planner library from the local checkout and restarting `com.train-track-api.api.service`. The runtime, deployment configuration, API routes, active timetable and unrelated source files were unchanged. Future full code releases can continue using the standard deployment script. Rebuild and deploy the app for the **Use live times** toggle and disruption presentation; older app/API calls continue to use scheduled results.

**262 selected backend tests passed**, including the supplied full timetable regressions and live matching/routing/provider/context tests. The same two unrelated baseline tests described in the progress report remain excluded. All **34 planner app unit tests**, the live override UI flow, and dark-mode largest-text clipping/touch-target checks passed. The checks use deterministic disruptions; a separate real-provider check verifies production matching.

Public KTH–VIC searches returned five untruncated journeys: live search completed in **20.63 seconds**, scheduled override in **6.45 seconds**, and a future search outside the live window in **9.00 seconds**. Five returned legs had safely matched live observations. Station lookups stayed below **0.27 seconds** while routing ran, and details took **0.17 seconds**. Previously returned details preserved their original live context after the override search. The legacy scheduled-only job returned five journeys in **1.41 seconds**, without new live response fields.

Health, v2 config and station responses matched their pre-release bytes. V1 and v2 departure routes retained their shapes and each returned 16 departures. Only TrainTrack's PID changed. The API peaked at about **1032 MiB RSS**, with no swapped memory; this small acceptance sample is not a production load-capacity guarantee. Live coverage is partial and upstream lookup limits/failures were correctly disclosed in the response.

Public evidence is `/tmp/traintrack-live-public/summary.json`, also retained privately on `sky` under `/home/mwagstaff/.local/share/train-track-api/deployment-checks/live-planner-20260916T135630Z/public-http`. That directory's parent contains the previous planner library, source hashes, service PID comparisons and memory measurements. Roll back by restoring `previous-planner-lib` to the API's `lib/planner` and restarting only TrainTrack. The older server ignores the new optional request field and returns scheduled results; in-memory jobs and live pagination expire across the restart. Update the local checkout before deliberately keeping a rollback through subsequent deployments.

### Coverage warning correction later on 16 September

A fresh KTH–INV diagnostic identified wasted requests for old, unrelated departures, not a general identity-matching failure: all 11 successful detail responses matched, while 13 old references returned HTTP 500. The old search treated unrequested details as unsafe matches and the first-pass detail cap as a global lookup failure. The corrected selection and visible-page coverage rules above remove those false warnings while retaining genuine rail-leg gaps.

The fixed captured-data replay kept all five journeys and removed all 24 detail lookups. After a scoped planner deployment, public KTH–INV returned five scheduled later journeys in 35.37 seconds, without the misleading warnings; KTH–VIC returned five journeys in 5.48 seconds with all five near-term rail legs confirmed and no coverage warning. Station lookups remained below 0.27 seconds. The 281 selected backend tests and 36 planner app unit tests passed, together with focused UI coverage checks. Rebuild the app to remove the generic Tube note from cards and show how many rail legs are confirmed on time.

Evidence and the immediately preceding planner library are under `/home/mwagstaff/.local/share/train-track-api/deployment-checks/live-coverage-20260916T144200Z`. Restore that library and restart only TrainTrack to roll back this correction. No timetable or deployment configuration changed. The four-hour check window remains an eligibility rule; a provider may expose a shorter forecast horizon. Increasing request limits cannot supply forecasts that have not been published.

### Dividing-train recovery later on 16 September

The public detail product returned repeatable HTTP 500 errors for eight upcoming two-destination Southern services while all 20 single-destination services checked succeeded. A bounded fallback to the existing Staff board subscription now verifies the original occurrence using UID/date/operator and its complete public calling pattern. Public VIC–ECR checks subsequently confirmed all five returned trains in both live and override modes; KTH–VIC also confirmed all five and applied an actual delay. Provider suppression and genuinely absent forecasts still remain gaps. No app rebuild is required.

The release changed only three planner modules and added the existing staff key to the planner environment through its Bitwarden Apps mapping. The prior library, candidate capture and public evidence are under `/home/mwagstaff/.local/share/train-track-api/deployment-checks/staff-recovery-20260916T163500Z`. Restore `previous-planner-lib` and restart only TrainTrack to roll back the code; the unused optional key may remain, or its original environment can be restored from the private `staff-env-20260916T170922Z` backup after checking for subsequent configuration changes. Preserve the loading service's key mapping. Update the local source before deliberately retaining a rollback through another deployment.

## Saved journey boards — additive API and deployment

`POST /api/v3/journey-planner/route-boards` serves My Journeys and Favourites.
No existing v1/v2 departure resource or v3 search/job contract is replaced.
Send `Content-Type: application/json` and the existing optional
`X-Planner-Client` installation header. Example:

```json
{"routes":[{"id":"home-work","origin":"KTH","destination":"VIC","via":[],"realtime":"apply"}]}
```

Batches contain 1–8 routes. IDs are client correlation values; they do not enter
the shared cache. `via` contains up to four distinct, ordered required stations.
A train calling at a required station can continue without a forced change.
`realtime` is `apply` or `ignore`; ignoring live changes still displays warnings.
The routing options `maxChanges`, `extraConnectionMinutes` and `allowedModes`
use the existing planner bounds. All boards search from the current instant.

The response is `{apiVersion:3, boards:[...]}`. Each board has its supplied `id`,
`status` (`queued`, `refreshing`, `ready`, or `unavailable`), and `pollAfterMs`.
When available, `result` has the existing planner search response shape with
complete inline itineraries. Scheduled calculation and expiry timestamps are
separate from the result's live observation timestamps. Repeat the same POST
to poll; an HTTP 200 can contain an individual queued or unavailable board.
Only a ready board with no journeys establishes an empty result. The new app
falls back to legacy saved-pair departures only if this endpoint returns 404.

Pending boards also include optional `progress`: `phase` (`queued`, `preparing`,
`searching`, `live`, or `retrying`), `queuedAt`, and, after execution starts,
`startedAt`. `queuePosition` describes the saved-route queue; interactive searches
can also be ahead in the shared worker. During scheduled calculation,
`completedWindows` and `totalWindows` report actual completed departure windows.
These are work counters, not a completion percentage or predicted finish time.
Older apps can ignore the extra fields. Ordinary capacity waiting has no error;
a failed calculation retains its real error while waiting to retry.

### Cache and work limits

- Scheduled departure profiles are shared across clients for up to two hours.
  Keys include timetable/routing versions, origin, destination, ordered required
  stops, options, and a two-hour absolute time bucket. The internal eight-hour
  window includes two hours before the bucket for delayed earlier trains and
  retains at least four future hours until the next bucket. It is not a cache
  of the first five results or a reusable weekday template.
- The dedicated profile retains alternatives at different departure instants.
  Profiles are bounded at 512 candidates and 4 MiB including their envelope;
  incomplete profiles are marked. Candidates are retained across departure times
  before filling remaining space with alternatives. Smaller departure windows
  are calculated as separate hourly worker tasks. Current-hour options appear
  first with an explicit scheduled/live-pending warning; later hours continue
  in the background. Additive `coverage`/`search.profileCoverage` fields identify
  searched windows, and `search.provisional` identifies previews. Interactive
  requests can run between tasks. A label-heavy hour subdivides into disjoint
  intervals; elapsed deadlines and cancellation remain enforced. Completed
  hours survive a later chunk failure. Live-validated boards return up to five choices.
  Connecting options incur a ten-minute arrival-ranking penalty against direct
  trains, so a connection arriving at least ten minutes earlier can rank first.
- The new `planner_route_profiles_v1` Mongo collection creates its own expiry
  index lazily. Records contain only scheduled route data, never caller
  identities or live forecasts. Versioned hourly fragments reuse overlapping
  hours across the two-hour bucket boundary; each expires two hours after its
  departure interval ends or two hours after calculation, whichever is later.
  Top-level profiles retain their two-hour lifetime. Persistent records are limited to 256 and 4 MiB
  each; the memory front cache is limited to 32 MiB. Database unavailability
  falls back to memory. Expiry is checked on reads independently of Mongo cleanup.
- Live results are reused for 30 seconds and never served as current after their
  observation expires. Each refresh prioritizes upcoming trains, with at most
  20 service-detail targets, eight stations and eight staff fallback targets,
  all under the existing shared 64-request/two-concurrent-request provider bound.
  Rail legs outside the four-hour window remain scheduled; Tube/walking transfers
  do not receive missing-rail-live-data warnings.
- Relevant delays, cancellations and newly catchable trains trigger a shared
  early replan. New structural alternatives remain in an ephemeral refresh
  profile and are retimed/revalidated each time; live forecasts are never written
  into the two-hour scheduled cache.
- At most eight saved-board tasks are admitted, with two per requesting client
  and four per network. Identical work shares a single admission. Calculations use the existing
  routing pool, per-worker heap and cooperative CPU budgets. Interactive work takes priority
  over queued warming; waiting refreshes age into service. Foreground admission
  does not interrupt a calculation already running.
- Waiting routes retain their place across polling and advance automatically as
  slots become available. Oldest outstanding work is admitted first; repeated
  refreshes cannot keep reclaiming the slots ahead of other saved routes.
  Deferred intents remain bounded by the existing in-memory route limit.
  Completed stages retain their place until a first result is available;
  subsequent refresh/replan requests and failed retries take a new place.
  Under profile memory pressure, an idle queued route releases its in-memory
  profile and reloads the scheduled cache at its turn, preserving its queue age.
  A profile currently in use is protected; memory and concurrency limits do not
  increase to admit more routes.
- Live lookups can release the routing slot while awaiting network responses.
  Only one context may be suspended, and only below 55% of the worker heap;
  resumed CPU work reacquires the same exclusive slot. All contexts remain
  inside existing admission/deadline/cancellation limits. In-flight provider
  requests coalesce across searches, with independent caller cancellation,
  at most two active planner lookups, and the same main-process upstream request
  spacing used by legacy departure calls. On-time observations and scheduled
  overrides annotate existing routes without recalculating unchanged routing.
  The search-job manager admits one operation per routing worker plus one I/O
  waiter when enabled. At most two operations run routing CPU work concurrently.
- The pool defaults to two workers with 1,024 MiB heaps; use `PLANNER_WORKERS=1`
  on constrained hosts. Runtime call compaction and shared path nodes reduce
  memory, but these limits are not process RSS caps. Measure phase timings and
  host headroom before deployment. A worker failure discards only its own
  active/suspended work; the other worker continues. Unstarted assigned work
  survives one restart with its original deadline.
- Refreshing is demand-driven. Polling renews interest; two minutes without any
  interested client cancels pending work. Closing one client does not cancel
  work still requested by another. Both app tabs share their requests and poll
  only while active. Regular 20-second refreshes do not rebuild scheduled profiles.

### Rollout and data updates

The September performance and admin-filter improvements require only a standard
API redeployment and a reload of the admin page. Existing app builds can display
the earlier scheduled options. No app rebuild, timetable reimport, additional
upstream key or heap/concurrency configuration change is required for these
improvements. Mongo creates any required indexes through the existing cache setup.

Deploy the API first using the existing project deployment process, then release
the rebuilt app. No new upstream keys, timetable import or manual database
migration is required for this feature. Existing clients keep their existing
departure APIs. Route-wide updates continue to use their existing saved-pair
subscriptions; the new per-train action verifies the actual service before
starting a separate one-leg tracking flow. It does not automatically switch an
active train or provide end-to-end multi-leg notifications.

Engineering diversions depend on dated services present in the active snapshot.
The direct `import` command rejects incremental deliveries; managed S3 `sync`
applies them only against a matching baseline and an unbroken update chain.
New full snapshots can also be imported and activated ad hoc using the existing commands.
Activation immediately changes new cache keys; no two-hour wait is required.
Live cancellations cannot supply a missing replacement timetable.

## Direct-first saved departures — v4

New app builds use `POST /api/v4/journey-planner/route-boards` for Favourites and
My Journeys. It accepts the same saved-route batch fields as v3 and returns
`apiVersion: 4`. A board has `source: "direct"` with `direct` containing the
existing departure-board data, or `source: "planned"` with the existing planner
`result` shape. Queue/progress and polling remain per board. Existing v1/v2
departure endpoints, v3 saved boards and manual planner searches retain their
contracts. New clients fall back to v3 only when the server returns 404 for v4.

The v4 flow is:

1. Check the existing fresh, shared live departure lookup for the saved origin
   and destination. Available direct trains appear without starting a planner
   worker or checking timetable readiness. Required intermediate stations must
   belong to the same ordered passenger branch before a train qualifies.
2. When a successful fresh board returns no suitable direct train, check the
   shared route-plan cache. Provider errors, stale observations and incomplete
   empty responses remain live-data errors and do not trigger national searches.
   An empty board establishes only that no suitable train was returned in that
   board window, not the absence of every future direct service.
3. On a cache miss, run one ordinary six-hour connecting-journey search. The
   fallback does not build eight hourly departure profiles. Scheduled direct
   trains cannot suppress connecting alternatives when live data just ruled
   them out. Required vias, transfer allowances and mode options still apply.
4. Cache the resulting route patterns and scheduled examples for two hours from
   completion. Updates check direct trains first, then refresh the train pairs
   in the cached patterns and rebuild feasible connections with the saved
   connection rules. This refresh needs neither the national timetable index
   nor another national route calculation. Delays/cancellations affect those
   connections; the scheduled-time override retains the warnings.

Planned v4 boards show only the earliest arrival for options that start on the
same train at the same time and follow the same route, before limiting results.
Live mode compares live arrivals; the override compares scheduled arrivals.
Different first trains, operators or stopping patterns remain separate, as do
disrupted options. The cached plan retains all connection candidates so later
trains can still be selected after a delay or cancellation. The app highlights
change counts with labelled pills, from green for one change to coral for five
or more; direct journeys retain their neutral label.

The separate `planner_saved_route_plans_v1` collection has an automatic expiry
index. Keys include timetable version, London date, ordered vias and route
options; exact request times, two-hour clock buckets and client IDs do not enter
the identity. Empty successful plans are cached too. A timetable activation or
expiry permits a new discovery search. A failed live refresh does not invalidate
the cached route or create a replan loop. Missing live coverage remains explicit.

Live checks have four bounded slots and reuse the existing shared departure
cache; one fallback calculation can run through the existing routing worker.
The fallback queue admits eight jobs with the existing per-client/network
limits. Plans are limited to 256 KiB each, with 64 cached records and an 8 MiB
memory cache. The API continues serving metadata and direct departures while
fallback work waits. A fallback calculation records one planner search. Initial
reuse of a shared cached plan records a cache hit; routine direct lookups and
subsequent cached-leg updates do not inflate search totals.

Deploy the API and rebuild/release the app to use this flow. No timetable
reimport, new upstream key or manual Mongo migration is required. Older app
builds keep using their existing endpoints.

Local real-worker checks at 13:30 UTC on 17 September, with the unchanged 1 GiB
worker, full CPU duty and no live-provider latency, returned five connecting options in
3.05 seconds for Farringdon–Kent House via Herne Hill (cold), 1.31 seconds for
East Croydon–Worthing via Brighton, and 5.44 seconds for Euston–Inverness.
Each used one routing call and had no truncation. Cached payloads including the
complete calling patterns used to verify per-train tracking were 40–55 KiB.
These are scheduled fallback
measurements on the development machine, not end-to-end production guarantees.

V4 validation: 488 API tests passed, including full-timetable regressions and the
direct → cached connection → new live trains → direct transition. One optional
Mongo integration test was skipped; the unchanged device-deletion suite remains
excluded because it previously passed its assertions without exiting. The app
built successfully and the planner/saved-route tests passed, including the
21-test saved-route follow-up covering unknown delays, source changes and
per-train tracking from complete live calling patterns.

## Local performance checks — 17 September 2026

These are local Node 25.8.1 measurements against RJTTF939, not production latency
promises. A three-day national network retained 258 MiB after indexing and GC,
down from 382 MiB before runtime-call compaction (32% less). Parent-linked routing
paths and indexed completion bounds preserved complete result equivalence in
representative comparisons; Euston–Edinburgh's hourly routing fell from 8.75 to
5.05 seconds in that comparison.

A separate complete eight-hour Euston–Edinburgh saved-profile run used the real
worker with the unchanged 1,024 MiB heap and full CPU duty. It published five
provisional options after 7.59 seconds and completed all eight hours in 54.89
seconds, including the hour that previously exceeded its label budget. Immediate
journey-details retrieval worked before completion. Observed worker heap reached
662 MiB and process RSS 1,093 MiB. No upstream rail requests were made in this
benchmark, so live-service latency is additional. Hourly fragments and the complete
profile were cached. Sampled heap does not establish the allocation peak or a
production capacity guarantee; use new log diagnostics after deployment to check
first-result latency, queue pressure and memory on `sky`.

Validation: 448 API tests passed, including the full-timetable regressions; the
optional real-Mongo integration test was skipped. The unchanged device-deletion test file was excluded
from that run because an earlier full-suite attempt passed its four assertions
but did not exit. Admin relative/custom filters and timing details were also
checked in the browser. These changes have not been deployed by this work.

## Interpretation limits

Scheduled-only results include supported rail and timetabled replacement buses, dated cancellations/overlays in this full snapshot, ordered operator-pair interchange rules, and validated walking/Tube links. Source-backed ALF links are interpreted as station pairs and indexed in both directions. Their source identity, calendar, priority and duration remain unchanged; station allowances apply in the actual travel direction. A walk starting the journey omits the origin's train-exit allowance, and a walk ending the journey omits the destination's train-entry allowance. Transfers between trains retain both allowances. Other directed links and ordered TSI rules are not reversed. Public times and passenger boarding/alighting rules govern feasibility. A separate validation pass checks each returned itinerary.

This ALF interpretation follows the station-pair wording and directionless layout of RSPS5046 §5.11, corroborated by the supplied FLF pair descriptions and the absence of separately reversed pairs in all 4,209 ALF rows. The specification explicitly treats TSI differently in §5.12.1.2. Bidirectionality is an interpretation of those combined sources, rather than a quoted explicit ALF statement. [RSPS5046 P-04-02](https://www.rspaccreditation.org/downloadPublic.php?did=c5VkXAQOgMj8q024cALYymTpxTFaroiwLL7mvDA0A3UB5FJKuO)

Unsupported supplementary services, split/join through continuity and schedules requiring an authoritative holiday calendar are retained for audit but excluded from routing. Ambiguous clock-change origins and ambiguous midnight public fields are conservatively excluded. A transfer must fit its applicability window; unsupported fixed-link modes are disabled. Overall schedule date range is an envelope, not proof of complete coverage on every route/date. Do not market this prototype as complete national coverage or a live journey guarantee.

## Nearby walking and journey comparisons — 18 September 2026

Nearby-station alternatives use the timetable's supplied walking links, rather
than estimating walkability from straight-line distance. Walking legs remain
visible, count towards the total duration, and do not count as a train change.
The search compares their complete departure/arrival times with other options,
including the receiving station's boarding allowance. Walking must be included
in `allowedModes`; the link's operating dates and times still apply. In RJTTF939,
Clock House–Kent House is a nine-minute link that enables the 18 September
04:59 departure from Clock House, 05:12 train from Kent House, and 08:05 arrival
at Bristol Temple Meads via Victoria and Paddington.

Planner results and saved-route cards display a bold departure followed by a
regular, secondary-colour arrow and arrival time. Dates remain visible for
overnight journeys, and changed live times retain their scheduled-time note.
The duplicate arrival sentence is removed. Within each displayed list for a
route, `Fastest` marks all tied minimum durations when durations differ, and
`Slower` marks durations strictly above their arithmetic mean. Unknown or
invalid durations and cancelled journeys do not affect that comparison.

Local verification: 419 planner tests passed (three optional checks skipped),
plus 40 full-timetable/live-search checks and 123 app unit tests. Six simulator
scenarios verified the planner, saved cards, uniform durations and legacy
fallback, including light mode and dark mode at the largest text size. The
saved-card scenario checks each journey row's 44-point tap target directly;
the whole-screen hit-region audit reports an unidentified SwiftUI node, and
existing header controls still have 30-point minimum frames. Clipping checks
remain enabled, and the planner/largest-text scenarios passed hit-region
audits. Previews are saved in `.release-prep/journey-times-20260918/` locally.
These changes have not been deployed.
