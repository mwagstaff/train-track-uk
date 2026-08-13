# Station Arrival Detection Strategy

This document describes the background arrival-detection strategy used by TrainTrack UK to decide when a user has reached the starting station for an active "journey updates" session.

The goal is to make station-arrival detection reliable enough to:

- confirm that the user reached the starting station
- keep journey updates active while the user remains at the station
- mute notifications and optionally end the matching Live Activity once the user leaves the 250m station area

The implementation lives in [NotificationGeofenceManager.swift](./TrainTrack%20UK/NotificationGeofenceManager.swift).

## Why This App Needs More Than Geofencing

Simple region entry handling was not reliable enough on its own. The app now uses a named
`CLMonitor`, whose condition records and last-observed states persist across launches.

Practical issues:

- iOS region events can arrive late or not at all
- the app can be cold-launched from a region event with very little execution time
- Reduced Accuracy location permission makes region monitoring unreliable
- a user may already be inside the region when monitoring starts
- train stations are larger than bike docks, but they are still small enough that GPS noise matters

For TrainTrack UK the pattern is therefore a **two-ring geofence** plus a homing heuristic:

1. **Inner "arrival" ring (~150m, primary).** Entering it is treated as arrival directly.
   A region boundary crossing reliably wakes even a suspended or terminated app, so this
   path does **not** depend on continuous background updates surviving the approach — which
   is the failure mode the homing heuristic alone cannot cover (iOS grants only a brief wake
   after a geofence event and may re-suspend the app before it homes in, especially once the
   app has been dormant for a day or two).
2. **Outer "approach" ring (~250m).** Wakes the app, starts a bounded precision sample,
   and drives departure detection on exit.
3. **Homing heuristic (secondary).** While the outer ring is active, judge arrival using
   both raw distance and the reported horizontal-accuracy envelope, with a short confirmation
   dwell before arming station-exit cleanup. This still confirms arrival when continuous
   updates do survive, and complements the inner ring. Arrival confirmation is idempotent, so
   whichever path fires first wins and the other is a no-op.

## TrainTrack-Specific Adaptation

The original Boris Bikes logic was tuned for cyclists arriving at a very small dock footprint.

TrainTrack UK needs slightly broader thresholds because users may:

- walk to a concourse or side entrance
- be dropped off at a forecourt or taxi rank
- park nearby and approach from a larger station perimeter
- enter a multi-platform station where "arrival" should be recognized before the exact platform area

That means this app intentionally allows a larger arrival area than the docking-app version.

## Session Model

The app monitors one or more active journey-update legs at a time. Each monitored leg stores:

- `subscriptionId`
- `from` CRS
- `to` CRS
- station name
- station coordinate
- confirmation state for the current arrival attempt

Monitoring is only active while there are eligible live sessions with `muteOnArrival != false`.

## Permission And Background Requirements

The feature prefers Always authorization for the most reliable cold-wake behavior, but will still monitor in a degraded `authorizedWhenInUse` state while continuing to request Always authorization. The app configuration assumes:

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `NSLocationTemporaryUsageDescriptionDictionary`
- `UIBackgroundModes` includes `location`
- `allowsBackgroundLocationUpdates = true` only during bounded precision sampling

When the app detects Reduced Accuracy on iOS 14+, it requests temporary full accuracy using:

- `accuracyAuthorization`
- `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`

Purpose key used by TrainTrack UK:

- `StationArrivalMonitoring`

This matters because Apple documents that Reduced Accuracy prevents effective region monitoring and ignores higher desired-accuracy settings.

## Tracking Mode

While station-arrival monitoring is active, the app uses the same two-stage tracking pattern as the dock-arrival flow in My Boris Bikes:

1. Use significant-location-change monitoring as the low-power recovery path.
2. Request a one-shot location on sync and background-push wakes.
3. Escalate to a maximum 20-second high-sensitivity burst when a region hint arrives or a
   location fix is plausibly within the station activation distance.

The low-power profile uses:

- significant-location-change monitoring
- `desiredAccuracy = kCLLocationAccuracyHundredMeters` for one-shot requests
- `distanceFilter = 100`
- `activityType = .fitness`
- `pausesLocationUpdatesAutomatically = true`

The high-sensitivity confirmation profile uses:

- `desiredAccuracy = kCLLocationAccuracyBestForNavigation`
- `distanceFilter = kCLDistanceFilterNone`
- `activityType = .otherNavigation`
- `pausesLocationUpdatesAutomatically = false`
- `allowsBackgroundLocationUpdates = true`
- `showsBackgroundLocationIndicator = true`
- maximum burst duration = `20s`

This avoids continuous GPS use between station decisions. `CLBackgroundActivitySession` is
held only for a precision burst, except when the user granted only When In Use authorization.

