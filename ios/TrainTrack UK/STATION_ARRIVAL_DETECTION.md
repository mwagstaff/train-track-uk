# Station Arrival Detection Strategy

TrainTrack UK detects visits to a journey’s starting station even when the app has remained in the background for days. A confirmed arrival keeps journey updates running while the user remains at the station; departure ends or mutes the matching updates according to the user’s settings.

The implementation is in `NotificationGeofenceManager.swift`, `StationDetectionPolicy.swift`, and `JourneyTrackingCoordinator.swift` in the app target. Scheduled monitoring also uses `NotificationScheduleActivationPolicy` and the locally cached subscriptions in `NotificationSubscriptionStore`.

## Background lifecycle

Automatic monitoring uses a named `CLMonitor` and locally persisted station targets. Region conditions are the primary wake mechanism. Significant-location-change events and bounded location requests provide additional observations; scheduled timers and pushes are not prerequisites for detecting a station visit.

The app holds a `CLServiceSession(authorization: .always)` while automatic monitoring remains enabled. This expresses the feature’s authorization requirement; it does not itself request continuous GPS sampling or show a persistent background-activity indicator. The initial session starts while the app is in the foreground. On every later launch, the app promptly recreates the service session, opens the same monitor, and resumes consuming events before waiting for network data.

