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

## Burnley timeout and queued searches — 16 September 2026

East Croydon–Burnley Manchester Road, arrive by 18:09, reproduced slow searches for both the screenshot's 16 September and the request's following day, 17 September. Local routing spent 21.44 of 23.06 seconds rebuilding national reachability bounds: 159 builds across 40 distinct horizons repeatedly displaced entries from an eight-entry cache. Reusing a permissive cached bound when full reduces routing to 2.69 seconds and operations from 4.51 million to 1.82 million, while preserving all 22 journey alternatives. This applies generally; no route-specific exception was added.

Searches also now have an additive asynchronous API and app flow:

- Public v3 `POST /search-jobs` admits work quickly, `GET /search-jobs/:id` reports progress/results, and `DELETE` cancels the caller's interest. The original synchronous search and all v1/v2 routes retain their contracts. The routing cursor policy remains `scheduled-v3`.
- Eight distinct pending searches, one computing worker, two active caller records per installation and four per network address bound demand. Equal pending searches share computation with independent cancellation. Idempotent submissions recover lost HTTP responses without creating duplicate work.
- Jobs target half of one worker's CPU through cooperative pauses, with separate eight-minute queue and ten-minute processing budgets plus a one-billion-operation ceiling. Node 24 worker measurements showed approximately 44% CPU over elapsed time. Native SQLite calls are not preemptible and V8 heap limits do not cap total process memory.
- A separate small worker keeps station/metadata requests available; returned details use a bounded parent cache with dataset-version validation. Polling keeps an active job alive; two minutes without polling expires it, and work with no remaining callers is cancelled. Results are bounded by retention time and record count. In-memory jobs expire on an API restart.
- The app shows queue/search progress and a cancel action, including pagination. It pins the API host and idempotency key, retries transient errors with backoff, and uses the old synchronous endpoint only when initial job submission returns 404. Rebuild the app to use the queued flow. Finite processing, admission and network-retry limits remain; completion cannot be guaranteed during outages or unlimited overload.

Verification:

- **211 selected backend tests passed**, including both supplied-data Burnley regressions, execution throttling/cancellation, queue/fairness/idempotency/expiry, HTTP contracts and 404 exhaustive-reference routing comparisons. The same two unrelated baseline exclusions apply. Log: `/tmp/traintrack-queued-search-backend-tests.log`. After adding immediate cancellation wake-up, all 12 HTTP/job tests passed again.
- **24 app planner unit tests passed**, including the seven new async admission, polling, retry, fallback, expiry and cancellation cases. Bundle: `/tmp/traintrack-journey-planner-derived/Logs/Test/Test-TrainTrack UK-2026.09.16_00-23-52-+0100.xcresult`.
- Focused iPhone UI checks passed for queued/running progress, results and pagination cancellation (`Test-TrainTrack UK-2026.09.16_00-27-02-+0100.xcresult`). Initial cancellation at the largest Dynamic Type size passed on both iPhone and dark-mode iPad (`Test-TrainTrack UK-2026.09.16_00-32-39-+0100.xcresult`). Both bundles are in the same test-log directory. An earlier initial-cancel run was interrupted by the simulator test runner; the two-device rerun resolves it. The deterministic fixture confirmed that cancellation sent DELETE to release the job.
- Isolated host verification completed the two queued searches in 28.42 and 47.01 seconds including their queue waits. Station lookups took 3–12 ms and details 2–3 ms. Peak process RSS was about 859 MiB, with no swapped memory; general production API health remained responsive.
- Deployed the API through the standard quick script. Public admission took 0.11–0.13 seconds, then the two searches completed in **27.43 and 46.93 seconds including queue waits**, with five untruncated journeys each. First result for both dates: **13:45 → 18:02 London time via Stevenage and Leeds**. The second job therefore completed beyond the former 30-second request deadline. Station searches took 0.10–0.24 seconds and details about 0.11 seconds through the gateway while routing ran.
- Public duplicate submission, independent cancellation of shared work and cancellation of queued work passed. A nearby uncached request through the original synchronous endpoint (17 September, arrive by 18:10) returned five untruncated journeys in **4.87 seconds**, confirming compatibility for existing app builds.
- Health/config/station responses matched pre-deployment bytes, v1/v2 live departure response shapes passed, and only TrainTrack's PID changed. Node 24 and the active timetable version are unchanged; no timetable import or deployment configuration change was required. The API peaked at about 891 MiB RSS and settled to about 588 MiB with no swap after the queued checks.

