# Journey planner implementation

## Scope and compatibility

Authorised 15 September 2026. Implement scheduled direct/connecting searches in both time modes, replacing Add Journey behind an app feature flag while preserving its existing manual flow. Keep recent searches locally. Public planner routes use `/api/v3/journey-planner`; existing v1/v2 payloads, routing and config stay unchanged. The later deployment repair was also authorised: configure a private runtime, persistent timetable storage and the standard deployer, then activate and verify the API on `sky`.

## Architecture decisions

- Existing JavaScript ES modules and Express; no additional routing service exposed publicly.
- Streaming directory/ZIP import into immutable SQLite snapshots, using Node's SQLite module in the isolated planner runtime.
- Lazy routing worker with bounded queue, cancellation and a pinned dataset for each request. No timetable parsing or routing on Express's event loop.
- Active/previous snapshot pointers live outside deployed source. Queries and cursors carry dataset and routing-policy versions.
- Dedicated SwiftUI models/client, optional Depart now/Depart at/Arrive by selection, recent searches, and a secondary Add a saved route action.
- Monthly full input expected, S3 delivery details/incremental cadence pending. The local prototype needs no cloud credentials.

## Completed prototype

| Milestone | State | Evidence |
|---|---|---|
| Repository/data reconnaissance | Reviewed | Nine extracted files; all supplied counts reproduced in planning. No original ZIP available. |
| Source inspector/importer | Complete | Directory/ZIP validation, full streaming import, SQLite snapshot and source hashes; synthetic ZIP integrity tests. |
| Calendar resolver and activation | Complete | Permanent/new/overlay/cancellation resolution, passenger times, overnight/DST exclusions, validation/operator gates and atomic publication/rollback. |
| Direct and connecting router | Complete | Genuine forward/reverse routing, up to five changes, ALF station-pair and ordered operator-specific transfers, independent itinerary validation and 400 exhaustive-reference comparisons. |
| Versioned API | Complete | New public v3 status/stations/search/details, exact versioned cursors, bounded queue/work, cancellation, freshness and scoped metrics. Existing v1/v2 contracts preserved. |
| App | Complete | Separate SwiftUI planner/client/models, optional London date/time, results/details/pagination, local recent searches, and existing secondary saved-route flow. |
| Local operations | Complete | Full import, two-version activation/rollback/failure drill, benchmark cases, private source explanation and operations runbook. |
| Production API deployment | Complete | Private Node 24.21.0, durable activated RJTTF939 snapshot, standard quick deployment, public status/stations/both search modes/details and legacy checks passed. |
| Automated feed acquisition | Awaiting external inputs | S3 delivery arrangement, freshness policy, unattended monthly imports, incremental cadence and production feed terms. |

## Dataset and reproducibility

The final dataset is in the ignored local directory `api/train-track-api/var/planner/snapshots/RJTTF939`, with a local pointer in `api/train-track-api/var/planner/active.json`. Production has its own validated copy and absolute Linux pointer under `/home/mwagstaff/.local/share/train-track-api/planner`.

- Version: `3d9d573635ed619ac3808338176858077f4d35650846ba0a0e829ed53ad64f5c`.
- Source content hash: `75dacf80a357fe5878cead08e8b043671006ea96de29f315c6dad9d5ca440784`.
- Source date: 2026-08-25. Coverage envelope: 2026-05-17 through 2027-05-15; this does not imply completeness on every route/date.
- 461,177 imported schedule records; 379,141 supported schedule variants; 2,650 selectable stations; 4,079,619 mapped passenger calls.
- SQLite size: 1,072,545,792 bytes. Full import plus representative-date validation: 15.3–16.9 seconds in local runs.
- Kent House 07:12 → Victoria 07:33 on 8 September resolved from P86964. Its 31 August cancellation does not cancel the September instance.
- Representative resolved service counts: May 17 13,420; August 25 23,150; August 29 22,293; August 30 15,010; May 15 2027 21,920.
- Two complete snapshots were activated in sequence; repeated import/activation were idempotent, a corrupt candidate left the active version untouched, and rollback restored the first version. Source generation date did not change when input was copied/reimported.

Private generated evidence is retained under `api/train-track-api/var/planner/reports/`. See [the operations runbook](journey-planner-operations.md) for commands and contracts.

## Verification

Initial prototype verification on Node 25.8.1 (the later Inverness regression results are recorded below):

```sh
PLANNER_FULL_DATASET="$PWD/var/planner/snapshots/RJTTF939" node --test --test-timeout=30000 test/planner-*.test.js
PLANNER_FULL_DATASET="$PWD/var/planner/snapshots/RJTTF939" node --test --test-timeout=30000 --test-skip-pattern='a notification save already in flight|station exit retires every live session' test/*.test.js
```

