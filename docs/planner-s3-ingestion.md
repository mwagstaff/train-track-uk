# Hourly timetable ingestion

## Delivery and safety

The API checks `s3://traintrack-uk-daily-full-timetable` in `eu-west-2` at startup
and every 3,600 seconds while running. It checks `timetable_full.zip` and
`timetable_update.zip` with HEAD; unchanged, committed deliveries need no GET,
parsing or search-snapshot rebuild. Changed deliveries are conditionally
downloaded with their checked ETag, bounded in size and cached with SHA-256.
An unchanged pending gap reuses the download but rechecks the daily manifest.

The monthly MCA bootstraps a private canonical SQLite store of complete raw
schedules, associations and TIPLOC definitions. A daily CFA is a delta, **not a
complete timetable**: N/R/D transactions require exact identities and an
unbroken sequence (including 999 → 001). Daily auxiliary files are complete
refreshes. Usable previous-file references are checked; historical constant HD
references in monthly files are not mistaken for current publication dates.
Publication freshness comes from DAT, not S3 upload time or import time.

After applying a delivery, the importer builds the compact schema 2 search
projection, validates inventory and representative dates/operators, then uses
the existing coverage-loss guards and atomic active-pointer switch. Calendar
rows, dated cancellations and overlays remain even where there are no routing
calls. Passing locations, non-passenger calls and parse-only payloads do not
inflate the search projection. Complete raw records stay on disk for subsequent
updates; they are not loaded into the routing worker's heap. No Redis or Mongo
copy of the national timetable is introduced.

Downloads/imports run in a separate 512 MiB V8-old-space process, not the HTTP
event loop. One owner-token lock prevents manual/hourly overlap. A run has a
15-minute limit, then SIGTERM and a five-second SIGKILL grace. Dead **local**
owners can be reclaimed safely, including private import/activation locks and
partial staging. Live owners are never evicted by age. Unknown, remote,
malformed or interrupted-recovery locks fail closed: inspect their owner and
confirm no relevant process is running before an operator removes an exact
lock file. Do not recursively delete the planner directory.

`active.json` → snapshot `metadata.delivery` → canonical store is the commit
chain. `ingestion-state.json` is an observational summary only. A process crash
after activation cannot make a stale state summary become the baseline for the
next update. A manual activation/rollback during ingestion blocks publication
against the superseded active version. Future checks follow the newly active
snapshot.

### Current delivery gap — verified on 18 September 2026

Read-only access tests on `sky` succeeded using the deployed credentials. The
bucket has monthly **939 / 25 August** and daily **962 / 17 September**. Updates
**940–961 (22 deliveries) are missing**. Their 18 September upload timestamps
do not establish fresh timetable content. Ingestion may build/activate the
complete compact 939 baseline, but **will not apply 962 directly**. It reports a
gap and keeps the last valid full/effective snapshot.

Obtain a current complete full package, or arrange replay of every missing
daily package in order, before expecting up-to-date daily routing. With only
two overwritten latest keys, an outage or missed delivery can cause another
gap; the current worker does not invent or fetch an unspecified historical-key
layout. Ask the delivery provider for immutable dated keys or accessible retained
versions and a replay mechanism. Bucket versioning configuration was not
accessible to this account, so it has not been established or changed.

## Configuration

The supplied Bitwarden-backed variables are used directly:

- `TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_ACCESS_KEY`
- `TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_SECRET_ACCESS_KEY`

No credentials are written to receipts, snapshots, state or logs. Optional
overrides are `TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET`,
`TRAIN_TRACK_UK_TIMETABLE_S3_REGION`, `TRAIN_TRACK_UK_TIMETABLE_S3_FULL_KEY` and
`TRAIN_TRACK_UK_TIMETABLE_S3_UPDATE_KEY`; their defaults are listed above.

