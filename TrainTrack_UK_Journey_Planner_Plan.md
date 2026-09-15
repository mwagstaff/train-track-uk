# TrainTrack UK — Full Timetable Journey Planner

**Implementation plan for Codex · 15 September 2026**  
**Scope: journey planning only. No fares, ticketing, ticket validity or retailing.**  
**Input inspected locally: nine extracted files for package `RJTTF939`, generated 25 August 2026.**  
**Status: implementation authorised on 15 September 2026. Existing API contracts and user flows must remain compatible.**

**Implementation record:** the scheduled prototype is now implemented. See [progress and verification](docs/journey-planner-progress.md) and [API/operations runbook](docs/journey-planner-operations.md) for the final contracts, commands, measurements and remaining production inputs. The design discussion below records the agreed plan.

## 0. Instructions to Codex

Implement a self-hosted, timetable-based journey planner for **TrainTrack UK**, using the full National Rail timetable data supplied with this plan. Integrate with the existing application and backend rather than creating a competing app or unnecessarily replacing existing services.

Source: https://raildata.org.uk/dashboard/dataProduct/P-04b05b6e-c14d-4a53-ba34-76ee7c48cc72/overview
Documentation: https://www.rspaccreditation.org/publicDocumentation.php#RSPS5046 

Read this document completely and follow the current conversation's authorisation. Implementation is now requested. Start with the source inspector and importer, then deliver working, tested increments. Maintain a short progress document recording completed milestones, commands run, test results and genuine blockers. All planner endpoints use the new `/api/v3/journey-planner` namespace; existing v1/v2 endpoints, payloads and configuration remain unchanged.

Repository reconnaissance has now established an Express backend using plain JavaScript ES modules, MongoDB for existing application state, and a SwiftUI app. The backend has live departure/service lookups but no full timetable router. Existing saved journeys are reusable station sequences; the current itinerary builder selects live departures. Keep new dated planner models separate. Paths, interfaces and commands below remain proposed contracts unless explicitly identified as existing code.

Keep this plan at its current referenced location during planning. The supplied extracted files are under `/Users/mwagstaff/dev/train-track-uk/api/train-track-api/resources/timetable_full`. The owner expects monthly full downloads, likely delivered by National Rail to an S3 bucket; the delivery arrangement is not yet confirmed.

Ad hoc incremental updates, including short-notice timetable amendments, remain to be confirmed. Preserve the boundaries needed for an update importer without making unconfirmed delivery mechanisms a prototype dependency.

**Non-negotiable rules:**

- Build a planner for passenger journeys, not a ticketing system. Do not add prices, railcards, fare restrictions, Routeing Guide processing, reservations, checkout, payments, ticket issuance or sales links.
- Use the feed's schedules and connection rules. Do not invent departures, passenger calls, connections, station equivalences or transfer durations.
- Keep the first working release **scheduled-only**, clearly labelled.
- A production result must be explainable through its source schedule and transfer records. A development shortcut must not silently become production behaviour.
- Consult the authoritative format documentation before implementing field layouts or ambiguous semantics. Isolate unsupported cases and report them; do not guess and claim complete national coverage.

When implementation begins, carry out each milestone and its tests before progressing. Planning does not authorise deployment or infrastructure changes. Monetisation is deferred until after the prototype; do not add authentication, subscription checks or app-only credentials to public planner API access. Administrative dataset operations remain private.

### 0.1 Confirmed owner decisions

| Decision | Agreed scope |
|---|---|
| First usable prototype | Connecting journeys and both depart-after and arrive-by searches; a direct-only slice is an internal milestone |
| Input cadence | Monthly full downloads; National Rail delivery to S3 is likely, with details pending |
| Incremental data | Ad hoc updates to be confirmed; no claim of daily or live freshness |
| API access and monetisation | Public planner API remains open; decide commercial access after the prototype |
| App entry point | Replace the current Add Journey screen with journey planning; date and time are optional |
| Existing Add Journey actions | Retain saving, favourites, manual routes and start/schedule tracking in a secondary "Add a saved route" flow |
| Planner actions | Search and view details initially; saving a selected itinerary or starting tracking from it is deferred |
| Recent searches | Let users view and reuse recent searches |

The recent-search retention count and detailed reuse rules in Section 9 are proposed implementation defaults, not additional owner requirements. Outstanding operational decisions are the actual S3 delivery configuration, acceptable feed age, and incremental-update availability.

---

## 1. Product scope and release boundaries

### 1.1 Intended capability

A user selects an origin and destination, optionally specifying a departure or arrival date and time. With no explicit date/time, the search means depart now. TrainTrack UK returns several usable passenger journeys with scheduled departure and arrival times, duration, changes, operators, calling points and transfer details.

The first usable prototype must support departure-time and arrival-deadline searches, direct journeys and journeys involving changes. It should understand station interchange allowances, supported transfer links, timetable amendments and cancellations present in its snapshot, and journeys that cross midnight. The direct-service milestone alone is not the agreed prototype.

Start with GB National Rail passenger services and explicitly supported connecting modes. Include identifiable, timetabled rail-replacement buses when their records can be interpreted correctly. Do not describe the dataset as covering every transport service in the United Kingdom.

### 1.2 Initial and deferred capabilities

| Capability | Treatment |
|---|---|
| Station-to-station scheduled rail journeys | Core |
| Direct journeys and up to two changes | Required for the first usable prototype; keep the limit configurable |
| Depart-after search | First routing milestone |
| Arrive-by search and earlier/later results | Required for the first usable prototype |
| Optional travel date/time | Default to depart now; offer depart-at and arrive-by date/time selection |
| Recent searches | Core app feature: view, refill and rerun searches against the active timetable |
| Save a selected dated itinerary or start tracking it | Deferred; existing manual saved-route actions remain available separately |
| Station aliases and public code normalisation | Core |
| Default and operator-specific connection times | Core |
| Supplied walking and cross-London transfer links | Enable after transfer semantics pass tests |
| Timetabled replacement buses | Enable after mode and schedule validation |
| Ferry and other supplementary services | Preserve on import; disabled by default unless explicitly validated and enabled |
| Train splitting/joining and through-service continuity | Preserve immediately; supported cases require explicit tests before being offered |
| Live predictions, cancellations and replanning | Later enhancement through the existing live-data integration |
| Step-free or wheelchair-accessible routing | Not promised by this dataset; do not add a misleading filter |
| Detailed Tube, street, walking or general bus routing | Out of scope; a supplied generic transfer is not a detailed itinerary |
| Fares, tickets, validity, reservations and retailing | Entirely out of scope |

Do not expand the project into maps, historical analytics, compensation, notifications or a redesign of unrelated TrainTrack UK screens. Existing features should continue to work.

---

## 2. Input package and reproducible checks

### 2.1 Verified archive inventory

The following observations were measured directly from the supplied archive, not estimated from documentation. They are fixtures for **this exact file**, not constants for future imports. [A1]

