# Version 5 release preparation

## Build and validation

- Current project version: **5 (4)**. Version numbers were preserved; check whether build 4 has already been uploaded before signing/uploading.
- Release simulator build succeeded.
- Full unit suite: **137 passing tests** after the final code changes.
- A separate Release-configuration test verified disabled logging, enabled recording, export and clearing.
- Final unsigned iOS archive succeeded: `../../.release-prep/TrainTrack-5-September-Final-Submission.xcarchive`.
- App and embedded widget/notification extensions all report version 5, build 4. Minimum iOS version is 18.6.
- Routine console-log markers checked in the archived binaries were absent.
- `git diff --check` passed.
- Build output contains Xcode's informational warning that App Intents metadata extraction was skipped for a target without an AppIntents dependency.

This archive has not been signed, uploaded or submitted to App Store Connect. A signing-enabled archive/distribution validation is still required. The current iOS scheme embeds the phone widget and notification service extensions, but no Watch app; do not advertise a newly bundled Watch companion without checking the intended release configuration.

## Release changes

- Kept the troubleshooting viewer and share option available in production under Profile → Preferences → Diagnostics.
- Added an opt-in recording switch, off by default in release builds. Turning recording off clears recorded logs.
- Retained bounded local app and notification-extension diagnostic files when recording is enabled.
- Removed routine Live Activity and widget debug console output from release builds; retained operational error/warning reporting.
- Avoided serialising Live Activity snapshots in release builds.
- Deferred diagnostic message/metadata construction while logging is disabled and avoided reading entire diagnostic files just to check their size.
- Avoided rewriting the in-memory troubleshooting list into preferences on every event in release builds.
- Kept developer API switching, journey simulation, test-history generation and server-audit controls restricted to development builds.

Existing uncommitted journey-tracking, completion and badge changes were preserved and included in validation. No commit was created.

## Screenshots

The complete set is in `screenshots/`, with six images in each device folder:

| File | Screen and content |
| --- | --- |
| `01-favourites.png` | East Croydon ↔ Gatwick Airport departures |
| `02-my-journeys.png` | Clock House → London Bridge; Kent House → Farringdon via Herne Hill |
| `03-route-map.png` | East Croydon → Gatwick Airport route, estimated train position near Coulsdon |
| `04-journey-history-delay-repay.png` | Clock House → London Bridge sample, 20 minutes late, Claim delay repay button |
| `05-journey-stats.png` | Journey totals, operators, punctuality, average delay and charts |
| `06-in-progress.png` | East Croydon → Gatwick Airport active journey, ETA and map |

The iPhone 6.9-inch images are **1320 × 2868**; iPad 13-inch images are **2064 × 2752**. These are native PNG screenshots without device frames. `App-Store-Screenshots.zip` contains both folders.

All screens use dark appearance. The background is the exact requested photo: Muhammed Fardeen Finos / Unsplash, provider ID `HPzMiuKz5Nw`, catalogue ID `unsplash-hpzmiukz5nw`. It was selected only for the screenshot simulators; production daily background rotation is unchanged.

Saved-route departures were refreshed from live data on **7 September 2026**. History uses an authorised dummy completed journey with a 20-minute Southeastern delay. Journey Stats uses nine consistent dummy completed journeys across the previous month. In Progress and its route map use sample service state and simulated location. No compensation claim was submitted. The fixture runs only when explicitly requested in a simulator capture build and is excluded from the device release. Developer testing controls are absent from the final captures.

Dedicated simulators: iPhone `D6C8476C-FB6A-444D-991A-D33E6DC3C3F1`; iPad `60184FC8-43D7-496F-9712-60C69E6AAD35`.

## App Store content

See [App-Store-Metadata.md](App-Store-Metadata.md) for description, subtitle, promotional text, keywords, What's New, review notes and remaining submission fields.

**Before submission:** reconcile the existing public “Data Not Collected” privacy label with the current privacy manifest and server behaviour, and update the public privacy policy to explain journey/location and diagnostic processing. These changes have been documented but not published.

## Verification logs

- `../../.release-prep/september-final-tests.log`
- `../../.release-prep/september-final-release-tests.log`
- `../../.release-prep/september-submission-archive.log`
