# Station Arrival Detection Strategy

This document describes the background arrival-detection strategy used by TrainTrack UK to decide when a user has reached the starting station for an active "journey updates" session.

The goal is to make the "Welcome to <station>" flow reliable enough to:

- end the matching Live Activity promptly
- send the mute-on-arrival request to the backend
- prevent further journey-update notifications for that leg

The implementation lives in [NotificationGeofenceManager.swift](./TrainTrack%20UK/NotificationGeofenceManager.swift).

## Why This App Needs More Than Geofencing

Simple `CLCircularRegion` entry handling was not reliable enough on its own.

Practical issues:

- iOS region events can arrive late or not at all
- the app can be cold-launched from a region event with very little execution time
- Reduced Accuracy location permission makes region monitoring unreliable
- a user may already be inside the region when monitoring starts
- train stations are larger than bike docks, but they are still small enough that GPS noise matters

For TrainTrack UK the correct pattern is therefore:

1. Use region monitoring as a helper and wake-up source.
2. Run continuous standard location updates for the active session.
3. Judge arrival using both raw distance and the reported horizontal-accuracy envelope.
4. Require a short confirmation dwell before muting.

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
- `allowsBackgroundLocationUpdates = true` while monitoring is active

When the app detects Reduced Accuracy on iOS 14+, it requests temporary full accuracy using:

- `accuracyAuthorization`
- `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`

Purpose key used by TrainTrack UK:

- `StationArrivalMonitoring`

This matters because Apple documents that Reduced Accuracy prevents effective region monitoring and ignores higher desired-accuracy settings.

## Tracking Mode

While station-arrival monitoring is active, the app uses the same two-stage tracking pattern as the dock-arrival flow in My Boris Bikes:

1. Start continuous low-sensitivity location updates for the active session.
2. Escalate to high-sensitivity updates when a region hint arrives or a location fix is plausibly within the station activation distance.

The low-sensitivity profile uses:

- `desiredAccuracy = kCLLocationAccuracyNearestTenMeters`
- `distanceFilter = 25`
- `activityType = .fitness`
- `pausesLocationUpdatesAutomatically = false`
- `allowsBackgroundLocationUpdates = true`
- `showsBackgroundLocationIndicator = true`

The high-sensitivity confirmation profile uses:

- `desiredAccuracy = kCLLocationAccuracyBestForNavigation`
- `distanceFilter = kCLDistanceFilterNone`
- `activityType = .otherNavigation`
- `pausesLocationUpdatesAutomatically = false`
- `allowsBackgroundLocationUpdates = true`
- `showsBackgroundLocationIndicator = true`

This keeps the app alive and receiving updates in the background without running the most aggressive location profile until the user is likely close enough for arrival confirmation.

## Role Of Region Monitoring

Region monitoring is still enabled, but it is not the primary detector.

Current role:

- wake the app when iOS delivers an entry event
- handle the "already inside" case through `didDetermineState(.inside)`
- provide a secondary hint that reduces the confirmation dwell slightly
- continue supporting departure-geofence behavior for Live Activity auto-end

Important rule:

- region entry does not mute immediately

Instead, entry and inside events:

1. reconstruct the target if needed after a cold wake
2. restart continuous tracking if required
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

With the current threshold this yields a practical acceptance cap of `130m`.

### Base Arrival Threshold

Current setting:

- base arrival threshold = `80m`

This is intentionally wider than the docking-app version because a station approach area is larger and the user experience is better if the app mutes slightly early rather than missing arrival.

### Threshold Expansion

The app expands the threshold when GPS is noisy.

Current setting:

- add `60%` of excess uncertainty above the base threshold
- cap expansion at `45m`

So the threshold can grow from `80m` to a maximum of `125m`.

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

`CLLocationManager` persists monitored regions across launches, but the in-memory target list does not.

Because of that, TrainTrack UK reconstructs a temporary monitoring target from the region identifier on region entry / inside callbacks. The app then:

1. resolves the starting station from the CRS code
2. restarts continuous tracking
3. evaluates the latest usable location immediately when available

This makes region events useful even when the app process was previously dead.

## Session Start

When a journey-updates session becomes geofence-eligible:

1. load the station list if needed
2. build monitored targets from active live sessions
3. request Always authorization if needed
4. request temporary full accuracy if the app is active and accuracy is reduced
5. start continuous location updates
6. start region monitoring for the same targets
7. request region state immediately for the "already inside" case

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

When arrival is confirmed or all monitored live sessions disappear:

1. stop continuous location updates
2. stop region monitoring for removed targets
3. invalidate the background activity session if nothing remains
4. clear in-memory confirmation state

Arrival confirmation then triggers the existing mute flow:

1. mark the leg muted locally
2. send the backend terminate request with any configured delay
3. clear pending departure auto-end state
4. stop the matching Live Activity
5. delete matching live-session records

## Current TrainTrack UK Tunables

These are the active values in `NotificationGeofenceManager`:

- region radius: `300m`
- base arrival threshold: `80m`
- activation distance: `450m`
- accepted horizontal accuracy: `60m ... 140m`
- threshold expansion factor: `0.6`
- max threshold expansion: `45m`
- standard dwell: `8s`
- region-hint dwell: `4s`
- confirmation timeout: `150s`
- reset hysteresis: `20m`

## Tuning Guidance

If the app still misses arrivals:

- increase the accepted horizontal-accuracy ceiling
- increase the maximum threshold expansion
- reduce dwell slightly
- increase activation distance

If the app starts muting too early:

- reduce the base arrival threshold
- reduce the maximum threshold expansion
- increase dwell slightly
- increase reset hysteresis if confirmation is too eager near busy roads or station-adjacent routes

## Apple APIs Worth Reviewing

- [`CLLocationManager.allowsBackgroundLocationUpdates`](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates)
- [`CLLocationManager.desiredAccuracy`](https://developer.apple.com/documentation/corelocation/cllocationmanager/desiredaccuracy)
- [`CLLocationManager.activityType`](https://developer.apple.com/documentation/corelocation/cllocationmanager/activitytype)
- [`CLLocationManager.pausesLocationUpdatesAutomatically`](https://developer.apple.com/documentation/corelocation/cllocationmanager/pauseslocationupdatesautomatically)
- [`CLLocationManager.accuracyAuthorization`](https://developer.apple.com/documentation/corelocation/cllocationmanager/accuracyauthorization)
- [`CLLocationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`](https://developer.apple.com/documentation/corelocation/cllocationmanager/requesttemporaryfullaccuracyauthorization(withpurposekey:))
- [`CLLocationManager.startMonitoring(for:)`](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoring(for:))

## Short Version

For reliable station-arrival detection on iOS:

- do not rely on geofencing alone
- keep continuous background location updates running for the active session
- request full accuracy when possible
- account for GPS uncertainty explicitly
- use regions as helper signals, not as the final source of truth
- keep confirmation short, but not instantaneous

That is the strategy TrainTrack UK now uses for muting journey updates when the user reaches the starting station.
