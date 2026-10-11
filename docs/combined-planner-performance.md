# Combined planner performance harness

Run from `api/train-track-api`. Node 24 and an installed dependency tree are
required. The local mode starts ephemeral loopback HTTP services, uses the real
planner workers and timetable, and calls the real TfL HTTP API. It does not
write production data or clear production caches. Search jobs are released on
completion/failure; local services are closed on exit.

```sh
npm run bench:combined -- \
  --dataset var/planner/snapshots/RJTTF939 \
  --tube-api-root /Users/mwagstaff/dev/tube-track-uk/api/tube-track-api \
  --time 2026-10-10T09:00:00Z --runs 2 \
  --require-directions --require-hop VIC:HHY \
  --output /tmp/combined-performance.json
```

Choose a future time and an in-date dataset when rerunning. The default endpoints
are Clock House (`nr:CLK`) and Acton Central (`910GACTNCTL`). Options `--from`,
`--to`, `--time-type arriveBy`, `--max-ms 60000`, and `--runs` select other cases.
`--require-hop VIC:HHY` fails unless that exact transfer appears with directions;
`--require-directions` fails if any returned transfer is unresolved. Without it,
fallbacks are reported but are allowed. The raw planner returns ten candidates;
this is stricter than the app adapter's selection of up to three distinct routes.

For a deployed baseline or post-deployment smoke test:

```sh
npm run bench:combined -- \
  --base-url https://api.skynolimit.dev/train-track/api/v5/journey-planner \
  --time 2026-10-10T09:00:00Z --runs 2 \
  --output /tmp/combined-deployed.json
```

Remote caches cannot be reset safely by this tool, so the first remote run is
labelled unknown. Upstream request counts are unavailable in remote mode. Local
counts include station/status requests as well as journey searches. Warm runs
reuse process caches but still perform new searches; there is no assumption that
every route has stayed within its short live-data expiry.

Use `--fault unavailable --runs 1` in local mode to return HTTP 503 from the
transfer service. The harness requires explicit warnings on fallback transfers.
Every normal run requires nonempty results, chronological legs and no explicitly
cancelled returned rail leg. JSON reports retain all legs, transfer steps,
warnings, search bounds and upstream timings. This catches missing-hop tests
that could otherwise pass without ever exercising the reported problem.

## Checks on 9 October 2026

Using the RJTTF939 local timetable and a search for 10 October:

| Search | First run | Repeat | Transfer outcome |
| --- | ---: | ---: | --- |
| Deployed Clock House → Acton Central baseline | 15.18 s | 14.95 s | Two unresolved transfers each run |
| Updated local depart-after 09:00 UTC | 9.12 s | 7.02 s | Victoria → Highbury verified; none unresolved |
| Updated local same-day departure | 9.11 s | 6.02 s | Victoria → Highbury verified; none unresolved |
| Updated local arrive-by 12:00 UTC | 9.26 s | 6.02 s | None unresolved |
| Transfer service unavailable | 2.10 s | — | Explicit timetable fallback warnings |

Live upstream variability and different host/cache/dataset state prevent a
controlled percentage-speedup claim. Future-date runs do not validate actual
same-day rail delays; deterministic live-routing tests cover delays/cancellations.
A direct Victoria → Highbury search verifies that hop, but can still include
lower-ranked rail detours with unchecked transfers. The bounded search is not a
guarantee that all ten alternatives receive TfL directions during an outage or
slow response.

## Release

Deploy TubeTrack API first (`/api/v2/journey-transfers`), then the TrainTrack
standalone planner on Mini. The existing gateway and iOS build need no update
for these performance changes. V1 and v3/v4 behaviour is retained. For rollback,
roll back the planner before removing the new TubeTrack endpoint.

Validation: TrainTrack planner suite 745 passed, 5 skipped; TubeTrack full API
suite 298 passed. Tests include bounded parallel verification with a single worker
I/O yield, elapsed rather than summed lookup time, conservative minute cache keys,
expiry/cancellation, closure exclusion, missed connections, unknown disruption
coverage and unchanged legacy endpoint behaviour.

## Required app-facing ranking check

The raw v5 benchmark alone does not validate the final TubeTrack route ordering.
After each benchmark, run this from the TubeTrack API directory:

```sh
node scripts/check-combined-ranking.js /tmp/combined-performance.json
```

It replays each captured result through the app-facing v2 HTTP adapter and checks
the first choice against all eligible raw journeys. This caught the duplicate
route ordering defect that promoted a 13:29–15:18 journey above 12:10–13:44.
Both departure and arrive-by reports pass after the TubeTrack ranking correction.

## Closed destination and incomplete-refresh checks

The 9 October Clock House → Arsenal investigation found TfL explicitly reporting
Arsenal closed because of infrastructure damage. Returned TfL routes reached it
overnight, outside the six-hour combined search limit. TfL stop messages were
previously discarded by transfer routing, hiding that explanation.

Transfer routing now preserves fresh TfL stop messages, bounds individual
lookups to six hours, and allows dynamic endpoint connections to use reserved
capacity (they have no timetable fallback to verify later). A lookup-limited
empty search returns `SEARCH_INCOMPLETE`; the app retains its prior stale result
with the error instead of replacing it with misleading empty suggestions.
TubeTrack also guards empty truncated results from older planner deployments
and presents TfL notices ahead of generic dataset limitations.

For live failure-path checks, the benchmark accepts `--expect-error` and
`--expect-message`. While this particular closure is active:

```sh
npm run bench:combined -- \
  --dataset var/planner/snapshots/RJTTF939 \
  --tube-api-root /Users/mwagstaff/dev/tube-track-uk/api/tube-track-api \
  --to 940GZZLUASL --runs 2 \
  --expect-error SEARCH_INCOMPLETE --expect-message 'Arsenal: Closed'
```

This live assertion is intentionally time-dependent; once the station reopens,
use normal nonempty-result assertions. Deterministic regression tests cover
out-of-window routes retaining closure notices, essential endpoint lookups using
reserved capacity, avoiding next-day lookups and incomplete empty searches.
Clock House → Finsbury Park returned ten raw candidates with no unresolved
transfers in 8.40 seconds cold and 6.02 seconds warm; both replays passed the
app-facing ranking assertion. Planner tests: 748 passed / 5 skipped. TubeTrack
API tests: 305 passed. Deploy TubeTrack API and the planner for these corrections;
no iOS change is needed.