| Item | Observed value |
|---|---:|
| Compressed archive size | 72,985,708 bytes |
| Total uncompressed member size | 676,525,613 bytes |
| Archive members | 9 |
| Main `.MCA` `BS` records | 455,794 |
| Main `.MCA` `BX`, `LO` and `LT` records | 388,617 of each |
| Main `.MCA` `LI` records | 6,479,382 |
| Main `.MCA` `AA` records | 5,634 |
| Main `.MCA` `CR` records | 91,623 |
| Main `.MCA` `TI` records | 12,085 |
| `.MSN` station/location `A` records, excluding its header | 3,299 |
| `.MSN` alias `L` records | 298 |
| `.TSI` rows | 35 |
| `.ALF` rows | 4,209 |
| `.FLF` actual link rows | 1,224, plus a separate `END` terminator |
| `.ZTR` `BS` records | 5,383 |

Archive SHA-256:

```text
15031ac6b867142ed63298d41b540a8decf54c7bff0d3ea7ecb8329ac97ba782
```

The `.FLF` count deliberately excludes `END`; counting it as a link produces 1,225 incorrectly.

**Local verification:** read-only streaming inspection reproduced all member sizes and record counts above from the nine extracted files. No timetable ZIP was found locally, so the compressed size, ZIP integrity and archive SHA-256 above are retained claims from the original supplied plan, not independently verified archive properties. Directory imports must record member hashes and a deterministic package-content identity rather than claim to reproduce the ZIP hash.

### 2.2 File responsibilities

| Actual filename | Planned use |
|---|---|
| `RJTTF939DAT.txt` | Discover package members; retain sequence and generation metadata |
| `RJTTF939MCA.txt` | Main schedules, calendars, calling locations, schedule variants and associations |
| `RJTTF939MSN.txt` | Passenger-location normalisation, names, aliases and default interchange information |
| `RJTTF939TSI.txt` | Operator-pair interchange rules |
| `RJTTF939ALF.txt` | Preferred fixed-link input, including applicability and priority fields |
| `RJTTF939FLF.txt` | Legacy fixed-link input for inspection and controlled compatibility |
| `RJTTF939ZTR.txt` | Separately parsed supplementary schedules |
| `RJTTF939REJ.txt` | Source rejection diagnostics; no rejected train entries in this sample |
| `RJTTF939SET.txt` | Preserve package metadata; do not build routing logic around its content |

Discover members by the manifest and recognised naming patterns. Support both the supplied `...MCA.txt` style and the documented `... .MCA` extension style. Do not hard-code sequence `939`, infer file types only from the final `.txt` extension, or assume every package is a full refresh.

RDG identifies RSPS5046 as the timetable-feed specification. Use the version applicable to the subscribed product; the public ASSIST listing inspected for this plan lists P-04-02, issued 3 June 2025. [R1][R2]

### 2.3 Dates, freshness and known irregularities

The `.DAT` metadata says **25 August 2026**. Main-file schedule date fields range from **17 May 2026 to 15 May 2027**. Supplementary schedules include expired entries and end dates represented as `991231`. The main `HD` record contains older-looking date values inconsistent with its schedule content. [A1]

Treat the attachment as a development snapshot, not a current production feed. Store source generation date, source header values, download time, import time and measured calendar coverage separately. Preserve date-only precision; do not manufacture a generation timestamp when only a date is supplied.

Do not derive the advertised planning horizon from the single greatest end date, especially a supplementary sentinel. Compute coverage diagnostics from active main schedules and supported supplementary data, and retain an explicit configured search horizon. Neither a wide date range nor the presence of a few services proves completeness for every station and date.

The earlier `PPTimetable_..._ref_...xml.gz` file is optional enrichment only. The planner must not need it to obtain schedules. Do not allow a reference extract from another publication to overwrite timetable identities indiscriminately.

---

## 3. Architecture: a small backend addition

### 3.1 Recommended shape

```text
Local archive / authorised feed download
                  |
        Archive inspection and validation
                  |
        Streaming parsers, isolated from HTTP
                  |
        Versioned normalised staging dataset
                  |
        Calendar resolution and compact routing indexes
                  |
        Automated validation and sample searches
                  |
        Atomic activation of a new dataset version
                  |
        Journey-search module / worker
                  |
        Existing TrainTrack UK API
                  |
        Existing iOS application

Later: existing live-data adapter -> versioned runtime overlay
```

Keep the importer, date resolver, transfer evaluator and router as separate testable modules. A single deployed backend plus an import/search worker is sufficient as the initial design. Do not introduce Kafka, a graph database, a separate cloud platform or several microservices without measured need.

### 3.2 Stack and storage decision

Use the existing JavaScript ES-module and Express conventions. Add focused planner modules, a route-registration module and command-line entry point within the existing backend. Keep CPU-heavy search work in a worker and imports outside the HTTP process. A TypeScript migration or native-language service is not part of this plan.

The proposed planner store is a versioned SQLite snapshot with compact arrays/indexes and integer identifiers for hot routing data. Existing MongoDB remains responsible for current application state. Its presence does not make millions of independently fetched calling-point documents appropriate for routing. Confirm the SQLite driver/runtime fit and resource budget before finalising storage; no benchmark has yet settled the sizing.

Benchmark before changing language or database. There are no measured routing-memory or query-latency results for this archive yet.

### 3.3 Dataset publication

Build a candidate dataset in isolation. Validate it, warm required indexes, then switch the active version atomically. Pin each in-flight request to one version and retain the previous version for rollback. Do not replace individual tables underneath active searches or publish a half-imported national timetable.

Budget disk for the incoming archive, staging output, current snapshot and rollback snapshot. Budget memory for a version switch as well as steady-state operation.

Production deployments use file synchronisation with deletion of obsolete files. Keep planner snapshots in a configured data directory outside deployed source, following the existing external-asset storage pattern. Do not place production active/rollback datasets in the repository's resources directory. Keep planner readiness independent of general API readiness so timetable outages do not interrupt existing departures or push processing. Do not horizontally scale the whole API as a routing shortcut: existing device-deletion coordination assumes one API process.

---

## 4. Domain model and service interfaces

### 4.1 Normalised entities

| Entity | Essential content |
|---|---|
| `DatasetVersion` | Content hash, source namespace, package metadata, parser/spec versions, validation report, supported coverage and activation state |
| `Station` | Stable public identifier, canonical CRS, public name, aliases, selectable status and location mappings |
| `TimingLocation` | TIPLOC, source identifiers, station mapping where valid and provenance |
| `ScheduleVariant` | Namespaced schedule identity, UID, calendar, transaction/STP fields, passenger/mode data, operator data and source record location |
| `CallingPoint` | Variant, sequence, timing-location suffix/occurrence, public and working times, day offsets, boarding/alighting flags and raw activity fields |
| `Association` | Both service identities, dates, location/occurrence, relationship and passenger-relevant continuity information |
| `InterchangeRule` | Station, applicable operator pair, duration and source |
| `FixedLinkRule` | Endpoints, mode, duration, applicability, priority, interpretation version and provenance |
| `ResolvedService` | A concrete selected variant operating on an origin service date |
| `Journey` | Ordered legs, connection decisions, scheduled timestamps, search assumptions and dataset version |

