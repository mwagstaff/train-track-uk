# Journey planner performance review — 17 September 2026

## Conclusion

The recent clock, calendar and temporal-cache changes improve ordinary searches,
but the largest remaining costs are saved-route profile generation, temporary
search allocations, and live API waits occupying the sole routing worker.
Reduce those costs before increasing worker count or heap limits.

This review inspected commit `c34d273`, the supplied speed-up summary, production
`sky` through read-only SSH/Mongo/Prometheus queries, and bounded local benchmarks.
No application code, production settings or production data were changed.

## Production findings

Measurements were taken around 13:31–13:36 BST (12:31–12:36 UTC).

| Item | Observed |
| --- | --- |
| Host | 4 virtual CPUs, AMD EPYC Genoa; 7.56 GiB RAM |
| Available RAM during inspection | Approximately 2.0–2.3 GiB |
| Lowest available RAM over 24 hours | 156.7 MiB, around 10:54 BST |
| Lowest available RAM over the last two hours | 1.07 GiB |
| Swap occupied | Approximately 1.69 GiB of 2 GiB |
| CPU idle over 24 hours | Approximately 71% on average in one-minute samples |
| Maximum observed one-minute load average | 6.66 on 4 CPUs |
| API runtime | Node 24.21.0 |
| Routing workers | One; separate small metadata worker |
| Routing worker old-generation heap limit | 1,024 MiB default; no override configured |
| Job CPU duty cycle | 100% default; no override configured |
| Service CPU quota / memory cap | Neither configured; all four CPUs allowed |

The host has spare CPU on average, but memory headroom is not consistently large.
The short `vmstat` sample showed no active swap-in/out, so occupied swap alone
does **not** establish current thrashing. Other applications and Mongo share this
host. Peak API RSS in the previous 24 hours reached approximately 1.29 GiB.

