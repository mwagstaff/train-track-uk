# Disruption monitor scheduling evidence

Verified locally on 19 September 2026 using Node v25.8.1 on macOS arm64.

## Mixed demand experiment

`api/train-track-api/test/planner-disruption-scheduling.test.js` runs the real
`PlannerService` with two actual worker threads and deterministic fixture work.
It warms both workers, then measures eight four-job bursts without maintenance
and eight equivalent bursts interrupting a two-second maintenance calculation.
Each burst contains three interactive jobs and one ordinary background job;
each job performs approximately ten milliseconds of worker work. Foreground
admission is deliberately limited to four jobs.

Observed in the recorded test run:

| Measurement | Result |
| --- | --- |
| Foreground/background jobs completed during maintenance interruptions | 32 of 32 |
| Maintenance slices interrupted | 8 of 8 |
| Maximum first foreground dispatch delay | 0.1 ms |
| Maximum four-job burst completion, without maintenance | 25.3 ms |
| Maximum four-job burst completion, interrupting maintenance | 25.4 ms |

These measurements validate scheduling and admission behavior on a small
fixture. They do not establish national-timetable throughput, production p95
latency, RSS headroom, or a guaranteed deadline for completing seven days of
monitoring. Small differences between repeated runs are expected.

Additional tests cover:

- One-worker operation: user demand preempts maintenance and is accepted even
  when the normal admission limit is one.
- Ordinary background work, such as saved-journey refreshes, also preempts
  maintenance.
- Maintenance is rejected immediately when workers are busy or resource
  headroom is unavailable. There is no planner-side maintenance backlog.
- With two workers, maintenance uses the final worker and preserves the first
  worker's foreground timetable cache, including when maintenance starts first.
- A maintenance worker that ignores cancellation is terminated after the
  100 ms cancellation grace period without discarding queued user requests.
- The maintenance deadline overrides an accidentally supplied longer user
  search budget. The deadline test completed rejection and a subsequent user
  request in approximately 215 ms with a deliberately configured 100 ms budget.

The resource gate is checked at admission. Cooperative execution uses a 25%
CPU duty cycle, a default 10-second deadline, and a default 10-million-operation
budget. This is application scheduling, not an operating-system QoS guarantee.

## Correctness and regression checks

The following command passed 87 tests, including existing planner API,
long-running search job, route-profile and live-worker scheduling regressions:

```sh
cd api/train-track-api
rtk proxy node --test \
  test/planner-disruption-profile.test.js \
  test/planner-disruption-scheduling.test.js \
  test/planner-worker-scheduling.test.js \
  test/planner-route-profile.test.js \
  test/planner-jobs.test.js \
  test/planner-api.test.js
```

Disruption-profile tests use the real timetable engine and router with small
synthetic timetables. They verify direct-service counting beyond public result
limits, ordered intermediate stations, route direction, bus versus ordinary
rail alternatives, duration calculations, overnight journeys, exact one-minute
windows, clock-change ambiguity, missing data, and explicit candidate limits.

## Local national timetable smoke

Two additional profiles ran through the actual routing worker against the
existing, read-only `RJTTF939-compact-v2` snapshot. Both used 18 September 2026,
08:00–09:00 UK time, the default 10-second maintenance deadline, 10-million
operation budget, and 25% CPU duty cycle. Live and Tube provider requests were
disabled. Only these two national-timetable calculations were performed.

| Route | Worker state | Elapsed | Direct trains | Minimum changes | Fastest scheduled duration |
| --- | --- | --- | --- | --- | --- |
| Kent House → London Victoria | Cold worker/date network | 8,571 ms | 4 | 0 | 21 minutes |
| Kent House → Bristol Temple Meads | Same worker/date network reused | 9,905 ms | 0 | 2 | 158 minutes |

Both calculations produced journeys and ordinary rail alternatives. The run
exposed an overly broad completeness guard: national `CONFLICTING_VARIANTS`
diagnostics and a global fixed-link ambiguity warning marked both ordinary
routes incomplete. Those exclusions are now disclosed as supported-coverage
limitations, rather than invalidating every route. A regression test verifies
that correction; malformed times, clock-hour ambiguity, truncated frontiers and
execution failures still produce incomplete profiles. The two national queries
were not repeated after this guard-only correction.

Both date networks reported these diagnostic categories:
`CONFLICTING_VARIANTS`, `HOLIDAY_CALENDAR_NOT_CONFIGURED`,
`INSUFFICIENT_PASSENGER_CALLS`, `SUPPLEMENTARY_DIALECT_NOT_ENABLED`, and
`UNSUPPORTED_MODE`. Unclassified fixed transfers are separately tested: they
are not described as all-rail and do not establish that a replacement bus is
required.

This fixture was published on **25 August 2026** and is stale for proactive
warnings. The smoke bypassed only admission headroom checks locally; it does
not establish feed freshness or enable user notifications. The manager's
publication-age and validated-ingestion checks remain necessary. The connecting
case nearly consumed the execution deadline, supporting adaptive subdivision
and measurement of real backlog progress before activation.

After that smoke, direct-service counting was changed to reuse the router's
existing cached departure index: it binary-searches the origin's exact time
window and examines only those departures. Calling-point expansion also reuses
the existing service index. This removes repeated national scans and map
allocation without changing the routing calculation or adding another cache.
Boundary, ordered-via and overnight regression tests cover the change; no
additional national-timetable timings are claimed for this optimization.

## Production observation

Before enabling user warnings, compare ordinary search latency and failure
rates with monitoring off and in observation mode under representative demand.
Record peak process RSS, available memory, maintenance deferrals, profile
timeouts, completed route-hour calculations, and the age of the pending backlog.
Include routes requiring connections and changes between timetable dates.

Calibrate `PLANNER_MAINTENANCE_MIN_FREE_MEMORY_MB` and
`PLANNER_MAINTENANCE_MAX_LOAD_PER_CPU` against those observations. Their defaults
are 512 MB free memory and 0.8 one-minute load per available CPU. A host can have
adequate free memory at admission yet incur additional allocation while
building a national timetable index; the fixture does not measure that peak.

Strict spare-capacity scheduling may leave checks pending during sustained
demand. Increasing the lookahead or promising checking deadlines requires
measured capacity or additional workers/hosts, rather than promoting old
maintenance jobs ahead of user requests.