Preserve enough raw data to audit transformations without keeping raw text attached to every object in the hot search path. An archive/member/line-number reference plus a retained authorised source archive is sufficient for many diagnostics.

### 4.2 Identity rules

Keep schedule-definition identity separate from a concrete day's service and from a live provider's identifier. Use the documented schedule identity fields, namespaced by source, and a distinct content/version hash. A UID alone is not a unique journey instance.

A practical resolved-service identifier includes dataset version, selected variant identity and **origin service date**. A calling point also needs its sequence/occurrence: repeated visits to the same TIPLOC are not interchangeable.

Do not join a `.ZTR` service to an `.MCA` service because their UID strings happen to match. Likewise, a Darwin identifier must be mapped explicitly rather than assumed equal to a timetable UID.

### 4.3 Module boundaries

Implement equivalents of these interfaces in the repository's language:

```text
inspectSource(directoryOrArchive) -> SourceReport
importFullSnapshot(directoryOrArchive, stagingTarget) -> DatasetCandidate
validateDataset(candidate) -> ValidationReport
resolveServices(dataset, originServiceDate) -> ResolvedServiceIndex
resolveConnection(arrivalContext, departureContext, policy) -> ConnectionDecision
findJourneys(request, pinnedDataset, optionalLiveSnapshot) -> JourneySearchResult
explainJourney(journeyId, pinnedDataset) -> JourneyExplanation
activateDataset(candidateVersion) -> ActivationResult
```

The router should consume normalised interfaces, not parse CIF text or query a remote feed during an inner search loop.

---

## 5. Importer and interpretation requirements

### 5.1 Archive handling

Support the supplied extracted directory as well as ZIP packages through the same logical member-reader interface. Validate directory manifest membership, file widths, required terminators and member hashes; validate ZIP-specific integrity when a ZIP is supplied. Do not manufacture an archive checksum for a directory.

Validate ZIP integrity, member paths, file counts, configured expanded-size limits and manifest membership. Reject path traversal, duplicate/conflicting logical members and truncated required files. Do not execute anything contained in an archive.

Stream members and batch database writes. Do not read the 673 MB main member into one string and call `split()` on it. Preserve fixed-width spaces until individual fields have been extracted. Handle line endings and file-specific encodings explicitly.

The sample's `.MCA` and `.ZTR` records are 80 characters before line endings, while `.MSN` data lines are 82 characters. `.ALF` and `.TSI` are variable length. A single universal 80-character parser will therefore fail. Classify MSN headers, trailers and its 440 legacy CRS-usage records separately from station rows. The local DAT has mixed line endings and no final newline; accept valid final records without trimming fixed-width fields. [A1]

Provide progress counters and a non-zero exit status on failed validation. Support cancellation without touching the currently active dataset. Re-importing the same content must be idempotent.

### 5.2 Specification-first parsers

Create separate parsers for the manifest, main timetable, station data, interchange data, fixed links and supplementary schedules. Use the layouts and code definitions referenced in RSPS5046; consult the relevant reference-code documentation where a value is not fully defined there. [R2][R3]

For the main timetable, account for `HD`, `TI`, `TA`, `TD`, `AA`, `BS`, `BX`, `LO`, `LI`, `CR`, `LT` and `ZZ`, as appropriate to full or update input. Count and classify every encountered record type. Do not discard a `CR` record merely because the simple direct-service fixture does not need it.

Represent transaction instructions separately from schedule applicability. A cancelled schedule may legitimately have no origin/calling-point body; an ordinary operating schedule with a missing body is a different situation. Keep unknown critical values out of routable output and make their impact visible in validation.

Parse `.ZTR` with an explicit supplementary-dialect adapter, not by assuming that every populated or blank field has exactly the main-file interpretation. Retain unsupported modes without presenting them as trains.

### 5.3 Calendar and amendment resolver

Build a pure, deterministic resolver that selects the applicable service for an origin date. It must consider inclusive operating dates, weekday masks, supported holiday restrictions, relevant schedule variants, cancellation records and any applied source transactions.

The main sample contains `P=135,127`, `N=111,267`, `O=142,223` and `C=67,177` STP records. These are variants, not separate daily trains. [A1]

Implement the documented precedence and identity semantics with small fixtures. Do not select the first record encountered, keep only the permanent schedule, or use an untested blanket `C > O > N > P` sort as a substitute for those semantics.

A cancellation affecting one date must not erase the service on other dates. An overlay must replace the applicable service rather than create a second departure beside it. A deletion in an update must not be confused with a passenger cancellation.

Generate a debug explanation for each resolved service: candidates considered, date applicability, chosen variant and rejected/suppressing records. Unresolved conflicting candidates should be reported and excluded, not decided by import order.

### 5.4 Passenger calls and times

Derive explicit `canBoard` and `canAlight` decisions for each location event. Preserve working and public times separately. A train appearing at a location is insufficient evidence of a passenger call: the sample contains Kent House passing records as well as genuine calls. [A1]

Make midnight handling context-aware. Do not globally turn every `0000` field into either a valid midnight call or a missing value. Test the documented field semantics together with activity and working-time context.

Preserve half-minute precision internally where present. Use elapsed seconds or another explicit precision rather than silently rounding. Use public passenger times for both display and minimum-connection calculations, as required by RSPS5046 section 5.4.13. Working times remain separate for chronology interpretation and diagnostics.

Maintain an origin service date and event day offsets. A search just after midnight may need trains whose origin date is earlier. Determine the lookback from supported journey/service duration and actual event offsets; do not assume all relevant trains started on the search's calendar date.

Implement the specific clock-change interpretation described in the feed documentation, not independent timezone conversion of each raw stop time. Accept query timestamps with an explicit offset and use `Europe/London` for presentation. Unresolved timetable ambiguity during a clock change must be flagged rather than silently assigned to an arbitrary occurrence. [R3, section 5.3.6]

### 5.5 Stations and codes

Use `.MSN` and validated passenger-call relationships to construct the selectable station catalogue. Retain operational timing locations separately. Filter synthetic and non-passenger entries according to documented classifications and observed usable calls, not a hard-coded list of familiar names.

Normalise aliases and legacy/minor public codes without flattening underlying location identities. The sample represents Abbey Wood with both `ABWD` and `ABWDXR`; the latter has minor code `ABX` but canonical code `ABW`. [A1]

Do not merge stations by similar names, nearby coordinates or a city label. “London” is not an automatic zero-minute link among its terminals. Station grouping for search must not create transfer edges.

Reuse the app's station coordinates where available. Do not treat raw grid-reference fields as latitude/longitude. Geographical conversion and map enhancements are not prerequisites for this planner.

The current app/API catalogue contains 2,606 distinct CRS codes; the MSN contains 3,113 distinct canonical CRS codes, with 2,605 in common. Its 508 additional codes include supplementary modes, overseas and special locations, so they are not 508 missing active rail stations. NTB exists only in the current catalogue. Build a validated planner catalogue, join existing metadata deliberately, and make coordinates optional for planner locations. Preserve the existing `/api/v2/stations` contract for live features.

### 5.6 Associations and continuity