Automatic checks require `PLANNER_INGESTION_ENABLED=true`; credentials alone
never assign ingestion ownership to a process. `false` or an unset value disables
unattended checks while allowing manual `sync`. `true` reports missing credentials
as a configuration error. **Unset `PLANNER_DATASET_PATH`**: a fixed
snapshot override would otherwise prevent searches following new activations.
Keep the existing absolute, persistent `PLANNER_DATA_DIR` outside deployed
source. Runtime: Node ≥22.16 with SQLite (production pinned Node 24), `unzip`,
and the lockfile-installed new `@aws-sdk/client-s3` dependency.

Minimum bucket permissions are `s3:GetObject` on both keys. `s3:ListBucket`
allows a missing optional update to produce 404; without it, a 403 is treated
as access denied rather than silently ignored. Conditional GET does not require
version permissions. See AWS [HeadObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html)
and [GetObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html).

The existing source-age readiness thresholds remain at their monthly defaults
(35-day warning / 45-day cutoff). Do not tighten them until the initial gap is
resolved: that would make the currently usable baseline unavailable. Once daily
delivery is established, set `PLANNER_WARN_AGE_DAYS=2` and
`PLANNER_MAX_STALE_DAYS=3` if those match the agreed service policy.

## Manual download + import

From the API directory, with the service's credentials/configuration loaded:

```sh
npm run planner -- sync
npm run planner -- sync --dry-run
```

`sync` checks/downloads changed objects, imports, validates and activates.
`--dry-run` still downloads and builds/validates candidates, but does **not**
alter the active pointer, activation history or ingestion state. It leaves a
private candidate for inspection; use an isolated `--data-dir` for repeated
experiments. It is not a bypass for gaps or coverage guards. Unchanged files
are cached; there is no unsafe force-apply option. Exit codes: 0 completed,
2 missing update chain (a valid full baseline may have activated), 1 failure,
130 interrupted.

On `sky`, after deployment, use the pinned Node runtime, not shell Node 20:

```sh
rtk proxy ssh sky 'cd /home/mwagstaff/dev/train-track-api && source .static-config-train-track-api.env.sh && source .bw-secrets.env.sh && /home/mwagstaff/.local/share/train-track-api/runtime/node24/bin/node --max-old-space-size=512 scripts/planner.js sync'
```

Add `--dry-run` for a validation-only activation check. Both environment files
export their assignments; do not print their contents. Do not pass `sync` to
`.start-with-bw-env-api.sh`: that wrapper starts the API and does not forward
CLI arguments. No unauthenticated HTTP import trigger is added.

## Storage and retention

On the supplied full package, a canonical delivery uses approximately **1.48
GiB** (868 MiB raw SQLite + 645 MiB full export), plus a **263 MiB** compact
search database. These are persistent/import storage figures, not routing heap.
Retained routing memory measurements remain in
[search optimisation](planner-search-optimisation.md).

Normal sync prunes only generated `PLANNER_DATA_DIR/deliveries` stores. It keeps
the three newest managed snapshots, the active and immediate rollback paths,
their required canonical stores, and the two newest retryable canonical
candidates. Download caching keeps four recent archives plus the currently
observed keys. Superseded generated stores are permanently removed and their
activation-history entries pruned; older managed versions are not guaranteed
rollback targets. Manual snapshots, existing `snapshots/` imports, user raw data
and source-tree files are never pruned. Progress logs report generated removals.

Provision at least **24 GiB** for this delivery pipeline at the supplied feed size, additional to legacy
manual snapshots and other API data; allow more for feed growth. Before heavy
download/extraction work, the worker requires **8 GiB free** on both data and OS
temporary filesystems. It prunes managed history before staging and after failed
normal runs, avoiding an accumulating failure loop. Dry-run candidates are not
automatically pruned by dry runs; subsequent normal sync applies retention.
V8 limits are not an RSS cap. Measure total memory, CPU contention and disk usage
on `sky` before turning on unattended imports.

## Grafana and deployment acceptance

