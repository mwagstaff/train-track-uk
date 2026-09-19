# RAPTOR proof of concept

This is an **experimental router**, initially developed offline and now available through an explicit debug-app request. The original router remains the default. Dataset imports, the active pointer and Grafana dashboards are unchanged.

## Test in the app

Deploy the updated API normally, then run an iOS **Debug** build. In **New journey → Debug routing**, switch **Use RAPTOR** on or off. It defaults off each time the search store is created. Release builds contain neither the selector nor the request-selection property; they continue to request the original router.

RAPTOR uses **Depart now / Depart at and timetable times only**, including supplied transfer allowances. Live rail updates and live Tube directions are not consulted. The live-time controls are hidden while selected, and Arrive by is explicitly rejected. Switching algorithms cancels the active UI task, invalidates old responses, and clears results/pagination. Debug recent searches distinguish algorithms; the results screen identifies the actual algorithm returned by the API.

The API advertises `capabilities.algorithms` and accepts optional `algorithm: "raptor"` on normal or queued search requests with `realtime: "off"`. Omitted or explicit `"original"` preserves the original normalized request identity and live behaviour. Unsupported RAPTOR combinations fail instead of falling back. Responses contain `search.algorithm`, and the app checks it: an older API that ignores selection cannot silently return original results as RAPTOR.

Each routing worker retains one RAPTOR index for its one dated immutable graph, builds it on first use or idle prewarm, drops it on date/version replacement or memory relief, and counts both compilation and required validation-index work against the existing execution budgets. The pool defaults to two workers sharing the SQLite snapshot (`PLANNER_WORKERS=1` restores one worker). Algorithms have separate result-cache namespaces and cursor policies. All earlier/later/more pages remain pinned to the original selection. Journey details and queued-search cancellation still use the existing retained-result and lease mechanisms.

The **Journey planner searches** admin page now has an **Algorithm** column showing **RAPTOR / Original**, including cache hits and shared queued work. New history records retain allowlisted selection/actual-router telemetry. Existing history rows without the new field display Original; no Mongo migration is required. Unknown stored values display Unknown rather than reflecting arbitrary text.

No new environment variables or timetable reimport are required. The server selection is an explicit experimental API opt-in, **not an authentication boundary**; only its iOS UI and request encoding are restricted to Debug builds. Deploying this code does not change ordinary client searches to RAPTOR.

### Repeat searches without a result-cache hit

After deploying the updated API, open **Admin → Journey Planner → Clear search cache** beside Refresh. Wait for the confirmation showing the number of cleared entries, then submit a **new search** in the app. No additional app update or environment variable is needed for this button.

This clears both algorithms' search-result caches across all started routing workers, without restarting them or dropping timetable/RAPTOR indexes, journey details, live/TfL snapshots or history. It tests warm routing rather than cold data/index loading. Work started before the clear cannot repopulate the result cache after completing. However, a new search can still share an identical running job, and other users/background searches can warm results again: wait for existing searches to finish before an independent comparison.

Completed polling leases and same-idempotency-key retries deliberately keep their old result. Press Search again rather than polling/retrying the existing job; the app creates a new idempotency key for a fresh search. Inspect the new admin row's Algorithm, Cache and Timing details.

The mutation is POST-only, requires a page-issued token and same-origin browser fetch metadata, and preserves reverse-proxy URL prefixes. These are cross-site-request protections, **not authentication**. The application has no admin authentication middleware; restrict the admin GET and POST paths using deployment access controls.

For timing interpretation, the original app mode may still perform live lookups, TfL verification and reroutes; RAPTOR currently does not. In-app elapsed-time differences are therefore **not a controlled same-input algorithm benchmark**. Use the offline comparisons below to isolate routing CPU, and admin Timing details to separate deployed queue/provider/routing costs.

### Debug-selector verification

The integrated API suite, including cache clearing, passes **600 tests**, with zero failures and the same two opt-in skips described below. A real routing-worker check against the national snapshot verified RAPTOR → original → RAPTOR requests, separate cache entries, correct algorithm metadata, pagination and retained journey details, without contacting live providers. Additional synthetic-worker tests verify miss → hit → clear → miss for both algorithms, index/detail preservation, pre-clear in-flight races and fresh queued requests after clearing. Nine admin URL/navigation tests also pass.

For the initial debug-selector integration, the iOS journey-planner suite passed **56 Debug tests and 50 Release tests**. Release verification explicitly covered ignoring a persisted Debug RAPTOR selection and omitting algorithm selection from encoded requests. The native selector also passed simulator UI checks in normal and dark/largest-text modes. The cache-clear button is API-only; desktop/mobile Chrome checks verified its same-origin POST, proxy/trailing-slash paths, unchanged filters/history, success feedback and error/retry controls.