- **49/49 planner tests passed**, including the supplied-data fixture.
- **163/163 selected backend tests passed**. The two excluded existing tests are detailed below; they were reproduced on an isolated copy of the original HEAD.
- The same **163 selected backend tests also passed on Node 24.21.0**, including the supplied full-dataset fixtures, before switching the production service runtime. Log: `/tmp/traintrack-node24-regression.log`.
- Real HTTP searches passed for KTH–VIC, KTH–BTN, BTN–CBG and BHM–EDB, with direct/connecting and both time modes represented. Detail retrieval, more/earlier/later cursors, stable version pinning and typed invalid-station/date errors passed.
- Private CLI explanation identifies the selected permanent P86964 variant, its date, source line and actual calling points.
- Oversized/malformed/non-JSON v3 requests fail within the v3 error contract. Existing 1 MB JSON/form parsing remains unchanged. A blocked worker times out, terminates, then recovers on a later request.
- Existing `AddJourneyView`, old network client/host selection, persistent saved-route models and existing API route bodies were not changed. The only existing iOS view edit selects the feature-flagged entry wrapper.
- iOS builds, **11 unit tests and four UI scenarios passed across runs** on iPhone 17 Pro Max and iPad Pro 13-inch M5 (iOS 26.5). Coverage includes real local API search/details/calling points/pagination/recent reuse, the disabled flag, favourite prefill and saved-route navigation, and largest Dynamic Type. Dark iPhone and light iPad screens were visually reviewed. Contrast, text-clipping and hit-region audits passed; native disabled controls are excluded from contrast checks.

The initial iPad audit and favourite-preservation run is `/tmp/traintrack-journey-planner-derived/Logs/Test/Test-TrainTrack UK-2026.09.15_13-48-10-+0100.xcresult`. It resolves the sole contrast failure from the preceding complete selected iPad run at `13-40-01` (14 passed, one then-failed audit). The iPhone unit/unavailable-flow audit run is at `13-33-53` in the same directory. Reproduce from the repository root, with the local planner server on port 3013 and the empty-window fixture on port 3014. Start the fixture in a separate terminal:

```sh
rtk proxy python3 'ios/TrainTrack UK/TrainTrack UKUITests/journey_planner_ui_fixture.py'
```

Then run the selected suite:

```sh
rtk proxy xcodebuild test \
  -project 'ios/TrainTrack UK/TrainTrack UK.xcodeproj' \
  -scheme 'TrainTrack UK' \
  -destination 'platform=iOS Simulator,id=60184FC8-43D7-496F-9712-60C69E6AAD35' \
  -parallel-testing-enabled NO \
  '-only-testing:TrainTrack UKUITests/JourneyPlannerUITests' \
  '-only-testing:TrainTrack UKTests/JourneyPlannerTests' \
  -derivedDataPath /tmp/traintrack-journey-planner-derived \
  CODE_SIGNING_ALLOWED=NO
```

The iPhone simulator identifier is `D6C8476C-FB6A-444D-991A-D33E6DC3C3F1`. Select an available equivalent device when reproducing on another machine. Existing unrelated actor-isolation and extension-version build warnings remain unchanged.

## Local resource measurements

Hardware: Apple M5 Pro, 18 logical CPUs, macOS arm64, Node 25.8.1, one routing worker with a 1024 MB V8 heap limit. These are development-machine measurements, not deployment-host p95 results.

The initial ten-case benchmark includes weekday/weekend, direct/connecting, both time modes and overnight searches. All returned five journeys without truncation. Initial cold query: 2.32 seconds; warm queries on prepared dates: approximately 6–423 ms; a fresh four-date overnight preparation/search: 2.77 seconds. Peak process RSS: 993,840 KiB (about 971 MiB). The broader twelve-case benchmark after the Inverness correction is recorded below.

An additional 20 **uncached** mixed-date requests passed with no failures/truncation. Heap use ranged from 330 to 785 MB, peak process RSS was 1,030,416 KiB (about 1006 MiB), and caches stayed at no more than four dates and one hot national index. Testing identified and fixed transient retention of old national indexes before this run; old indexes and unrelated dates are now released before another date range is prepared. The V8 heap limit does not bound SQLite native memory or total process RSS.

A separate complete CLI import with `NODE_OPTIONS=--max-old-space-size=512`, measured using `/usr/bin/time -l`, passed in 18.21 seconds with 421.09 MiB peak process RSS, including five-date validation. It reproduced the final dataset version. The temporary measurement candidate and earlier experimental copies were removed; the original source and final local snapshot were retained.

## Production deployment verification — 15 September 2026

