# Siri and Shortcuts

## Scope and setup

This implementation covers phases 0–4 of `TrainTrack_UK_Siri_Implementation_Plan.md` for iPhone, including Siri through AirPods. It does not add Watch execution, tracking writes, selected-departure navigation, iOS 27 schemas, or journey planning.

1. Save a **direct, single-leg** route in **Favourites or My Journeys**. Save its return journey too if you want automatic direction selection.
2. Open **Profile → Preferences → Siri & Shortcuts**.
3. Explicitly select its **Default route**. No saved route is selected automatically.
4. Optionally give a route a custom name such as **Commute**. Saved outward and return directions share this name and one settings entry. A blank name restores its station-based title. “Try with Siri” shows a named example as soon as a route has a name, even without a default.
5. Use the Shortcuts link to configure an action, or create a personal shortcut and name it **TrainTrack next train**.

Actions allow execution while locked where Siri and protected storage permit it. They do not bypass system restrictions or request new microphone, location or notification permission. When live information cannot be verified, they explain unavailability; there is no timetable fallback.

For a saved outward/return pair, the default-route and named-route actions choose the direction whose departure station is nearer. Set the optional **Departure station** in either action to fix the direction instead. A route with only one saved direction uses that direction and does not request location; it never invents a return journey. Explicit station-to-station lookups also keep the requested direction.

Automatic selection checks existing location authorization, then a location no more than 60 seconds old with recorded accuracy of at most 1 km. It can make one authorized location request, bounded to two seconds. It does not start tracking or request background authorization. If location is unavailable, inaccurate, stale or too close to a tie, Siri asks which departure station to use. The distance difference must exceed both 200 m and twice the reported accuracy. The choice is for that invocation and does not change the saved default.

## Actions and registered phrases

These phrases are registered in the app metadata. **Physical-device Siri recognition remains to be verified.** In code, the actual application-name placeholder is used; “Hey Siri” is not part of the registration. The main app declares **TrainTrack** as an alternative app name. The installed SDK expands that placeholder to both **TrainTrack UK** and **TrainTrack**; the display name and bundle identifier remain unchanged.

| Action | Parameters | Registered phrase |
| --- | --- | --- |
| Get My Next Train | Explicitly selected default; optional departure-station override | Use TrainTrack to get my next train |
| Get Trains for Saved Route | Saved route; optional departure-station override | Get next trains for [route] in TrainTrack |
| Get Train Departures | Origin and destination stations | Check train departures in TrainTrack |
| Check Tracked Journey | Existing active train | Check my journey in TrainTrack |
| Check Tracked Train Platform | Same active train | Check my train platform in TrainTrack |

The default action also registers **“Get me my next train in [application name]”** and retains the original **“Get my next train in [application name]”**. These additions do not change the action's identity or saved parameters. Similar wording can match through Siri's flexible phrase matching, but a registered phrase does not guarantee Siri will choose this app.

The general action exposes both stations in Shortcuts and requests missing parameters. Station search preserves ambiguous alternatives such as London Victoria and Manchester Victoria. It does not guess from a weak match or use location. Full free-form wording such as “when's my next train from Kent House to Victoria” is an experimental device-validation target, not a supported parsing guarantee.

All actions return a spoken dialog, a snapshot card and up to three structured departure entities. Structured properties expose service identity, stations, scheduled/expected departure, platform, status, transport mode, timing uncertainty and separate provider/backend/client timestamps. Unknown values remain absent. The result card does not continuously refresh.

Tracking status reads the persisted active checkpoint without initializing the tracking coordinator. Armed route candidates are not a selected train. Before boarding detection, while matching a service, or while awaiting the next train at an interchange, the action explains that no train is selected. A platform answer refers to the selected train's **boarding** station, not its arrival platform.

### When Siri opens Maps

On the test iPhone, “Hey Siri, get me my next train in TrainTrack UK” repeatedly returned a Maps card for United Kingdom. The user confirmed that tapping **My Next Train** in Shortcuts runs correctly. This points to Siri's spoken app/action routing; it is not evidence of a departure lookup failure. The missing exact “get me” variant is a registration gap, not proof of the cause.