Preserve association dates, location occurrences and relationship types. Through-journey reconstruction must distinguish a passenger staying on the same train/portion from a real change of vehicle.

Never infer passenger continuity solely from a matching headcode, reused stock or an operational previous/next relationship. A split must not allow a passenger to remain on the wrong portion for their destination.

Unsupported continuity cases may be excluded from the first prototype with explicit diagnostics. They must not be turned into artificial zero-minute changes. Resolve and test the relevant cases before claiming comprehensive coverage.

---

## 6. Connection and fixed-link engine

### 6.1 Source rules to implement

The authoritative specification says that ALF supersedes FLF; fixed-link transit time is added to the station interchange allowances at both ends. ALF includes applicability and priority, with higher numbers representing higher priority. TSI overrides station defaults for an ordered arriving/departing operator pair. [R3, sections 5.10–5.12]

Keep interpretation in one reusable connection engine, shared by forward search, reverse search, result validation and later live replanning.

### 6.2 Same-station changes

For a same-station change, resolve the applicable operator-pair rule or the station default. Add a user-requested extra connection buffer once; it may increase but never reduce the required time.

The arriving operator is part of the routing state. An earlier arrival on one operator is not necessarily superior to a slightly later arrival on another when their onward interchange requirements differ.

Distinguish an initial boarding from a change. Do not silently apply an interchange penalty before the first train or after the final arrival. An optional initial boarding margin is a separate product setting and defaults to zero in this plan.

Missing connection data is not a zero-minute rule. Exclude the ambiguous connection or use an explicitly approved, visible conservative policy; record which policy produced the result.

### 6.3 Transfers between different stations

Model a transfer as distinct stages: arrival, exit allowance, link travel, entry allowance and onward boarding. Assign each allowance exactly once. Use station defaults at fixed-link endpoints unless a documented applicable rule says otherwise; do not apply a same-station TSI pair across two different stations.

Evaluate a link when the passenger can actually use it, after reaching its start, rather than at the journey's initial search time. Respect date/day/time applicability and priority before selecting a candidate. Do not choose an expired or lower-priority link just because it is quicker.

Resolve directionality, overlapping windows, tie handling and boundary inclusivity against the applicable feed specification and reference examples. Preserve origin/destination fields verbatim in raw storage. Do not silently synthesise reverse links merely because a walking route seems plausible.

Where a boundary convention remains undocumented, isolate it behind a named policy and add explicit tests. A conservative prototype can require traversal to fit within the active window, but label this as a product assumption, not a verified feed rule. Validate it before enabling unrestricted production fixed-link routing.

Waiting for a link to open, or for a changed duration/priority window, can affect which onward journey is feasible. Preserve relevant alternatives; a static footpath approximation must not discard a valid later transfer. Apply the same temporal interpretation in arrive-by search.

### 6.4 ALF versus FLF

Use ALF as the authoritative fixed-link dataset when supplied. Keep FLF for diagnostics or a separately selected legacy-only mode. Do not union both files, automatically fill every ALF gap from FLF, or use FLF to resurrect a link outside its ALF availability window.

Reject a package or disable unsupported transfer capability if the selected link source cannot be interpreted reliably. A rail-only fallback must disclose that cross-station transfers were not searched.

### 6.5 Verified sample-based connection tests

These inputs were read from the supplied files. [A1]

| Case | Expected interpretation |
|---|---|
| Kent House default | 4 minutes |
| Clapham Junction default | 10 minutes |
| Clapham Junction, `SN` → `SN` | 5 minutes |
| Victoria default | 15 minutes |
| Victoria, `SE` → `SE` | 10 minutes |
| Waterloo → Waterloo East fixed-link example | 15-minute Waterloo allowance + 1-minute link + 4-minute Waterloo East allowance = **20 minutes**, before an optional user buffer |

Test a synthetic arrival/departure pair one second below, exactly at and one second above a required connection threshold. The Waterloo example must never produce a one-minute platform-to-platform interchange.

For non-walking modes, label the result as a generic supplied transfer, not a specific live-verified Tube, tram, bus or ferry service. Do not invent intermediate stops, departure frequencies, street instructions or ticket-inclusion claims.

---

## 7. Routing engine

### 7.1 Algorithm choice

Use a public-transport routing approach. The recommended target is a RAPTOR-style, round-based implementation, adapted for this feed's transfer rules and service relationships. RAPTOR's original formulation optimises arrival time and number of transfers; use the original paper as the algorithm reference. [R4]

Begin with a small exhaustive or time-expanded reference solver for synthetic fixtures. Its purpose is to check correctness independently of the optimised router. Do not use a geographic shortest-path graph or an LLM to choose operational journeys.

### 7.2 Index preparation

Build indexes for station departures/arrivals, active service instances and ordered stopping patterns. Retain public boarding/alighting permissions, operator context, transfer rules and through-service continuity.

Resolve calendars before using trips in a date-specific index. Prewarm a configurable small window around current dates; build and cache later dates on demand. Do not expand every timetable variant onto every date through a supplementary far-future sentinel.

Account for overtaking trains. Grouping trips by the same stop sequence does not prove that the earliest departure is the earliest arrival at every downstream stop. Split non-overtaking groups or use a scan that remains correct with overtaking.

### 7.3 Search-state correctness

Retain enough state to distinguish meaningful future possibilities: arrival time, number of vehicle boardings/changes, inbound operator, relevant location/transfer state and through-service identity. Do not collapse everything into one earliest-arrival label per station.

Only prune a label when another label is no worse for **all relevant future connections**. Inbound-operator interchange differences and time-windowed links require particular care. Keep parent pointers per retained label so the final explanation matches the actual selected path.

Prevent zero-cost cycles, repeated identical boardings and unbounded walks/transfers. Use documented, configurable maximum journey duration, transfer count and search-window limits. Do not quietly present a bounded or timed-out search as exhaustive.

### 7.4 Depart-after and multiple results

Search for boardings on or after the requested instant, then return several distinct useful alternatives. Optimise actual arrival and changes, with an optional separately defined walking/transfer preference.

A single earliest-arrival query is not enough for an “earlier/later trains” interface. Use a departure-window/profile search or correctly advancing repeated searches. Include later departures rather than returning only alternative paths to the first arrival. Deduplicate by service instances, boarding/alighting occurrences and transfer sequence.

Pagination must advance deterministically and retain the dataset version and search policy. A stale cursor should expire clearly after its dataset is no longer retained, not silently switch timetables.

### 7.5 Arrive-by

Implement a genuine arrival-deadline search, preferably a reverse scan sharing the same transfer evaluator. Preserve the forward meaning of the arriving and departing operators when searching backward. Reverse lookup must not turn a directional connection rule into its inverse.

A forward search from an arbitrary guessed time followed by filtering is not an acceptable arrive-by implementation. Validate latest feasible departure against the reference solver, including after-midnight and fixed-link cases.

### 7.6 Changes and journey reconstruction

Define `changes` consistently as switches between passenger vehicle legs. Walking legs do not count as a boarding; a generic non-walking transfer does. A correctly established through service remains one vehicle ride even when multiple source segments are involved. Provide `railChanges` separately only if the existing UI needs that different concept.

