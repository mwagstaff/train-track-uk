# TrainTrack UK — Siri and App Intents implementation plan

**Prepared:** 15 September 2026  
**Audience:** Codex working in the existing TrainTrack UK repository  
**Primary goal:** Answer live train questions aloud, without requiring the user to navigate through the app.  
**Default implementation scope:** Phases 0–4 below. Later phases are separately gated enhancements.

**Implementation decisions (15 September 2026):** User approved locked-device answers where Siri permits, live-unavailable explanations with no timetable fallback, iPhone/AirPods first, single-leg favourites with persistent group IDs for future multi-leg support, and optional custom route names. Local implementation and verification are recorded in [`docs/siri-shortcuts.md`](docs/siri-shortcuts.md). Physical Siri/device checks and backend rollout must be completed before claiming the core release is device-verified; phases 5–7 remain separate.

**Initial testing follow-up:** Direct saved routes now include both Favourites and My Journeys. Saved outward/return directions share a name, and default/named lookup chooses the nearer departure station when a usable, already-authorized location is available. An optional departure-station override fixes the direction; otherwise Siri asks when location is unavailable or ambiguous. This pairing does not add journeys requiring a change. Passed departure times and delays without a new time have distinct, plain-language explanations. The named-route example appears independently of the default selection.

> **Instructions to Codex:** Inspect the repository, then implement the core scope in small, buildable increments. Reuse existing departures, favourites, tracking, networking and navigation code. Do not stop after producing another plan. Preserve existing functionality and saved Shortcuts. Verify API signatures against the installed SDK, run the available builds and tests, and report exactly what passed, failed or needs physical-device testing. Do not invent Apple schemas, backend endpoints or live information.

## 1. Product outcome and boundaries

The first experience to deliver is:

**User:** “Hey Siri, get my next train in TrainTrack UK.”  
**Siri:** “Your next train from Kent House to London Victoria is at 8:42, in eight minutes, from platform 2. It’s running on time.”

This is an illustrative response using synthetic data, not a real departure. The app must assemble every factual part of the answer from the resolved route and current service data.

The user selects a default saved route in TrainTrack UK. Siri retrieves current departures on invocation, speaks a short answer and optionally shows a compact result card. Also expose a configurable origin/destination action in Shortcuts and an explicit command that prompts for missing stations.

The desired richer wording is:

> “Hey Siri, when’s my next train from Kent House to Victoria in TrainTrack UK?”

Treat this exact free-form wording as an **on-device validation target**, not an automatic consequence of implementing an intent. Standard App Shortcut phrases require the application-name placeholder and support at most one interpolated intent parameter in Apple’s documented model. An intent itself can have multiple parameters; this phrase limitation does not prevent a configurable two-station action.[^shortcuts]

Use saved-route entities to represent both stations in one phrase parameter. Keep prompted station selection as the reliable general-purpose fallback. Do not hard-code Kent House or London Victoria as production defaults.

### Scope

| Delivery | Included |
|---|---|
| Core release: Phases 0–4 | Next train on a default route; named saved routes; configurable two-station departures; spoken answers; result card; setup/help; tests. Reuse existing tracked-journey status/platform services where available. |
| Follow-on: Phase 5 | Start/stop tracking and open a selected departure, using existing tracking and Live Activity infrastructure. |
| Follow-on: Phase 6 | Suitable iOS 27 schemas, in-app search and onscreen context, only after SDK and device validation. |
| Separate dependency: Phase 7 | Full journey-planning intents, only when the timetable-based planner is available. |

**Not included:** ticketing, fares, ticket validity, reservations, retailing, a new journey-planning engine, a custom voice assistant, an LLM service, or changes to TubeTrack UK, BikeSpot London or Top Scores.

## 2. Phase 0 — Repository and SDK audit

The previously used repository location is `/Users/mwagstaff/dev/train-track-uk`. Use the actual current checkout; do not assume this absolute path exists in every Codex environment.

Before modifying code, inspect the following and write a short implementation note in the repository:

| Area | Establish before implementation |
|---|---|
| Build configuration | Actual project/workspace, schemes, minimum iOS/watchOS versions, installed Xcode/SDK versions and existing test targets. |
| Existing Siri integration | `AppIntent`, `AppShortcutsProvider`, `AppEntity`, SiriKit definitions/extensions, donations, shortcut identifiers and localisation resources. |
| Train data | Departures API client, destination filtering, service-detail lookup, stable service identity, timestamps, cancellation/status parsing and station catalogue. |
| User state | Favourite-route models, persistence, default selections, active journey and relevant App Group/Watch synchronisation. |
| UI/system integration | Navigation/deep links, widgets, Live Activities, notifications and shared packages, including `JourneyActivityShared` if present. |

Preserve existing intent identities, parameter contracts and entity IDs wherever practical. Do not rename or remove an existing Siri action merely to match the suggested names in this document. Avoid introducing a second shortcut provider or a new extension without an architectural reason.

Use the installed SDK and official references to check `supportedModes`, `authenticationPolicy`, entity queries, snippet APIs and availability. Do not raise the app’s minimum deployment target just to add an optional iOS 27 feature. Isolate new APIs with appropriate availability and build-time handling; a runtime check alone does not make an unknown symbol compile in an older SDK.

**Exit condition:** Identify concrete existing types to reuse, the smallest required refactors, compatibility constraints and the first testable vertical slice. Keep unrelated refactoring out of scope.

## 3. Phase 1 — A shared, testable lookup layer

### 3.1 Architecture

```text
Siri / Shortcuts
        |
App Intent: resolve parameters and enforce execution policy
        |
Existing app services through a small testable adapter
        |
Existing backend / live-data provider / local user state
        |
Normalised result with provenance and freshness
        |
Spoken response + structured output + optional SwiftUI card
```

Keep railway selection and status logic outside intent types and SwiftUI views. The same logic should remain usable by the normal app UI. Inject the clock, data client and stores so tests are deterministic.

Read-only intents must work from a cold invocation with no departure screen loaded. Do not depend on a scene’s view model, a selected tab, or in-memory state initialised by `onAppear`. Initialise dependencies in the actual execution process. If a separate extension is already used, verify its access to required shared storage and credentials instead of assuming the app’s memory is available there.

Use the existing concurrency and persistence conventions. Avoid synchronous network work, broad unnecessary `@MainActor` isolation, force unwraps and detached tasks that outlive the request without a reason.

### 3.2 Entity model

These are suggested application types, **not Apple-provided railway schemas**. Adapt them to existing types rather than duplicating models.

| Entity | Identity and contents | Query behaviour |
|---|---|---|
| `StationEntity` | Existing stable catalogue ID; canonical name; useful disambiguation text. | Resolve by ID, search names/aliases, suggest a bounded set of relevant stations. |
| `SavedRouteEntity` | Existing persistent route ID; origin and destination IDs; user label. | Resolve after relaunch; suggest favourites; distinguish duplicate labels. |
| `DepartureEntity` | Existing provider service identity, operating date and any boarding-stop discriminator required for uniqueness. | Rehydrate service information; handle expired/unresolvable services without silently selecting a different train. |

Apple’s entity/query model supports persistent identifier resolution and string-based lookup.[^entities] Keep live running state separate from identity: “the 8:42” is not a globally unique service identifier.

Do not create fresh UUIDs every time favourites are queried. A route rename should preserve its ID. A deleted route should produce a helpful missing-route result, not unexpectedly switch a saved shortcut to another route.

### 3.3 Station and route resolution

Resolve against the app’s real station catalogue, including its existing identifiers and aliases. Do not invent station codes or create a Siri-only station database.

Match canonical names and known aliases first, normalising case, punctuation and whitespace. Bound fuzzy matching and return genuine candidates for disambiguation rather than guessing from a weak match. Rank favourites sensibly, but do not globally equate “Victoria” with London Victoria. A saved route already supplies an unambiguous station ID; an unresolved spoken name may require a question.

A station query may not have access to another parameter’s value. Do not make its implementation depend on knowing the origin. Apply route-aware validation after parameter resolution, or use an explicit supported disambiguation flow.

Reject identical origin and destination. Ask only for missing or ambiguous information. Do not request location access for an explicitly supplied route.