Public evidence: `/tmp/traintrack-queued-search-public/summary.json`. Host evidence and rollback library/routes: `/home/mwagstaff/.local/share/train-track-api/deployment-checks/queued-search-20260915T234000Z`. The operations runbook records job semantics, defaults, compatibility and rollback.

## Live times and disruption-aware routing — 16 September 2026

The agreed behavior is live updates for journeys starting within the next **four hours**, with an override that routes using scheduled times while retaining live warnings. The additive v3 `realtime` field accepts `apply` and `ignore`; omission or `off` preserves the scheduled API contract and cursor policy. The app defaults to live updates, remembers the choice in recent searches, and reruns the displayed time window when the toggle changes.

- Station boards and service details are matched to a unique timetable occurrence using dated scheduled times, station, operator and ordered calling points. The public feed does not expose timetable UIDs; opaque service identifiers are not treated as UIDs. Missing, ambiguous, stale or future-dated observations cannot assert an on-time or cancelled train.
- Routing uses immutable overlays, so delays affect catchability, connection feasibility and arrival deadlines before results are selected. Explicit cancelled stops and non-operating portions are excluded appropriately, while an intermediate skipped stop does not prohibit through travel. Cancelled or unusable scheduled alternatives are available separately with warnings. Override results retain the original timetable times and disruption annotations.
- The full useful scheduled frontier and unfiltered origin boards seed discovery, followed by bounded checks of new boarding stations after rerouting. Coverage is explicitly partial. Unmatched services retain scheduled times; provider failure gives a visible scheduled fallback. Unknown expected times remain unknown rather than becoming a false on-time claim.
- Live calls are limited to two at a time, 64 per search, eight stations and three discovery rounds. They have three-second deadlines, no retries and a bounded 30-second cache. Existing queue, CPU duty cycle, heap, elapsed-time and total operation bounds remain. Cancellation also stops pending upstream requests.
- Only provider timestamps within 90 seconds are accepted. More-results pages pin the result context; Earlier/Later fetch fresh observations. Context expiry is explicit. Detail IDs include mode and snapshot so an override or subsequent refresh cannot silently replace a previous result's context.
- The app shows delays in yellow and affected cancellations with red strikethrough, including calling points. Unknown times display labelled scheduled fallbacks. Other cancelled portions warn without striking an unaffected selected leg. Search and per-journey warnings remain accessible.

Verification:

- **262 selected backend tests passed**, including full supplied-data regressions and the same two unrelated baseline exclusions. New cases cover delayed trains becoming catchable, missed connections, arrival deadlines, partial cancellations, unknown timings, override behavior, provider failure, matching freshness, cursor expiry, cancellation, shared operation budgets and detail-context isolation. The final pagination regression crosses the four-hour boundary while preserving the original scheduled page context. Log: `/tmp/traintrack-live-final-backend-tests.log`.
- **34 planner app unit tests passed**, along with the focused live/override/cancelled-calling-point UI flow. Dark mode at the largest Dynamic Type size passed a separate text-clipping and touch-target audit. Results: `/tmp/traintrack-journey-planner-derived/Logs/Test/Test-TrainTrack UK-2026.09.16_14-55-32-+0100.xcresult` and `Test-TrainTrack UK-2026.09.16_14-59-36-+0100.xcresult` in the same directory. Fixture servers were stopped after validation.
- Eight full-data overlays changing 150 geographically spread services each rebuilt affected indexes in 229–353 ms, reusing 1,542 unchanged station event arrays. The 69,129-occurrence benchmark peaked at about 764 MiB RSS. This avoids duplicating the whole national event index for each overlay; it is not a capacity guarantee.
- A staged Node 24 host check using the real live provider returned five KTH–VIC journeys with matched annotations. Cold live search completed in 21.74 seconds, scheduled override in 5.17 seconds, and the five-hour-future scheduled fallback in 8.26 seconds. Station lookups stayed below 35 ms and details took 2.6 ms. Mode-specific journey IDs remained distinct and earlier details retained their original context. The candidate peaked at about 1002 MiB RSS, with no swapped memory, and was stopped after verification.
- Deployed the planner library and restarted only TrainTrack. Public checks returned five journeys each for live, override and future searches in **20.63**, **6.45** and **9.00 seconds**. Five returned legs had matched live annotations. Station lookup latency stayed below **0.27 seconds** and details took **0.17 seconds**. The original scheduled-only job contract returned five journeys in **1.41 seconds**, with no live fields.
- Health/config/stations matched their pre-release responses byte-for-byte; v1/v2 departure response shapes passed with 16 departures each. Other service PIDs, runtime and active timetable were unchanged. The API peaked at about **1032 MiB RSS**, with no swap. Public evidence: `/tmp/traintrack-live-public/summary.json`. Production evidence and rollback library: `/home/mwagstaff/.local/share/train-track-api/deployment-checks/live-planner-20260916T135630Z`.