After installing the updated build, try **“Hey Siri, use TrainTrack to get my next train”**. For an installed build that still routes to Maps, create a personal shortcut with the **Get My Next Train** action, name it **TrainTrack next train**, then say **“Hey Siri, TrainTrack next train”**. A personal shortcut has its own spoken name. Retest the updated app's registered phrases separately, recording whether Siri invokes TrainTrack or another app.

## Data and execution

- Uses `NetworkServicePhone`, existing `/api/v2/departures/...` and `/api/v2/service_details/...` endpoints, the existing station catalogue and App Group. No provider secret or additional direct provider client is added.
- Siri requests use `includeStatus=true&requireFresh=true`. The additive `siri` metadata carries the provider board's `generatedAt`, backend fetch time, request offsets and platform provenance. `generatedAt` is a board timestamp, not a claimed per-train telemetry observation time.
- Both provider and backend snapshot timestamps must be no more than **60 seconds** old. Missing metadata, including responses from a server that has not received this update, cannot qualify as verified live data.
- The backend bounds voice-initiated work to **7.5 seconds**, including queueing, with no retries. A caller can join existing shared work without cancelling another client's refresh. The client bounds its entire board/detail sequence to **eight seconds**, propagating cancellation. Parameter-resolution requests are also bounded, separately from time spent in Siri's conversation.
- Automatic direction selection may add at most **two seconds** before the board/detail sequence. Location requests belong to each invocation, so cancellation cannot stop a screen's request or another Siri invocation. Existing location cache entries without recorded accuracy are not used for direction selection.
- A lookup makes one board request and at most one exact-detail batch (up to 12 candidate services). Detail verification rejects departed boarding calls, cancelled destinations/associations and branches requiring a change. Missing verification yields unavailable/partial information, never a claim that no trains run.
- Times and platforms come from the newer of the verified board and detail snapshots. A withdrawn, retained, missing or placeholder platform is not announced as confirmed. A replacement bus is identified as a bus.
- Eligible trains are ordered by reliable expected departure. A delayed train with a passed schedule remains eligible; an earlier service without a reliable estimate is explicitly mentioned as uncertain. Partial information is described as a confirmed option rather than an unqualified next train.
- When a listed departure time has just passed, the answer says **“I can't confirm whether the 22:19 train … has left.”** The card says **“Was due at 22:19”** and **“Departure not yet confirmed”**. This is distinct from **“is delayed, with no new departure time yet”**. A later option is described as **“Another train is expected at 22:29”**; neither case asserts that the earlier train departed.
- Railway clock times use **Europe/London** and provider dates, including calendar-day crossings. Strict calendar matching rejects ambiguous repeated/missing DST times. Operating dates are not supplied by the current API contract and remain unknown; resolved boarding calendar dates are not mislabelled as operating dates.
- Existing provider-default board windows/row limits do not prove complete coverage. Empty results are limited to the returned direct-departure board. No connections are invented.
- Departure references contain a version, exact service ID, origin/destination CRS and resolved scheduled boarding date. Rehydration refreshes that exact service and never substitutes another departure. References outside the retained window fail safely.
- New diagnostics contain outcome, failure category and elapsed time, without nicknames, spoken requests, travel history or authentication values.

**Backend rollout:** the backend changes must be deployed through the existing deployment process before live Siri departure lookup can succeed. This task changes local source only. Older clients retain their existing response shapes and cache behaviour.

## Persistence and compatibility

