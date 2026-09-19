# Journey planner parallelism investigation — 18 September 2026

Warm RAPTOR searches are CPU-bound in the current local implementation. They run on one routing thread and use an already-loaded national graph. Multicore execution helps, both across independent searches and, experimentally, within one search. Multiple SQLite copies on the same machine do not address the measured bottleneck.

The recommended next step is a bounded two-worker pool using the same read-only SQLite snapshot, followed by an optional departure-seed partition mode for expensive searches when spare capacity exists. Reduce allocation and range-search work in parallel with that development. Four independently loaded workers consume too much memory to recommend as the default on the current server.

This investigation inspected the current working tree, researched primary sources, ran local offline experiments, and inspected production capacity through read-only SSH. No application source, production configuration, datasets, or deployed services were changed. The experimental scripts and raw evidence are retained under `api/train-track-api/var/planner/parallelism-2026-09-18/` and are ignored by Git. This document is the only new non-ignored file.

**Where the time goes**

The scheduler deliberately owns one long-lived routing worker and one active CPU operation. A separate small worker handles metadata. Live waits can release the routing slot, but that enables I/O overlap rather than simultaneous routing. See [service.js](../api/train-track-api/lib/planner/service.js#L42), [worker.js](../api/train-track-api/lib/planner/worker.js#L78), and [search-jobs.js](../api/train-track-api/lib/planner/search-jobs.js#L23).

The repository opens a read-only `node:sqlite` connection. Date preparation loads and resolves services; the engine caches the resulting graph and RAPTOR index. Warm `findRaptorJourneys()` calls traverse JavaScript objects, Maps, Sets, labels and connection rules without querying SQLite. See [repository.js](../api/train-track-api/lib/planner/repository.js#L273), [engine.js](../api/train-track-api/lib/planner/engine.js#L202), and [raptor-poc.js](../api/train-track-api/lib/planner/raptor-poc.js#L236).

New measurements on the local Apple M5 Pro, Node 24.19.0, snapshot RJTTF939 compact v2:

| Warm search | Median elapsed | Median routing-thread CPU | Median per-run CPU / elapsed |
| --- | ---: | ---: | ---: |
| Kent House → Inverness | 455 ms | 453 ms | 99.6% |
| Victoria → Kent House | 95 ms | 95 ms | 99.7% |
| Glasgow Central → Plymouth | 435 ms | 433 ms | 99.6% |
| Bristol Temple Meads → Edinburgh | 599 ms | 587 ms | 99.7% |

These are full-frontier scheduled searches with warm indexes and no exact-result cache, queue, HTTP or provider waits. Each route has six measured samples in the one-worker run. Ratios are medians of individual ratios, so they need not equal the ratio of the displayed medians. `process.threadCpuUsage()` isolates the routing thread; process CPU additionally includes concurrent GC/runtime threads. High process CPU alone would not prove that the routing algorithm itself uses multiple cores.

A separate sampled profile of six warm Kent House searches attributed approximately 22% of self time to `board()`, 10% to `retain()`, and 25% to connection/allowance functions collectively. About 4% was sampled GC; 27% was attributed to the outer benchmark caller, including inlined work, and the remainder included bounds, runtime and profiler overhead. This supports targeting boarding, dominance and repeated connection calculations. It is not a precise allocation profile or proof that every listed function can be safely cached.

End-to-end searches can still include cold SQLite reads, date resolution, index compilation, queueing and live provider waits. The CPU-bound conclusion applies to measured warm scheduled routing, not every millisecond of deployed HTTP latency. The current RAPTOR mode excludes live lookups; the original router still supports them.

**Independent searches on multiple cores**

The experiment created persistent workers, each with its own connection to the same SQLite file and independently prepared graph. Each worker warmed all four routes twice. Three batches of eight searches were then dynamically dispatched, returning compact criteria hashes and metrics. Every result's criteria hash matched across all worker counts: 72 measured queries, with itinerary feasibility validation performed by the router.

| Workers | Median eight-search batch | Searches / second | Throughput gain | Whole-process RSS at batch boundaries |
| --- | ---: | ---: | ---: | ---: |
| 1 | 3,154 ms | 2.54 | 1.00× | 851–858 MiB |
| 2 | 1,999 ms | 4.00 | 1.58× | 1,267–1,580 MiB |
| 4 | 1,234 ms | 6.48 | 2.56× | 3,428–3,440 MiB |

This improves throughput and queue waiting. It does not make an individual unchanged routing call faster: concurrent calls generally took longer than the isolated one-worker calls. More cores also increased total CPU consumption in some batches. The two-worker batches varied from 1.86 to 3.04 seconds, so the median is preliminary evidence rather than a service-level guarantee.

Counts ran sequentially in one parent process, terminating the previous workers between counts. RSS includes the parent, runtime and potentially retained allocator state from earlier counts; it is neither per-worker memory nor a fresh-process capacity estimate. Samples can miss transient peaks. Startup, graph loading and warmup were excluded from the throughput table. This was an 18-core Mac with 24 GiB RAM, not the four-vCPU production machine. There is no production load-test or p95/p99 claim.

Node workers execute JavaScript in parallel, support shared buffers, and are intended for CPU-intensive work. Persistent pools avoid per-request startup overhead. JavaScript object graphs are not automatically shared between isolates. [Node worker documentation](https://nodejs.org/docs/latest-v24.x/api/worker_threads.html)

**Making one search faster**

The current router is a departure-range, multicriteria RAPTOR variant. It retains competing source departures, arrivals and boarding counts. The paper's range-search parallelism is consequently especially relevant.

An isolated temporary copy of the router partitioned initial departure seeds into two or four equal boundary intervals while preserving the original query and full dated graph. Workers returned complete internal departure/arrival/boarding frontiers; the parent globally merged them. Direct origin-to-destination fixed-link candidates were generated once. Both serial partitioning and concurrent partitioning were measured, so reduced bag size could be distinguished from actual multicore gains.

| Route | Unpartitioned | Two parts, serial | Two parts, parallel | Four parts, parallel |
| --- | ---: | ---: | ---: | ---: |
| Kent House → Inverness | 568 ms | 650 ms | 417 ms / 1.36× | 288 ms / 1.97× |
| Victoria → Kent House | 124 ms | 187 ms | 107 ms / 1.17× | 95 ms / 1.31× |
| Glasgow Central → Plymouth | 540 ms | 733 ms | 397 ms / 1.36× | 344 ms / 1.57× |
| Bristol Temple Meads → Edinburgh | 775 ms | 1,050 ms | 516 ms / 1.50× | 379 ms / 2.04× |

All 60 logical experiment runs—four routes, five modes including four-part serial, three repetitions; 156 underlying router calls excluding warmup—produced matching merged internal criteria frontiers. All 12 unpartitioned baselines also matched the unchanged router's public criteria hashes from the earlier experiment. Each shard's returned itineraries passed the router's existing validator.

Partitioning did more work. Two parts increased operation counts by 19–82%; four parts increased them by 57–218%. Serial partitioning was slower for every route. Four-part concurrent routing used roughly 1.6–2.7 times the baseline routing-thread CPU, summed over workers. It wins wall time by spending spare cores, not by reducing total computation. This is suitable for an expensive foreground search when idle capacity exists; under load, those cores can instead serve other users.

The second table has its own within-experiment baseline: four prewarmed workers remained resident throughout, mode order alternated, and the temporary router returned extra diagnostics. Do not combine its absolute timings with the earlier table. Timings include dispatch and criteria merging but exclude cold preparation and final API assembly. Only four scheduled national cases were tested. This is promising feasibility evidence, not a production implementation or full equivalence proof.

A production version must preserve several details:

- Partition the original initial departure seeds, including initial fixed-link plus train combinations, by the actual journey departure boundary. Moving `request.time` for several ordinary HTTP calls changes direct fixed-link enumeration.
- Keep the complete onward timetable and original duration horizon for every part, including overnight travel. Dividing services geographically or trimming them to the departure interval loses valid continuations.
- Merge complete internal frontiers before global ranking, deduplication and pagination. Five or ten public results per part are insufficient. Preserve internal boardings: public zero changes conflates walking with a one-boarding train journey.
- Use deterministic tie handling and the original dominance mode. Saved departure profiles preserve separate boundaries and need their own equivalence checks.
- Apply one query-wide deadline, cancellation and work/memory budget. The diagnostic prototype gave each shard the existing budget; it does not yet provide aggregate enforcement or API pagination.
- Use a global worker budget. Do not create four workers per request or let simultaneous partitioned searches oversubscribe the host. Start with two parts only above a measured cost threshold; consider seed-count/work balancing rather than equal clock intervals.

**What the RAPTOR paper supports**

The original paper describes parallel route scans within each round and partitioning source departures for range searches. Its C++/OpenMP London results were 7.7→4.1 ms for basic RAPTOR, 92.3→26.8 ms for rRAPTOR, and 280.2→66.1 ms for range McRAPTOR on six cores: approximately 1.9×, 3.4× and 4.2×. Scaling tapered at twelve cores. These are different hardware, data and implementations, not forecasts for this application. [Original paper, §§3.3–4.2 and Table 3](https://www.microsoft.com/en-us/research/wp-content/uploads/2012/01/raptor_alenex.pdf)

Descending-departure rRAPTOR reuses earlier computations across successive departures and avoids carrying the same kind of large range bags. It deserves a separate algorithmic experiment, especially for ordinary global-frontier searches. Per-departure saved-profile semantics require care. [Author's later journal manuscript, §4.2](https://renatowerneck.files.wordpress.com/2016/06/dpw14-raptor.pdf)

OpenTripPlanner also exposes a search thread pool for dividing an individual RAPTOR search into parallel jobs, separately from handling independent requests. This is useful architectural precedent, not evidence that its configuration can be transplanted into this service. [Official configuration documentation](https://docs.opentripplanner.org/en/dev-2.x/RouterConfiguration/#searchthreadpoolsize)

Parallel route scans inside a round are a larger refactor here. `retain()` mutates global bags, destination bounds and label activity while other route scans consume marked labels. A correct implementation needs immutable round inputs, worker-local output buffers, and deterministic merging at a barrier; walking/fixed-link relaxation must remain in the correct stage. The next round depends on the previous one. `Promise.all`, `async` functions or a larger libuv thread pool do not parallelize these synchronous JavaScript loops.

**Database and deployment alternatives**

| Option | Likely benefit and recommendation |
| --- | --- |
| Multiple workers, same SQLite file | First choice for local throughput. Each worker owns a read-only connection and query state. No DB cloning required. |
| Multiple SQLite copies on one machine | Replication, not sharding. No benefit to the measured warm routing loop; additional disk space and potentially duplicated OS cache pages. |
| SQLite WAL/shared cache/cache tuning | Does not address this read-only in-memory bottleneck. Shared-cache mode is discouraged by SQLite. Investigate cache/mmap tuning only if cold loading becomes significant. |
| Affinity by dataset/date range | Avoids rebuilding a worker's one hot national graph when unrelated date ranges alternate. Keep overnight lookback and full onward horizons. It is work placement, not an incomplete date shard. |
| Parallel date loading/index preparation | Possible cold-start improvement, with transient memory and result-copy costs. Benchmark staged prewarming and precomputed compact dated indexes first. |
| Planner processes or separate hosts | Useful for capacity, fault isolation and larger memory budgets. Across hosts, local immutable SQLite replicas make sense. Preserve version consistency and job/cursor state ownership. |
| Geographic/operator shards | A plain split of SQL records is insufficient: cross-boundary and cross-operator journeys need coordinated routing and complete transfer information. Not a near-term optimization. |
| Packed shared timetable | Numeric IDs and typed arrays can reduce object overhead and allow one immutable graph in shared memory, with per-query labels kept private. A valuable foundation for larger pools and parallel route scans. |
| Native Rust/C++ routing kernel | Could improve locality, allocation and parallel scan efficiency. Requires substantial correctness/FFI/operational work; first measure packed JavaScript and range-search improvements. No measured speedup here. |
| GPU execution | Low priority for branch-heavy small Pareto bags and irregular transfer logic; host/device movement and synchronization add costs. Potentially interesting for large batched workloads after a data-layout rewrite, but unmeasured. |

SQLite permits multiple simultaneous readers; its single-writer limitation does not serialize independent read-only workers. Imports already build separate snapshots. WAL is therefore not a prerequisite for this pool. [SQLite locking](https://www.sqlite.org/lockingv3.html), [isolation](https://www.sqlite.org/isolation.html). Memory mapping can change cold-read copying and cache behavior, while shared-cache mode is explicitly discouraged. [SQLite mmap](https://www.sqlite.org/mmap.html), [shared-cache guidance](https://www.sqlite.org/sharedcache.html)

For genuine network partitioning, HypRAPTOR is the relevant research direction: partition routes and precompute sufficient connections between cells. Published country-network gains were approximately 1.7× and 2.1×, with material preprocessing cost. Adapting that to this timetable's operator-sensitive/timed transfers and live changes would be a separate routing project. [HypRAPTOR paper](https://drops.dagstuhl.de/storage/01oasics/oasics-vol059_atmos2017/OASIcs.ATMOS.2017.8/OASIcs.ATMOS.2017.8.pdf)

**Reduce work alongside parallelism**

Existing RAPTOR already marks affected routes, applies local/target dominance and uses optimistic remaining-boarding and route-tail bounds. There is no generic missing pruning switch.

The strongest local candidates are:

- Reduce history Set copying and rejected-candidate allocation around `board()` and `retain()`; compact inactive bag entries. Preserve the unusual-service history guards.
- Reduce repeated connection-rule evaluation for equivalent station/operator/allowance conditions without dropping timed-rule semantics. Connection handling was a material sampled cost.
- Experiment with descending-departure range reuse and admissible time-to-target bounds. Profile/ranking contracts must remain explicit.
- Bound and cache destination topology bounds for an identical network, modes and boarding cap. The measured bounds cost was small relative to the whole search, so this alone will not produce a large gain.
- Evaluate removing redundant final historical-frontier comparisons: `complete()` maintains a current nondominated list, yet finalization revisits historical results quadratically. Preserve representative/tie behavior. This was a code-review opportunity, not a measured dominant hotspot.
- Reduce cold/index memory by replacing the legacy validator's full event index with a purpose-built independent validation index. Keep independent feasibility validation. Current RAPTOR compilation alone understates total worker memory.

**Production capacity and rollout implications**

A read-only snapshot of `sky` at 22:55–22:56 UTC on 18 September found four available vCPUs, 7.56 GiB RAM, 1.88 GiB available RAM, and approximately 1.01 GiB swap occupied. The API was running Node 24.21.0, with 374.5 MiB current RSS and an 872.8 MiB process high-water mark. No CPU quotas or memory limits were found at the inspected service/ancestor cgroups. A five-second sample was approximately 80% idle. These observations show spare CPU at that moment, not sustainable capacity under routing load; swap occupancy alone does not establish active thrashing.

Start by validating two workers against mixed interactive/saved-board/date-changing workloads and process RSS. Do not infer a safe four-worker pool from the CPU count. Heap limits are per isolate and exclude some native/external memory; shared typed-array storage also requires explicit accounting. [Node worker resource limits](https://nodejs.org/docs/latest-v24.x/api/worker_threads.html#new-workerfilename-options)

The scheduler work needs more than replacing `this.worker` with an array. Update both service and search-job admission limits; keep deduplication, cancellation and upstream throttling centralized. Preserve worker affinity for existing live/TfL cursor snapshots, fan cache clears out to every worker, and prewarm RAPTOR as well as the original index. With multiple API processes, job/lease/idempotency state needs affinity or shared ownership, and ingestion scheduling must remain coordinated.

Recommended sequence: implement and verify a two-worker pool; improve the profiled allocation/range work; then add optional two-part seed execution using otherwise idle slots. Measure both throughput and single-query p50/p95/p99, including queue time, cold preparation, total CPU, peak RSS, cancellation and first usable result. Validate full routing contracts, fixed-link-only routes, initial links, midnight/DST, overtaking, zero-time services, profile mode and pagination before enabling partitions. Expand worker count only after memory and load measurements justify it.

The retained `benchmark.mjs`, `results.json`, `warm-kth.cpu.json`, `seed-benchmark.mjs`, `seed-router.mjs` and `seed-results.json` contain reproduction code and evidence. The unchanged-router report records source hashes, options, request times and dataset path. Both scripts use only the local immutable snapshot, exclude providers, and can be rerun with Node 24 from the repository root:

```sh
rtk proxy node api/train-track-api/var/planner/parallelism-2026-09-18/benchmark.mjs
rtk proxy node api/train-track-api/var/planner/parallelism-2026-09-18/seed-benchmark.mjs
```

These scripts are deliberately diagnostic artifacts, not supported production commands. No application test suite was rerun because application code was unchanged; the experiments checked the stated criteria/feasibility properties, not the entire API contract.