Apple preserves outstanding Core Location sessions across suspension and system termination, but only gives the relaunched app a short period to reclaim them. An Always permission shown in Settings is therefore insufficient on its own: session restoration and a live event consumer must also be correct. [Apple’s session lifecycle guidance](https://sosumi.ai/videos/play/wwdc2024/10212)

`CLBackgroundActivitySession` has a different purpose. It extends in-use access with a visible indicator and may support an explicit journey or short precision attempt. A new session must start in the foreground; a background launch can only rejoin an existing session. With Always authorization, automatic scheduled monitoring does not hold one from schedule creation for days or weeks. The degraded When In Use mode may retain a visible background session, but cannot provide the same unattended relaunch behavior as Always authorization. [Background activity sessions](https://sosumi.ai/documentation/corelocation/clbackgroundactivitysession-3mzv3), [background updates](https://sosumi.ai/documentation/corelocation/handling-location-updates-in-the-background)

## Station conditions and geometry

Each selected station coordinate has two primary conditions:

- **Arrival: 150 m.** A satisfied condition supplies direct evidence of station presence. Arrival processing does not require a later continuous location stream.
- **Departure: 250 m.** Leaving the station area supplies departure evidence after arrival has been established.

A separate **500 m approach condition** gives an earlier opportunity to request a bounded precision sample. Its entry does not confirm arrival and its exit does not enlarge the departure threshold. The existing distance-based arrival heuristic uses a 125 m base threshold.

Station coordinates come from the shared station catalogue. Where a station has multiple coordinates, location distance is measured to the nearest coordinate, and departure reasoning considers the union of the monitored station areas. Leaving one anchor’s circle does not mean leaving the whole station. Condition observations carry timestamps and persist across process launches so an old inside state cannot silently become a fresh observation.

No station-specific coordinates are hardcoded into the detection logic. Additional concourse or platform anchors should be added through the station data only after checking their coverage and false-positive risk. Multiple anchors consume monitoring capacity, so their availability does not guarantee every anchor is currently registered.

Core Location permits at most 20 monitored conditions per app. The app allocates priority station arrival/departure pairs before spending remaining capacity on secondary coordinates and approach conditions. Active journey conditions share the same budget. A larger approach ring improves the opportunity for a wake; it provides no delivery-time guarantee. [Condition monitoring](https://sosumi.ai/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions)

## Observation time and delayed delivery

The time of an observation and the time it reaches the app are separate values. The app evaluates `CLMonitor.Event.date` and `CLLocation.timestamp` against the relevant journey and schedule; it does not substitute the delivery time.

For example, an observation recorded at 17:56 and delivered at 18:00 can still establish that the user was at the station during the relevant window. This is historical recovery, not a claim that the user remains at the station at 18:00.

The recovery policy:

1. Accepts observations up to 60 minutes old and rejects future observations.
2. Rejects duplicate or older observations already processed for the same state.
3. Processes location batches in timestamp order, preserving an earlier arrival followed by a later departure.
4. Rejects invalid horizontal accuracy, including negative and non-finite values.
5. Uses observation timestamps for dwell and resets the dwell across gaps longer than 30 seconds.
6. Persists station condition observations so a process restart does not erase the evidence needed to interpret a later exit. The last observed time and last handled time are stored separately, allowing an interrupted event to replay without processing a completed event twice.

A `CLMonitor` record contains the last event handled by the app. It is not a fresh position query and does not advance until the app consumes the event. Event timestamps describe observed condition state, not a guaranteed exact time at which a physical boundary was crossed. [Monitor records and event handling](https://sosumi.ai/videos/play/wwdc2023/10147)

## Bounded precision sampling

A station hint can trigger up to 20 seconds of high-accuracy `CLLocationManager` sampling. The profile requests navigation accuracy, no distance filter, background updates, and disables automatic pausing for the duration of the attempt. Between attempts, the app returns to significant-location-change monitoring and one-shot requests.

Background high-accuracy delivery remains subject to authorization and the app lifecycle. A precision attempt can improve the evidence but must not be required for a valid arrival condition to advance state. The app does not interpret a failed or interrupted request as evidence that the user is outside the station.

The distance heuristic uses:

- Base arrival threshold: 125 m.
- Accepted horizontal accuracy: up to 140 m.
- Activation distance for a precision attempt: 450 m, adjusted for uncertainty.
- Confirmation dwell: 8 seconds, or 4 seconds after a recent region hint.
- Confirmation attempt timeout: 150 seconds.
- Departure fallback: the accuracy envelope lies more than 50 m beyond the 250 m station area for 6 seconds.

Distance and accuracy are supporting evidence. A broad uncertainty envelope alone must not be reported as a precise arrival time, and a long delivery delay must not be counted as continuous dwell.

## Scheduled monitoring

Enabled recurring schedules must remain represented in the local monitoring plan between their active windows. The next scheduled window cannot depend on an in-process timer, a foreground visit, or a timely push recreating its origin conditions.

Each observation is evaluated against the schedule that applies at its timestamp, including day-specific windows and overnight journeys. Schedule-window validity and delayed-delivery retention are separate decisions. Retaining evidence for recovery does not make an out-of-window visit eligible. If observed station presence begins before the window and extends into it, the app can use the window start as the effective arrival time; it does not require a timer wake at that moment. A visit known to have ended before the window cannot establish arrival for that window, and presence intervals longer than the 60-minute recovery limit are not used for this inference.

Origin and destination conditions are available before optional route-geometry enrichment finishes. The local cache can retain up to two downstream intermediate stations from a current service branch, plus the destination. This geometry is refreshed opportunistically and is never evidence that the user caught a particular service. One-off schedules remain available for up to 60 minutes after expiry to evaluate in-window observations; recurring schedules resolve the dated occurrence from the observation time, including weeks after the last foreground session.

A missed origin departure can start a partial journey only after two distinct downstream stations are observed in cached route order. The observations must be 15 seconds to 60 minutes apart, station centers at least 300 m apart, and implied average movement between 4 and 100 m/s. Observations must fall within the dated occurrence’s recovery period and remain no more than 60 minutes old when delivered. One destination event alone cannot start a recovered journey.

These are conservative recovery heuristics, not proof of a particular train. A recovered record begins at the first observed downstream station, leaves its origin departure undetected, and carries an uncertain outcome. History labels the internal start time “Tracking started” instead of “Departed”. An active checkpoint and local station data restore these conditions without needing a network request during launch.

## Diagnostics and verification

Log the observation timestamp, delivery timestamp, age, condition identifier, target route, and whether the observation was accepted or rejected. Include the reason for a rejection so delayed delivery can be distinguished from invalid authorization, stale data, a duplicate, or an ineligible schedule.

On iOS 18+, inspect service-session and condition-event diagnostics, including authorization denial, insufficient in-use access, a required service session, accuracy limitations, condition limits, unsupported conditions, and persistence failures. Temporary full accuracy requests use the `StationArrivalMonitoring` purpose key when foregrounded. The app configuration includes the When In Use and Always usage descriptions and the location background mode.

Automated tests cover delayed delivery, ordering and deduplication, invalid data, observation-gap dwell, persisted region state, schedule windows, and monitoring-condition limits. These tests verify app decisions, not iOS wake timing.

Physical-device checks must cover:

- A normal station visit after the app has stayed backgrounded overnight and across several schedule windows.
- A system-terminated app restored by location events without network access.
- An entry and exit delivered together, and events delivered after a schedule window ends.
- A multi-coordinate station, including exit from one anchor while still inside another.
- Reduced Accuracy, authorization changes, reboot and first unlock, and user force quit as distinct scenarios.

Apple controls when conditions are observed and when an app is woken. Region events may be delayed or unavailable; no radius guarantees a notification at the instant of arrival. Reboot and user force quit are different from ordinary background suspension and must not be advertised as unconditional recovery cases. Monitor restoration should be checked after the first unlock following reboot. [Apple’s region guidance](https://sosumi.ai/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions)