- Existing `saved_journeys` JSON, route UUIDs and `siri_default_route_id_v1` are preserved. Shared outward/return names use `siri_route_names_v2`, keyed by the unordered station pair. Old per-direction `siri_route_names_v1` values remain readable and intact. An explicitly blank new name overrides old names.
- Suggestions/defaults include direct routes from both Favourites and My Journeys. Opposite directions share a settings entry; each original group UUID still resolves its original station orientation. Unfavouriting does not remove a default. A deleted group ID does not silently become another group. Multi-leg support can use the same group identity in follow-on work.
- A rename changes presentation, not identity. Conflicting old direction names resolve deterministically, preferring the existing default's name, and are preserved when the default changes. Duplicate names for different station pairs include station descriptions. Route edits refresh parameter suggestions; live train refreshes do not.
- Existing default/named actions retain their identifiers and outputs. Their additional departure-station parameter is optional, so existing shortcuts remain resolvable; saved pairs now use the requested nearest-direction behaviour when no override is supplied.
- Existing `CustomJourneyIntent.journey`, widget `JourneyEntity` IDs (`FROM_TO`), widget configuration/control intents, URL routes and their target ownership are untouched. The new app `SavedRouteEntity` uses the existing group UUID.
- Checkpoint reading/writing shares the existing `journeyHistoryTrackingCheckpointV1` envelope. The coordinator remains the owner of tracking mutations and lifecycle work.
- Cold-launch inspection found existing notification prompts only in explicit setup/tracking actions. Geofence restoration exits when permission is undetermined and restores established tracking when applicable. No launch-policy changes were required; real background Siri launch remains a device check.

## Toolchain and API audit

Verified against installed **Xcode 26.6 (17F113)**, **iOS/watchOS SDK 26.5**, including AppIntents and `_AppIntents_SwiftUI` interface declarations.

| Target | Preserved deployment minimum |
| --- | --- |
| iPhone app, phone widget, notification extension and phone tests | iOS 18.6 |
| Watch app and tests | watchOS 26.0 |
| Separate Live Activity extension | iOS 26.1 |
| JourneyActivityShared package | iOS 16.0 |

The baseline uses `AppEntity`, `EntityStringQuery`, `ProvidesDialog`, `ReturnsValue`, `ShowsSnippetView`, `ShortcutsLink`, and synchronous `updateAppShortcutParameters()`. Read-only intents keep `openAppWhenRun=false`; iOS 26+ additionally declares background `supportedModes`. Authentication is explicitly `alwaysAllowed`. No iOS 27-only symbols or new extension are required.

`AppIntentsTesting` is absent from the installed SDK and is not a dependency. Existing Swift Testing/XCTest targets are used. There is no shared-package test target. The pre-existing `TrainTrackDebugLiveActivityExtension` scheme references a missing target and is excluded from baseline checks.