### 3.4 Normalised result contract

Use existing domain models where possible, with an adapter carrying these concepts:

| Concept | Required meaning |
|---|---|
| Resolved route | Canonical origin and destination identity, not only spoken text. |
| Service identity | Identity suitable for later detail lookup and tracking. |
| Timing | Scheduled and expected departure separately; destination arrival when available; operating date. |
| Calling pattern | Evidence that the train permits the requested journey, or an authoritative route-filtered response. |
| Status | Cancellation, departure/arrival completion, delay with/without an estimate, platform availability and advertised transport mode. |
| Freshness | Provider observation timestamp where supplied; backend snapshot/cache timestamp; client fetch time. Do not conflate these. |
| Coverage | Search window and completeness/limitations where known. |
| Outcome | Live result, labelled scheduled-only result, no matching direct service in the searched window, unavailable data, invalid route, or needs clarification. |

Unknown values remain unknown. A successful HTTP response alone does not prove that the underlying running information is fresh.

### 3.5 Departure-selection rules

Implement and unit-test the following product rules, adapting them to the provider’s documented semantics:

1. Request services for the origin and destination using existing filtering where available. Otherwise verify the destination occurs **after the boarding call**, with the necessary passenger pickup/set-down permissions. Do not filter only by the train’s final destination.
2. Exclude trains known to have departed the boarding station, cancelled options, and trains that no longer call at the destination. Do not exclude an otherwise valid delayed train solely because its scheduled departure is in the past.
3. Order eligible departures by current expected departure when a reliable estimate exists, otherwise by scheduled departure with the appropriate uncertainty. A train delayed without an estimate must not be confidently ranked using its obsolete scheduled time.
4. Define “next train” as the next eligible departure, not automatically the journey with the earliest arrival. Respect an existing user-configured departure buffer; otherwise do not silently add one.
5. Return up to three options for display/Shortcuts, normally speaking only the first. Mention a materially relevant cancellation or uncertainty succinctly.

Preserve absolute dates and the operating date. Interpret and present UK railway times in `Europe/London`, even when the phone is abroad. Test midnight, delayed services crossing dates and daylight-saving transitions; do not join a timetable clock string to the phone’s current calendar date.

An empty or truncated board is not proof that no trains run today. Say there are no matching direct departures in the searched window when that is all the data establishes. Label replacement buses explicitly when returned by the provider; never call one a train. Do not invent connections to fill an empty direct-service result.

### 3.6 Freshness, networking and failures

Reuse the existing client’s authentication, cache and provider limits. Do not add a second direct-to-provider path or put server secrets into the app.

Make one bounded request sequence per invocation; no continuing polling after the answer. Reuse a fresh cached snapshot only under a documented policy. As an **initial product default to validate**, consider a maximum live snapshot age of 60 seconds and an approximately eight-second network deadline, unless existing service constraints call for different values. These are proposed settings, not Apple execution-time guarantees or guaranteed provider freshness.

Preserve original snapshot timestamps through cache layers. Cancel work when the intent is cancelled. Avoid unbounded retries; distinguish timeout, connectivity failure, authentication failure, rate limiting and malformed/partial data internally.

When live information is unavailable, either state that clearly or use a separately identified scheduled fallback. Never describe stale cached data as current, announce an old platform as confirmed, or interpret a failed request as “no trains”. If upstream freshness cannot be established, describe the limitation rather than inventing a timestamp.

## 4. Phase 2 — App Intents and App Shortcuts

### 4.1 Actions

Suggested names below are implementation labels. Retain equivalent existing types and identifiers.

| Action | Parameters | Behaviour |
|---|---|---|
| `GetNextFavouriteTrainIntent` | None | Read the user’s explicitly configured default route and fetch fresh departures. |
| `GetNextTrainsForSavedRouteIntent` | One required `SavedRouteEntity` | Fetch departures for that saved route. |
| `GetNextDeparturesIntent` | Required origin and destination `StationEntity` values | Configure both in Shortcuts, or prompt for missing station values through Siri. |
| `GetTrackedJourneyStatusIntent` | None initially | Refresh the existing active journey and report current status. Include only if the underlying tracking service is available. |
| `GetTrackedTrainPlatformIntent` | None initially | Report the boarding platform for that same active journey, or explain that no confirmed platform is available. |