A change requires alighting and boarding permissions plus the resolved connection allowance. Passing a station does not make it an interchange. Do not penalise a passenger for staying on the same train at an intermediate call.

Return complete, chronological legs and explicit transfer instructions. Reject any reconstructed itinerary that fails an independent final feasibility check.

### 7.7 Ranking and search budgets

Default to useful scheduled choices: earliest arrival and reasonable alternatives with fewer changes. Preserve genuine trade-offs rather than sorting only by departure time or keeping the single shortest duration.

Proposed initial policy: a two-hour departure window, up to two changes, five returned journeys and a 24-hour maximum total journey duration. These are configurable product limits, not facts about the feed. Widening a sparse-service search must be explicit in response metadata; never silently truncate an overnight journey to the calendar day.

If a search limit is reached, return a `searchTruncated` warning or a distinct failure. “No journey found within this window” must not be presented as “no trains exist today”.

---

## 8. API contract

Integrate with the existing API's conventions. The following is a proposed shape; preserve established route naming and response envelopes where appropriate.

```text
GET  /api/v3/journey-planner/stations?q=kent
GET  /api/v3/journey-planner/status
POST /api/v3/journey-planner/search
GET  /api/v3/journey-planner/journeys/{id}
```

Keep administrative import, activation, explanation and rollback endpoints private. Do not expose source download credentials or raw diagnostic records publicly.

### 8.1 Example request

```json
{
  "origin": "KTH",
  "destination": "VIC",
  "time": "2026-09-08T07:00:00+01:00",
  "timeType": "departAfter",
  "maxChanges": 2,
  "extraConnectionMinutes": 0,
  "allowedModes": ["rail", "replacementBus", "walk", "tubeTransfer"],
  "limit": 5
}
```

The date above deliberately targets the supplied test snapshot. It must not become a hard-coded application date.

Optional date/time is an app interaction, not an ambiguous API timestamp. For "Depart now", the client resolves the current instant when submitting and sends it as `time` with `timeType: departAfter`. Explicit "Depart at" also maps to `departAfter`; "Arrive by" maps to `arriveBy`. Preserve the user's relative/explicit intent in recent searches separately from this resolved request.

Validate public station identifiers, time/offset, allowed modes, supported horizon and bounded numeric fields. Translate aliases before searching. Reject unknown inputs explicitly. For identical origin and destination, return a documented already-at-destination result rather than an artificial rail loop.

### 8.2 Response requirements

Return:

| Area | Required information |
|---|---|
| Search metadata | Normalised request, actual searched interval, applied limits and any truncation |
| Timetable metadata | Dataset version, source generation date, import time, freshness and coverage basis |
| Journey summary | Stable-within-version opaque ID, scheduled start/end, duration, changes and supported ranking labels |
| Vehicle leg | Mode, service identity, origin service date, operator, boarding/alighting locations, scheduled times and relevant calling points |
| Transfer leg | Endpoints, mode, allowance/travel breakdown, generic-transfer label and any caveats |
| Live fields | Explicitly absent/unavailable until live integration; never default to “on time” |
| Warnings | Stale data, scheduled-only, generic transfer, unsupported excluded capability, incomplete search or known ambiguity |
| Pagination | Version-bound earlier/later cursor or equivalent |

Internally preserve the rule identifiers and selected variant identity needed to explain each result. Public payloads need not include full raw CIF records.

### 8.3 Scheduled and live values

Keep scheduled, expected and actual times separate. Use offset-aware timestamps in payloads and `Europe/London` for rail-time display. A timetable platform, when present, is scheduled information, not a confirmed live platform.

Use explicit states such as `scheduledOnly`, `liveChecked`, `livePartial` and `liveUnavailable`. Avoid a single `isLive=true` flag that hides partial coverage.

### 8.4 Errors and caching

Distinguish invalid station, unsupported date, unavailable dataset, stale-policy rejection, search timeout and a genuine empty result. Follow existing HTTP conventions and include machine-readable error codes.

Cache keys must include dataset version, normalised query, mode filters, buffer, limits and routing-policy version. Later, include live-overlay version/freshness. Rounding a requested time for caching must not accidentally include a train that has already departed before the user's actual requested instant.

Public planner station, status, search and journey-detail endpoints must not require login, a subscription, an API key or an app-only access token for the prototype. An app feature flag controls presentation, not API entitlement. Keep import/activation/rollback/explanation private. Bounded work queues, numeric limits and ordinary rate limiting protect availability without introducing a commercial access gate. Existing installation identifiers are not authentication.

---

## 9. TrainTrack UK integration

### 9.1 Replace the Add Journey entry point

Replace the current Add Journey presentation with the planner, using its existing navigation entry points rather than adding a tab. Introduce this behind an app feature flag during development. The primary flow is "Find journeys" -> results -> details. Existing departures, saved journeys and live tracking must continue independently of timetable availability.

The owner has confirmed a secondary **"Add a saved route"** entry. It opens the existing manual flow for saving routes/favourites, intermediate stops, automatic return-route behaviour, starting journeys and scheduling notifications. Preserve existing entry context such as favourite prefilling. This secondary action remains usable when the planner dataset is unavailable. It does not convert a selected planner itinerary into a saved or tracked journey.

Planner searches and detail views must not create saved journeys, favourites, reverse journeys, notifications or tracking sessions. A route already present in My Journeys must still be searchable. Via-station constraints are not part of the first planner; its connections are computed automatically. Manual intermediate stops remain in the secondary saved-route flow.

### 9.2 Optional date and time

Use a native form with origin, destination, swap and a "When" control:

| Selection | Behaviour |
|---|---|
| Depart now | Default; no date/time input required. Resolve now when submitting, including after a form has been left open |
| Depart at | Show date/time controls; request a depart-after search |
| Arrive by | Show date/time controls; request an arrival-deadline search |

Switching back to Depart now removes the explicit date constraint. Display and interpret railway date/time choices in `Europe/London`, even when the device is abroad, and send offset-aware timestamps. Make dates visible for overnight journeys. Do not use the existing label "Schedule journey" for this control; that label belongs to notification scheduling in the secondary flow.

Reuse station-picker presentation but require explicit selection or an unambiguous exact match. Do not silently choose the first suggestion. Constrain selectable dates using planner status and validate again on the API, since coverage can change while the form is open.

### 9.3 Results, details and state ownership

Results show scheduled departure, arrival, duration, changes and operators, with earlier/later navigation. Details show ordered vehicle and transfer legs, calling points and connection instructions. Use service-level operator branding already supplied by the API; station ownership must not determine train styling.

Introduce a focused planner client, a screen-owned observable state store and separate `PlannedJourney`, vehicle-leg and transfer-leg models. Existing `Journey`/`JourneyGroup` represent reusable routes, while `DepartureV2` and `JourneyItineraryBuilder` are tied to live departures. Reuse their presentation patterns where appropriate, without coercing dated planner data into those models. Follow existing API host selection/networking conventions, and support typed errors, cancellation and rejection of late responses from superseded searches.