References: [App Intents overview and phrases](https://sosumi.ai/videos/play/wwdc2025/244/), [execution modes](https://sosumi.ai/documentation/appintents/appintent/supportedmodes), [authentication](https://sosumi.ai/documentation/appintents/intentauthenticationpolicy), [strict calendar matching](https://sosumi.ai/documentation/foundation/calendar/nextdate(after:matching:matchingpolicy:repeatedtimepolicy:direction:)).

Direction selection also checks the installed SDK declarations for [parameter disambiguation](https://sosumi.ai/documentation/appintents/intentparameter/requestdisambiguation(among:dialog:)) (iOS 16+) and [one-shot location](https://sosumi.ai/documentation/corelocation/cllocationmanager/requestlocation()) (iOS 9+). Existing When In Use authorization does not guarantee fresh background delivery; the direction question handles that case.

App-name synonyms and application-name phrase substitution are described in [Implement App Shortcuts with App Intents, 06:20 and 18:31](https://sosumi.ai/videos/play/wwdc2022/10170). [Explore enhancements to App Intents, 13:56 and 20:34](https://sosumi.ai/videos/play/wwdc2023/10102) covers flexible matching and app-name synonyms. The legacy [synonym plist reference](https://sosumi.ai/documentation/sirikit/specifying-synonyms-for-your-app-name) still mentions an Intents extension; this app uses the modern App Shortcuts approach, with alias expansion verified in the installed SDK's generated `root.ssu.yaml`. No new extension or pronunciation hint is added.

## Verification record — 15 September 2026

The original iPhone Debug simulator build passed before implementation. After initial testing feedback, the regression run passed **357 unit tests in 29 suites**, including stale/missing data, cancellation, midnight/DST, ambiguous stations, route persistence, exact-service rehydration, tracked calling order, newer-versus-older platform observations, shared return-route names, legacy-name migration and automatic/explicit direction selection.

Both Debug and Release app builds passed. Generated Release App Intents metadata initially contained **five actions, five registered phrases and three entity types** with the intended array outputs and background/authentication settings. Legacy widget/Live Activity intent files and project deployment settings have no changes.

| Build/check | Result |
| --- | --- |
| iPhone Debug and Release, including embedded phone widget and notification extension | Passed |
| Watch app Debug | Passed |
| Separate Live Activity extension Debug | Passed |
| JourneyActivityShared Debug | Passed |
| iPhone unit tests | 357 passed in 29 suites |
| Siri settings UI tests | All three passed: named-default persistence across relaunch, My Journeys selection/named example without a default, largest-text layout and tap-target checks |

UI inspection replaced a truncating compact route picker with a wrapping selection screen and corrected low-contrast button subtitles. The final dark-mode build and largest-text UI test passed; exported screenshots were inspected after the colour correction. Dark appearance is controlled with `simctl`; the UIKit-style launch argument did not change actual simulator appearance and was removed from the tests. The simulator's light appearance was restored afterwards.

The feedback run passed all 357 unit tests and the first two UI flows together. The expanded route list caused the accessibility audit to scroll before the UI test's next tap; after restoring the test's scroll position, the largest-text flow passed separately in actual dark appearance. This was a test-position correction, with the clipping/tap-target audit retained. Debug and Release metadata keep the five action identifiers and mark both new departure-station parameters optional.

The subsequent Maps-routing follow-up passed a Release registration build, all **three SiriIntentTests**, and the existing **My Journeys/named-example UI test** with the revised Settings copy. Both Release and Debug generated metadata now contain **five shortcuts, seven phrase templates and three entity types**. Their `root.ssu.yaml` files include **TrainTrack UK** and **TrainTrack** as application-name expansions, and the exact reported “Get me my next train…” phrase. Full action, entity and query contracts compare equal to the metadata captured before this change; the bundle identifier, displayed app name and iOS 18.6 minimum remain unchanged. These checks establish correct registration, not successful on-device recognition.

Existing build warnings remain in the diagnostics/history code and older tests about actor isolation, and embedded extensions report version `5` against app version `5.21`. These are outside this change. The new Siri sources have no remaining compiler warnings. Metadata extraction skips targets without an App Intents dependency; the main app's extraction succeeds.

Backend targeted checks passed **22 tests**, including freshness, old-client compatibility, platform retention, exact split-service lookup and a real 7.5-second abort test. Full `npm test` produced **183 passes, 2 skips and one terminated worker** after its pre-existing `device-data-deletion.test.js` hung. That test awaits an update without installing its fake subscription into the manager map; the identity guard exits before signalling it. Both behaviours exist in HEAD and were left unchanged.

## Source map

| Area | Files |
| --- | --- |
| Intent registration, entities and spoken/card outputs | `TrainShortcuts.swift`, `SiriDepartureSnippet.swift` |
| Lookup, freshness, service selection and London times | `SiriLookupService.swift`, `SiriDeparturePolicy.swift`, `SiriLookupModels.swift` |
| Saved route identity, names and setup | `SiriRouteStore.swift`, `SiriShortcutsSettingsView.swift`; small hooks in `JourneyStore.swift` and `PreferencesView.swift` |
| Automatic direction and location | `SiriRouteDirectionResolver.swift`, `SiriRouteLocationProvider.swift`; existing `LocationManagerPhone.swift` additionally records actual cache accuracy |
| Existing service reuse | Additive changes to `ApiModels.swift`, `NetworkService.swift` and `StationsService.swift` |
| Tracking checkpoint reuse | `JourneyTrackingCheckpointStore.swift`; existing coordinator load/save delegate to it |
| Backend freshness contract | `lib/siri-departure-policy.js`, `lib/realtime-trains-api.js`, `lib/departure-response.js`, `lib/upstream-api-client.js`; existing departures handler in `index.js` |
| iPhone regression tests | `SiriLookupTests.swift`, `SiriLookupServiceTests.swift`, `SiriRouteStoreTests.swift`, `SiriRouteDirectionTests.swift`, `SiriRouteLocationProviderTests.swift`, `SiriIntentTests.swift`, `SiriShortcutsUITests.swift` |
| Backend regression tests | `test/siri-departures.test.js`, `test/upstream-api-client.test.js` |

The iPhone source files are under `ios/TrainTrack UK/TrainTrack UK`; backend files are under `api/train-track-api`. Existing unrelated working-tree changes were retained.

### Commands

Run from the repository root unless noted. The simulator UUID below identifies the installed iPhone 17 / iOS 26.5 used for this task.

```sh
rtk proxy xcodebuild -project 'ios/TrainTrack UK/TrainTrack UK.xcodeproj' -scheme 'TrainTrack UK' -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
rtk proxy xcodebuild -project 'ios/TrainTrack UK/TrainTrack UK.xcodeproj' -scheme 'TrainTrack UK' -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
rtk proxy xcodebuild -project 'ios/TrainTrack UK/TrainTrack UK.xcodeproj' -scheme 'TrainTrack UK' -configuration Debug -destination 'platform=iOS Simulator,id=D5E8439F-92AA-4205-9BC9-917DD260ED33' -only-testing:'TrainTrack UKTests' -parallel-testing-enabled NO test
rtk proxy xcodebuild -project 'ios/TrainTrack UK/TrainTrack UK.xcodeproj' -scheme 'TrainTrack UK' -configuration Debug -destination 'platform=iOS Simulator,id=D5E8439F-92AA-4205-9BC9-917DD260ED33' -only-testing:'TrainTrack UKTests' -only-testing:'TrainTrack UKUITests/SiriShortcutsUITests' -parallel-testing-enabled NO test
rtk proxy xcodebuild -project 'ios/TrainTrack UK/TrainTrack UK.xcodeproj' -scheme 'TrainTrack UK Watch App' -configuration Debug -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
rtk proxy xcodebuild -project 'ios/TrainTrack UK/TrainTrack UK.xcodeproj' -scheme 'Live ActivityExtension' -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
rtk proxy xcodebuild -project 'ios/TrainTrack UK/TrainTrack UK.xcodeproj' -scheme 'JourneyActivityShared' -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For the separate dark appearance check, use the already booted simulator and restore its appearance afterwards:

```sh
rtk proxy xcrun simctl ui D5E8439F-92AA-4205-9BC9-917DD260ED33 appearance dark
rtk proxy xcodebuild -project 'ios/TrainTrack UK/TrainTrack UK.xcodeproj' -scheme 'TrainTrack UK' -configuration Debug -destination 'platform=iOS Simulator,id=D5E8439F-92AA-4205-9BC9-917DD260ED33' -only-testing:'TrainTrack UKUITests/SiriShortcutsUITests/testSettingsAtLargestTextSize' -parallel-testing-enabled NO test
rtk proxy xcrun simctl ui D5E8439F-92AA-4205-9BC9-917DD260ED33 appearance light
```

From `api/train-track-api`:

```sh
rtk proxy node --check index.js
rtk proxy node --test test/siri-departures.test.js test/upstream-api-client.test.js test/departure-data-status.test.js test/split-service-details.test.js test/recent-departures-repository.test.js
rtk npm test
```

### Physical-device checks still required

- Registered phrases, station prompts/disambiguation, named-route phrases and personally named shortcuts.
- Automatic outward/return selection near each endpoint; explicit departure-station overrides; unavailable/revoked location and an ambiguous midpoint, including voice-only direction questions.
- Voice-only responses through AirPods; UK English speech.
- Siri-hosted result cards at large text sizes, VoiceOver reading order and speech/card agreement.
- App running, backgrounded and cold; locked/unlocked; permitted/restricted Siri settings.
- Real installation upgrade retaining saved widget configurations and Shortcuts.
- Minimum supported iOS and iOS 27/enhanced-Siri behaviour when devices/toolchains are available; no iOS 18.6 or iOS 27 runtime is installed here.
- The richer Kent House → Victoria sentence must be recorded as passed, unreliable or unsupported based on actual routing, not direct intent execution.

Native Watch, HomePod and CarPlay support are not advertised. Phases 5–7 remain independent follow-on work.
