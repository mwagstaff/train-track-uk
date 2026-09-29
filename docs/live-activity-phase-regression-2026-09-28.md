# KTH–VIC Live Activity investigation, 28 September 2026

The Live Activity reverted from an in-progress arrival display to a departure
board while the app continued tracking the correct 07:42 Kent House service.
This is confirmed by production notification event records, not just inferred
from the screenshots. All times below are British Summer Time.

## Evidence

Read-only inspection of `notification_events` for the matching activity found:

| Time | Revision | Phase | Main time | Scheduled departure |
| --- | --- | --- | --- | --- |
| 07:43:22.339 | 26 | en_route | 08:03 | 07:42 |
| 07:43:22.676 | 27 | en_route | 08:03 | 07:42 |
| 07:43:23.068 | 28 | pending_start | 07:57 | 07:57 |
| 07:56:00.846 | 33 | pending_start | 07:57 | 07:57 |
| 07:56:28.720 | 36 | en_route | 08:03 | 07:42 |

The intermediate pushes also remained in `pending_start`. The 07:56 push
matches the lock-screen screenshot, including the following 08:12 and 08:27
departures. The subscription retained the matched 07:42 service ID throughout
the regression. APNs accepted these pushes with HTTP 200; acceptance does not
prove the exact time the phone displayed them.

Journey-tracking logs independently show progress for the 07:42 service through
Penge East, Sydenham Hill, West Dulwich, Herne Hill and Brixton. At 07:56:28 the
corrected Live Activity push described the train between Brixton and Victoria.

## Code findings

- `api/train-track-api/lib/live-activity-manager.js`, `handleJourneyPhase`, accepts
  any valid phase when its observation timestamp is not older. It permits
  `en_route` to regress to `pending_start`, retaining the preferred service ID.
- Departure polling only uses in-progress service handling for `en_route` and
  `arrived`. Once reset, the departed 07:42 service is replaced by the next
  available departure, explaining the displayed 07:57 and arrival label 08:19.
- `registerSubscription` can also overwrite an existing phase from a registration
  payload without a phase progression guard.
- On iOS, `JourneyTrackingCoordinator.arm` publishes `pendingStart` for an armed
  candidate. Its active-journey guard compares subscription IDs, whereas Live
  Activity phase updates target a route. This is a possible reset source, not
  proven to be the callback responsible on this phone.

There was a re-registration at 07:43:22.384, followed by correct en-route pushes.
The stored registration event does not include its phase, and successful status
requests are not individually audited. These records cannot distinguish the
exact reset caller or request ordering. Device diagnostics would be needed for
that last attribution.

## Verification and recommended correction

An isolated local reproduction used `LiveActivityManager` with persistence and
polling stubbed out. Sending `en_route` with a matched train at timestamp 1000,
then `pending_start` at 1001, reproduced the phase reset while retaining the
matched train. It performed no database writes or push sends.

Protect an existing activity from pre-boarding phase resets after boarding,
across both status updates and registrations. New journeys should have a new
activity/session identity; legitimate corrections of an in-progress train and
resumption after arrival must remain supported. The iOS candidate-arming path
should also avoid resetting a matching active route. Add regression coverage
for these transitions and log accepted/rejected phase changes for attribution.

The initial investigation made no application code or production configuration changes.

## Fix applied locally

Following the request to apply the fix:

- The server ignores `pending_start` / `at_start` status updates for an existing
  `en_route` / `arrived` activity before advancing its observation timestamp.
- Late registrations refresh the push token while preserving the journey phase,
  matched train and automatic-ending preferences when attempting that reset.
- The iOS Live Activity manager rejects pre-boarding updates for a matching
  actively tracked route, or an activity already underway/arrived.
- Train corrections, unconfirmed-train recovery, arrival, resumption and new
  pre-boarding activities remain supported.

Validation: 57 selected backend tests passed across Live Activity, exclusivity,
journey tracking and live-session origin suites. All 48 selected iOS simulator
tests passed across journey history and Live Activity update policy suites.
The existing live-session test encountered an unavailable local Mongo connection
and passed after its timeout. The iOS build emitted existing unrelated actor
isolation and extension-version warnings.

The backend has not been deployed and the iOS change has not been released.