Always show scheduled-only status; generic Tube/walking transfers remain labelled honestly. Provide specific states for unsupported dates, no result in the searched window, loading, maintenance, stale data and expired itinerary IDs. A valid empty result may offer an explicit wider-window search. A cached itinerary, if retained for display, is labelled with its original freshness and refreshed before being presented as current.

Check Dynamic Type, VoiceOver, light/dark appearances, iPad layout, keyboard/focus behaviour and existing Add Journey navigation. Do not add watchOS, widgets, Live Activities or notification work beyond preserving the existing secondary flow.

### 9.4 Recent searches

The owner requires recent searches to be visible and reusable. Proposed prototype defaults:

- Show **Recent searches** on the planner entry screen, newest first, with station names and the requested time mode/date.
- Keep the last **10** completed searches on the device across app launches. Include valid searches returning no journeys; exclude invalid submissions and network/server failures.
- Store query intent: canonical station codes, display-name snapshots, relative Depart now versus explicit depart/arrive time, any applied user filters, and last-searched time. Do not use old itinerary IDs or cached result lists as a recent-search record.
- Deduplicate by route, time intent and filters. Depart now searches for the same route coalesce regardless of their resolved execution timestamp; distinct explicit dates/times remain distinct. A repeat moves to the top.
- Tapping a recent item prefills the form for review. Depart now uses the current time on resubmission. Future explicit times are restored; past explicit times are visibly flagged and require a new date/time or an explicit switch to Depart now. Do not silently shift dates.
- On submission, search the active dataset again and revalidate station identifiers and coverage. A removed/unsupported station requests reselection without losing the rest of the form.
- Provide individual removal and Clear recent searches, plus a simple empty state. Clearing recent searches must not affect saved routes or journey history.

Use a small versioned local store with optional-date handling. This feature needs no login, backend history endpoint, device-token lookup or cross-device sync. Local query history and the server's performance cache have different purposes and must not be conflated.

---

## 10. Live-aware planning — later, still journey planning only

Darwin supplies predictions, platforms, schedule changes and cancellations; it is complementary to this planned timetable. Reuse TrainTrack UK's existing authorised integration where possible. [R5]

The initial scheduled planner must work without Darwin. Later, add a separate runtime overlay rather than mutating the imported baseline. Preserve dataset version, overlay version, last update and matching confidence.

Map live services using available service identity, origin date and validated calling-pattern information. A loose match on station and departure minute is not sufficient. Apply no update when the identity is ambiguous; report live coverage as partial.

Handle cancellation, reinstatement, skipped stops, shortened services, additional services and changed times. Distinguish absence of a live update from confirmation that a service is running normally.

A true live planner must incorporate live changes into candidate generation and feasibility. Annotating only the top static journeys can miss a delayed connection that becomes useful or an additional service. A staged enrichment-only implementation is acceptable, but label it as live checking of scheduled candidates, not complete live-optimal routing.

After applying updates, revalidate each connection. If a connection is no longer feasible, replace it or clearly mark the itinerary unusable; do not leave an apparently valid connection with two contradictory time labels. Respect publication/suppression instructions in the applicable live feed.

---

## 11. Refreshes, validation and operations

### 11.1 Start with complete snapshots

For the prototype, import complete packages and replace the active snapshot. The owner expects monthly full downloads. Never accumulate successive packages as additional services.

The sample contains no `.CFA` update file. Supporting update packages is a distinct implementation milestone: source transactions and refreshed supporting files must be applied according to the subscribed feed's delivery semantics. [A1][R3, section 4]

Do not advertise daily timetable freshness from an older full file simply because Darwin is connected. If production freshness requires incremental updates, complete and test their importer before launch. Validate update continuity, duplicates, revisions, deletions, sequence rollover and resynchronisation from a full snapshot. Never apply an update to the wrong baseline.

### 11.2 Acquisition and freshness policy

First support the available local extracted directory and ZIP files. Plan an S3 acquisition adapter for the expected National Rail monthly full delivery, but confirm bucket ownership, region, key/package layout, read permissions and the signal that an upload is complete before configuring it. S3 delivery is likely, not yet an established integration. Do not guess a provider endpoint or place credentials in source control or logs.

Use a complete immutable package or a completion manifest, copy it to staging, verify its content and then run the same import/validation path used locally. Support repeat delivery idempotently. A re-download, copy or re-import must not advance the source generation date. Object modification time, source publication date, retrieval time and activation time remain separate.

Make discovery cadence, expected next delivery and acceptable staleness explicit configuration based on the monthly product. Do not choose a daily-expiry threshold that makes a normal monthly snapshot unusable for most of its delivery cycle. Conversely, monthly delivery does not establish daily amendment completeness. Show the publication date and explain that later timetable changes may be missing.

A failed scheduled download/import keeps the last validated dataset and reports its age. Stop serving searches when the separately agreed maximum stale age or supported horizon is exceeded. The stale threshold and any delivery grace period remain open operational decisions; do not treat a successful repeat import as fresh delivery.

Ad hoc incremental availability remains to be confirmed. No incremental downloader/importer is required to prove the scheduled prototype, but the production freshness decision must establish whether monthly snapshots meet the intended use or whether updates are required before broader release. Darwin enrichment alone does not resolve missing baseline timetable amendments.

Record provider attribution and applicable terms for the actual subscribed dataset. Public deployment is a release gate; this document makes no entitlement or accreditation claim.

### 11.3 Dataset quality gates

Validate manifest consistency, critical parser errors, missing locations, normalised-code conflicts, malformed calendars, source transaction integrity, selected-service conflicts, negative/implausible chronology and invalid transfer rules.

Measure active passenger services per representative date, per region/operator and around timetable boundaries. Compare distributions with the previous import. The sudden loss of a large part of the network must block activation or require review, not pass because the file parsed successfully.

Account for records intentionally excluded by mode or unsupported semantics. Report counts and affected journeys/locations. Do not hide incomplete coverage behind a successful import exit code.

### 11.4 Operational outputs

Provide import logs, a machine-readable validation report, a human-readable summary, search latency metrics, cache statistics, dataset age and an activation history. Record routing decisions without retaining users' detailed travel searches longer than operationally necessary.

An import job must have resource limits, a lock against conflicting imports and a cleanup policy. Preserve the active and rollback datasets when deleting old staging data.

### 11.5 Proposed performance targets

Treat these as initial engineering targets to measure and revise, not benchmark results:

| Metric | Initial target |
|---|---|
| Warm direct query, backend only | p95 below 250 ms |
| Warm connecting query, backend only | p95 below 1 second |
| Cold date preparation/search | Bounded and cancellable; report separately from warm queries |
| Full import | Streaming, observable and within the host's configured memory/disk budget |
| Activation | No partially visible dataset and no invalidated in-flight request |

Record hardware, dataset hash, cold/warm state, concurrency and supported query limits with every benchmark. Measure peak import memory, steady-state search memory and dual-version activation memory. Do not promise that this national timetable fits a particular VM until measured there.

---

## 12. Milestones and acceptance gates

### Milestone 0 — Repository reconnaissance

