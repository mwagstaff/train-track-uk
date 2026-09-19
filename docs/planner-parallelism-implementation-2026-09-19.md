# Two-worker routing and CPU reductions — 19 September 2026

The planner now supports two independent routing workers, and the measured RAPTOR hot paths do less allocation and repeated connection-rule work. This implements the first two priorities from the [parallelism investigation](planner-parallelism-review-2026-09-18.md). Changes are local; production has not been deployed or reconfigured.

`PLANNER_WORKERS` defaults to **2**, accepts **1 or 2**, and starts workers only as demand needs them. `PLANNER_WORKERS=1` restores the previous routing capacity. Both workers open the same immutable SQLite snapshot read-only. Each retains its own graph and indexes, bounded by the existing 1,024 MiB old-generation limit; that setting is per worker and is not a process RSS cap.

One shared queue preserves the existing eight-operation global admission bound, interactive priority and background ageing. Only one live context may park across the entire pool. The search-job manager can admit two CPU operations plus that one waiter. A cancelled or crashed worker does not terminate the other worker's work. Unstarted work retains its deadline through recovery.

Scheduling prefers an idle worker that owns a repeated search result or a matching dated graph. Date affinity is a hint, while live/TfL pagination affinity is mandatory: snapshot cursors return to their owning worker and expire if that worker has restarted. Journey details stay in the bounded parent cache. Search-cache clearing fans out to all started routing workers while preserving graph indexes, journey details and snapshots. Runtime reporting sums worker heap/cache counters but reports shared process RSS once. Idle prewarm prepares RAPTOR and the original validation index in each started worker.

The parent also owns a two-request upstream broker. Identical pending requests from different workers share transport while each caller retains independent cancellation. The last cancellation aborts transport, and an aborted request retains its concurrency slot until it physically settles. The broker does not add an observation cache; existing worker caches and upstream host spacing continue to apply.

RAPTOR changes preserve scan order, unsafe-service history guards and the existing equal-criteria representative:

- Allocate alighting paths/labels and boarding histories after dominance accepts them.
- Compact dominated label/boarding bags in place.
- Reuse the maintained destination frontier instead of rebuilding and filtering historical completions quadratically.
- Pre-resolve operator interchange conflicts once per immutable connection index.
- Cache fallback station allowances with station/value/provenance checks so TfL endpoint overlays remain correct.
- Reuse parsed fixed-link clocks and a bounded London calendar cache, preserving overnight service dates and DST rules.

Descending-departure rRAPTOR reuse is deferred. It changes search-state reuse and tie handling substantially; the targeted reductions below already produce a material gain without changing the routing policy. Single-query departure partitioning, packed shared graphs and database sharding are also outside this implementation.

**Local measurements**

Node 24.19.0 on the local M5 Pro, compact RJTTF939 snapshot. Baseline code was copied before this implementation. Each pair receives the identical dated graph, warm indexes and full-frontier requests; there are two warmup pairs and three measured pairs per case, with measured execution order alternating. Timing includes itinerary validation and excludes providers and result-cache hits.

| Scheduled route | Before, median | After, median | Reduction |
| --- | ---: | ---: | ---: |
| Kent House → Inverness, evening | 543 ms | 310 ms | 43% |
| Kent House → Inverness, overnight | 596 ms | 383 ms | 36% |
| Victoria → Kent House | 103 ms | 72 ms | 30% |
| Glasgow Central → Plymouth | 473 ms | 315 ms | 33% |
| Bristol Temple Meads → Edinburgh | 647 ms | 406 ms | 37% |

Synthetic five-minute delay and cancellation cases for Kent House → Inverness improved from 467→310 ms and 468→306 ms. All seven cases matched **exact journeys, pagination and policy**, including tied representatives, across all warmup and measured comparisons. This is stronger than comparing only departure/arrival/change tuples. The comparison process holds both old and new indexes and is not used for worker-memory claims.

A separate benchmark exercised the actual `PlannerService`, worker transport and API engine. Each batch submitted eight distinct requests concurrently, returning ordinary five-result pages, with warm indexes and all result-cache misses. Worker counts ran in separate fresh processes; each had three measured batches.

| Workers | Median eight-search batch | Throughput | Observed process RSS at batch boundaries |
| --- | ---: | ---: | ---: |
| 1 | 2,366 ms | 3.38 searches/s | 961–962 MiB |
| 2 | 1,222 ms | 6.55 searches/s | 1,445–1,464 MiB |

The pool provided **1.94× throughput** over the optimized single worker. All 48 API-engine results matched across repetitions and worker counts. These numbers exclude HTTP, job-lease queueing and provider waits. RSS samples can miss transient peaks. They do not establish production percentiles or spare capacity on `sky`; other services and simultaneous date changes/imports still need a deployment memory budget.

**Verification and evidence**

Focused tests cover true simultaneous CPU execution in separate isolates, global admission, cancellation and crash isolation, live/TfL cursor ownership, expired snapshots, cache/date affinity, global I/O parking, pinned resumption, cache clearing, startup configuration and runtime reporting. Broker tests cover shared concurrency, request identity, cancellation, errors and closure. Connection and RAPTOR tests include seeded exhaustive-oracle fixtures, timed links, overnight/DST boundaries, endpoint overlays, unusual services and exact tie/pagination regressions. A differential run of the RAPTOR fixture suite also compares exact outputs against the pre-change implementation.

The final planner suite with the national snapshot passed **628 tests**, with **zero failures and two opt-in skips** for external Mongo and raw ingestion fixtures. A separate national comparison of the original router also matched exact output across scheduled, delayed, cancelled and scheduled-again phases, because connection optimizations affect that router too.

The broader API run passed 774 tests and skipped the same two opt-in cases. Two existing, unchanged non-planner files, `device-data-deletion.test.js` and `live-session-origin.test.js`, did not finish and their processes were stopped after approximately 98 seconds. That broader run is not reported as passing; its two termination failures are retained in `full-tests.log`. The final planner result is in `planner-tests.log`.

Raw measurements and reproduction scripts are retained locally under the ignored directory `api/train-track-api/var/planner/parallelism-implementation-2026-09-19/`:

- `core-benchmark.mjs` / `core-results.json`: paired exact-output routing comparisons and current source hashes.
- `pool-benchmark.mjs` / `pool-1-results.json` / `pool-2-results.json`: real worker/API-engine throughput and memory samples.
- `original-router-differential.json`: legacy router comparison with matching baseline connection and Tube resolver modules.

The baseline module tree is `api/train-track-api/var/planner/parallelism-implementation-baseline/lib/`. Diagnostic artifacts are not production commands. Existing deployment/runtime pinning is unchanged; no new timetable import or database copies are needed.