For no default route, offer a supported route-selection prompt or clear setup instruction. Do not silently select the first favourite. A one-off spoken selection must not overwrite the default unless the user explicitly performs a settings action.

For multiple tracked journeys, use the app’s explicit active selection or ask the user to choose. Do not infer “my train” from whichever screen happened to be viewed last.

Describe titles, parameters and summaries clearly in Shortcuts. Where practical, return structured departure entities as well as the spoken response, so a shortcut can inspect a result or pass it to a later action. Do not force downstream actions to parse prose.

### 4.2 Supported invocation design

Register a small set of distinct phrases in the existing provider. These are **templates to compile and test**, not a promise that every variation will route correctly:

| Purpose | Phrase template |
|---|---|
| Default route | `Get my next train in <applicationName>` |
| Saved route | `Get next trains for <route> in <applicationName>` |
| General lookup | `Check train departures in <applicationName>` |
| Active journey | `Check my journey in <applicationName>` |
| Platform | `Check my train platform in <applicationName>` |

Use the real application-name placeholder in Swift, not the literal placeholder text above. Do not include “Hey Siri” inside the registered phrase. The saved-route template has one parameter; the general lookup has no interpolated stations and obtains them through parameter resolution.

Do not create a two-parameter phrase such as `from <origin> to <destination>` without a verified supported mechanism in the target SDK. Do not enumerate every station pair or add a single free-text phrase parameter as an unverified workaround for unrestricted speech parsing.

Refresh shortcut parameter suggestions when saved routes are added, renamed or deleted, using the applicable provider update API. Do not refresh the shortcut catalogue for every live train update.[^refresh]

### 4.3 Spoken answers and result cards

Use `ProvidesDialog` for the answer and, where appropriate, `ShowsSnippetView` for a SwiftUI result card. Ensure the full spoken dialog makes sense without the screen; Apple explicitly describes this voice-only use case.[^responses]

Create a deterministic response formatter shared by tests. Use natural station names and speak platform numbers clearly. Never use custom speech synthesis or microphone capture for this integration.

Synthetic examples:

| Data outcome | Example wording |
|---|---|
| Confirmed live departure | “Your next train from Kent House to London Victoria is at 8:42, in eight minutes, from platform two. It’s running on time.” |
| Known delay | “The 8:42 to London Victoria is expected at 8:49, seven minutes late.” |
| Unknown platform | “The next train is at 8:42. The platform hasn’t been announced.” |
| Relevant cancellation | “The 8:42 is cancelled. The next available train is at 8:57.” |
| No reliable delay estimate | “The 8:42 is delayed, but there isn’t an expected departure time yet.” |
| Scheduled-only fallback | “Live updates are unavailable. The timetable shows a departure at 8:42.” |
| Limited empty result | “I couldn’t find a direct departure to London Victoria in the next two hours.” |
| No active journey | “You don’t have a train selected for tracking.” |

Use the actual searched window, not the example’s two hours. “On time” requires supporting data. Round countdowns sensibly and recompute them from the response-time clock. Avoid negative minute counts. Aim for one or two sentences except when clarification is necessary.

The card should show the resolved route, up to three departures, scheduled versus expected time, status, known platform and freshness/“scheduled only” labelling. Use accessible text and symbols, not colour alone. Support Dynamic Type, VoiceOver and light/dark appearance. A card is a snapshot, not a permanently live departure board.

Only add a navigation action where the target surface supports it. Use the existing deep-link/navigation path, re-resolve the selected service and refresh on opening. Spoken lookup must not require that action to complete.

### 4.4 Execution, authentication and privacy

Read-only lookup should normally complete without foregrounding the app. Explicit navigation is a separate action. Select the execution APIs supported by the project’s actual SDK/deployment target; preserve compatible behaviour on older supported versions.[^execution]