The saved-route navigation/cancel UI check also passes. The separate unavailable-planner accessibility audit reports contrast failures in unchanged saved-route/recent-search captions; the full UI suite is not being reported as passing. Its existing environment-driven planner fixture is Debug-only, so running that particular fixture unchanged in Release stops before the audit. Release request-encoding checks and compilation verified the Debug-only selection boundary instead.

## What is being tested

The existing planner already uses boarding rounds, but expands individual train events and path labels. The POC instead selects routes from marked stops and scans each affected FIFO route chain once per round. It retains source-departure boundaries as well as arrival time and boarding count: this is a **range-search McRAPTOR-style prototype**, not basic fixed-departure RAPTOR. See [the original paper, sections 3–4](https://www.microsoft.com/en-us/research/wp-content/uploads/2012/01/raptor_alenex.pdf).

Route patterns include ordered call occurrences, pickup/setdown permissions, operator, mode and missing endpoint times. Overtaking services are partitioned into separate FIFO chains rather than silently discarded. The POC reuses existing interchange/TSI and timed fixed-link rules, including latest-timed initial links, endpoint allowances and the one-consecutive-fixed-link restriction. Supplied non-walking links consume a boarding. An optimistic reachability lower bound ignores timing constraints and prunes only suffixes that cannot fit the change limit.

Source timetable objects are not modified. Delays, cancellations, skipped stops and split services must be applied to a fresh effective network before compiling its index; the prototype does not update live route patterns incrementally. Positive-duration chronological services can safely share dominated histories: remaining aboard replaces a future repeat boarding. Zero-time/nonchronological services retain history-sensitive bags and alternative onward trips. Dropping those guards loses routes in the independent oracle fixtures.

## Run it

From `api/train-track-api`, use Node 24 and an existing validated dataset. The commands do not download, import, activate, contact upstream providers or write search history.

```sh
rtk proxy node --expose-gc --max-old-space-size=1536 scripts/planner-raptor-poc.js --dataset var/planner/snapshots/RJTTF939-compact-v2 --origin KTH --destination INV --time 2026-09-18T16:59:52+01:00 --repetitions 3
rtk proxy node --expose-gc --max-old-space-size=1536 scripts/planner-raptor-poc.js --dataset var/planner/snapshots/RJTTF939-compact-v2 --repetitions 3
rtk proxy node --expose-gc --max-old-space-size=1536 scripts/planner-raptor-poc.js --dataset var/planner/snapshots/RJTTF939-compact-v2 --origin KTH --destination INV --time 2026-09-18T16:59:52+01:00 --disruptions --repetitions 3
rtk proxy node --test test/planner-raptor-poc.test.js
rtk proxy env PLANNER_FULL_DATASET=/absolute/path/to/RJTTF939-compact-v2 npm run test:planner
```

The default corpus includes evening and overnight Kent House → Inverness, Victoria → Kent House, Glasgow Central → Plymouth and Bristol Temple Meads → Edinburgh. `--cases PATH` accepts a JSON array of forward requests instead; it cannot be combined with the single-request arguments. `--disruptions` additionally delays every timed call on the first vehicle of the baseline's best journey by five minutes and separately cancels its last vehicle. These are synthetic effective-timetable checks, not real provider-response tests.

Progress goes to stderr and JSON evidence to stdout. `--repetitions` controls 1–10 warm paired runs, default 3; `--timeout-ms` controls the per-query deadline, default 30,000. A mismatch sets exit status 1. Reaching a work/result safety cap fails rather than claiming a complete frontier or a misleading speedup.

## Comparison contract

Both routers receive the identical dated national timetable, modes, extra connection allowance and journey bounds. The default corpus uses a six-hour departure window, five-change limit and 24-hour journey-duration limit. Real live/TfL lookups and exact-result caching are excluded from both sides. Index/route compilation and dated-timetable preparation are reported separately from first and warm query times; warm execution order alternates. Synthetic overlays include fresh compilation costs.

The POC currently validates with the existing router's event index. `firstRaptorIncludingRequiredIndexesMs` includes that required index, compilation and query; use this field for startup-cost comparisons. `firstRaptorIncludingCompileMs` assumes the validation index is already ready and is **not** a standalone cold-start total. First means first query for that case in this process, not a fresh worker per row: consecutive cases with the same dated graph may reuse existing preparation/index caches. Dated-timetable preparation is common additional cost for either algorithm.

The benchmark requests the complete frontier, deduplicates departure/arrival/change triples and applies strict Pareto filtering. Every returned itinerary is also independently checked with the existing feasibility validator, including source window and duration. **Equal-criteria itineraries may differ:** the POC returns one feasible representative rather than every tied train/path. This is not equality of complete API output, saved-board departure profiles, ranking or cursor behaviour.

CPU measurements include process GC threads. Peak RSS is the **combined comparison process**, containing both indexes, not the memory requirement for a production RAPTOR worker. Timings on the local Mac do not establish deployed HTTP latency.

## Local evidence — 18 September 2026

Node **24.19.0** on the local Mac, compact `RJTTF939` baseline, three paired warm repetitions per case. Every query requests the whole criteria frontier, not only the public five-result page.

| Scheduled route | Existing warm median | POC warm median | Speedup |
| --- | ---: | ---: | ---: |
| Kent House → Inverness, evening | 510 ms | 484 ms | 1.05× |
| Kent House → Inverness, overnight | 661 ms | 580 ms | 1.14× |
| Victoria → Kent House | 214 ms | 91 ms | 2.35× |
| Glasgow Central → Plymouth | 802 ms | 439 ms | 1.83× |
| Bristol Temple Meads → Edinburgh | 878 ms | 653 ms | 1.34× |

All **20 paired full-frontier comparisons matched** (first plus three warm runs per case), with every itinerary independently valid. Evening Kent House → Inverness returns eight distinct trade-offs. Its first-query cost including required indexes was **1.903 s existing vs 0.964 s POC**, plus **0.636 s** shared dated-timetable preparation. Compiling the POC index took **160 ms**.

A separate Kent House → Inverness process checked scheduled, synthetic five-minute delay and final-train cancellation phases. All **12 paired full-frontier comparisons matched**. Warm medians were respectively **800 → 528 ms**, **482 → 477 ms**, and **756 → 472 ms**. The repeat scheduled result also shows GC/JIT variation between processes: **there is not a reliable large warm-query improvement for this particular route yet**. In particular, rebuilding an effective POC index costs another roughly **155 ms** per overlay; a one-percent warm delayed-query gain does not justify switching production.

The national dated graph contains **69,241 services / 835,972 calls**, reduced to **5,593 FIFO route chains**. Four service occurrences fail the strict-progress predicate and use conservative history handling. Compilation adds approximately **13.7 MiB retained V8 heap** to the dated source graph in a separate memory-only process. Its required legacy validation index adds another **113.8 MiB**. A standalone first POC query with that validator reached approximately **533 MiB RSS**; the five-case *combined comparison* process peaked at **1,208 MiB**. These are observed local allocations, not worker limits or host-capacity guarantees, and the compiler delta alone is not standalone POC memory.

The focused suite has **31 tests**, including **84 seeded exhaustive-oracle fixtures** checked in both global and per-departure profile modes, plus overtaking, permissions, repeated stations, TSI boundaries, timed/directional ALF links, DST, effective overlays, pagination, immutability and work/cancellation limits. Degenerate zero-time/nonmonotone continuation fixtures are checked directly against the independent oracle: the incumbent itself misses some of those adversarial routes.

The initial offline planner suite on Node 24.19.0 passed **578 tests**, with **zero failures and two opt-in skips**; see the integrated debug-selector verification above for the expanded suite. `PLANNER_FULL_DATASET` was enabled, so national snapshot and long-distance regressions ran. The skipped tests require external `MONGO_TEST_URI` and raw full/daily import fixtures (`PLANNER_INGESTION_FULL_SOURCE` / `PLANNER_INGESTION_UPDATE_SOURCE`), respectively.

Complete timing evidence, hashes, budgets and per-query metrics are retained locally in ignored artifacts:

- `api/train-track-api/var/planner/reports/raptor-poc-national-node24-2026-09-18.json`
- `api/train-track-api/var/planner/reports/raptor-poc-disruptions-node24-2026-09-18.json`

This supports continuing the experiment, **not deploying RAPTOR as the production planner**. The incumbent already has round/profile and temporal pruning. The prototype still expands substantial range bags (about 52,000 labels and 1.5 million trip searches on the evening Kent House case). Descending-departure rRAPTOR/profile reuse, better time-dependent pruning and packed hot-loop arrays are the next targeted experiments. Live provider/rerouting latency remains outside these measurements.

## Scope before default production use

Supported: scheduled `departAfter` searches without ordered via stations, and freshly compiled effective-timetable overlays. The core also has departure-profile fixtures, but the CLI's comparison contract is the regular full Pareto frontier.

Not supported: `arriveBy`, ordered via stations, dynamic TfL resolution, direct-route exclusion callbacks, incremental live-index maintenance or production saved-board/tie-enumeration compatibility. Unsupported requests are rejected explicitly. The API's experimental forward-search cursors now pin the RAPTOR policy, but the default engine and saved-board pipeline remain original.

A production decision needs full-contract differential tests, reverse/via support, live/TfL integration, bounded worker memory/cache lifecycle and measurements on `sky` including provider waits and reroutes. If range-label work remains large, the paper's descending-departure rRAPTOR variant is another experiment, not an assumed improvement. The paper's basic single-departure latency figures are not directly comparable to these UK range searches.