The reported station-search failure came from an unactivated timetable. The standard deployer had also selected system Node 20.20.2, which cannot run the planner's SQLite worker. The copied development pointer referred to a Mac path.

- Installed the official Node 24.21.0 Linux x64 distribution in TrainTrack's own runtime directory after checking its SHA-256. System Node remains 20.20.2.
- Validated the copied snapshot on `sky`, moved it into external storage under its 64-character version, and activated it. A measured validation took 21.80 seconds and 358.5 MiB RSS with a 512 MiB V8 heap setting. Activation revalidated and completed in 13.16 seconds.
- Added optional `node_binary` and `rsync_excludes` settings to the shared deployer. TrainTrack alone sets the runtime pin, external `PLANNER_DATA_DIR` and two timetable exclusions. Five mocked quick/full deployment regression groups, syntax checks and independent review passed.
- Ran the standard quick deploy. The service executable is now `/home/mwagstaff/.local/share/train-track-api/runtime/node-v24.21.0-linux-x64/bin/node`, with the correct `PLANNER_DATA_DIR`. Only TrainTrack's PID changed; all 14 other user services kept their PIDs.
- Public v3 readiness reports `available: true`; station search for `kent h` returns Kent House (`KTH`). Searches for 16 September returned five journeys each: KTH–VIC depart-after 07:00 London in 5.493 seconds, KTH–BTN arrive-by 10:00 in 4.118 seconds. Both detail requests matched the selected itinerary and included calling points; the Brighton journeys include a change. Neither search was truncated.
- Existing v2 station/config responses and general health response matched their pre-deployment bytes. Live v1/v2 KTH–VIC requests returned 16 departures with their existing response shapes.
- The standalone two-case host benchmark peaked at 952,300 KiB RSS (about 930 MiB). After public searches, the full API process used 901,932 KiB RSS (about 881 MiB), had no swapped memory, and the host had about 1.56 GiB available. These are a small acceptance sample, not a load-test or percentile claim.

Production evidence and rollback wrapper/configuration are in `/home/mwagstaff/.local/share/train-track-api/deployment-checks/20260915T135318Z`. See the operations runbook for future code deployments and separate monthly timetable activation. No new app binary was required for this repair; the app already deployed by the user can retry the station search.

## Inverness correction — 15 September 2026

The supplied sleeper and all three long-distance daytime legs were already supported. The missing reverse directions for ALF station-pair links blocked Victoria–Euston and St Pancras–King's Cross. The app additionally fixed the maximum at two changes, while the API's two-hour default window hid preferable later feeders.

- Source-backed ALF rows are indexed in both directions with the same source identity, calendar, priority and duration; arbitrary directed links and ordered TSI rules retain their original meaning. The snapshot is unchanged.
- Default searches allow five changes over six hours. Explicit lower limits are preserved. The CLI shares the change default; the app omits its hard-coded two-change limit and presents actionable empty-window paging.
- Routing gains optimistic timetable reachability and operator-aware dominance across boarding counts. Tests compare 400 cases against exhaustive routing, including five-change paths. The production work bound is 10 million checked operations; the existing 30-second/1024 MB worker limits remain.
- **176 selected backend tests passed**, including the optional supplied-data overnight regressions. The same two unrelated baseline tests remain excluded. Log: `/tmp/traintrack-inverness-backend-tests.log`.
- **14 app unit tests passed**, including omission of the old two-change cap, explicit overrides, compatibility with older responses and consecutive empty-window paging. All five original/expanded iPad UI scenarios passed. After the final empty-state layout change, focused largest-text paging passed separately on iPad (`Test-TrainTrack UK-2026.09.15_15-42-26-+0100.xcresult`) and iPhone (`Test-TrainTrack UK-2026.09.15_15-44-42-+0100.xcresult`). The iPad bundle also records an iPhone failure caused by interleaving the accessibility audit with paging; the separate iPhone functional run resolves that failure.
- The final empty state uses separate native list rows so its context and earlier/later buttons remain reachable at the largest Dynamic Type size. Independent text-clipping and hit-region audits passed on both dark iPhone and light iPad in `Test-TrainTrack UK-2026.09.15_15-46-12-+0100.xcresult`. These bundles are under `/tmp/traintrack-journey-planner-derived/Logs/Test/`. The deterministic fixture binds only to localhost and verifies that initial requests use server defaults and paging sends only a cursor.
- The unit-test bundle is `Test-TrainTrack UK-2026.09.15_15-33-45-+0100.xcresult`; the five-scenario iPad bundle before the final row layout is `Test-TrainTrack UK-2026.09.15_15-35-46-+0100.xcresult`, in the same directory. The fixture was stopped after verification; the local planner on port 3013 remains running.
- Twelve local benchmark cases and five staged Linux Node 24.21.0 cases passed without truncation. Cold default Inverness preparation/search took 18.625 seconds and about 722 MiB peak RSS. The five-case host benchmark peaked at about 943 MiB RSS, with individual searches between 2.539 and 14.029 seconds after initial preparation. API health returned in 2–37 ms during the staged cold search.
- Deployed with the standard quick script. Public departure search returned five journeys in 13.032 seconds, including London-time 15:27 → 08:26 next day and 19:57 → 08:45 next day. The former uses Victoria/King's Cross then the source-verified Edinburgh/Aberdeen trains; it is not a claim to reproduce the screenshot's exact Herne Hill/St Pancras transfer. Arrive-by returned five journeys in 4.417 seconds, with matching details.
- A request matching the currently installed app's explicit two-change setting returned two journeys in 6.394 seconds, led by the 19:57 sleeper connection. Rebuilding the app is needed to remove that restriction and get the new empty-state presentation.
- Public cursor policy advances to `scheduled-v2`; previous cursors fail safely with 410. V2 stations/config and general health matched their pre-deploy responses byte-for-byte. Only TrainTrack's service PID changed; the other 14 services were untouched.