Review `authenticationPolicy` and protected storage access deliberately. Public station departures and a personal saved route/active journey have different privacy implications. Respect system lock-screen restrictions and any existing app privacy controls. Do not weaken file protection or keychain accessibility just to bypass an unlock requirement. Do not promise lock-screen execution before testing it.

Do not add microphone, location, notification, SiriKit entitlements or background modes indiscriminately. Check what the chosen architecture actually requires. A simple read-only lookup should not trigger notification permission setup.

Log outcomes, latency and freshness diagnostics with the app’s existing privacy conventions. Avoid production logs containing spoken requests, route nicknames, travel history or authentication data. No new analytics service is required.

## 5. Phase 3 — Setup, discoverability and device behaviour

Add a small **Siri & Shortcuts** section to existing settings or favourite-route management. It should expose the default route, show tested example phrases and explain general station lookup. Do not add an unrelated onboarding flow.

Explain how to create a personal shortcut named, for example, **“My next train”**, using the default-route action, or **“Train to Victoria”**, with explicit station parameters. Apple supports invoking a personal shortcut by its name.[^personal-shortcuts] Distinguish this user-configured name from an app claiming ownership of every generic train question.

A supported Shortcuts discovery link/control is welcome, but do not invent an API that silently installs a personal shortcut. Keep any instructions or controls consistent with the installed SDK.

Prioritise iPhone Siri and voice-only use through AirPods. Separately audit the existing Watch target: reuse shared domain logic and the established synchronisation mechanism, but do not assume iPhone process memory or its App Group storage is shared with watchOS. Test connected and disconnected Watch behaviour before advertising it.

If native Watch execution is not part of the current architecture, document the limitation and keep the iPhone core release independent. Do not claim HomePod or CarPlay support from iPhone tests alone.

## 6. Phase 4 — Tests, compatibility and release evidence

### 6.1 Automated test matrix

Use a fixed clock and synthetic fixtures. Do not make ordinary unit tests depend on the live railway feed.

| Test | Required result |
|---|---|
| Default route exists | Uses the saved station IDs, without asking again. |
| Missing/deleted default | Helpful selection/setup flow; no silent fallback to another favourite. |
| Favourite renamed | Existing saved shortcut still resolves its persistent ID. |
| Ambiguous “Victoria” | Preserves distinct candidates; does not guess globally. |
| Destination is an intermediate stop | Includes the service when the requested call is valid. |
| Destination before boarding / skipped call | Does not offer the service for that journey. |
| Normal live result | Accurate ordering, spoken time, platform and status. |
| Scheduled time passed, expected departure future | Retains the delayed train when still boardable. |
| Known departure already completed | Does not offer that train. |
| Cancellation or partial cancellation | Does not describe an invalid journey as available. |
| Delay without estimate | Honest uncertainty, not a fabricated departure time. |
| Missing/suppressed platform | No invented or stale confirmed platform. |
| Replacement bus | Clearly labelled; never called a train. |
| Midnight / previous operating date | Correct service identity and absolute time. |
| Daylight-saving change / phone abroad | Correct London time and interval calculations. |
| Empty, limited or incomplete board | Does not overstate absence of services. |
| Stale upstream snapshot in a new response | Not relabelled as fresh because HTTP fetch succeeded. |
| Timeout, offline, throttling, malformed payload | Concise safe result, bounded work, no false “no trains”. |
| User cancels | Work stops without unwanted side effects. |
| Cold invocation / concurrent invocations | Dependencies initialise correctly; no shared-state corruption. |
| No tracked journey / multiple tracked journeys | Appropriate explanation or disambiguation. |
| Spoken/card/structured output comparison | All outputs describe the same selected services and freshness. |

### 6.2 App Intents integration and manual tests

With a suitable toolchain, use `AppIntentsTesting` for intent execution, entity queries and result chaining. Apple’s framework runs through the intent stack from an XCUITest bundle; the test runner and app require matching signing teams. These tests do not replace manual Siri routing checks.[^testing]

Use an isolated test store and app-side test configuration for fixture data. Keep test-only reset/seed actions out of release builds and non-discoverable. Preserve the app’s ordinary unit tests when the new testing framework is unavailable.