The deployment dashboard is
`api/train-track-api/observability/grafana/dashboards/timetable-ingestion.json`
(title **Timetable Ingestion & Data Quality**). The deployment
tool imports this directory during a full deployment; a quick code-only deploy
does not import the dashboard. Alternatively import its JSON in Grafana and
select the existing folder, retaining UID
`tt-timetable-ingestion` and confirming overwrite. This needs no API restart.
Do not point the central importer at a temporary single-dashboard directory:
it prunes other dashboards absent from that directory. Metrics use the existing
`/metrics` scrape and the deployment-injected datasource, like sibling service
dashboards. No Prometheus/Instance/PID selector bar is present. All status
cards/tables and historical gauges select the newest singleton API process at
each timestamp; historical graphs span restarts. Histogram rates aggregate
across PIDs. The default view is the last hour;
choose a longer range for historical comparisons. See
[Grafana README](../api/train-track-api/observability/grafana/README.md) for
thresholds and optional alert expressions.

Panels distinguish source age and S3 upload age, successful HEAD checks and
successful imports, applied/baseline sequence and missing chain boundaries,
interrupted workers, schema 2 status, validated size/inventory, diagnostic
exclusions and representative-day/per-operator coverage. Unknown data is N/A,
not fabricated zero or a successful validation. Structural validation and
schedule-range coverage do **not** certify complete national service coverage;
existing ZTR, holiday-calendar and split/join limitations still apply.

Suggested rollout (not performed by this work):

1. Deploy with `PLANNER_INGESTION_ENABLED=false`; install lockfile dependencies
   using the pinned runtime. Import the dashboard via full deploy or Grafana UI.
2. Run manual `sync --dry-run`, inspect candidate validation and confirm the
   known 940→962 gap, without changing production data.
3. Run `sync` when ready to switch to compact full data; verify publication
   remains 25 August if the gap is unresolved. Exercise station lookup, direct
   and connecting journeys, both time modes, and legacy v1/v2 endpoints.
4. Resolve the delivery gap/current full baseline, then enable hourly checks and
   restart the TrainTrack API only. Verify startup and subsequent hourly check,
   unchanged-file behaviour, daily sequence advancement, freshness and operator
   inventories. Observe host load/RSS alongside departures and push handling.

Code and access checks are local/read-only; this work does not deploy, restart
production, import the live bucket into production, change IAM/bucket settings
or install a live Grafana dashboard/alerts.

## Local verification — 18 September 2026

The isolated full-size acceptance test used the supplied monthly 939 and daily
962 directories, packaged as ZIPs, on Node 24.19 with 512 MiB V8 old-space. The
check/import/validation took **65.6 seconds**, with **454 MiB peak RSS**. It
produced a valid **275.7 MB** search SQLite database, 461,177 variants including
retained ZTR rows, and 4,079,619 compact routing calls. Full 939 activated only
inside the temporary test directory; daily 962 stayed blocked at the 22-update
gap. The repeat check took **89 ms**, downloaded zero bytes and did not change
the pointer. These are local measurements, not a production latency guarantee.

The acceptance test is opt-in and leaves existing planner stores untouched:

```sh
PLANNER_INGESTION_FULL_SOURCE=/absolute/path/to/timetable_full \
PLANNER_INGESTION_UPDATE_SOURCE=/absolute/path/to/timetable_update \
node --max-old-space-size=512 --test --test-name-pattern='opt-in real' test/planner-ingestion.test.js
```

It requires `zip` only to generate test archives; production ingestion requires
`unzip`, not `zip`. Unit/integration coverage includes N/R/D routing changes,
auxiliary refresh and recovered mappings, rollover, gaps, conditional/corrupt
downloads, manual/hourly concurrency, hard-kill locks/staging, activation races,
dry-run isolation, retention protection, metric unknown states and dashboard
queries. The existing planner full-fixture regressions also passed against the
compact snapshot. Other API tests passed except the unchanged
`device-data-deletion.test.js` was deliberately excluded because it is known to
finish its assertions without exiting; the optional live-Mongo check was skipped.
Dependency audit still reports the three existing moderate Express/body-parser/qs
issues; no AWS SDK vulnerability was reported and unrelated dependencies were
not changed automatically.