Inspect repository instructions, backend, app models, station identifiers, live-data adapters, deployment and tests. Record the intended module locations, stack decision, feature flag and authorised input configuration in a short architecture decision record.

**Done when:** the integration points are identified without speculative rewrites, and tests/build commands for the existing application have been run or their environmental blockers recorded.

**Planning reconnaissance already performed:** API integration is within the existing Express/ES-module backend, with planner modules, extracted route registration and the existing Node test runner. iOS integration replaces Add Journey, uses separate dated models and preserves the existing manual flow. The existing API suite passed 23 initial assertions before hanging in an unrelated device-deletion test fixture; it was interrupted. No iOS build or routing benchmark was run, and this milestone is not marked complete by the planning review.

### Milestone 1 — Archive inspector and parsers

Implement local directory/ZIP inspection, manifest discovery, member/package checksums, streaming parsers, source-location diagnostics and a reusable synthetic fixture builder. Produce the inventory in Section 2 from the supplied files; validate ZIP integrity when the original or another archive becomes available.

**Done when:** the verified counts are reproduced, `END` is not counted as a link, file-specific record lengths are handled correctly and malformed/truncated fixtures fail explicitly. No routing UI is required yet.

### Milestone 2 — Normalised snapshot and date resolver

Persist stations, schedules, calendars, calls, interchange data, fixed links and associations. Implement variant resolution, passenger-call classification, overnight chronology and dataset provenance. Add versioned snapshot activation.

**Done when:** a given date produces explainable service instances; overlay/cancellation tests pass; re-import is idempotent; a failed candidate cannot replace the active dataset.

### Milestone 3 — Direct-journey vertical slice

Implement station search, direct depart-after routing, the private/debug explanation and a basic backend API. Exercise the supplied Kent House fixture plus synthetic overnight and overtaking examples. Integrate a minimal feature-flagged iOS result screen.

**Done when:** a user can search and view a genuine direct scheduled journey end to end, with no invented passenger calls or live-status claims.

This is an internal integration checkpoint. The agreed usable prototype additionally requires Milestones 4 and 5.

### Milestone 4 — Changes and supplied transfer links

Implement the shared connection evaluator, bounded multi-criteria routing, operator-context labels, mode handling and supported fixed links. Add one- and two-change journeys with accurate reconstruction.

**Done when:** connection thresholds, operator overrides, transfer allowances, availability/priority and duplicate-link tests pass against the reference solver. Unsupported link semantics cannot silently enter production results.

### Milestone 5 — Complete scheduled search

Implement arrive-by, departure alternatives, earlier/later navigation, repeated-location handling and supported through-service cases. Complete API error/freshness states, the replacement Add Journey form with optional date/time, planner detail models, recent-search persistence/reuse, and the secondary existing saved-route flow.

**Done when:** connecting journeys and both time modes work end to end; forward/reverse correctness and the full test matrix pass; pagination is stable; recent searches survive restart and rerun correctly; existing route actions remain usable; searches do not save or start journeys; public planner endpoints have no authentication/subscription gate; limitations are explicit.

### Milestone 6 — Freshness and operational readiness

Implement authorised acquisition for the confirmed delivery arrangement, monthly full-refresh handling, monitoring, regression comparisons, resource limits and rollback. Confirm S3 details and a cadence-aware stale policy. Add incremental updates here if they become required by the production freshness policy; their ad hoc delivery remains unconfirmed.

**Done when:** a fresh authorised dataset passes validation on the target host, an import-failure drill preserves service, and the acceptance sample shows no unexplained infeasible journeys.

### Milestone 7 — Optional live integration

Connect the existing live provider, validate service matching and distinguish enrichment-only from genuinely live-aware search. Recheck connections and expose partial/unavailable live coverage.

**Done when:** cancellation, late running, reinstatement and missed-connection tests pass without corrupting the planned snapshot. This milestone does not introduce ticketing or change the core scope.

At the end of each milestone, record changed files, reproducible commands, test results, measured limitations and the next uncompleted milestone. Do not treat placeholder methods, empty successful responses or mocked national results as completion.

---

## 13. Test strategy

### 13.1 Independently constructed synthetic fixtures

Use tiny, human-readable service definitions to generate source-format fixtures. Keep expected answers independent of the production parser/router. Avoid checking in large licensed data extracts when a synthetic example is sufficient.

| Test group | Required cases |
|---|---|
| Archive/parser | Wrong member name, manifest mismatch, duplicate member, truncation, bad ZIP path, record-width differences, unknown critical code |
| Calendars | Weekday/weekend, inclusive boundaries, holiday handling where supported, expired schedule, far-future sentinel, ambiguous two-digit year policy |
| Variants/updates | Permanent only, overlay on one date, cancellation on one date, reinstatement/revision, new STP, conflicting candidates, update applied twice or to wrong baseline |
| Passenger calls | Pass only, board only, alight only, request-stop handling, origin/terminus restrictions, midnight public-time ambiguity |
| Chronology | Half-minute times, overnight origin date, repeated location, long service spanning the search date, spring/autumn clock changes |
| Same-station transfer | Default time, directional operator pair, exact threshold, extra buffer, missing rule, arriving-operator label dominance |
| Fixed links | Both endpoint allowances, no double counting, priority conflict, expiry, time-window boundary, wait-until-open, directionality, legacy fallback disabled |
| Routing | Direct, one/two changes, overtaking, loops, unavailable connection, equivalent journeys, slower direct versus faster connecting alternative |
| Through journeys | Stay aboard, join/divide, wrong portion, operational association not passenger continuity |
| Reverse search | Latest departure, directional TSI, fixed-link timing, midnight, parity with reference solver |
| API/cache | Unsupported date, no result in window, exact query time, stale cursor, version change, concurrent requests and bounded timeout |
| App form/navigation | Depart now evaluated on submit, explicit depart/arrive mode, exact station selection, already-saved route still searchable, secondary saved-route flow and favourite context preserved |
| Recent searches | Persistence, cap/deduplication, relative-now reuse, future/past explicit dates, removed station after refresh, successful empty result, failed request excluded, individual removal/clear without affecting saved journeys |
| Public planner access | Station/status/search/detail endpoints usable without login or paid entitlement; administrative operations remain private |
| Monthly acquisition | Complete upload detection, duplicate delivery, unchanged source age on re-import, missed monthly delivery, failure preserves active snapshot, maximum stale age and horizon enforced |
| Live, later | No update, ambiguous identity, cancellation/reinstatement, skipped call, newly feasible/infeasible connection, additional service |

Property-based tests should verify chronology, valid boarding/alighting, active calendars and connection feasibility for every generated result. An exhaustive solver on tiny networks should agree with the optimised engine within identical search bounds.

### 13.2 Verified direct-service regression fixture

The supplied main file contains this planned service definition. [A1]

```text
UID:                    P86964
Operator:               SE
Origin service:         Orpington -> London Victoria
Permanent calendar:     Monday-Friday, 18 May-11 December 2026
Passenger test date:    Tuesday 8 September 2026
Board:                  Kent House / KTH / KENTHOS at 07:12
Alight:                 London Victoria / VIC / VICTRIE at 07:33
Between these points:   Penge East, Sydenham Hill, West Dulwich,
                        Herne Hill, Brixton
Expected direct ride:   21 minutes, zero changes
```