Evidence/rollback files: `/home/mwagstaff/.local/share/train-track-api/deployment-checks/inverness-20260915T142015Z`. See the operations runbook for the corrected ALF interpretation and deployment details.

## Departure-time timeout correction — 15 September 2026

The later 16:00 Kent House–Inverness search reproduced a work-limit timeout, despite the earlier 15:10 case passing. The API returned JSON `SEARCH_TIMEOUT`; the public gateway replaced its HTTP 504 body with plain text, causing the app's generic message. The deployed runtime and active timetable were correct.

- Cached eligible station events and occurrence-level boarding dominance remove repeated train-call expansion while retaining the full search scope. Nearby 16:00, 16:05, 16:15, 16:30 and 17:00 London cases use 2.4–3.0 million operations under the unchanged 10-million limit. The 30-second and 1024 MB limits remain unchanged.
- **179 selected backend tests passed**, including supplied-data regressions and 402 comparisons with exhaustive routing. The same two baseline exclusions apply. Log: `/tmp/traintrack-departure-timeout-backend-tests.log`. Independent review found no material correctness issues.
- **17 app unit tests passed**. Unstructured HTTP 504 and transport timeouts now explain that the request took too long; structured server errors and cancellation behavior are preserved. Result: `/tmp/traintrack-journey-planner-derived/Logs/Test/Test-TrainTrack UK-2026.09.15_16-05-48-+0100.xcresult`. No view code changed in this correction.
- Seven staged Node 24 host cases passed. The first cold search took 11.557 seconds; peak standalone RSS was about 1048 MiB. Existing API health responded in 1.5 ms during the benchmark.
- Deployed through the standard quick script. Public checks returned four journeys for 16:00 (11.514 seconds), five for 16:05 (6.247 seconds, plus two through pagination), four for a fresh Depart now at 16:13:59 (4.027 seconds), and five for arrive-by (4.587 seconds). All detail checks matched and no results were truncated. The installed app can retry immediately; rebuilding adds only the improved timeout messages.
- Cursor policy advances to `scheduled-v3` because equivalent path selection can change; old cursors return 410. Existing v1/v2 calls remain unchanged. Health/config/stations matched pre-deploy bytes, both live departure versions returned 17 trains, and only TrainTrack's service PID changed.

Production evidence and rollback library: `/home/mwagstaff/.local/share/train-track-api/deployment-checks/departure-timeout-20260915T150400Z`. Public check results: `/tmp/traintrack-departure-timeout-public/summary.json`. No timetable import or deployment configuration changes were needed.

## Baseline and remaining external inputs

Two pre-existing tests time out: `device-data-deletion.test.js` (“a notification save already in flight…”) and `live-session-origin.test.js` (“station exit retires every live session…”). Both were reproduced without planner changes using `git archive HEAD` in an isolated temporary checkout. The first fixture waits for a callback after saving an unregistered fake subscription; the second reaches existing Mongo-dependent live-session cleanup. They remain unchanged. Baseline and final logs are `/tmp/traintrack-original-baseline.log` and `/tmp/traintrack-final-backend-tests.log`.

Production S3 bucket/delivery details, acceptable maximum feed age and ad hoc incremental delivery remain unconfirmed. They do not block local scheduled prototype implementation. Live timetable overlays and itinerary saving/tracking are later work.

Supplementary/through-service continuity, special holiday calendars and ambiguous midnight/clock-change cases have explicit conservative exclusions. The API and app label results scheduled-only and expose human-readable coverage limitations. Release app builds retain the old Add Journey screen by default until the planner feature flag is enabled.