## Role Of Region Monitoring

Condition monitoring is still enabled, but it is not the only detector.

The app enforces Core Location's 20-condition limit. It reserves an inner/outer pair for
each highest-priority journey before adding secondary coordinates, prioritising journeys
awaiting departure, then nearby and soonest-expiring journeys.

Current role:

- wake the app when iOS delivers an entry event
- handle the "already inside" case through `didDetermineState(.inside)`
- provide a secondary hint that reduces the confirmation dwell slightly
- continue supporting departure-geofence behavior for Live Activity auto-end

Important rule:

- region entry does not mute immediately

An inner-ring entry confirms arrival and arms departure cleanup immediately. Outer-ring entry
and inside events:

1. resolve the persisted local target
2. start a bounded precision burst if required
3. record a region hint
4. re-run the same arrival heuristic against the latest usable location

## Arrival Heuristic

Each accepted `CLLocation` is evaluated against every monitored station.

The app computes:

- `rawDistance`
- `horizontalAccuracy`
- `compensatedDistance = max(0, rawDistance - horizontalAccuracy)`
- `effectiveArrivalThreshold`

### Accepted Accuracy

TrainTrack UK ignores fixes with poor accuracy.

Current setting:

- baseline = `arrivalThreshold + 50m`
- clamp to `60m ... 140m`

With the current threshold this yields a practical acceptance cap of `140m`.

### Base Arrival Threshold

Current setting:

- base arrival threshold = `125m`

This is intentionally wider than the docking-app version because a station approach area is larger and the user experience is better if the app confirms arrival early and waits for station exit rather than missing arrival.

### Threshold Expansion

The app expands the threshold when GPS is noisy.

Current setting:

- add `60%` of excess uncertainty above the base threshold
- cap expansion at `45m`

So the threshold can grow from `125m` to a maximum of `134m` within the current accepted-accuracy cap.

### Candidate Rule

The location becomes an arrival candidate when:

- `min(rawDistance, compensatedDistance) <= effectiveArrivalThreshold`

This lets the app treat the destination as plausibly reached when the uncertainty envelope overlaps the station strongly enough, instead of trusting the reported point estimate as exact ground truth.

## Confirmation Logic

The app does not fire on the first plausible fix.

Current settings:

- activation distance = `450m`
- standard dwell = `8s`
- dwell after a recent region hint = `4s`
- confirmation timeout = `150s`
- reset hysteresis = `20m`

Interpretation:

- once the user is reasonably near the station, a plausible fix starts confirmation
- if qualifying fixes continue long enough, arrival is confirmed
- if the user clearly moves back away from the station, confirmation resets
- if the app keeps receiving only poor-quality fixes for too long, confirmation times out and restarts later

The dwell is still short because long dwells tend to increase missed arrivals more than they reduce false positives for this workflow.

## Cold-Wake Behavior

`CLMonitor` persists condition records across launches. TrainTrack also persists the matching
route and station target locally so a cold wake never needs the stations API before recording
an arrival or departure.

On launch, the app then:

1. restores persisted targets from the app-group store
2. promptly recreates the Always service session and named monitor event sequence
3. starts the low-power recovery path and evaluates the latest usable location when available

This makes region events useful even when the app process was previously dead.

## Session Start

When a journey-updates session becomes geofence-eligible:

1. load the station list if needed
2. build monitored targets from active live sessions
3. request Always authorization if needed
4. request temporary full accuracy if the app is active and accuracy is reduced
5. start significant-change monitoring and request one current location
6. add prioritized `CLMonitor` conditions within the 20-condition budget
7. assume outside when adding a new condition so an already-inside correction produces an event

## Each Location Update

For each new `CLLocation`:

1. reject negative or stale fixes
2. reject fixes worse than the accepted-accuracy cap
3. compute raw distance
4. compute compensated distance
5. compute the effective threshold
6. start or continue confirmation if the location qualifies
7. confirm arrival when the dwell requirement is satisfied

## Session End

When all monitored live sessions disappear:

1. stop significant-change and precision location updates
2. remove obsolete monitor conditions
3. invalidate the background activity session if nothing remains
4. clear in-memory confirmation state

Arrival confirmation keeps monitoring active and arms station-exit cleanup:

1. clear the pending-arrival health marker
2. mark the leg as awaiting station-exit cleanup
3. continue Live Activity and notification updates while the user remains within 250m
4. on outer-region exit, mark the leg muted locally and send the backend terminate request
5. optionally stop the matching Live Activity, depending on the user's auto-end setting
6. remove matching notification live-session records locally

## Current TrainTrack UK Tunables

These are the active values in `NotificationGeofenceManager`:

- outer (approach) region radius: `250m`
- inner (arrival) region radius: `150m`
- base arrival threshold (homing heuristic): `125m`
- activation distance: `450m`
- accepted horizontal accuracy: `60m ... 140m`
- threshold expansion factor: `0.6`
- max threshold expansion: `45m`
- standard dwell: `8s`
- region-hint dwell: `4s`
- confirmation timeout: `150s`
- reset hysteresis: `20m`
- precision sampling burst: at most `20s`
- departure fallback: accuracy envelope at least `50m` beyond the `250m` outer radius
- departure confirmation dwell: `6s`
- persisted departure-state lifetime: `4h`
- maximum monitored conditions: `20` (two per station coordinate)

## Tuning Guidance

If the app still misses arrivals:

- increase the accepted horizontal-accuracy ceiling
- increase the maximum threshold expansion
- reduce dwell slightly
- increase activation distance

If the app starts confirming arrival too early:

- reduce the base arrival threshold
- reduce the maximum threshold expansion
- increase dwell slightly
- increase reset hysteresis if confirmation is too eager near busy roads or station-adjacent routes

## Resilience Backstops

Continuous background location updates after a region-enter wake are **not guaranteed to
persist**. iOS grants only a short execution window for a geofence wake and can re-suspend
the app before the homing step reaches the arrival threshold — especially once the app has
been dormant for a day or two (reduced Background App Refresh budget). When that happens the
user reaches the station but arrival is never confirmed, and historically this failed
silently (no station-exit cleanup, no indication anything went wrong).

The **inner arrival ring** (above) is the primary fix: a tight region crossing confirms
arrival without relying on continuous updates. The two backstops below remain as defence in
depth for the residual cases where even the inner ring's entry event is delayed or dropped
(iOS region events are best-effort):

1. **Background-wake re-check** (`refreshArrivalFromBackgroundWake`) — every background push
   requests a fresh location even when no entry event was observed, recovering completely
   missed entries. After arrival, the same path conservatively confirms a missed exit when
   `distance - accuracy` remains at least 50m beyond the outer radius for 6 seconds.

2. **Missed-arrival health notification** — when the user **enters** the origin geofence we
   set a pending-arrival marker (`NotificationMuteStorage.markArrivalDetectionPending`),
   cleared when arrival is confirmed (`armDepartureCleanupAfterArrival`). If the marker survives to the
   region **exit** (they reached and left the station without us detecting arrival) — or to a
   later wake more than 5 minutes after entry — we post a clear, tappable notification
   (`ARRIVAL_DETECTION_HEALTH` category, `arrival_detection_failed` alert type). Tapping it
   reopens the app, which re-arms monitoring via the foreground subscription/geofence sync
   (`NotificationAlertHandler.reArmArrivalDetection`). The marker is consumed atomically so
   the notification fires at most once per leg per day. The marker is set on outer-region
   entry and on outer-region `didDetermineState(.inside)`, because scheduled starts can
   register monitoring after the user is already inside the station area. It is not set from
   inner arrival-region state alone, which avoids false positives for users whose home is
   already inside the station geofence.

## Apple APIs Worth Reviewing

- [`CLLocationManager.allowsBackgroundLocationUpdates`](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates)
- [`CLLocationManager.desiredAccuracy`](https://developer.apple.com/documentation/corelocation/cllocationmanager/desiredaccuracy)
- [`CLLocationManager.activityType`](https://developer.apple.com/documentation/corelocation/cllocationmanager/activitytype)
- [`CLLocationManager.pausesLocationUpdatesAutomatically`](https://developer.apple.com/documentation/corelocation/cllocationmanager/pauseslocationupdatesautomatically)
- [`CLLocationManager.accuracyAuthorization`](https://developer.apple.com/documentation/corelocation/cllocationmanager/accuracyauthorization)
- [`CLLocationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`](https://developer.apple.com/documentation/corelocation/cllocationmanager/requesttemporaryfullaccuracyauthorization(withpurposekey:))
- [`CLMonitor`](https://developer.apple.com/documentation/corelocation/clmonitor-2r51v)
- [`CLBackgroundActivitySession`](https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession-3mzv3)

## Short Version

For reliable station-arrival detection on iOS:

- use a tight inner geofence as the primary arrival trigger — a region crossing reliably
  wakes even a suspended/terminated app, so it does not depend on continuous updates
- do not rely on continuous background location updates surviving a geofence wake; treat the
  homing heuristic as a secondary confirmation, not the primary path
- request full accuracy when possible
- account for GPS uncertainty explicitly in the homing heuristic
- keep confirmation short, but not instantaneous
- surface silent failures to the user rather than failing quietly

That is the strategy TrainTrack UK now uses for muting journey updates after the user reaches and then leaves the starting station.