The file also contains a `C` record for the same UID on **31 August 2026**. Use this as an additional resolver test after considering all matching records. It must not cancel the 8 September instance. Do not bypass the resolver by searching only the permanent record.

These are snapshot-based expectations, not live-running evidence or promises about a future extract. Pin this regression to measured source-member/package hashes, or to the archive hash once verified, and use separate synthetic tests for general behaviour.

### 13.3 Broader validation searches

Create a recorded comparison set covering local, intercity, cross-London, rural, weekend and overnight journeys. Useful station pairs include Kent House–Victoria, Kent House–Brighton, Beckenham Junction–London Bridge, Brighton–Cambridge, Manchester Piccadilly–Leeds, Birmingham New Street–Edinburgh and a validated overnight sleeper corridor.

For each comparison, record the exact station codes, date/time, mode filters, buffer, source generation date and search bounds. Use dates covered by the tested snapshot. Do not compare an old extract to today's live planner and classify every difference as an algorithm bug.

Use an established planner as a useful reference, not an unquestioned oracle or a scraped production dependency. Investigate discrepancies: amended data, live information, transfer policy, unsupported modes and different search limits can explain legitimate differences.

### 13.4 Explainability as a release criterion

For every returned journey, an internal explanation must identify selected schedule variants and operating dates, actual passenger calls, connection rules/allowances, fixed-link applicability and total chronology. A reviewer should be able to reproduce why each change is allowed.

A result that merely looks plausible is not sufficient evidence of correctness.

---

## 14. Required deliverables and commands

Deliver the importer, normalised schema, resolver, connection engine, routing module, open public API integration, feature-flagged replacement Add Journey flow, recent searches, preserved secondary saved-route actions, fixtures, automated tests and an operations runbook. Keep any necessary schema migrations, recent-search persistence and routing-index formats versioned.

Implement equivalents of these commands using the project's existing tooling; they are proposed interfaces, not commands that already exist:

```bash
planner inspect --source "$TIMETABLE_SOURCE_PATH"
planner import --source "$TIMETABLE_SOURCE_PATH" --mode full --staging ./var/planner/candidate
planner validate --dataset ./var/planner/candidate
planner query --dataset ./var/planner/candidate --from KTH --to VIC \
  --depart-after '2026-09-08T07:00:00+01:00' --explain
planner benchmark --dataset ./var/planner/candidate --cases tests/planner/search-cases.json
planner activate --dataset ./var/planner/candidate
planner status
planner rollback --version '<previous-version>'
```

Commands that affect activation must require suitable permissions. Local test commands should work without cloud credentials. Full-archive tests may run separately from fast CI; the synthetic correctness suite should run on every change.

`TIMETABLE_SOURCE_PATH` may identify the supplied extracted directory or a ZIP. These are illustrative local commands; production staging and active datasets must use the configured data directory outside deployed code.

Document how to obtain/configure an authorised fresh input, run a local import, reproduce sample searches, interpret validation failures, measure host resources, activate a candidate and roll back. Keep generated datasets and credentials out of Git.

### Final completion checklist

- [x] Journey-planning scope preserved; no retail or ticketing implementation added.
- [x] Supplied extracted package imported and file-specific counts reproduced; ZIP properties verified separately when an archive is available.
- [x] Passenger calls and service-day calendars resolved correctly.
- [x] Amendments and cancellations in full snapshots tested independently; incremental input is explicitly rejected.
- [x] Same-station and cross-station connection rules implemented without invented shortcuts.
- [x] Direct, connecting, depart-after and arrive-by searches pass reference-solver tests.
- [x] Multiple useful departures and stable earlier/later navigation work.
- [x] Feature-enabled Add Journey opens the planner with optional date/time and a preserved secondary saved-route flow; Release remains off by default.
- [x] Recent searches persist, can be removed/cleared, and rerun against the active dataset with correct date intent.
- [x] Search/details have no saved-journey or tracking side effects; public planner API access remains ungated.
- [x] Overnight, clock-change and supported association behaviour is explicit and tested.
- [x] Scheduled-only and incomplete/live-unavailable states are honest.
- [x] Active dataset remains available through a failed refresh and can be rolled back.
- [ ] Performance measured on the deployment host; no untested sizing claims.
- [ ] Fresh authorised production input and applicable attribution/terms recorded before launch.
- [ ] Monthly delivery and stale policy are explicit; S3 configuration and the need for incremental updates are resolved before production operation.

---

## 15. Sources and implementation references

**[A1] User-supplied timetable package, inspected 15 September 2026.** The original plan reports `timetable_full.zip` and its SHA-256. Repository reconnaissance independently inspected all nine extracted files under `/Users/mwagstaff/dev/train-track-uk/api/train-track-api/resources/timetable_full`, reproducing the sizes, counts and direct-service fixture. No local timetable ZIP was available to verify its checksum or compressed integrity. These are observations of this snapshot, not universal feed limits.

**[R1] Rail Delivery Group — Timetable data.** Identifies the timetable-feed family and its official specification. Accessed 15 September 2026.

```text
https://www.raildeliverygroup.com/our-services/essential-services/rail-data/timetable-data.html
```

**[R2] RDG / RSP ASSIST — Public documentation.** Publication index for RSPS5046 and related reference-code and Darwin specifications. Use this stable index to locate the applicable version rather than relying indefinitely on a generated download URL. Accessed 15 September 2026.

```text
https://www.rspaccreditation.org/publicDocumentation.php
```

**[R3] RSPS5046 P-04-02 — Timetable Information Data Feed Interface Specification.** Issued 3 June 2025; inspected for this plan. Consult section 4 for package types, 5.3–5.5 for schedule interpretation/layouts, 5.8 for supplementary schedules, 5.10–5.12 for fixed links/interchanges and 5.13 for station data. This plan does not reproduce the field-layout tables. Check product/version compatibility and use the original source when implementing.

```text
https://www.rspaccreditation.org/downloadPublic.php?did=c5VkXAQOgMj8q024cALYymTpxTFaroiwLL7mvDA0A3UB5FJKuO
```

**[R4] Delling, Pajor and Werneck — Round-Based Public Transit Routing, ALENEX 2012.** Original RAPTOR algorithm reference. Its baseline assumptions do not remove the need to model this planner's operator-dependent and time-windowed transfers.

```text
https://www.microsoft.com/en-us/research/publication/round-based-public-transit-routing/
```

**[R5] National Rail — Darwin Data Feeds.** Scope of live running information; relevant only to the later live-aware milestone. Accessed 15 September 2026. Check the user's actual subscribed interface and applicable documentation before coding an adapter.

```text
https://www.nationalrail.co.uk/developers/darwin-data-feeds/
```

Architecture choices, API shapes, numerical search limits, engineering targets, milestones and synthetic-test requirements in this document are proposed implementation decisions, not claims that they are mandated by RDG or already exist in TrainTrack UK.
