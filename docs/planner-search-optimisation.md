# Planner search storage and optimisation — 18 September 2026

The storage/import measurements below record the initial local optimisation pass, before its deployment. The subsequent hourly S3 importer is documented in the [ingestion runbook](planner-s3-ingestion.md); the missing daily sequence chain still prevents activating the latest supplied update. See the [daily feed audit](planner-daily-feed-audit.md). The new routing-phase pass at the end of this document is local code, not yet deployed.

## Storage and memory recommendation

Raw timetable deliveries are import inputs, not read on every search. `lib/planner/repository.js` imports them into `timetable.sqlite` plus metadata/validation files. Local active storage is `api/train-track-api/var/planner/snapshots/RJTTF939`; production storage is the directory selected by `PLANNER_DATA_DIR` and its atomic `active.json` pointer. `PLANNER_DATASET_PATH` can select an explicit candidate.

The long-lived routing worker already caches resolved service dates, one national event index, target boarding/temporal bounds and exact scheduled search responses. Prewarming resolves the current date range while idle. The exact-result cache has a five-minute lifetime; live observations have their own shorter validity. The existing date/index cache bounds and memory-pressure relief should remain enabled.

**Keep durable SQLite snapshots and process-local routing data. Do not put the routing hot loop in Redis or MongoDB.** This recommendation follows the measured pipeline: parsing/index preparation and route expansion are CPU work; a remote store does not remove that work. Redis introduces client/server communication and serialization, and MongoDB would duplicate a database working set alongside the routing graph. Redis may become useful for sharing versioned result/observation caches between multiple API processes, but is not needed for the current single routing worker. See [Redis latency documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/latency/) and [MongoDB cache architecture](https://www.mongodb.com/docs/manual/core/wiredtiger/).

Measured three-date network (17–19 September): **69,241 services and 835,972 passenger calls**. Its retained indexed V8 heap is about **253 MiB**, essentially unchanged by the compact disk format because the runtime call objects were already compact. For the compact candidate, observed process RSS was about **462 MiB after indexing**, **693 MiB after the three default routing cases**, and **876 MiB peak across sixteen varied cases/date ranges**. These are standalone offline measurements, not a total API/Mongo/host memory budget or production capacity test. Leave host headroom and measure the deployed service; V8's 1,024 MB worker heap limit does not limit native SQLite memory or total RSS.

There is no reason to preload the whole timetable year as JavaScript objects. Copying a database into SQLite `:memory:` would also consume memory in addition to the dated graph and still require decoding/indexing. [SQLite in-memory database documentation](https://www.sqlite.org/inmemorydb.html) describes its connection lifetime and mandatory memory residency. Prewarm only the dated working set and use the filesystem/SQLite caches for persistent storage.

## Compact full imports

New imports write schema **v2**. Existing schema v1 snapshots remain readable and valid, allowing a normal candidate/activation/rollback workflow. Reimport into a new directory; an existing v1 directory is not silently rewritten.

For routing, import now retains only:

- Schedule UID, variant/source identity and source line, operator/mode, date range, weekday mask, STP and exclusion state.
- Mapped passenger-call CRS/TIPLOC, original occurrence sequence, public arrival/departure offsets and platform.
- Original working-origin departure, even when it is an unadvertised depot origin. It determines the whole working's GMT/BST convention.
- MSN station mappings/allowances, ordered operator-specific TSI overrides, and ALF transfer availability/priority/timings. Provenance/association records remain on disk and outside routing's hot loop.

Import discards passing/nonadvertised/unmapped calls from the search payload, parsing-only working arrival/pass values, raw public time strings, activities/suffixes and unused schedule-detail payloads. It retains diagnostics and raw source hashes. Original source files are not modified or deleted. Direct compact decoding avoids allocating verbose intermediate call objects. A covering calendar-metadata index avoids fetching large payload pages just to select running variants.

**Do not strip cancellations or excluded overlays.** Their calendar rows must still suppress a permanent service. Do not discard later/overtaking departures, repeated station occurrences, pickup/setdown permissions or the original working-origin time to obtain a smaller graph. Those changes could return invalid or incomplete routes. Platforms and TIPLOC/sequence are retained for existing presentation and exact live-service matching rather than inventing another lookup during search.

Schema v2 validation checks routing-call count/UTF-8 payload bytes, valid working origins and minimum supported-call counts in addition to SQLite integrity, schedule identities and representative-date/operator coverage. A passing validation report is still not certification of upstream completeness: existing holiday, supplementary and through split/join limitations remain unchanged.

## Measured results

Node 25.8.1 on the local Mac; sequential offline rail/walk searches, live/TfL disabled, five changes allowed. Measurements are not HTTP end-to-end latency guarantees. Filesystem cache/GC variability affects individual cold runs.

| Measure | Original schema v1 | Compact schema v2 |
| --- | ---: | ---: |
| SQLite snapshot | 1,072,545,792 bytes | 275,701,760 bytes (−74.3%) |
| Serialized call payloads | 595,429,216 bytes | 159,683,865 bytes (−73.2%) |
| Unused variant-detail payloads | 169,316,149 bytes | 922,354 bytes (`{}` placeholders) |
| Supported schedule variants | 379,141 | 379,141 |
| Stored mapped routing calls | 4,079,619 equivalent after decode | 4,079,619 |
| Total preparation, sixteen cases/date ranges | 5.380 s | 2.456 s (−54.3%) |
| Peak RSS, that sixteen-case run | 996.6 MiB | 876.5 MiB |

The storage comparison uses the same updated router on both snapshots. All sixteen normalized full-itinerary hashes, frontier counts, exact operation counts and label counts matched; so did all six default-case repetitions. The cases cover genuine arrive-by, overnight/Saturday and long-distance journeys. Only the content-version prefix of service IDs is normalized, since schema v2 intentionally has a different snapshot version.

Separately, profiling found millions of repeated cancellation/deadline clock reads in the routing loop. Polling now occurs at entry/every 256 work checkpoints, after native index preparation, before/after Tube I/O and before publishing a result. **Every operation is still counted and capped exactly.** No traversal/pruning policy or routing/cursor policy version changed.

| Warm route (compact snapshot) | Before poll batching | After poll batching |
| --- | ---: | ---: |
| Victoria → Kent House | 76 ms | 41 ms |
| Glasgow Central → Plymouth | 643 ms | 506 ms |
| Bristol Temple Meads → Edinburgh | 648 ms | 483 ms |

These are individual profiled runs, not population averages. Operations, labels and itinerary hashes stayed identical. Regression tests cover cancellation/deadline expiry in short and long searches and immediately after async Tube lookups, alongside the existing exhaustive forward/reverse routing oracle.

The complete planner test suite passed against both the original and compact full-data candidates: **467 passed, 1 optional input fixture skipped per run**, including independently pinned overnight/sleeper/public-time, live/TfL fallback and detail/cursor regressions. Synthetic tests additionally compare real v1/v2 snapshots across both DST transitions, passenger restrictions, repeated/unmapped calls, cancellation and excluded-overlay controls; corrupted compact payloads cannot activate.

The remaining warm-CPU cost is route-profile expansion and label dominance. This pass reduces import/read/decode and polling overhead, **not asymptotic graph complexity**. Further material complexity/RAM reductions should target packed station/event arrays and route-pattern/frontier indexing, verified against the exhaustive oracle; moving the same objects to Redis will not solve that bottleneck. Live rail and TfL lookup latency must be measured separately before claiming faster app end-to-end searches.

## Reproduce and roll out safely

From `api/train-track-api`, inspect a delivery or build a new complete-feed candidate:

```sh
rtk proxy node scripts/planner.js inspect --source sample_data/timetable_update
rtk proxy node --max-old-space-size=512 scripts/planner.js import --source resources/timetable_full --staging var/planner/snapshots/NEW_COMPACT_CANDIDATE --mode full
rtk proxy node scripts/planner.js validate --dataset var/planner/snapshots/NEW_COMPACT_CANDIDATE
rtk proxy node --expose-gc scripts/planner-storage-benchmark.js --dataset var/planner/snapshots/NEW_COMPACT_CANDIDATE --cases test/planner-benchmark-cases.json --repetitions 1
rtk proxy env PLANNER_FULL_DATASET=/absolute/path/to/NEW_COMPACT_CANDIDATE npm run test:planner
```

The already-built local candidate is `var/planner/snapshots/RJTTF939-compact-v2`; the original active pointer still references `RJTTF939`. Measurement artifacts are in `var/planner/reports/storage-v1-after-polls.json`, `storage-v2-after-polls.json`, `storage-v1-broad-after-polls.json` and `storage-v2-broad-after-polls.json`. The benchmark's optional `--output PATH` saves a new report without overwriting an existing one.

Production requires deploying the code, importing/validating a new complete snapshot on the host and explicitly activating it via the existing CLI. A code-only deployment keeps the v1 snapshot usable but does not gain compact-storage benefits. This work does not deploy, activate, configure a daily job or change freshness thresholds.

For daily delivery, first obtain a current full MCA (or missing 940–961 updates for baseline 939). Then implement atomic, idempotent, strictly ordered CFA application to a canonical import store, refresh the full supporting files, rebuild the compact projection and validate before activation. The new inspector labels CFA packages `feedMode: "update"` / `requiresBaseline: true`; it never claims their presence proves complete coverage. The full importer explicitly rejects them.

## Routing-phase profiling and unchanged-topology reuse

This is a code-only routing pass. It does not import, activate, deploy, change search freshness rules, reduce the time window/change allowance, or alter timetable gap handling.

Profiling exposed a separate TfL fallback hotspot: every eligible unavailable/request-limited connection copied the entire national station map to override just two allowances. Resolution and validation now construct only the two endpoint records. This changes that per-transfer work from O(stations) to O(1), without caching or changing live responses, closure evidence, rule priorities, availability windows or allowance calculations. Regression tests prohibit station-map iteration and verify original station records remain untouched.

Timing/platform-only live overlays now reuse the pinned baseline's boarding-distance bounds, including a first cache miss. Service identity, mode, ordered station calls and boarding/alighting permissions must be unchanged. Cancellations, split services, skipped/unknown calls and added connectivity calculate their own topology bounds: weaker baseline bounds could otherwise increase work or disable completion-specific temporal pruning. Time-dependent bounds always remain on their own effective network, so a delay can still create a newly feasible connection.

The existing cache limits and memory-pressure release remain in force. There is no new database, Redis dependency or persistent cache. Complete itineraries, calling points, ranking and pagination are compared before/after; the routing policy/cursor version is unchanged.

New searches persist these additional bounded fields in the existing seven-day search log and show them under **Timing details**:

- `indexBuildMs`, `topologyBoundsMs`, `temporalBoundsMs`, `labelExpansionMs`.
- `transferResolutionMs`: TfL connection resolution and selected-result verification wall time, including provider waits and queue resumption. This is not a pure network-I/O or CPU measurement.
- `resultAssemblyMs`: candidate deduplication/Pareto filtering, ranking, itinerary construction and independent feasibility validation.
- Topology/temporal build and cache-hit counts, plus `internalRoutePasses` (including internal TfL retry passes).

Phase durations are within route-calculation time, not extra durations to add to it. Outer `routeCalls` still counts engine reroutes separately. Failed/cancelled searches retain completed and interrupted phase measurements; old log rows do not gain invented measurements.

### Measured routing results

On the local Mac, Node **24.19.0**, against `RJTTF939-compact-v2`, three paired repetitions per phase gave these median routing wall times. The before modules were captured before this pass and include the original transfer resolver; both sides include the previously implemented clock-poll batching. Index preparation is excluded and real live/TfL provider latency is not simulated.

| Kent House → Inverness phase | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Scheduled, cold bounds | 4.016 s | 2.046 s | 49.1% |
| Synthetic five-minute live delay | 3.790 s | 1.829 s | 51.8% |
| Cancelled final train, fresh live bounds | 3.990 s | 2.195 s | 45.0% |
| Scheduled again, warm bounds | 3.637 s | 1.825 s | 49.8% |

All **12 paired full-output hashes matched**, including calling points, ranking and pagination. Label counts are identical in every phase. Operations remain identical except the timing-only overlay avoids the topology scan (5,608,645 → 5,605,400). Cancellation still builds its own topology bounds and preserves its original work/pruning behavior.

The after delayed phase spends about **1.63 s** expanding routing states, **84 ms** resolving fallback transfers and **0.55 ms** assembling final results; topology is a cache hit and temporal bounds rebuild. This identifies state/frontier work as the next local CPU target, not final-result assembly. The original resolver's transfer phase in the preceding controlled profiling run was about 1.77 s, even without network requests.

The complete paired report is retained locally at `api/train-track-api/var/planner/reports/routing-phases-node24-2026-09-18.json` (ignored benchmark artifact). These measurements do **not** establish that a deployed 45-second live search will take two seconds: host CPU/memory pressure, real upstream requests, live-triggered reroutes and TfL verification passes still require a fresh deployed search.

An additional arrive-by Kent House → Inverness request for 19 September at 10:00 BST matched all four paired phase outputs, returning five journeys per phase. Its report is `api/train-track-api/var/planner/reports/routing-phases-arrive-by-node24-2026-09-18.json`; it was a correctness check run alongside tests, not used for performance claims. The final complete planner suite on Node 24 passed **547 tests**, with two opt-in tests skipped (real national-source reimport acceptance and external Mongo integration). The full-dataset overnight/long-distance tests ran. New focused tests cover cache isolation, disrupted exhaustive-oracle equivalence, cancellation/timeout during verification, phase accounting and non-iteration of the national station map.

### Offline benchmark and deployment check

The read-only benchmark uses the same dated full network, five-change/six-hour request and retained live-frontier capacity for scheduled, synthetic five-minute delay, cancellation and scheduled-again phases. It does not contact live providers, write search history or modify a dataset. It compares every non-metric result field when an optional before-router module is supplied, alternates paired order, and reports per-phase median timings.

```sh
rtk proxy node --expose-gc --max-old-space-size=1536 scripts/planner-routing-benchmark.js --dataset var/planner/snapshots/RJTTF939-compact-v2 --origin KTH --destination INV --time 2026-09-18T16:59:52+01:00 --repetitions 3
rtk proxy env PLANNER_FULL_DATASET=/absolute/path/to/RJTTF939-compact-v2 npm run test:planner
```

`--baseline-router /absolute/path/to/router-before.mjs` enables full-output comparison. That module must resolve unchanged dependencies to the same application code. To compare a transfer-resolver change as well, also supply `--baseline-tube-resolver /absolute/path/to/tube-before.mjs`; the before router's transfer validator must use that before module too. Otherwise the current resolver is used for both sides and only the router is compared. Both baseline paths are recorded in the report. Progress goes to stderr and the report to stdout. Without a baseline, `comparisonsMatched` is `null`, not a correctness claim. Scheduled indexes are prepared before timing; `preparationMs` is separate. Benchmark CPU is process CPU (including GC threads), unlike the admin worker-thread CPU measurement. Peak RSS is the combined benchmark process, not a per-router production memory estimate.

After deploying the API code, run a fresh queued live Kent House → Inverness search and expand **Timing details** in `/admin/journey-planner`. Verify a timing-only live reroute records a topology cache hit and fresh temporal bounds, and compare route calculation, worker CPU, transfer resolution, result assembly, routing operations and internal pass counts. Exact cached responses may not execute routing; use a fresh request when validating the new fields. No timetable reimport is required for this code-only pass.

The selector-free `tt-timetable-ingestion` dashboard JSON is also ready locally. Import it with overwrite using the normal complete dashboard deployment directory, or upload that single dashboard in Grafana. Do not run the central dashboard synchroniser against a one-file temporary directory: it can remove other dashboards absent from that directory. An API code-only deployment does not update Grafana.