`ERR_WORKER_OUT_OF_MEMORY` is consistent with exhausting the worker's own V8
heap allowance; free host RAM does not automatically raise that allowance.
Worker limits do not cover all native/external allocations, so a 1,024 MiB
worker is not a 1,024 MiB process-RSS cap. See the
[Node 24 worker resource-limit documentation](https://nodejs.org/docs/latest-v24.x/api/worker_threads.html#new-workerfilename-options).
The retained error log contains two such messages, without timestamps. No kernel
OOM-kill message was returned for the last day, and the current service cgroup
reports zero OOM kills. This does not identify the precise allocation that failed.

### The screenshot precedes the latest deployment

Production hashes for `engine.js`, `router.js`, `service.js`, `worker.js`,
`live-search.js` and `route-boards.js` match the current local files. The memory
correction described as uncommitted in the attachment is now committed and
present in production.

The current API process started at **11:53:44 BST**. All 45 retained search-log
rows finished by **11:06:53 BST**, before that restart. They therefore do not
measure the latest deployed memory correction. The current process's observed
RSS high-water mark was only about 150 MiB during this inspection; these readings
are not an active-routing stress test of the new build.

The 45 rows comprise:

- Nine successful saved-route initializations.
- One failed initialization (`DATASET_UNAVAILABLE`).
- Seventeen expired operations.
- Eighteen superseded operations.
- Zero recorded cache hits, twelve misses, thirty-three unknown cache outcomes.

The batch initialized around 11:00 BST. Results completed sequentially, reaching
6m 49s; several remaining entries expired together at about 6m 53s. Durations
include waiting, routing and live lookup stages. Expiry can follow loss of client
interest; it is not evidence that every route consumed six minutes of CPU.
The log does not yet retain enough phase timings to apportion those durations.
The profile-cache collection was empty at inspection, after the two-hour lifetime
of these profiles had elapsed; this is not proof of a persistence failure.

## Highest-impact findings

### 1. Saved boards do eight expensive searches before exposing any result

[`route-board-engine.js:81`](../api/train-track-api/lib/planner/route-board-engine.js#L81)
runs eight serial one-hour national searches. Unlike an ordinary search, each
preserves alternatives for each departure. A single profile occupies the shared
worker throughout. The manager then waits for a separate live-refresh turn before
making the board ready, despite the profile operation already producing an initial
scheduled result (`route-boards.js:298`).

Local measurements on snapshot RJTTF939, Node 25.8.1, unthrottled, with a 1.5 GiB
heap allowance, for **17 September, 10:00–18:00 UTC**, five changes:

| Saved route | Scheduled profile result, without live API calls |
| --- | --- |
| Kent House → Victoria | 4.66 seconds cold; 151 candidates |
| East Croydon → Worthing, required via Brighton | 29.81 seconds warm; 512 retained candidates |
| Euston → Edinburgh | Failed in the fifth hourly slice at the 200,000-label limit |

Euston → Edinburgh's first four hourly slices took 9.86, 10.21, 10.47 and 10.64
seconds. The fifth slice independently reproduced “Journey search exceeded its
label budget.” Earlier completed hours are lost when the whole operation throws.
These are local workload measurements, not production latency estimates or the
exact time windows in the screenshot.

**Recommendation:** make hourly calculations separate, resumable tasks. Prioritize
the current-hour options, publish them with explicit partial-coverage status, and
finish later hours in the background. Allow interactive searches between chunks.
If a chunk exceeds its work/label budget, subdivide its departure window and retain
completed chunks. Splitting must preserve exact boundaries, deduplication, required
vias and completeness reporting; it still needs a bounded fallback if an individual
departure is expensive. Longer timeouts or smaller displayed result counts do not
solve the underlying exploration cost.

### 2. Compact timetable calls before attempting a large routing rewrite

A measured three-day network contained 69,080 services and 859,260 call objects.
It retained about 265 MiB after date resolution and **382 MiB after indexing**.
`calendar.js:113` and `time.js:111` retain parsing/time-resolution fields that the
runtime search does not need.

An isolated experiment retaining only `tiploc`, `sequence`, `station`, `arrival`,
`departure`, `canBoard`, `canAlight` and `platform` reduced indexed retained heap
to **258 MiB: 124 MiB / 32% less**.

This is a measured allocation opportunity, not a production-ready patch. Construct
compact runtime objects directly, preserve importer/debug representations, and
verify complete output and live-matching equivalence. In particular, staff matching
still needs TIPLOC.

The pressure valve at `engine.js:171` runs before network preparation, not between
the eight hourly searches or every live reroute. Boundary samples reached about
807 MiB for the via-Brighton profile and 892 MiB for Euston → Edinburgh; actual
peaks can be higher. Evicting caches cannot free structures still used by the
active search.

Follow-on changes, with unmeasured gains:

- Replace repeated path-array copying (`router.js:686`) with parent-linked labels.
- Index completed bounds by departure boundary and boarding count, avoiding the
  full completed-label scan in `finishBound()` (`router.js:527`). Prune dominated
  completions while preserving search semantics.
- Include remaining required vias in optimistic pruning bounds.
- Store events/labels in compact numeric arrays once the simpler compaction is
  validated. Account for their memory explicitly because external buffers sit
  outside worker V8 heap limits.

### 3. Skip rerouting when live data has not changed route feasibility

`live-search.js:254` reroutes when snapshot identity changes. An on-time service
still creates a changed service in `live-network.js:122`.

A synthetic test using the real engine/router verified **two full route calls for
one on-time direct train**, in both `apply` and `ignore` modes.

**Recommendation:** in override/ignore mode, reuse scheduled routing and annotate
the journeys with live warnings. In apply mode, also reuse routing when effective
times, boarding/alighting permissions and operational sections are unchanged.
Keep exact “now” filtering, cancellation warnings and live coverage checks.
Continue rerouting for changes that can alter feasibility or ranking.

### 4. Reuse hourly profiles across the two-hour cache boundary

`route-boards.js:41` keys profiles by a fixed two-hour clock bucket;
`route-boards.js:385` cancels and removes old-bucket work. This means a profile
computed just before the boundary can become unusable almost immediately, despite
its nominal two-hour TTL. All requested routes can become cold together.

Successive eight-hour windows overlap by six hours. Cache immutable hourly
scheduled fragments by dataset, policy, route, ordered vias and relevant options.
Compose profiles from those fragments, refreshing live observations separately.
With suitable fragment retention and coverage checks, rollover could reuse six
of eight hours—**up to 75% fewer repeated scheduled calculations**. This is a
work-reuse estimate, not a measured end-to-end speed-up.

Ordinary realtime searches also bypass the scheduled result cache
(`engine.js:261`), and live snapshots are reused only through a supplied pagination
snapshot ID (`live-search.js:137`). Reusable scheduled candidates can improve
cross-client “Depart now” reuse, but simply rounding timestamps and returning a
cached result risks showing departed trains or omitting newly relevant journeys.

### 5. Live I/O holds the only routing slot while CPU is idle

`service.js:176` keeps one active operation through routing and network waits.
`live-provider.js:103` permits two simultaneous lookups, up to 64 requests, with a
three-second deadline each. Timeout waves can therefore approach **96 seconds**
before routing and other overhead. That is a structural worst-case estimate,
not a measured explanation of every slow row.

**Recommendation:** split routing and live lookup into scheduled stages, releasing
the exclusive routing slot while awaiting observations. Retain a bounded shared
request broker, deduplicate in-flight lookups and overlap useful origin-board
fetches with initial routing. Tune upstream concurrency from observed latency and
provider limits; do not just replace two with six everywhere. Legacy departure
calls must share the same aggregate protection.

### 6. Fix prewarm scheduling and add phase measurements

Prewarm is lazy because the routing worker starts on the first search. It also
checks `busy` before awaiting dataset I/O but does not reserve the worker or
recheck afterward (`worker.js:64`). A real request can start during that await.
This is a possible cache/allocation interleaving, not a reproduced OOM cause.
Run warming through the same low-priority scheduler, with explicit ownership and
a memory budget. Startup warming is useful only when capacity permits it.

Record queue wait, preparation, routing, live I/O, serialization, CPU time,
worker heap/RSS samples, labels, operations, candidate counts and reroute count.
Distinguish profile/result cache hits, live-observation cache hits and shared work.
Expose first-usable-result time separately from full-profile completion. Existing
main-thread heap metrics do not reveal the routing isolate's heap usage.

## CPU and memory recommendation for sky

1. **Keep one routing worker initially.** It already runs at full duty cycle and
   has no service CPU quota. Remove unnecessary work and release its slot during
   live I/O before adding another national index in RAM.
2. **Do not raise the heap blindly to 1,280 MiB.** That is a reasonable controlled
   experiment after compaction, but not an unconditional production recommendation
   given the 157 MiB historical headroom. Measure the latest build's mixed saved
   and interactive workload, including process/native memory and other services.
3. **Add a second worker only with a measured host budget.** It improves throughput
   and queue wait, not the speed of one serial route calculation. Reserve memory
   for Express, metadata, Mongo, other services, the OS and transient allocations.
   Use a shared compact timetable representation or more dedicated memory before
   attempting several independent national indexes.
4. **Avoid compensating with larger queues/timeouts.** This can lengthen waits and
   increase abandoned work. OOM currently also fails queued jobs (`service.js:204`),
   multiplying retries and cold starts. Consider bounded retry of unstarted work
   after recovery once memory safety is addressed.

## Suggested implementation sequence

1. Add phase/resource telemetry and reproduce the latest deployed build under a
   bounded representative workload; retain the current API contracts.
2. Compact runtime calls; skip unchanged/ignored-live rerouting; index completed
   departure bounds and validate routing equivalence.
3. Make saved profiles resumable, prioritize near-term results, reuse hourly cache
   fragments, and handle oversized chunks without losing completed coverage.
4. Separate live I/O from exclusive routing; add shared lookup coalescing and tune
   upstream concurrency.
5. Reassess heap size and worker count from measured peaks and p95/p99 queue times;
   then consider numeric/shared indexes and per-date event merging.

Validation should include both time modes, short and long routes, required vias,
overnight travel, live delays/cancellations, clock changes, cache rollover,
simultaneous saved-route batches, cancellation and worker recovery. Compare full
journeys and coverage metadata as well as latency. The present review did not
rerun the complete equivalence suite or modify the routing policy.