On a physical device, verify the registered phrases, the missing-station conversation, a saved-route phrase, the personally named shortcut and the desired full Kent House → Victoria question. Record the latter as passed, unreliable or unsupported; do not mark it passed because direct `perform()` execution succeeded.

Test the app running, backgrounded and cold; locked/unlocked device states; UK English speech; AirPods output; permitted and restricted Siri settings; and current iOS 27 alongside older supported OS versions where devices/runtimes are available. Test enhanced Siri availability separately from OS version. Repeat Watch-specific checks only when implementing Watch support.

Inspect App Intents metadata extraction/build warnings. Build the affected app, Watch, widget and shared-package targets using the discovered project configuration. Do not guess an Xcode path or claim a physical-device test ran in a simulator.

### 6.3 Core definition of done

- [ ] A configured default route returns an accurate spoken answer through a tested app-qualified Siri phrase without opening the app unnecessarily.
- [ ] Users can configure both stations in Shortcuts and resolve missing/ambiguous parameters through the supported flow.
- [ ] No stale, missing, cancelled or incomplete data becomes an invented live fact.
- [ ] Existing favourites, tracking, Live Activities, widgets and saved Shortcuts remain functional.
- [ ] Applicable builds and automated tests pass; unexecuted device checks are explicitly listed.
- [ ] Documentation separates verified invocation wording from experimental natural-language behaviour.

Add a short repository document, such as `docs/siri-shortcuts.md`, recording shipped actions, tested phrases, setup steps, freshness rules, compatibility and remaining device checks. Keep this implementation plan updated with actual decisions, not speculative completion ticks.

## 7. Phase 5 — Tracking and navigation follow-on

Add this only after the core lookup works and the existing tracking service is understood.

Expose an action that starts tracking a resolved `DepartureEntity`, an explicitly named convenience action for the next train on a saved route, a stop-tracking action and an open-departure action. Reuse the existing tracking coordinator and backend subscription lifecycle.

Revalidate the service immediately before a tracking write. A train selected earlier may now be cancelled, departed or no longer serve the destination. Make start/stop idempotent so repeated invocations do not create duplicate subscriptions or Live Activities. Ask for a choice where service identity is ambiguous, and confirm replacing an existing tracked journey where that would discard meaningful state.

Distinguish “tracking saved” from “Live Activity successfully started” in the result. Do not announce notifications or a Live Activity that could not actually be enabled.

Apple documents foreground Live Activity creation, a `LiveActivityIntent` background-start path, and ActivityKit push alternatives.[^activitykit] Verify the applicable OS version, invocation context and existing implementation before selecting a route. Do not assume any arbitrary background intent can call `Activity.request` successfully, and do not add a new push service solely for this feature.

Recheck privacy, locking, permissions and cancellation for these state-changing actions. A failed attempt must not leave a half-created subscription or silently replace the tracked service.

## 8. Phase 6 — iOS 27 enhancements, behind compatibility gates

The core release must not wait for this phase. Apple’s schema catalogue distinguishes domains with Siri integration from Shortcuts-specific domains. A schema annotation is not a universal promise of Siri support.[^schemas]

### 8.1 Schema-fit investigation

Review the current Maps and System/in-app-search domains against actual TrainTrack functionality. Record any matching schema’s exact symbol, required properties, supported actions and minimum OS. Adopt only genuine semantic matches; Apple advises against forcing an ill-fitting schema.[^schema-fit]

This plan does **not** assert that Apple provides a dedicated live rail-departure schema. Do not invent names such as `.transport.nextTrain`, misrepresent a departure as a calendar event, or claim navigation-session semantics unless the app genuinely implements them. A documented lack of a suitable schema is a valid outcome; retain App Shortcuts and file feedback separately.

### 8.2 In-app search and onscreen context

Investigate the system `searchInApp` integration as a way to open the app’s actual search results. It is not itself a voice-only live-departure API. Prototype entity annotations for a departure list or selected journey and test references such as “open that one”. Apple describes both in-app search and view/entity annotation approaches.[^responses]

Keep service identifiers stable and refresh data when resolving a referenced departure. An annotation must not expose stale platform information as a current fact. Keep “track that train” and “the one after that” experimental until the appropriate action actually routes on a device; do not add a global mutable “last Siri result” as a substitute for system conversation context.