The operations runbook describes the live contract and deployment. No timetable import, schema migration, new package or additional API key is required. Rebuild the app to receive the toggle and presentation.

## Live coverage warning correction — 16 September 2026

The Kent House–Inverness screenshot exposed misleading aggregation and wasted live lookups. A fresh bounded production diagnostic at 15:33 London made **27 requests**: three successful boards and 24 service-detail requests. All **11 successful details matched** the timetable. The remaining **13 details returned HTTP 500** for departures scheduled 31–122 minutes earlier; four even carried old estimated clock times despite having no actual-departure field. No authentication, rate-limit or timeout failures were observed. These errors are consistent with expired board-relative references: [OpenLDBWS documents service-detail availability as normally ending about two minutes after expected departure](https://lite.realtime.nationalrail.co.uk/OpenLDBWS/documentation.aspx). The provider's specific reason for each HTTP 500 is not asserted.

The old matcher counted all 22 unverified board services, including never-requested details, as unsafe matches. The search also reported a lookup-limit warning when its initial 24-detail batch omitted unrelated services, despite not reaching the 64-request ceiling. Those station-wide diagnostics were shown against every result. In the later diagnostic, the first returned train departed at 19:57, outside the four-hour window; none of those checked old trains belonged to the returned itineraries. This is a fresh reproduction, not a reconstruction of the screenshot's earlier live data.

Corrections:

- Details are requested for near-term useful itinerary legs and potentially catchable delayed origin trains. Expired estimates and unrelated on-time station traffic are skipped. Rerouting checks newly useful trains even when their boarding station has already been visited. CPU, concurrency and request limits remain unchanged.
- Private matching diagnostics distinguish missing detail, stale detail, genuine pattern mismatch and ambiguity. Missing detail is not an unsafe match. An otherwise compatible ambiguous candidate also prevents selecting a different apparently unique candidate.
- Public coverage and warnings concern only the visible page's near-term rail legs. Genuine gaps remain attached to affected legs; later trains get a neutral scheduled-times note. Tube and walking transfers are excluded from live rail coverage counts.
- Cards show how many trains are confirmed on time rather than applying one checked train's status to an overnight journey. The generic Tube-transfer information remains in leg details and no longer appears as a card/live warning; genuine disruption warnings remain visible.

Verification:

- **281 selected backend tests passed**, including the supplied national timetable regressions; the same two unrelated baseline exclusions apply. After the final pending-lookup scoping and current-clock refinements, all **49 focused matching/coverage/search tests passed** again. Log: `/tmp/traintrack-live-coverage-backend-tests.log`.
- **36 app planner unit tests** and the focused long-distance/Tube coverage UI test passed. Result: `/tmp/traintrack-journey-planner-derived/Logs/Test/Test-TrainTrack UK-2026.09.16_15-31-20-+0100.xcresult`. The fixture and dedicated simulator were stopped afterward.
- A deterministic full-engine replay of the exact captured query/observations returned the same five itineraries and times with **three board selections and zero detail selections**, eliminating all 24 wasted detail requests. It used zero network calls. The visible context correctly became scheduled later trains, without blanket retrieval/matching/limit warnings or misleading observation timestamps. Evidence: `/tmp/traintrack-live-diagnostic.json` and `/tmp/traintrack-live-replay-report.json`.
- Deployed only the four changed planner modules and restarted TrainTrack. Public Inverness search returned five journeys in **35.37 seconds**, correctly labelled scheduled later trains, with the first at 19:57 → 08:45 next day (London time). Victoria returned five journeys in **5.48 seconds**, with **5/5 near-term rail legs confirmed**, `live.status: live` and no live warnings. Station lookups stayed below **0.27 seconds** and details below **0.15 seconds**. Health/config/station responses matched pre-release bytes; only TrainTrack's PID changed. Public evidence: `/tmp/traintrack-live-coverage-public/summary.json`; host evidence and rollback library: `/home/mwagstaff/.local/share/train-track-api/deployment-checks/live-coverage-20260916T144200Z`. Rebuild the app for the card/Tube presentation changes.

Four hours remains the eligibility window, not a guarantee that the provider has published forecasts that far ahead. In this capture, the future-offset board extended only to about two hours ahead. Truly broader coverage requires a suitable live feed; increasing request caps would not resolve expired references, unavailable forecasts or ambiguous timetable identity.

## Dividing-train live recovery — 16 September 2026

Victoria–East Croydon reproduced genuine public-provider failures. At 16:37 London, all eight failed detail requests were Southern services advertising two destinations; all 20 single-destination details succeeded and matched safely. Failures returned HTTP 500 with `Unexpected server error` in 133–206 ms. The 16:38 service failed before departure, so this case was not an expired reference. Retrying, looking up the same train at East Croydon, and requesting destination-filtered Victoria boards did not recover the details. This diagnoses the observed sample, not every dividing service nationally.

The existing loading service's Staff departure-board subscription returned complete dated forecasts with timetable UIDs for the same trains. The planner now uses that feed only after a requested public detail returns `upstream`/`unavailable`, and only when the optional staff credential is configured. It verifies exact UID/date/operator and every public call against the selected timetable occurrence. It preserves both arrival and departure forecasts, cancellation scope, hidden-platform and suppression flags. It does not infer forecasts from the other portion of a dividing train. At most eight station/minute recovery queries share the original 64-request ceiling, two-call concurrency, timeout, cache and cancellation controls.

Verification and release:

- **304 selected backend tests passed**, with the same two baseline exclusions. After final validation, conflict-handling and override refinements, **56 focused provider/matcher/search tests passed**. Log: `/tmp/traintrack-staff-recovery-backend-tests.log`.
- Captured-data replay matched G26231's 21 public calls and C93139's eight calls exactly, including Victoria departures and East Croydon arrivals. It used no network calls. Evidence: `/tmp/traintrack-staff-replay-report.json`.
- An isolated real-provider host search took **30.66 seconds** and made **39 calls**, including eight staff calls. Seven failed public services were recovered. The eighth, C93145 at 17:38, was explicitly `serviceIsSupressed: true` at Victoria and correctly remained a gap; every timetable field otherwise matched. This produced four confirmed trains out of the first five, without loosening identity or suppression checks.
- Added `train-track-api` to the existing staff credential's Bitwarden **Apps** field while preserving `train-loading-service` and all other fields. A guarded, reversible sync added only that credential to the planner environment. Subsequent standard Bitwarden-enabled deployments retain the mapping. No new subscription or duplicated vault item was created.
- Deployed only `live-provider.js`, `live-search.js` and `live-staff-matching.js`, then restarted only TrainTrack. Fresh public **VIC–ECR live and override searches both confirmed all five returned trains**. Live mode had no coverage warnings; override retained its scheduled-routing explanation. Completion took **38.35** and **15.40 seconds** respectively. KTH–VIC completed in **7.34 seconds**, confirmed all five trains and correctly used a real three-minute departure/two-minute arrival delay on the first train.
- Station requests stayed below **0.34 seconds** and details below **0.19 seconds** during checks. Health/config/station responses matched pre-release bytes and other service PIDs were unchanged. No app source change/rebuild, timetable import or new API version was needed. Test jobs released their leases and the diagnostic worker exited.

Production evidence and prior planner library: `/home/mwagstaff/.local/share/train-track-api/deployment-checks/staff-recovery-20260916T163500Z`. Public evidence: `/tmp/traintrack-staff-recovery-public/summary.json`. The previous credential environment is backed up privately under `deployment-checks/staff-env-20260916T170922Z`. Missing, withheld or ambiguous provider data still produces honest scheduled fallback; successful recovery does not guarantee universal live coverage.

## Saved journeys and favourites — 17 September 2026

Implemented locally following approval of the saved-route plan. This change has **not been deployed**. The additive `POST /api/v3/journey-planner/route-boards` resource serves the new app; existing v1/v2 resources and existing v3 search/job contracts are preserved.

- My Journeys and Favourites display complete planned itineraries, including valid multi-leg and engineering-diversion routes in the active timetable. Manually saved intermediate stations remain required in order, without forcing a change when the same train calls there. Direct trains receive a ten-minute preference in arrival ranking.
- Dated scheduled profiles are shared across clients and optionally persisted in Mongo for up to two hours. Timetable and routing versions, ordered stops, options and a two-hour time bucket identify each profile. An eight-hour internal window retains later departures and potentially catchable delayed trains; it does not reuse a first-page search as a route cache.
- Live refreshes reuse the existing public departure-board/service-detail provider and optional staff recovery. They retime and validate cached candidates, reuse observations for 30 seconds, and apply the existing four-hour live window. The per-route live toggle uses scheduled routing while retaining disruption warnings. Relevant disruptions can trigger a bounded early replan; forecasts never enter the scheduled cache.
- Work is demand-driven, coalesced across clients, and admitted through bounded global/client/network queues. Background route calculation uses the existing worker and CPU/memory limits. Interactive searches have priority over queued work; active calculations are not preempted. Polling stops when the relevant tab/app is inactive. Database response deadlines and actual outstanding operations are bounded separately.
- Full itinerary details offer separately verified tracking for each train. Existing route-wide subscriptions remain a separate action. New tracking references, timetable identity and complete public calling patterns exist only on the new resource; older clients continue using their existing APIs.

Validation:

- **354 selected backend tests passed**, with the same two documented baseline exclusions below. Coverage includes API compatibility, shared cache reuse/restart, expiry and timetable invalidation, ordered required stops, delayed/cancelled routes, ranking and duplicate suppression, queue saturation, hung database operations, response bounds and a complete synthetic KTH–BMS–VIC diversion through the engine and cache facade. Log: `/tmp/traintrack-saved-boards-backend-final.log`. Local runtime: Node 25.8.1.
- **112 app unit tests passed**, including request compatibility, coalesced requests, required stops/direction, host and live-mode isolation, stale observations, departed-row filtering, verified train identity and five existing tracking suites. Explicit tracking rechecks the host and evidence freshness after permission/token waits and at actual start; it cannot silently choose a different train. Public clock matching rejects ambiguous autumn-fold and nonexistent spring-gap times, and a board-time bound prevents selecting a neighboring day's train. The combined run also passed the dark/largest-text functional UI scenario, with no failures or skips: `/tmp/traintrack-saved-route-final-verification.xcresult` on iPhone 17 Pro Max, iOS 26.5.
- Functional app checks cover queued-to-ready boards, full itinerary details, a failed train-verification action, live-mode switching and the explicit legacy-server fallback. Light and dark screens were visually inspected, including the largest Dynamic Type setting. The final header layout passed a further focused UI run: `/tmp/traintrack-saved-route-final-header-ui.xcresult`; screenshots are in `/tmp/traintrack-saved-route-final-header-attachments/`. The dark detail accessibility audit reported one text-clipping issue without an identifiable element; it remains recorded as an audit limitation rather than a clean audit pass. The dedicated fixture server and QA simulator were stopped after verification.
- Full-data departure profiles were measured for KTH–VIC, KTH–BMS–VIC, KTH–INV and ECR–BYM. The national profile is calculated in one-hour departure partitions under one cumulative budget, releasing intermediate labels between partitions. This corrected excessive memory retention in the original eight-hour calculation without increasing worker limits.
- The final ECR–BYM run took **53.24 seconds**, retained **all 292 distinct departure times** across the eight-hour window in 512 candidates, and used **3.72 MB** of serialized cache space. Peak sampled heap/RSS was **791/1061 MB**, within the unchanged 1 GB V8 heap limit (RSS also includes native memory). Additional alternatives were omitted under the cap and explicitly marked as incomplete. The other three profiles took approximately **5.15**, **11.25** and **12.78 seconds** in the earlier four-case run. These are local unthrottled measurements, not production latency guarantees; configured CPU throttling can increase cold completion time. Reports: `/tmp/traintrack-route-profile-benchmark.json` and `/tmp/traintrack-route-profile-partition-benchmark.json`.

See the [operations runbook](journey-planner-operations.md#saved-journey-boards--additive-api-and-deployment) for the request contract, limits and rollout. Deploy the API first, then release the rebuilt app. This feature requires no new key, timetable reimport or manual database migration. Engineering works still require an updated dated timetable; live cancellations cannot invent replacement services absent from the active snapshot.

## Saved-route queue fairness and visible progress — 17 September 2026

Fixed locally after the deployed app showed My Journeys indefinitely waiting to be planned. This follow-up has **not been deployed**.

The manager recorded routes rejected by the two-task client limit, but did not automatically admit them when a slot became free. Fixed-order polling could let the first two cards repeatedly refresh before later cards received a turn. A deterministic three-route reproduction left the third route unstarted after nine simulated minutes. With the fix, all three receive results and continue rotating; the third receives its first result at 270 simulated seconds with deliberately slow 45-second worker stages. These are regression-test timings, not a production ETA.

- Waiting routes now retain their age, advance automatically and cannot be overtaken indefinitely by repeated refreshes. The eight-task global, two-task client and four-task network admission limits remain unchanged, as do worker CPU and memory limits. Under memory pressure, unused queued profiles can be released and reloaded from the shared scheduled cache without losing the route's place. Active profiles remain protected.
- Pending boards expose optional progress fields: queue position, queued/start timestamps, current phase and actual completed hourly timetable windows. Capacity waiting is a progress state, not an error. Genuine failures retain their error and retry automatically while the client remains interested. Abandoned routes and obsolete time buckets release their work.
- My Journeys and Favourites show a spinner, queue position, elapsed waiting and the current planning/live-check phase. Completed-window counters show actual work without promising a finish time. Old responses remain supported. Trains with no published live forecast remain labelled Scheduled; only actual expired live evidence produces a Live times out of date label, including in itinerary details.
- This is an additive change to the existing v3 saved-route resource. Existing v1/v2 APIs and v3 search/job contracts are unchanged. No timetable reimport, cache clearing, new credential or schema migration is required. Redeploy the API and rebuild the app to receive both the queue fix and progress display.

Verification:

- **364 selected backend tests passed**, with the same two documented unrelated baseline exclusions below. New regressions cover automatic draining, repeated polling fairness, memory-pressure admission and cache reload, queue progress, worker start, failed retries, cancellation, live-mode changes and obsolete time buckets. Log: `/tmp/traintrack-route-queue-backend-final.log`; local runtime Node 25.8.1.
- **53 focused app unit tests passed**, covering old/new progress responses, capacity waiting and retries, stale live evidence, future scheduled services and existing planner behavior. Bundle: `/tmp/traintrack-route-progress-verification.xcresult`. The final queued → searching → ready UI scenario passed separately with missing/unknown forecasts correctly labelled Scheduled and no false stale warning in details: `/tmp/traintrack-route-progress-final-ui.xcresult`.
- The largest Dynamic Type size in dark mode passed the focused queue screen scenario and text-clipping/touch-target audits: `/tmp/traintrack-route-progress-large-ui.xcresult`. Normal and large-text screenshots were visually inspected. The temporary fixture and dedicated simulator were stopped after verification.
- Read-only production inspection found the API active with no service restarts since its current start and no matching planner-worker failures in the preceding hour's journal. No production code, configuration or process was changed during this investigation.

## Search speed-up, tier 1 — 17 September 2026

Profiling the routing worker against the RJTTF939 snapshot showed that most search time was spent outside the search itself: `Intl.DateTimeFormat` clock resolution during fixed-link checks (38% of routing CPU on long-distance searches), national reachability bounds rebuilt on every routing call (a further 18–28%, repeated for each live re-route), and per-date timetable resolution that filtered weekday calendars in JavaScript and read each selected schedule with its own SQLite lookup. The queued search path used by the app also ran at a 50% CPU duty cycle.

- The Europe/London clock used by fixed-link windows is now a table of BST boundaries with integer arithmetic. It was checked against `Intl` on 4.3 million instants between 2000 and 2099, including second-by-second sweeps of every clock change, with no differences.
- Temporal reachability bounds are cached on the prepared national index, keyed by target, direction, modes and boarding budget, so repeated routing (paging, nearby times, live re-routing) reuses them. The search's own global envelope is always present before the existing bounded-cache fallback.
- Date resolution filters running weekdays in SQLite, caches the weekday per date, and reads the selected schedules' calls in batches of 500.
- The queued-search CPU duty cycle defaults to 1; `PLANNER_JOB_CPU_DUTY_CYCLE` still accepts a lower value.
- Dates adjacent to a newly prepared range are retained, so alternating today/tomorrow searches no longer re-resolve a date each time.
- The routing worker pre-warms today's dates and national index shortly after start and again when the London date or active timetable changes (`PLANNER_PREWARM=false` disables it). It skips warming when fewer than 300 MB of heap headroom remain or while a request is active.

### Worker memory correction — 17 September 2026

Production logged `ERR_WORKER_OUT_OF_MEMORY` after the deployment. The retained (post-GC) heap of the routing worker was already about 535 MB before this work with four resolved dates and one national index, leaving under 500 MB of the 1024 MB limit for live re-routing and saved-board replans; the first version of the shared bounds cache also kept each search's eligible-event caches alive on the index.

- Only the temporal bounds are shared between searches; the eligible-event and call caches now live on a per-search view and are released with it. The shared cache holds at most four target keys. Retained heap on a twelve-search mixed workload is back to the original 534 MB.
- At most four dates stay resident: adjacent dates are retained only within that budget. Pre-warming resolves the daytime range only (three dates).
- A memory valve runs before each network preparation: above 70% of the worker heap limit it drops the search result cache, the derived index caches and all but the two newest live snapshots; above 85% it also releases the national index. Each release logs `[planner] memory pressure` at most once a minute. Results are unaffected; the following searches rebuild what they need.

Eight local unthrottled cases (M5 Pro, cold worker, no pre-warm) fell from 17.6 to 10.7 seconds in total; for example KTH–VIC 2.69 → 1.58 s, BHM–EDB arrive-by 2.50 → 1.20 s, VIC–BTN late-evening 3.31 → 1.68 s, KTH–INV 16:00 1.40 → 0.89 s. Full journey payloads, pagination and warnings for these and the twelve repository benchmark cases are byte-identical at both the five-journey page and the complete frontier. With pre-warming, the first Depart-now KTH–VIC search after worker start took 0.35 seconds instead of 1.76. All 235 planner tests pass, including the full-dataset regressions. No routing policy or cursor version changed.

## Search history and admin dashboard — 17 September 2026

Implemented locally; **not deployed**. The new Mongo `planner_searches` collection
retains search lifecycle records for seven days using a fixed TTL index on
`startedAt`. Startup creates the collection/indexes through the standard API
deployment. No app rebuild, new credential, timetable import or migration is
required. Existing API request/response contracts remain unchanged.

- Synchronous searches and queued caller submissions record submission and
  completion times, queue-inclusive duration, public route fields, result count,
  outcome and observed cache hit/miss/unknown. Status polls and accepted
  idempotent retries do not create duplicates. Coalesced callers retain separate
  outcomes. Saved-route initial stage chains are one record; subsequent actual
  refresh/replan work is separate. Internal capacity retries retain their record.
- Writes run independently, with a bounded buffer, one batch at a time, retries
  and revision guards against late pending writes overwriting completed records.
  Unfinished/cancelled/expired work is distinguishable from failure, and an empty
  search is still successful. Logs contain no device IDs, IPs, raw requests,
  cursors or provider credentials.
- `/admin/journey-planner`, linked from the existing admin portal, displays the
  newest searches first. All eight headings sort server-side; pagination and
  hour/day/week and source filters operate across the retained dataset. Cards
  report full-filter counts, success/failure percentages, exact nearest-rank p99,
  maximum, average and cache-hit rate. Definitions explain exclusions and the
  15-second shared statistics snapshot.

Verification:

- **388 selected backend tests passed**, with two previously documented unrelated
  baseline exclusions and the separate opt-in Mongo integration test skipped in
  this ordinary run. Log: `/tmp/traintrack-search-log-backend-final.log`.
- The integration test **passed against an isolated MongoDB 7.0.43 instance**,
  exercising actual bulk upserts/revision guards, TTL indexes, 245 retained plus
  five expired fixture rows, all heading sort directions, pagination and
  whole-window statistics. The private test databases, process, downloaded
  binaries and temporary data were removed afterward. It can be repeated with
  `MONGO_TEST_URI` and `test/planner-search-log-mongo.test.js` against a local test
  Mongo instance.
- Browser verification passed at desktop and 390-pixel mobile width, including
  keyboard sorting, both sort directions, source filtering, next-page navigation,
  unchanged summary cards across pages, empty data and database error states.
  Both layouts were visually reviewed; the temporary synthetic fixture and tabs
  were closed and viewport overrides reset. Eight focused admin tests are included
  in the backend total.

No production code, process or database was changed. See the
[operations runbook](journey-planner-operations.md#search-history-in-mongo-and-the-admin-portal)
for lifecycle definitions, retention and logging-outage limits.

## Admin links behind the production proxy — 17 September 2026

Fixed locally after the deployed search-history page dropped `/train-track/`
from Refresh and other links. All admin destinations now resolve relative to
the request path: planner filters, sorting, pagination and retry; shared
navigation; device and raw-record links; payload replay forms/backlinks;
test-harness forms/redirects; and the dashboard's subscription API request.
This preserves arbitrary proxy prefixes without deployment-specific settings,
including trailing-slash and nested POST replay pages. API contracts are
unchanged. This fix needs an API redeploy and browser reload only.

Verification: **399 backend tests passed**, with the same two unrelated baseline
exclusions and opt-in Mongo test skipped. Log:
`/tmp/traintrack-admin-prefix-tests.log`. Automated checks exercise direct and
mounted HTTP routes, every admin link/form and the five harness redirects;
helper checks include encoded IDs and deeper prefixes. Browser checks passed
for Refresh, sorting, pagination, filters and navigation at the simulated
`/train-track/admin/journey-planner` deployment path. Synthetic fixture and test
browser tab were closed afterward.

## Baseline and remaining external inputs

Two pre-existing tests time out: `device-data-deletion.test.js` (“a notification save already in flight…”) and `live-session-origin.test.js` (“station exit retires every live session…”). Both were reproduced without planner changes using `git archive HEAD` in an isolated temporary checkout. The first fixture waits for a callback after saving an unregistered fake subscription; the second reaches existing Mongo-dependent live-session cleanup. They remain unchanged. Baseline and final logs are `/tmp/traintrack-original-baseline.log` and `/tmp/traintrack-final-backend-tests.log`.

Production S3 bucket/delivery details, acceptable maximum feed age and ad hoc incremental delivery remain unconfirmed. They do not block the implemented planner. Complete national live-feed coverage and end-to-end multi-leg tracking/notifications remain later work.

Supplementary/through-service continuity, special holiday calendars and ambiguous midnight/clock-change cases have explicit conservative exclusions. The API and app distinguish scheduled results from partial live coverage and expose human-readable limitations. Release app builds retain the old Add Journey screen by default until the planner feature flag is enabled.
