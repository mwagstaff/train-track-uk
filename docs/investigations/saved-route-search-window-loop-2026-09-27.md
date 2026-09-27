# Saved-route search window loop — 27 September 2026

## Finding

The prolonged Elmers End → Birkbeck spinner was a window progression bug, not CPU or memory saturation.

The phone log repeatedly alternated a new queued board with a ready, empty board. The planner's search history on Mini confirmed 93 completed, uncached ELE–BIK searches between 02:26:35 and 02:35:26 UTC. Their elapsed times were 244–320 ms (median 269 ms); worker queue waits were at most 2 ms. Requested departure times advanced from 06:26:31 to 06:35:20 UTC, rather than advancing in six-hour steps.

`SavedRouteLive.refresh()` replaced every result's timetable window with `now…now+4h`, including explicitly dated future searches. The app accepted an overlapping window if its endpoint advanced at all. Each response therefore prompted another almost identical search, followed by a minimum five-second polling sleep. The 24-hour limit kept receding out of reach.

A second defect in `SavedRouteBoards.prune()` discarded actively polled future-day entries because their departure date differed from today's date. That could repeatedly cancel and restart a search once the app reached tomorrow.

## Changes

- Preserve the original timetable window and requested time for explicitly dated searches. Keep live evidence's four-hour horizon separate; live substitutions must also stay inside the requested departure window.
- Retain dated future boards while their caller lease is active, including across midnight. Expired leases still release resources.
- Reject mismatched future-window starts in the app instead of launching an unbounded chain of overlapping searches.
- Honor the API's polling interval (bounded to 1–20 seconds), removing the additional 5/10/15-second minimum backoff for this user-initiated search.
- Log requested and returned window boundaries for later searches.

Regression coverage includes the real live refresher composed with saved boards, empty windows followed by a departure across midnight, live substitutions outside a requested interval, future-entry retention/expiry, and the app's response to the old moving-window payload.

## Capacity and alternatives

Mini has eight CPUs and 16 GiB RAM. Its running process uses `PLANNER_WORKERS=auto`, selecting four workers; saved-route jobs can use three concurrently, reserving one for interactive searches. The configured defaults allow full CPU duty and 1 GiB heap per worker. The repeated ELE–BIK jobs peaked at approximately 334 MiB worker heap. Process RSS at inspection was approximately 1.22 GiB.

The dashboard's process heap metric does not represent all worker heaps: Node reports `heapUsed` for the calling thread, whereas RSS covers the process. See [Node memoryUsage documentation](https://nodejs.org/api/process.html#processmemoryusage). HTTP response latency here also measures the quick polling response, not completion of an asynchronous routing job. Search duration, worker queue time, CPU time and worker heap peaks are the useful job-level measurements.

An internal benchmark on the local development machine (Node 26.9.0, copied production timetable, departure 27 September at 03:30 BST, timetable-only RAPTOR) compared uncached searches with loaded timetable data:

| Strategy | Three elapsed times | Result |
| --- | --- | --- |
| Successive six-hour windows | 2,418 / 1,846 / 1,771 ms | 23:53 ELE → London Bridge → 06:33 BIK, one change |
| One experimental 24-hour window | 439 / 404 / 664 ms | Same journey |

The initial cold six-hour sequence took 2,863 ms. These are local engine timings, excluding phone polling/network overhead; Mini uses Node 24. The public API still caps windows at six hours. The experimental wider request bypassed that validation only in the benchmark and is not a shipped API change.

Recommended order:

1. Deploy the window/lease corrections and rebuild the app for the polling and overlap safeguards. Extra hardware cannot repair the loop.
2. Evaluate a bounded 24-hour empty-result fallback. This route benefits substantially, but dense routes, required vias, overnight journeys, operation budgets and earliest-departure ordering need validation before widening the public contract.
3. Alternatively, batch at most three future windows through the existing pool, using fixed boundaries and retaining chronological result ordering. This trades more total work for lower latency and must not claim a full-day empty result until every interval succeeds. No parallel-window change was made in this fix.
4. Keep the current memory and worker limits unless job-level measurements show queueing, heap pressure or CPU saturation. More workers duplicate indexes and can displace interactive searches.

No production configuration or deployment was changed during this investigation.