### 8.3 Optional indexing and donations

Index useful stable content, such as saved routes, only where it helps a verified integration. Update/delete indexed entries when the underlying content changes. Do not index every live departure or use the index as the current running-status source.

Donate only real user interactions that match the supported API/schema. Do not fabricate donations, donate background refreshes as user actions, or duplicate system-recorded Siri interactions. Donations and annotations do not guarantee app selection for an unqualified question.[^responses]

**Exit condition:** A brief compatibility/results table identifies each enhancement as implemented and device-verified, unavailable, or deferred. Preserve the baseline on devices where enhanced Siri features are unavailable.

## 9. Phase 7 — Journey-planning integration when ready

The Rail Data Marketplace timetable work is **journey planning only**. Keep ticketing, fares and retailing out of this integration.

Once the existing planner can answer multi-leg requests, add a separate journey-planning intent with origin, destination, date/time and depart-after versus arrive-by selection. Reuse that planner; do not implement connection search inside an intent.

Return leg identities, changes, departure/arrival times and an explicit scheduled/live status. Honour the planner’s transfer rules and data coverage. Do not represent a scheduled-only itinerary as live-confirmed. Test “arrive before nine” with an explicit date and `Europe/London` time interpretation.

Keep direct next-departure lookup distinct from multi-leg journey planning. When the planner is not available, report the direct lookup’s limits rather than inventing a connecting route.

## 10. Codex handover requirements

Finish the implementation response with the files changed, actions shipped, exact build/test commands and outcomes, device tests still required, compatibility choices and intentionally deferred phases. Flag unrelated pre-existing failures separately. Do not describe this plan or generated tests as an implementation that has already been verified.

**Success means:** a user can configure Kent House → London Victoria, ask a tested Siri command, and hear a truthful, useful answer using the existing TrainTrack UK data stack—without navigating through the app.

## Official references

These references were checked for this plan on 15 September 2026. They support the Apple-platform design; proposed product rules, type names and thresholds above are implementation recommendations, not Apple requirements. Installed SDK declarations and actual device behaviour must be checked before shipping. Some individual symbol pages were not fully readable in this research session, so this document deliberately does not prescribe unverified signatures or authentication-policy enum values.

[^shortcuts]: Apple, **Get to know App Intents**, WWDC25. App Shortcut phrases and parameter model. <https://developer.apple.com/videos/play/wwdc2025/244/>

[^entities]: Apple, **Dive into App Intents**, WWDC22. Entities, queries and custom intent architecture. <https://developer.apple.com/videos/play/wwdc2022/10032/>

[^refresh]: Apple, **Spotlight your app with App Shortcuts**, WWDC23. Updating suggestions as entity data changes. <https://developer.apple.com/videos/play/wwdc2023/10102/>

[^responses]: Apple, **Explore advanced App Intents features for Siri and Apple Intelligence**, WWDC26. Spoken dialogs, snippets, search, annotations and donations. <https://developer.apple.com/videos/play/wwdc2026/343/>

[^execution]: Apple, **Get to know App Intents**, WWDC25, plus SDK references for [`supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes) and [`authenticationPolicy`](https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy). Verify declarations and availability in the installed SDK. <https://developer.apple.com/videos/play/wwdc2025/244/>

[^personal-shortcuts]: Apple Support, **Use Siri to run shortcuts with your voice**. <https://support.apple.com/en-gb/guide/shortcuts/apd07c25bb38/ios>

[^testing]: Apple, **Validate your App Intents adoption with AppIntentsTesting**, WWDC26. <https://developer.apple.com/videos/play/wwdc2026/295/>

[^activitykit]: Apple, **Displaying live data with Live Activities**. <https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities>

[^schemas]: Apple, **App schema domains**. <https://developer.apple.com/documentation/appintents/app-schema-domains>

[^schema-fit]: Apple, **Apple Intelligence Group Lab**, WWDC26, especially the schema-fit discussion from 3:09 and 7:08. <https://developer.apple.com/videos/play/wwdc2026/8011/>
