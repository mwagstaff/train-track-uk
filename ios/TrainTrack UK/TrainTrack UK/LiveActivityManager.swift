import Foundation
import ActivityKit
import JourneyActivityShared
// Shared attributes type is included in both app and widget targets
import SwiftUI
import Combine
import OSLog
import UIKit

// Type alias for convenience - ActivityAttributes conformance is now in the shared package
typealias JourneyActivityAttributes = JourneyActivityShared.JourneyActivityAttributes

@MainActor
final class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    private struct RoutePresentation {
        let title: String
        let deepLinkFromCRS: String
        let deepLinkToCRS: String
    }

    // Journey details can now run up to 3 sessions in parallel, each with up to 3 legs.
    private let maxConcurrentActivities = 9

    private let logger = Logger(subsystem: "dev.skynolimit.traintrack.app", category: "LiveActivityManager")

    // Track multiple activities with their associated data
    private struct TrackedActivity {
        let activity: Activity<JourneyActivityAttributes>
        let fromCRS: String
        let toCRS: String
        let startedAt: Date
        var preferredServiceID: String?
        var journeyUpdatesEnabled: Bool
        var scheduleKey: String?
        var windowStart: String?
        var windowEnd: String?
        var timer: Timer?
        var fallbackEndTimer: Timer?
    }
    private var trackedActivities: [String: TrackedActivity] = [:] // keyed by activity.id

    private var activityUpdatesTask: Task<Void, Never>? = nil
    private var stateMonitorTasks: [Activity<JourneyActivityAttributes>.ID: Task<Void, Never>] = [:]
    private var pushTokenTasks: [Activity<JourneyActivityAttributes>.ID: Task<Void, Never>] = [:]
    private var pushToStartTokenTask: Task<Void, Never>? = nil
    private var lastEndedAt: Date? = nil
    private let autoRestartSuppressionWindow: TimeInterval = 10
    private let durationKey = "liveActivityDurationMinutes"
    private var lastBackendCheckInAt: Date? = nil
    private let backendCheckInMinIntervalSeconds: TimeInterval = 5
    private var lastRegisteredPushToStartToken: String? = nil
    private var notificationLiveSessionEnsuredActivityIDs: Set<String> = []

    // Live Activity lifetime; set to nil to disable auto-expiry and rely on manual dismissal.
    private let activityExpiryInterval: TimeInterval? = nil
    // Local fallback end if remote end push never arrives. Scheduled journeys use their window end.
    private var fallbackEndInterval: TimeInterval? { durationSeconds }
    // Force end any lingering activity as a last-resort safety.
    private var forceEndAfterSeconds: TimeInterval { durationSeconds }

    // Global monitor timer for all activities
    private var monitorTimer: Timer? = nil

    // User-configurable duration in minutes (default 60). Reads from UserDefaults.
    private var durationSeconds: TimeInterval {
        let storedMinutes = UserDefaults.standard.integer(forKey: durationKey)
        let minutes = min(120, max(1, storedMinutes == 0 ? 60 : storedMinutes))
        let seconds = Double(minutes * 60)
        print("🔧 [LiveActivity] Duration preference: \(minutes) minute\(minutes == 1 ? "" : "s") (\(seconds) seconds)")
        return seconds
    }

    private func scheduledWindowEndDate(
        scheduleKey: String?,
        windowStart: String?,
        windowEnd: String?,
        referenceDate: Date
    ) -> Date? {
        guard let endMinutes = minutesSinceMidnight(windowEnd) else { return nil }

        let calendar = Calendar.current
        var components = scheduledDateComponents(from: scheduleKey)
            ?? calendar.dateComponents([.year, .month, .day], from: referenceDate)
        components.hour = endMinutes / 60
        components.minute = endMinutes % 60
        components.second = 0

        guard var endDate = calendar.date(from: components) else { return nil }
        if let startMinutes = minutesSinceMidnight(windowStart),
           endMinutes < startMinutes {
            endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        }
        return endDate
    }

    private func scheduledDateComponents(from scheduleKey: String?) -> DateComponents? {
        guard let scheduleKey else { return nil }
        let parts = scheduleKey.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }

        let dateParts = parts[3].split(separator: "-")
        guard dateParts.count == 3,
              let year = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let day = Int(dateParts[2]) else {
            return nil
        }

        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.month = month
        components.day = day
        return components
    }

    private func minutesSinceMidnight(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    private func fallbackEndDeadline(
        scheduleKey: String?,
        windowStart: String?,
        windowEnd: String?,
        now: Date = Date()
    ) -> (date: Date, source: String)? {
        if let scheduledEnd = scheduledWindowEndDate(
            scheduleKey: scheduleKey,
            windowStart: windowStart,
            windowEnd: windowEnd,
            referenceDate: now
        ) {
            return (scheduledEnd, "schedule_window_end")
        }

        guard let interval = fallbackEndInterval else { return nil }
        return (now.addingTimeInterval(interval), "duration_preference")
    }

    private func forceEndDeadline(
        for tracked: TrackedActivity,
        now: Date
    ) -> (date: Date, source: String) {
        if let scheduledEnd = scheduledWindowEndDate(
            scheduleKey: tracked.scheduleKey,
            windowStart: tracked.windowStart,
            windowEnd: tracked.windowEnd,
            referenceDate: now
        ) {
            return (scheduledEnd, "schedule_window_end")
        }

        return (
            tracked.startedAt.addingTimeInterval(forceEndAfterSeconds),
            "duration_preference"
        )
    }

    // Published properties for UI binding
    @Published var isActive: Bool = false
    @Published var activeJourneys: [(fromCRS: String, toCRS: String)] = []
    @Published var lastMessage: String? = nil

    // Legacy properties for backward compatibility
    var currentFromCRS: String? { activeJourneys.first?.fromCRS }
    var currentToCRS: String? { activeJourneys.first?.toCRS }

    private init() {
        startActivityLifecycleLogging()
        startPushToStartTokenObservation()
        updatePublishedState()
    }

    deinit {
        activityUpdatesTask?.cancel()
        stateMonitorTasks.values.forEach { $0.cancel() }
        pushToStartTokenTask?.cancel()
    }

    /// Check if there's an active Live Activity for the given journey
    func isActive(for journey: Journey) -> Bool {
        let fromCRS = journey.fromStation.crs.uppercased()
        let toCRS = journey.toStation.crs.uppercased()
        return trackedActivities.values.contains {
            $0.fromCRS.uppercased() == fromCRS && $0.toCRS.uppercased() == toCRS
        } || systemActivities(forFromCRS: fromCRS, toCRS: toCRS).isEmpty == false
    }

    /// Check if an active Live Activity exists for the given journey and preferred service.
    func isActive(for journey: Journey, preferredServiceID: String?) -> Bool {
        guard let preferredServiceID else { return isActive(for: journey) }
        let fromCRS = journey.fromStation.crs.uppercased()
        let toCRS = journey.toStation.crs.uppercased()
        return trackedActivities.values.contains {
            $0.fromCRS.uppercased() == fromCRS
                && $0.toCRS.uppercased() == toCRS
                && $0.preferredServiceID == preferredServiceID
        }
    }

    /// Get the activity ID for a specific journey (if active)
    func activityID(for journey: Journey) -> String? {
        let fromCRS = journey.fromStation.crs.uppercased()
        let toCRS = journey.toStation.crs.uppercased()
        if let trackedID = trackedActivities.first(where: {
            $0.value.fromCRS.uppercased() == fromCRS && $0.value.toCRS.uppercased() == toCRS
        })?.key {
            return trackedID
        }
        return systemActivities(forFromCRS: fromCRS, toCRS: toCRS).first?.id
    }

    func preferredServiceID(fromCRS: String, toCRS: String) -> String? {
        trackedActivities.values.first {
            $0.fromCRS.caseInsensitiveCompare(fromCRS) == .orderedSame
                && $0.toCRS.caseInsensitiveCompare(toCRS) == .orderedSame
        }?.preferredServiceID
    }

    /// Get the count of currently active Live Activities
    var activeCount: Int {
        return Set(
            currentSystemActivities().map { $0.id }
                + trackedActivities.keys
        ).count
    }

    func refreshIfActive(journeyStore: JourneyStore, depStore: DeparturesStore) async {
        if trackedActivities.isEmpty {
            await registerAnyUnregisteredActivities()
        }

        guard !trackedActivities.isEmpty else {
            print("⚠️ [LiveActivity] No active activities, skipping refresh")
            return
        }

        print("🔄 [LiveActivity] refreshIfActive called for \(trackedActivities.count) active activities")

        // Refresh all tracked activities
        for (activityID, tracked) in trackedActivities {
            let fromCRS = tracked.fromCRS
            let toCRS = tracked.toCRS

            print("🔄 [LiveActivity] Refreshing activity \(activityID): \(fromCRS) → \(toCRS)")

            // Find the matching journey
            if let journey = journeyStore.journeys.first(where: {
                $0.fromStation.crs == fromCRS && $0.toStation.crs == toCRS
            }) {
                print("✅ [LiveActivity] Found existing journey for \(activityID), refreshing...")
                await refreshAndUpdate(for: journey, depStore: depStore, activityID: activityID)
            } else {
                print("⚠️ [LiveActivity] Journey not found in store for \(activityID), attempting to create temporary journey...")

                // Try to find stations and create a temporary journey
                if let fromStation = StationsService.shared.stations.first(where: { $0.crs == fromCRS }),
                   let toStation = StationsService.shared.stations.first(where: { $0.crs == toCRS }) {
                    let tempJourney = Journey(fromStation: fromStation, toStation: toStation, favorite: false)
                    print("✅ [LiveActivity] Created temporary journey for \(activityID), refreshing...")
                    await refreshAndUpdate(for: tempJourney, depStore: depStore, activityID: activityID)
                } else {
                    print("❌ [LiveActivity] Could not find stations for \(fromCRS) → \(toCRS)")
                }
            }
        }
    }

    func start(
        for journey: Journey,
        depStore: DeparturesStore,
        preferredServiceID: String? = nil,
        triggeredByUser: Bool = false,
        bypassSuppression: Bool = false,
        allowAutomaticStart: Bool = false,
        journeyUpdatesEnabled: Bool = true,
        scheduleKey: String? = nil,
        windowStart: String? = nil,
        windowEnd: String? = nil
    ) async {
        guard triggeredByUser || allowAutomaticStart else {
            print("🚫 [LiveActivity] Start ignored (not user-triggered; auto-starts disabled)")
            return
        }
        if !bypassSuppression, let lastEndedAt, Date().timeIntervalSince(lastEndedAt) < autoRestartSuppressionWindow {
            print("🚫 [LiveActivity] Start suppressed to avoid immediate auto-restart (last end \(Date().timeIntervalSince(lastEndedAt))s ago)")
            return
        }

        let applicationState = UIApplication.shared.applicationState
        if allowAutomaticStart && !triggeredByUser && applicationState != .active {
            let matchingSystemActivities = systemActivities(
                forFromCRS: journey.fromStation.crs.uppercased(),
                toCRS: journey.toStation.crs.uppercased()
            )
            ClientDiagnosticsLogger.log("live_activity", "automatic_background_start_probe", metadata: [
                "application_state": applicationState.rawValue,
                "from": journey.fromStation.crs.uppercased(),
                "to": journey.toStation.crs.uppercased(),
                "matching_system_activity_count": matchingSystemActivities.count,
                "tracked_count": trackedActivities.count,
                "schedule_key": scheduleKey
            ])
            DebugLogStore.shared.log(
                "Scheduled Live Activity background probe for \(journey.fromStation.crs.uppercased())→\(journey.toStation.crs.uppercased()): system activities=\(matchingSystemActivities.count), appState=\(applicationState.rawValue)",
                category: "Scheduled"
            )

            for activity in matchingSystemActivities where trackedActivities[activity.id] == nil {
                await registerRemoteStartedActivityIfNeeded(activity)
            }

            if !matchingSystemActivities.isEmpty {
                return
            }

            DebugLogStore.shared.log(
                "No push-to-start Live Activity found for \(journey.fromStation.crs.uppercased())→\(journey.toStation.crs.uppercased()); attempting local Activity request fallback",
                category: "Scheduled"
            )
        }

        // Check if already tracking this journey. If a preferred service was provided,
        // update the tracked preference and refresh immediately.
        if let existingActivityID = activityID(for: journey) {
            let route = routePresentation(for: journey)
            if let preferredServiceID,
               var tracked = trackedActivities[existingActivityID],
               tracked.preferredServiceID != preferredServiceID {
                tracked.preferredServiceID = preferredServiceID
                trackedActivities[existingActivityID] = tracked
                print("✅ [LiveActivity] Updated preferred service to \(preferredServiceID) for \(journey.fromStation.crs) → \(journey.toStation.crs)")
                if let tokenData = tracked.activity.pushToken {
                    let tokenString = encodePushToken(tokenData)
                    _ = await sendLiveActivityRegistration(
                        activityID: existingActivityID,
                        tokenString: tokenString,
                        fromCRS: journey.fromStation.crs,
                        toCRS: journey.toStation.crs,
                        routeTitle: route.title,
                        deepLinkFromCRS: route.deepLinkFromCRS,
                        deepLinkToCRS: route.deepLinkToCRS,
                        preferredServiceID: preferredServiceID,
                        journeyUpdatesEnabled: tracked.journeyUpdatesEnabled,
                        scheduleKey: tracked.scheduleKey,
                        windowStart: tracked.windowStart,
                        windowEnd: tracked.windowEnd
                    )
                }
                await refreshAndUpdate(for: journey, depStore: depStore, activityID: existingActivityID)
            } else {
                print("✅ [LiveActivity] Already tracking \(journey.fromStation.crs) → \(journey.toStation.crs), skipping")
            }
            return
        }

        let info = ActivityAuthorizationInfo()
        print("🚂 [LiveActivity] ===== START REQUESTED =====")
        print("🚂 [LiveActivity] Current active activities: \(trackedActivities.count)/\(maxConcurrentActivities)")
        print("🚂 [LiveActivity] areActivitiesEnabled=\(info.areActivitiesEnabled)")
        print("🚂 [LiveActivity] frequentPushesEnabled=\(info.frequentPushesEnabled)")
        os_log("[LiveActivity] ===== START REQUESTED =====")
        os_log("[LiveActivity] areActivitiesEnabled=%{public}@", String(info.areActivitiesEnabled))
        os_log("[LiveActivity] frequentPushesEnabled=%{public}@", String(info.frequentPushesEnabled))

        if !info.areActivitiesEnabled {
            print("❌ [LiveActivity] ERROR: Not enabled in Settings")
            lastMessage = "Live Activities are disabled in Settings"
            os_log("[LiveActivity] ERROR: Not enabled in Settings", type: .error)
            return
        }

        // If at max capacity, end the oldest activity first
        if trackedActivities.count >= maxConcurrentActivities {
            print("⚠️ [LiveActivity] At max capacity (\(maxConcurrentActivities)), ending oldest activity")
            await endOldestActivity()
        }

        print("🚂 [LiveActivity] Attributes type=\(String(reflecting: JourneyActivityAttributes.self))")
        print("🚂 [LiveActivity] Request start for \(journey.fromStation.crs) → \(journey.toStation.crs)")
        print("🚂 [LiveActivity] ActivityAttributes check: \(JourneyActivityAttributes.self is any ActivityAttributes.Type ? "✅ Conforms" : "❌ Does NOT conform")")
        os_log("[LiveActivity] Attributes type=%{public}@", String(reflecting: JourneyActivityAttributes.self))
        os_log("[LiveActivity] Request start for %{public}@ → %{public}@", journey.fromStation.crs, journey.toStation.crs)

        // Compute initial state
        let initial = await contentState(
            for: journey,
            depStore: depStore,
            preferredServiceID: preferredServiceID,
            journeyUpdatesEnabled: journeyUpdatesEnabled,
            scheduleKey: scheduleKey,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        print("🚂 [LiveActivity] Initial state: platform=\(initial.platform), est=\(initial.estimated), dest=\(initial.destinationTitle)")
        os_log("[LiveActivity] Initial content state: fromCRS=%{public}@, toCRS=%{public}@, dest=%{public}@, platform=%{public}@, est=%{public}@",
               initial.fromCRS, initial.toCRS, initial.destinationTitle, initial.platform, initial.estimated)

        do {
            let route = routePresentation(for: journey)
            let attr = JourneyActivityAttributes(displayName: route.title)
            print("🚂 [LiveActivity] Attributes displayName=\(attr.displayName)")
            os_log("[LiveActivity] Attributes displayName=%{public}@", attr.displayName)

            print("🚂 [LiveActivity] Calling Activity.request()...")
            os_log("[LiveActivity] Calling Activity.request()...")
            let act = try Activity<JourneyActivityAttributes>.request(
                attributes: attr,
                content: .init(state: initial, staleDate: nil),
                pushType: .token
            )

            print("✅ [LiveActivity] SUCCESS! Activity created!")
            print("✅ [LiveActivity] Activity ID: \(act.id)")
            print("✅ [LiveActivity] Activity state: \(act.activityState)")
            os_log("[LiveActivity] Activity created successfully!")
            os_log("[LiveActivity] Activity ID: %{public}@", act.id)
            os_log("[LiveActivity] Activity state: %{public}@", String(describing: act.activityState))
            os_log("[LiveActivity] Activity content: %{public}@", String(describing: act.content))
            os_log("[LiveActivity] Push token: %{public}@", String(describing: act.pushToken))

            // Listen for push token updates so we can register with the backend for APNs live updates.
            watchPushToken(for: act, fromCRS: journey.fromStation.crs, toCRS: journey.toStation.crs)
            if act.pushToken == nil {
                print("⏳ [LiveActivity] Waiting for push token via pushTokenUpdates stream (requested pushType=.token)")
            } else {
                print("📡 [LiveActivity] Initial push token already available; will still watch for updates")
                let tokenString = encodePushToken(act.pushToken!)
                _ = await sendLiveActivityRegistration(
                    activityID: act.id,
                    tokenString: tokenString,
                    fromCRS: journey.fromStation.crs,
                    toCRS: journey.toStation.crs,
                    routeTitle: route.title,
                    deepLinkFromCRS: route.deepLinkFromCRS,
                    deepLinkToCRS: route.deepLinkToCRS,
                    preferredServiceID: preferredServiceID,
                    journeyUpdatesEnabled: journeyUpdatesEnabled,
                    scheduleKey: scheduleKey,
                    windowStart: windowStart,
                    windowEnd: windowEnd
                )
            }

            // Create tracked activity with its own timers
            var tracked = TrackedActivity(
                activity: act,
                fromCRS: journey.fromStation.crs,
                toCRS: journey.toStation.crs,
                startedAt: Date(),
                preferredServiceID: preferredServiceID,
                journeyUpdatesEnabled: journeyUpdatesEnabled,
                scheduleKey: scheduleKey,
                windowStart: windowStart,
                windowEnd: windowEnd
            )

            // Schedule update timer for this activity
            tracked.timer = scheduleUpdates(for: journey, depStore: depStore, activityID: act.id)

            // Schedule fallback end timer for this activity
            tracked.fallbackEndTimer = scheduleFallbackEnd(
                for: act.id,
                scheduleKey: scheduleKey,
                windowStart: windowStart,
                windowEnd: windowEnd
            )

            // Store the tracked activity
            trackedActivities[act.id] = tracked

            // Update published state
            updatePublishedState()

            // Check all active activities
            let allActivities = currentSystemActivities()
            print("✅ [LiveActivity] Total active activities: \(allActivities.count)")
            os_log("[LiveActivity] Total active activities: %{public}d", allActivities.count)
            for (index, activity) in allActivities.enumerated() {
                print("✅ [LiveActivity] Activity [\(index)]: id=\(activity.id), state=\(activity.activityState)")
                os_log("[LiveActivity] Activity [%{public}d]: id=%{public}@, state=%{public}@",
                       index, activity.id, String(describing: activity.activityState))
            }

            print("✅ [LiveActivity] ===== START COMPLETED SUCCESSFULLY =====")
            print("✅ [LiveActivity] Now tracking \(trackedActivities.count) activities")
            lastMessage = nil
            os_log("[LiveActivity] ===== START COMPLETED SUCCESSFULLY =====")
        } catch {
            print("❌ [LiveActivity] ===== START FAILED =====")
            print("❌ [LiveActivity] Error: \(error)")
            print("❌ [LiveActivity] Error localizedDescription: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("❌ [LiveActivity] Error domain: \(nsError.domain), code: \(nsError.code)")
                print("❌ [LiveActivity] Error userInfo: \(nsError.userInfo)")
            }
            ClientDiagnosticsLogger.log("live_activity", "start_failed", metadata: [
                "from": journey.fromStation.crs.uppercased(),
                "to": journey.toStation.crs.uppercased(),
                "triggered_by_user": triggeredByUser,
                "allow_automatic_start": allowAutomaticStart,
                "application_state": UIApplication.shared.applicationState.rawValue,
                "schedule_key": scheduleKey,
                "error": error.localizedDescription,
                "error_details": String(describing: error)
            ])
            DebugLogStore.shared.log(
                """
                Live Activity start failed
                Route: \(journey.fromStation.crs.uppercased())→\(journey.toStation.crs.uppercased())
                Auto start: \(allowAutomaticStart && !triggeredByUser)
                Error: \(error.localizedDescription)
                """,
                category: "Error"
            )
            let shouldSuppress = shouldSuppressStartError(
                error,
                triggeredByUser: triggeredByUser,
                allowAutomaticStart: allowAutomaticStart,
                journey: journey
            )
            if shouldSuppress {
                lastMessage = nil
            } else {
                lastMessage = "Unable to start Live Activity: \(error.localizedDescription)"
            }
            os_log("[LiveActivity] ===== START FAILED =====", type: .error)
            os_log("[LiveActivity] Error: %{public}@", error.localizedDescription)
            os_log("[LiveActivity] Error details: %{public}@", String(describing: error))
            if let nsError = error as NSError? {
                os_log("[LiveActivity] Error domain: %{public}@, code: %{public}d", nsError.domain, nsError.code)
                os_log("[LiveActivity] Error userInfo: %{public}@", String(describing: nsError.userInfo))
            }
        }
    }

    /// End the oldest tracked activity to make room for a new one
    private func endOldestActivity() async {
        guard let oldest = trackedActivities.min(by: { $0.value.startedAt < $1.value.startedAt }) else {
            print("⚠️ [LiveActivity] No activities to end")
            return
        }

        let activityID = oldest.key
        let tracked = oldest.value
        print("🛑 [LiveActivity] Ending oldest activity \(activityID) (\(tracked.fromCRS) → \(tracked.toCRS)) started at \(tracked.startedAt)")

        await stopActivity(activityID: activityID)
    }

    /// Stop all active Live Activities
    func stop() async {
        print("🛑 [LiveActivity] Stopping all \(trackedActivities.count) activities")

        // Copy activity IDs to avoid mutation during iteration
        let activityIDs = Array(trackedActivities.keys)

        for activityID in activityIDs {
            await stopActivity(activityID: activityID)
        }

        // A Live Activity can have been remote-started while the app was not
        // running, so it may not yet be represented in trackedActivities.
        // End those as well when all journey updates are being stopped.
        let untrackedActivities = currentSystemActivities().filter {
            trackedActivities[$0.id] == nil
        }
        for activity in untrackedActivities {
            await activity.end(nil, dismissalPolicy: .immediate)
            ScheduledLiveActivityAutoStartManager.shared.removeRecord(activityID: activity.id)
            await sendLiveActivityUnregistration(activityID: activity.id)
        }

        lastEndedAt = Date()
        updatePublishedState()
        os_log("[LiveActivity] All activities stopped")
    }

    /// Stop a specific Live Activity by its ID
    func stopActivity(
        activityID: String,
        preserveNotificationLiveSession: Bool = false
    ) async {
        guard let tracked = trackedActivities[activityID] else {
            print("⚠️ [LiveActivity] Cannot stop activity \(activityID) - not found in tracked activities")
            return
        }

        print("🛑 [LiveActivity] Stopping activity \(activityID) (\(tracked.fromCRS) → \(tracked.toCRS))")

        // Invalidate timers for this activity
        tracked.timer?.invalidate()
        tracked.fallbackEndTimer?.invalidate()

        // End the ActivityKit activity
        await tracked.activity.end(nil, dismissalPolicy: .immediate)
        print("🛑 [LiveActivity] End requested for \(activityID) with dismissalPolicy=.immediate")

        // Cancel push token task for this activity
        pushTokenTasks[activityID]?.cancel()
        pushTokenTasks[activityID] = nil

        // Remove from tracked activities
        trackedActivities[activityID] = nil
        notificationLiveSessionEnsuredActivityIDs.remove(activityID)
        ScheduledLiveActivityAutoStartManager.shared.removeRecord(activityID: activityID)

        // Arrival-triggered stops must leave the notification live-session intact until
        // `/notifications/terminate` succeeds; otherwise the backend loses the record
        // it uses to send the welcome/muted push and returns 404.
        if preserveNotificationLiveSession {
            NotificationMuteRequestSender.shared.deferLiveActivityUnregistration(
                activityID: activityID,
                from: tracked.fromCRS,
                to: tracked.toCRS
            )
            let msg = "Deferred Live Activity unregistration during stop for \(tracked.fromCRS)→\(tracked.toCRS)"
            DebugLogStore.shared.log(msg, category: "Mute")
            print("📍 \(msg)")
        } else {
            await sendLiveActivityUnregistration(activityID: activityID)
        }

        // Update published state
        updatePublishedState()
        Task { @MainActor in
            await NotificationSubscriptionStore.shared.syncGeofencesNow()
        }

        lastEndedAt = Date()
        os_log("[LiveActivity] Activity %{public}@ stopped", activityID)
    }

    /// Stop the Live Activity for a specific journey
    func stop(
        for journey: Journey,
        preserveNotificationLiveSession: Bool = false
    ) async {
        let fromCRS = journey.fromStation.crs.uppercased()
        let toCRS = journey.toStation.crs.uppercased()

        let trackedIDs = trackedActivities.compactMap { entry -> String? in
            let tracked = entry.value
            guard tracked.fromCRS.uppercased() == fromCRS, tracked.toCRS.uppercased() == toCRS else { return nil }
            return entry.key
        }
        if !trackedIDs.isEmpty {
            for activityID in trackedIDs {
                await stopActivity(
                    activityID: activityID,
                    preserveNotificationLiveSession: preserveNotificationLiveSession
                )
            }
            return
        }

        let matchingActivities = systemActivities(forFromCRS: fromCRS, toCRS: toCRS)
        guard !matchingActivities.isEmpty else {
            print("⚠️ [LiveActivity] No activity found for \(journey.fromStation.crs) → \(journey.toStation.crs)")
            return
        }

        for activity in matchingActivities {
            await activity.end(nil, dismissalPolicy: .immediate)
            if preserveNotificationLiveSession {
                NotificationMuteRequestSender.shared.deferLiveActivityUnregistration(
                    activityID: activity.id,
                    from: fromCRS,
                    to: toCRS
                )
                let msg = "Deferred Live Activity unregistration during stop for \(fromCRS)→\(toCRS)"
                DebugLogStore.shared.log(msg, category: "Mute")
                print("📍 \(msg)")
            } else {
                await sendLiveActivityUnregistration(activityID: activity.id)
            }
        }
        updatePublishedState()
        Task { @MainActor in
            await NotificationSubscriptionStore.shared.syncGeofencesNow()
        }
        lastEndedAt = Date()
    }

    func stopMatching(
        fromCRS: String,
        toCRS: String,
        preserveNotificationLiveSession: Bool = false
    ) async {
        let trackedMatches = trackedActivities.values.contains {
            $0.fromCRS.uppercased() == fromCRS.uppercased() && $0.toCRS.uppercased() == toCRS.uppercased()
        }
        if trackedMatches || !systemActivities(forFromCRS: fromCRS.uppercased(), toCRS: toCRS.uppercased()).isEmpty {
            if let fromStation = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(fromCRS) == .orderedSame }),
               let toStation = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(toCRS) == .orderedSame }) {
                await stop(
                    for: Journey(fromStation: fromStation, toStation: toStation, favorite: false),
                    preserveNotificationLiveSession: preserveNotificationLiveSession
                )
                return
            }
        }
        for activity in systemActivities(forFromCRS: fromCRS.uppercased(), toCRS: toCRS.uppercased()) {
            await activity.end(nil, dismissalPolicy: .immediate)
            if preserveNotificationLiveSession {
                NotificationMuteRequestSender.shared.deferLiveActivityUnregistration(
                    activityID: activity.id,
                    from: fromCRS,
                    to: toCRS
                )
                let msg = "Deferred Live Activity unregistration during stop for \(fromCRS.uppercased())→\(toCRS.uppercased())"
                DebugLogStore.shared.log(msg, category: "Mute")
                print("📍 \(msg)")
            } else {
                await sendLiveActivityUnregistration(activityID: activity.id)
            }
        }
    }

    func setJourneyUpdatesEnabled(for journeys: [Journey], enabled: Bool, depStore: DeparturesStore) async {
        for journey in journeys {
            await setJourneyUpdatesEnabled(for: journey, enabled: enabled, depStore: depStore)
        }
        updatePublishedState()
    }

    func setJourneyUpdatesEnabled(for journey: Journey, enabled: Bool, depStore: DeparturesStore) async {
        let fromCRS = journey.fromStation.crs.uppercased()
        let toCRS = journey.toStation.crs.uppercased()

        let systemMatches = systemActivities(forFromCRS: fromCRS, toCRS: toCRS)
        for activity in systemMatches where trackedActivities[activity.id] == nil {
            await registerRemoteStartedActivityIfNeeded(activity)
        }

        let trackedIDs = trackedActivities.compactMap { entry -> String? in
            let tracked = entry.value
            guard tracked.fromCRS.uppercased() == fromCRS, tracked.toCRS.uppercased() == toCRS else { return nil }
            return entry.key
        }

        for activityID in trackedIDs {
            guard var tracked = trackedActivities[activityID] else { continue }
            guard tracked.journeyUpdatesEnabled != enabled else { continue }
            tracked.journeyUpdatesEnabled = enabled
            trackedActivities[activityID] = tracked

            if let tokenData = tracked.activity.pushToken {
                let route = routePresentation(for: journey)
                _ = await sendLiveActivityRegistration(
                    activityID: activityID,
                    tokenString: encodePushToken(tokenData),
                    fromCRS: tracked.fromCRS,
                    toCRS: tracked.toCRS,
                    routeTitle: route.title,
                    deepLinkFromCRS: route.deepLinkFromCRS,
                    deepLinkToCRS: route.deepLinkToCRS,
                    preferredServiceID: tracked.preferredServiceID,
                    journeyUpdatesEnabled: enabled,
                    scheduleKey: tracked.scheduleKey,
                    windowStart: tracked.windowStart,
                    windowEnd: tracked.windowEnd
                )
            }

            await update(for: journey, depStore: depStore, activityID: activityID)
        }
    }

    /// Update the published state based on tracked activities
    private func updatePublishedState() {
        let trackedPairs = trackedActivities.values.map { ($0.fromCRS.uppercased(), $0.toCRS.uppercased()) }
        let systemPairs = currentSystemActivities().map {
            ($0.contentState.fromCRS.uppercased(), $0.contentState.toCRS.uppercased())
        }
        let allPairs = trackedPairs + systemPairs
        var seen = Set<String>()
        activeJourneys = allPairs.filter { pair in
            let key = "\(pair.0)->\(pair.1)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        isActive = !activeJourneys.isEmpty
        updateGlobalActivityMonitor()
        print("📊 [LiveActivity] State updated: isActive=\(isActive), activeJourneys=\(activeJourneys.map { "\($0.fromCRS)→\($0.toCRS)" })")
    }

    private func updateGlobalActivityMonitor() {
        let hasAnyActivities = !trackedActivities.isEmpty || !currentSystemActivities().isEmpty

        if hasAnyActivities {
            guard monitorTimer == nil else { return }
            scheduleGlobalActivityMonitor()
            print("🛰️ [LiveActivity] Started global monitor")
            return
        }

        if let timer = monitorTimer {
            timer.invalidate()
            monitorTimer = nil
            print("🛰️ [LiveActivity] Stopped global monitor (no activities)")
        }
    }

    private func systemActivities(forFromCRS fromCRS: String, toCRS: String) -> [Activity<JourneyActivityAttributes>] {
        currentSystemActivities().filter {
            $0.contentState.fromCRS.uppercased() == fromCRS && $0.contentState.toCRS.uppercased() == toCRS
        }
    }

    private func currentSystemActivities() -> [Activity<JourneyActivityAttributes>] {
        Activity<JourneyActivityAttributes>.activities.filter(isUsableSystemActivity)
    }

    private func isUsableSystemActivity(_ activity: Activity<JourneyActivityAttributes>) -> Bool {
        switch activity.activityState {
        case .active, .stale:
            return true
        case .ended, .dismissed:
            return false
        @unknown default:
            return false
        }
    }

    private func shouldSuppressStartError(
        _ error: Error,
        triggeredByUser: Bool,
        allowAutomaticStart: Bool,
        journey: Journey
    ) -> Bool {
        let nsError = error as NSError
        let combinedMessage = [
            error.localizedDescription,
            nsError.localizedDescription,
            String(describing: nsError.userInfo)
        ].joined(separator: " ")
        let isForegroundRestriction = combinedMessage.localizedCaseInsensitiveContains("target is not foreground")

        if !systemActivities(
            forFromCRS: journey.fromStation.crs.uppercased(),
            toCRS: journey.toStation.crs.uppercased()
        ).isEmpty {
            print("ℹ️ [LiveActivity] Suppressing start error because a matching activity already exists")
            os_log("[LiveActivity] Suppressing start error because a matching activity already exists", type: .info)
            return true
        }

        if isForegroundRestriction && (allowAutomaticStart || !triggeredByUser) {
            print("ℹ️ [LiveActivity] Suppressing automatic foreground-only start error: \(error.localizedDescription)")
            os_log("[LiveActivity] Suppressing automatic foreground-only start error: %{public}@", error.localizedDescription)
            return true
        }

        return false
    }

    private func scheduleFallbackEnd(
        for activityID: String,
        scheduleKey: String? = nil,
        windowStart: String? = nil,
        windowEnd: String? = nil
    ) -> Timer? {
        let now = Date()
        guard let deadline = fallbackEndDeadline(
            scheduleKey: scheduleKey,
            windowStart: windowStart,
            windowEnd: windowEnd,
            now: now
        ) else {
            print("⚠️ [LiveActivity] Fallback end timer NOT scheduled for \(activityID) (interval is nil)")
            return nil
        }
        let interval = max(1, deadline.date.timeIntervalSince(now))
        let minutes = Int(interval / 60)
        let deadlineText = ISO8601DateFormatter().string(from: deadline.date)
        print("⏰ [LiveActivity] Scheduling fallback end timer for activity \(activityID): \(minutes) minute\(minutes == 1 ? "" : "s") (\(interval) seconds), source=\(deadline.source), deadline=\(deadlineText)")
        DebugLogStore.shared.log(
            "Fallback end scheduled for \(activityID): source=\(deadline.source), deadline=\(deadlineText)",
            category: "Live Activity"
        )
        ClientDiagnosticsLogger.log("live_activity", "fallback_end_timer_scheduled", metadata: [
            "activity_id": activityID,
            "source": deadline.source,
            "deadline": deadlineText,
            "interval_seconds": interval,
            "schedule_key": scheduleKey,
            "window_start": windowStart,
            "window_end": windowEnd
        ])
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            print("⏳ [LiveActivity] Fallback end fired for \(activityID) after \(interval)s (\(minutes) min), source=\(deadline.source); ending locally")
            Task { @MainActor in
                DebugLogStore.shared.log(
                    "Fallback end fired for \(activityID): source=\(deadline.source), deadline=\(deadlineText)",
                    category: "Live Activity"
                )
                await self.stopActivity(activityID: activityID)
            }
        }
        print("✅ [LiveActivity] Fallback end timer scheduled for activity \(activityID) at \(deadline.date)")
        return timer
    }

    private func scheduleGlobalActivityMonitor() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            let list = self.currentSystemActivities()
            let states = list.map { "\($0.id): \($0.activityState)" }.joined(separator: "; ")
            print("🛰️ [LiveActivity] Monitor tick - activities: \(states)")

            // Check each tracked activity for force-end on the main actor
            Task { @MainActor in
                let now = Date()
                for (activityID, tracked) in self.trackedActivities {
                    let deadline = self.forceEndDeadline(for: tracked, now: now)
                    if now > deadline.date {
                        let elapsed = now.timeIntervalSince(tracked.startedAt)
                        let deadlineText = ISO8601DateFormatter().string(from: deadline.date)
                        print("⏳ [LiveActivity] Force-ending activity \(activityID) after \(Int(elapsed))s, source=\(deadline.source), deadline=\(deadlineText)")
                        DebugLogStore.shared.log(
                            "Force-ending activity \(activityID): source=\(deadline.source), deadline=\(deadlineText)",
                            category: "Live Activity"
                        )
                        ClientDiagnosticsLogger.log("live_activity", "force_end_deadline_reached", metadata: [
                            "activity_id": activityID,
                            "source": deadline.source,
                            "deadline": deadlineText,
                            "elapsed_seconds": elapsed,
                            "schedule_key": tracked.scheduleKey,
                            "window_start": tracked.windowStart,
                            "window_end": tracked.windowEnd
                        ])
                        await tracked.activity.end(nil, dismissalPolicy: .immediate)
                        self.cleanupAfterRemoteEnd(for: tracked.activity)
                    }
                }
            }
        }
    }

    private func scheduleUpdates(for journey: Journey, depStore: DeparturesStore, activityID: String) -> Timer {
        print("⏰ [LiveActivity] Scheduling timer for activity \(activityID) updates every 10 seconds")
        os_log("[LiveActivity] Scheduling timer for activity %{public}@ updates every 10 seconds", activityID)

        // NOTE: Timer-based updates only work when app is in foreground
        // For background updates, push notifications via APNs would be needed
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            print("⏰ [LiveActivity] Timer fired for \(activityID) - starting refresh")
            os_log("[LiveActivity] Timer fired for %{public}@ - starting refresh", activityID)
            Task {
                // Force refresh departure data before updating the Live Activity
                await self.refreshAndUpdate(for: journey, depStore: depStore, activityID: activityID)
            }
        }

        // Fire immediately on first setup
        Task {
            await self.refreshAndUpdate(for: journey, depStore: depStore, activityID: activityID)
        }

        return timer
    }

    private func refreshAndUpdate(for journey: Journey, depStore: DeparturesStore, activityID: String? = nil) async {
        // Fetch fresh departure data from the API
        let timestamp = Date()
        let activityLabel = activityID ?? "all"
        print("🔄 [LiveActivity] [\(timestamp)] Fetching fresh departure data for \(journey.fromStation.crs) → \(journey.toStation.crs) (activity: \(activityLabel))")
        os_log("[LiveActivity] Fetching fresh departure data for %{public}@ → %{public}@", journey.fromStation.crs, journey.toStation.crs)

        // Refresh departure data for this specific journey
        await depStore.refreshSpecificJourney(fromCRS: journey.fromStation.crs, toCRS: journey.toStation.crs)

        // Get the updated departures and fetch service details for the selected departure
        let deps = depStore.departures(for: journey)
        let preferredServiceID: String? = {
            if let activityID {
                return trackedActivities[activityID]?.preferredServiceID
            }
            return trackedActivities.first {
                $0.value.fromCRS == journey.fromStation.crs && $0.value.toCRS == journey.toStation.crs
            }?.value.preferredServiceID
        }()
        let relevantDeps = relevantDepartures(from: deps)
        let effectivePreferredServiceID = preferredServiceID.flatMap { preferredServiceID in
            relevantDeps.contains(where: { $0.serviceID == preferredServiceID }) ? preferredServiceID : nil
        }

        if let activityID,
           preferredServiceID != effectivePreferredServiceID,
           var tracked = trackedActivities[activityID] {
            tracked.preferredServiceID = effectivePreferredServiceID
            trackedActivities[activityID] = tracked

            if let expiredPreferredServiceID = preferredServiceID {
                print("↪️ [LiveActivity] Preferred service \(expiredPreferredServiceID) is no longer relevant for \(journey.fromStation.crs) → \(journey.toStation.crs); falling back to the next live departure")
            }

            if let tokenData = tracked.activity.pushToken {
                let tokenString = encodePushToken(tokenData)
                let route = routePresentation(for: journey)
                _ = await sendLiveActivityRegistration(
                    activityID: activityID,
                    tokenString: tokenString,
                    fromCRS: journey.fromStation.crs,
                    toCRS: journey.toStation.crs,
                    routeTitle: route.title,
                    deepLinkFromCRS: route.deepLinkFromCRS,
                    deepLinkToCRS: route.deepLinkToCRS,
                    preferredServiceID: effectivePreferredServiceID,
                    journeyUpdatesEnabled: tracked.journeyUpdatesEnabled,
                    scheduleKey: tracked.scheduleKey,
                    windowStart: tracked.windowStart,
                    windowEnd: tracked.windowEnd
                )
            }
        }

        print("🔄 [LiveActivity] Found \(deps.count) departures after refresh")
        if let selectedDep = selectPrimaryDeparture(
            preferredServiceID: effectivePreferredServiceID,
            allDepartures: deps,
            filteredDepartures: relevantDeps
        ) {
            print("✅ [LiveActivity] Fetched departure data, selected service: \(selectedDep.serviceID), platform: \(selectedDep.platform ?? "TBC"), time: \(selectedDep.departureTime.estimated ?? selectedDep.departureTime.scheduled)")
            os_log("[LiveActivity] Selected service: %{public}@, platform: %{public}@", selectedDep.serviceID, selectedDep.platform ?? "TBC")
            await depStore.ensureServiceDetails(for: [selectedDep.serviceID], force: true)
        } else {
            print("⚠️ [LiveActivity] No departures found after refresh")
            os_log("[LiveActivity] WARNING: No departures found after refresh", type: .error)
        }

        // Now update the Live Activity with the fresh data
        await update(for: journey, depStore: depStore, activityID: activityID)
    }

    private func update(for journey: Journey, depStore: DeparturesStore, activityID: String? = nil) async {
        let preferredServiceID: String? = {
            if let activityID {
                return trackedActivities[activityID]?.preferredServiceID
            }
            return trackedActivities.first {
                $0.value.fromCRS == journey.fromStation.crs && $0.value.toCRS == journey.toStation.crs
            }?.value.preferredServiceID
        }()
        let trackedMetadata: TrackedActivity? = {
            if let activityID {
                return trackedActivities[activityID]
            }
            return trackedActivities.first {
                $0.value.fromCRS == journey.fromStation.crs && $0.value.toCRS == journey.toStation.crs
            }?.value
        }()
        let state = await contentState(
            for: journey,
            depStore: depStore,
            preferredServiceID: preferredServiceID,
            journeyUpdatesEnabled: trackedMetadata?.journeyUpdatesEnabled ?? true,
            scheduleKey: trackedMetadata?.scheduleKey,
            windowStart: trackedMetadata?.windowStart,
            windowEnd: trackedMetadata?.windowEnd
        )

        // Find the activity to update
        let activity: Activity<JourneyActivityAttributes>?
        if let activityID = activityID {
            activity = trackedActivities[activityID]?.activity
        } else {
            // Find by journey
            activity = trackedActivities.first {
                $0.value.fromCRS == journey.fromStation.crs && $0.value.toCRS == journey.toStation.crs
            }?.value.activity
        }

        if let a = activity {
            await a.update(ActivityContent(state: state, staleDate: nil))
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let timeStr = formatter.string(from: state.lastUpdated)
            print("✅ [LiveActivity] Updated \(a.id) at \(timeStr) to show: platform=\(state.platform), est=\(state.estimated), dest=\(state.destinationTitle), upcoming=\(state.upcomingDepartures.count)")
            os_log("[LiveActivity] Updated activity %{public}@ at %{public}@", String(describing: a.id), timeStr)
        } else {
            print("⚠️ [LiveActivity] Update skipped; activity not found for \(journey.fromStation.crs) → \(journey.toStation.crs)")
            os_log("[LiveActivity] Update skipped; activity not found", type: .error)
        }
    }

    private func contentState(
        for journey: Journey,
        depStore: DeparturesStore,
        preferredServiceID: String? = nil,
        journeyUpdatesEnabled: Bool = true,
        scheduleKey: String? = nil,
        windowStart: String? = nil,
        windowEnd: String? = nil
    ) async -> JourneyActivityAttributes.ContentState {
        let route = routePresentation(for: journey)
        let allDeps = depStore.departures(for: journey)
        let deps = relevantDepartures(from: allDeps)
        let next = selectPrimaryDeparture(preferredServiceID: preferredServiceID, allDepartures: allDeps, filteredDepartures: deps)
        let title: String = {
            if let first = next?.destination.first {
                if let via = first.via, !via.isEmpty { return "\(first.locationName) \(via)" }
                return first.locationName
            }
            return "\(journey.toStation.name)"
        }()
        let primaryArrivalTime: String?
        if let next, !next.isCancelled {
            primaryArrivalTime = await finalArrivalTime(for: next, startingJourney: journey, depStore: depStore)
        } else {
            primaryArrivalTime = nil
        }
        var statusText: String? = nil
        var delayMins: Int = 0
        if let n = next {
            if n.isCancelled {
                statusText = nil
            }
            if !n.isCancelled, let details = depStore.serviceDetailsById[n.serviceID] {
                if let live = computeLiveStatus(from: details, within: journey.fromStation.crs, toCRS: journey.toStation.crs) {
                    statusText = live.text
                    delayMins = live.delayMinutes
                }
            }
            if n.departureTime.estimated
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "delayed" {
                delayMins = 240
            }
        }
        let platform = next?.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (next?.platform ?? "TBC") : "TBC"
        let est = liveActivityDepartureText(for: next)
        let scheduledDeparture = next?.departureTime.scheduled
        let length = next?.length

        // Build upcoming departures (skip the first one as it's the main departure, get next 3)
        var upcoming: [JourneyActivityAttributes.UpcomingDeparture] = []
        let upcomingDeps: [DepartureV2] = {
            if let next,
               let selectedIndex = allDeps.firstIndex(where: { $0.serviceID == next.serviceID }) {
                let tail = Array(allDeps.suffix(from: selectedIndex + 1))
                return Array(tail.filter(isDepartureStillRelevant).prefix(3))
            }
            return Array(deps.dropFirst().prefix(3))
        }()
        for (index, dep) in upcomingDeps.enumerated() {
            let depDelayMins = calculateDelayMinutes(scheduled: dep.departureTime.scheduled, estimated: dep.departureTime.estimated)
            // Only check departures that come after this one in the list
            let laterDeps = Array(upcomingDeps.dropFirst(index + 1))
            let hasFaster = checkForFasterLaterService(dep: dep, allDeps: laterDeps, fromCRS: journey.fromStation.crs, toCRS: journey.toStation.crs, depStore: depStore)
            upcoming.append(JourneyActivityAttributes.UpcomingDeparture(
                time: liveActivityDepartureText(for: dep),
                arrivalTime: dep.isCancelled ? nil : await finalArrivalTime(for: dep, startingJourney: journey, depStore: depStore),
                delayMinutes: depDelayMins,
                isCancelled: dep.isCancelled,
                platform: dep.platform,
                hasFasterLaterService: hasFaster
            ))
        }

        let state = JourneyActivityAttributes.ContentState(
            fromCRS: journey.fromStation.crs,
            toCRS: journey.toStation.crs,
            routeTitle: route.title,
            deepLinkFromCRS: route.deepLinkFromCRS,
            deepLinkToCRS: route.deepLinkToCRS,
            destinationTitle: title,
            arrivalLabel: primaryArrivalTime.map { "Arr \($0)" },
            scheduledDeparture: scheduledDeparture,
            length: length,
            platform: platform,
            estimated: est,
            isCancelled: next?.isCancelled ?? false,
            statusText: statusText,
            delayMinutes: delayMins,
            upcomingDepartures: upcoming,
            lastUpdated: Date(),
            journeyUpdatesEnabled: journeyUpdatesEnabled,
            scheduleKey: scheduleKey,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        return state
    }

    private func routePresentation(for journey: Journey) -> RoutePresentation {
        let legs = relevantJourneyLegs(for: journey)
        guard let firstLeg = legs.first, let lastLeg = legs.last else {
            return RoutePresentation(
                title: "\(journey.fromStation.name) → \(journey.toStation.name)",
                deepLinkFromCRS: journey.fromStation.crs.uppercased(),
                deepLinkToCRS: journey.toStation.crs.uppercased()
            )
        }

        let viaCodes = legs
            .dropLast()
            .map { $0.toStation.crs.uppercased() }
            .filter { !$0.isEmpty }
        let title: String
        if viaCodes.isEmpty {
            title = "\(firstLeg.fromStation.name) → \(lastLeg.toStation.name)"
        } else {
            title = "\(firstLeg.fromStation.name) → \(lastLeg.toStation.name) via \(viaCodes.joined(separator: ", "))"
        }

        return RoutePresentation(
            title: title,
            deepLinkFromCRS: firstLeg.fromStation.crs.uppercased(),
            deepLinkToCRS: lastLeg.toStation.crs.uppercased()
        )
    }

    private func relevantJourneyLegs(for journey: Journey) -> [Journey] {
        guard let group = JourneyStore.shared.journeyGroups().first(where: { $0.id == journey.groupId }) else {
            return [journey]
        }
        if let index = group.legs.firstIndex(where: { $0.id == journey.id }) {
            return Array(group.legs.dropFirst(index))
        }
        if let index = group.legs.firstIndex(where: { $0.legIndex == journey.legIndex }) {
            return Array(group.legs.dropFirst(index))
        }
        return group.legs.filter { $0.legIndex >= journey.legIndex }
    }

    private func selectDeparture(for leg: Journey, earliest: Date?, depStore: DeparturesStore) -> DepartureV2? {
        let departures = depStore.departures(for: leg)
        if let earliest,
           let match = departures.first(where: { departure in
               guard !departure.isCancelled,
                     let departureDate = departureDate(for: departure) else {
                   return false
               }
               return departureDate >= earliest
           }) {
            return match
        }
        return departures.first(where: { !$0.isCancelled }) ?? departures.first
    }

    private func departureDate(for departure: DepartureV2) -> Date? {
        parseHHmmToDate(displayDepartureTime(for: departure))
    }

    private func arrivalTime(for departure: DepartureV2, toCRS: String, depStore: DeparturesStore) -> String? {
        guard let details = depStore.serviceDetailsById[departure.serviceID] else { return nil }
        let targetCRS = toCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let callingPoint = details.allStations.first(where: {
            $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS
        }) {
            return callingPointDisplayTime(callingPoint)
        }
        if details.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS {
            if let ata = details.ata, ata != "Cancelled" {
                if ata == "On time", let sta = details.sta { return sta }
                return ata
            }
            if let sta = details.sta {
                return sta
            }
        }
        if let targetName = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(toCRS) == .orderedSame })?.name {
            let normalizedTarget = normalizeStationName(targetName)
            if let callingPoint = details.allStations.first(where: {
                normalizeStationName($0.locationName) == normalizedTarget
            }) {
                return callingPointDisplayTime(callingPoint)
            }
        }
        return nil
    }

    private func callingPointDisplayTime(_ callingPoint: CallingPoint) -> String {
        if let at = callingPoint.at, at != "Cancelled" {
            return at == "On time" ? callingPoint.st : at
        }
        if let et = callingPoint.et, et != "Cancelled" {
            return et == "On time" ? callingPoint.st : et
        }
        return callingPoint.st
    }

    private func normalizeStationName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private func finalArrivalTime(
        for firstDeparture: DepartureV2,
        startingJourney: Journey,
        depStore: DeparturesStore
    ) async -> String? {
        let legs = relevantJourneyLegs(for: startingJourney)
        guard !legs.isEmpty else { return nil }

        var previousArrivalDate: Date? = nil
        var previousDepartureDate: Date? = nil
        var latestArrivalTime: String? = nil

        for (index, leg) in legs.enumerated() {
            let departure: DepartureV2
            if index == 0 {
                departure = firstDeparture
            } else {
                let earliest = previousArrivalDate ?? previousDepartureDate
                guard let nextDeparture = selectDeparture(for: leg, earliest: earliest, depStore: depStore) else {
                    return latestArrivalTime
                }
                departure = nextDeparture
            }

            await depStore.ensureServiceDetails(for: [departure.serviceID])

            let departureDate = departureDate(for: departure)
            guard let arrivalTime = arrivalTime(for: departure, toCRS: leg.toStation.crs, depStore: depStore) else {
                return latestArrivalTime
            }

            latestArrivalTime = arrivalTime
            previousArrivalDate = parseHHmmToDate(arrivalTime)
            previousDepartureDate = departureDate
        }

        return latestArrivalTime
    }

    private func selectPrimaryDeparture(preferredServiceID: String?, allDepartures: [DepartureV2], filteredDepartures: [DepartureV2]) -> DepartureV2? {
        if let preferredServiceID,
           let preferred = filteredDepartures.first(where: { $0.serviceID == preferredServiceID }) {
            return preferred
        }
        return filteredDepartures.first
    }

    private func relevantDepartures(from departures: [DepartureV2]) -> [DepartureV2] {
        departures.filter(isDepartureStillRelevant)
    }

    private func isDepartureStillRelevant(_ departure: DepartureV2) -> Bool {
        let now = Date()
        let gracePeriodSeconds: TimeInterval = 60
        guard let depTime = parseHHmmToDate(displayDepartureTime(for: departure)) else {
            return true
        }
        return depTime.timeIntervalSince(now) > -gracePeriodSeconds
    }

    private func calculateDelayMinutes(scheduled: String, estimated: String?) -> Int {
        guard let est = estimated, !est.isEmpty, est.lowercased() != "on time" else { return 0 }
        if est.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delayed" {
            return 240
        }
        guard let schedTime = parseTimeToMinutes(scheduled), let estTime = parseTimeToMinutes(est) else { return 0 }
        return estTime - schedTime
    }

    private func parseTimeToMinutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    private func checkForFasterLaterService(dep: DepartureV2, allDeps: [DepartureV2], fromCRS: String, toCRS: String, depStore: DeparturesStore) -> Bool {
        guard let thisDepMins = parseDepartureMinutes(dep.departureTime),
              let thisArrMins = parseArrivalMinutes(dep: dep, toCRS: toCRS, depStore: depStore) else { return false }

        // Calculate journey time for this train (handles midnight crossover)
        let thisJourneyMins = thisArrMins >= thisDepMins ? (thisArrMins - thisDepMins) : (thisArrMins + 1440 - thisDepMins)

        for other in allDeps {
            guard let otherDepMins = parseDepartureMinutes(other.departureTime) else { continue }
            guard otherDepMins > thisDepMins || (otherDepMins < thisDepMins && otherDepMins < 360) else { continue } // Must depart later (or after midnight)
            guard let otherArrMins = parseArrivalMinutes(dep: other, toCRS: toCRS, depStore: depStore) else { continue }

            // Calculate journey time for other train (handles midnight crossover)
            let otherJourneyMins = otherArrMins >= otherDepMins ? (otherArrMins - otherDepMins) : (otherArrMins + 1440 - otherDepMins)

            // Calculate when 'other' arrives relative to when 'this' arrives
            // If other departs later but arrives before this train does, it's faster
            let otherArrivalFromThisDep = (otherDepMins - thisDepMins + 1440) % 1440 + otherJourneyMins
            let thisArrivalFromThisDep = thisJourneyMins

            if otherArrivalFromThisDep < thisArrivalFromThisDep {
                return true // Later departure but arrives earlier
            }
        }
        return false
    }

    private func parseDepartureMinutes(_ depTime: DepartureTimeV2) -> Int? {
        let timeStr = depTime.estimated ?? depTime.scheduled
        return parseHHmmToMinutes(timeStr)
    }

    private func parseArrivalMinutes(dep: DepartureV2, toCRS: String, depStore: DeparturesStore) -> Int? {
        guard let details = depStore.serviceDetailsById[dep.serviceID] else { return nil }
        guard let cp = details.allStations.first(where: { $0.crs == toCRS }) else { return nil }
        let timeStr: String = {
            if let et = cp.et, !et.isEmpty, et.lowercased() != "on time" { return et }
            return cp.st
        }()
        return parseHHmmToMinutes(timeStr)
    }

    private func parseHHmmToMinutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    private func parseHHmmToDate(_ time: String) -> Date? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let now = Date()
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = h
        components.minute = m
        components.second = 0
        guard var candidate = calendar.date(from: components) else { return nil }
        if candidate < now && now.timeIntervalSince(candidate) > 6 * 3600 {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private func displayDepartureTime(for departure: DepartureV2?) -> String {
        guard let departure else { return "—" }
        let estimated = departure.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = estimated.lowercased()
        if estimated.isEmpty || lowered == "delayed" || lowered == "cancelled" || lowered == "on time" {
            return departure.departureTime.scheduled
        }
        return estimated
    }

    private func liveActivityDepartureText(for departure: DepartureV2?) -> String {
        guard let departure else { return "—" }
        let estimated = departure.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines)
        if estimated.lowercased() == "delayed" {
            return "Delayed"
        }
        return displayDepartureTime(for: departure)
    }

    private func startActivityLifecycleLogging() {
        activityUpdatesTask?.cancel()
        activityUpdatesTask = Task { [weak self] in
            guard let self else { return }
            self.logger.info("[ActivityMonitor] Activity.activityUpdates stream started")
            for await activity in Activity<JourneyActivityAttributes>.activityUpdates {
                await self.handleActivityUpdate(activity)
            }
            self.logger.info("[ActivityMonitor] Activity.activityUpdates stream completed")
        }
    }

    private func handleActivityUpdate(_ activity: Activity<JourneyActivityAttributes>) async {
        await registerRemoteStartedActivityIfNeeded(activity)
        self.logger.info("[ActivityMonitor] Activity emitted id=\(activity.id, privacy: .public) state=\(self.describe(state: activity.activityState), privacy: .public)")
        logActivitySnapshot(activity, context: "activityUpdates emit")
        stateMonitorTasks[activity.id]?.cancel()
        stateMonitorTasks[activity.id] = Task { [weak self] in
            guard let self else { return }
            for await state in activity.activityStateUpdates {
                self.logger.info("[ActivityMonitor] Activity \(activity.id, privacy: .public) transitioned to \(self.describe(state: state), privacy: .public)")
                logActivitySnapshot(activity, context: "state transition -> \(self.describe(state: state))")
                if state == .ended || state == .dismissed {
                    pushTokenTasks[activity.id]?.cancel()
                    pushTokenTasks[activity.id] = nil
                    self.cleanupAfterRemoteEnd(for: activity)
                }
            }
            self.logger.info("[ActivityMonitor] Activity \(activity.id, privacy: .public) state stream ended")
            self.stateMonitorTasks[activity.id] = nil
        }
    }

    private func registerRemoteStartedActivityIfNeeded(_ activity: Activity<JourneyActivityAttributes>) async {
        await replaceScheduledActivityIfNeeded(with: activity)

        let fromCRS = activity.contentState.fromCRS.uppercased()
        let toCRS = activity.contentState.toCRS.uppercased()
        let scheduleKey = scheduledActivityKey(for: activity)
        let effectiveJourneyUpdatesEnabled = remoteStartedJourneyUpdatesEnabled(for: activity)
        guard trackedActivities[activity.id] == nil else {
            ClientDiagnosticsLogger.log("live_activity", "remote_started_already_tracked", metadata: [
                "activity_id": activity.id,
                "schedule_key": activity.contentState.scheduleKey,
                "from": fromCRS,
                "to": toCRS,
                "journey_updates_enabled": activity.contentState.journeyUpdatesEnabled,
                "effective_journey_updates_enabled": effectiveJourneyUpdatesEnabled
            ])
            await ensureScheduledJourneyUpdatesActiveIfNeeded(activity, fromCRS: fromCRS, toCRS: toCRS)
            await ensureNotificationLiveSessionForRemoteStartedActivity(activity, fromCRS: fromCRS, toCRS: toCRS)
            return
        }

        ClientDiagnosticsLogger.log("live_activity", "remote_started_activity_discovered", metadata: [
            "activity_id": activity.id,
            "from": fromCRS,
            "to": toCRS,
            "route_title": activity.contentState.routeTitle,
            "schedule_key": activity.contentState.scheduleKey,
            "window_start": activity.contentState.windowStart,
            "window_end": activity.contentState.windowEnd,
            "journey_updates_enabled": activity.contentState.journeyUpdatesEnabled,
            "effective_journey_updates_enabled": effectiveJourneyUpdatesEnabled
        ])
        if scheduleKey != nil && !activity.contentState.journeyUpdatesEnabled {
            DebugLogStore.shared.log(
                "Scheduled push-started activity promoted to live journey updates for \(fromCRS)→\(toCRS)",
                category: "Scheduled"
            )
        }

        var tracked = TrackedActivity(
            activity: activity,
            fromCRS: fromCRS,
            toCRS: toCRS,
            startedAt: Date(),
            preferredServiceID: nil,
            journeyUpdatesEnabled: effectiveJourneyUpdatesEnabled,
            scheduleKey: scheduleKey,
            windowStart: activity.contentState.windowStart,
            windowEnd: activity.contentState.windowEnd
        )
        tracked.fallbackEndTimer = scheduleFallbackEnd(
            for: activity.id,
            scheduleKey: scheduleKey,
            windowStart: activity.contentState.windowStart,
            windowEnd: activity.contentState.windowEnd
        )
        trackedActivities[activity.id] = tracked
        watchPushToken(for: activity, fromCRS: fromCRS, toCRS: toCRS)
        updatePublishedState()
        await ensureNotificationLiveSessionForRemoteStartedActivity(activity, fromCRS: fromCRS, toCRS: toCRS)
    }

    private func scheduledActivityKey(for activity: Activity<JourneyActivityAttributes>) -> String? {
        guard let scheduleKey = activity.contentState.scheduleKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !scheduleKey.isEmpty else {
            return nil
        }
        return scheduleKey
    }

    private func remoteStartedJourneyUpdatesEnabled(for activity: Activity<JourneyActivityAttributes>) -> Bool {
        if scheduledActivityKey(for: activity) != nil {
            return true
        }
        return activity.contentState.journeyUpdatesEnabled
    }

    private func ensureScheduledJourneyUpdatesActiveIfNeeded(
        _ activity: Activity<JourneyActivityAttributes>,
        fromCRS: String,
        toCRS: String
    ) async {
        guard let scheduleKey = scheduledActivityKey(for: activity),
              var tracked = trackedActivities[activity.id] else {
            return
        }

        let wasEnabled = tracked.journeyUpdatesEnabled
        let needsMetadataRefresh = tracked.scheduleKey != scheduleKey
            || tracked.windowStart != activity.contentState.windowStart
            || tracked.windowEnd != activity.contentState.windowEnd
        guard !wasEnabled || needsMetadataRefresh else { return }

        tracked.journeyUpdatesEnabled = true
        tracked.scheduleKey = scheduleKey
        tracked.windowStart = activity.contentState.windowStart
        tracked.windowEnd = activity.contentState.windowEnd
        if needsMetadataRefresh {
            tracked.fallbackEndTimer?.invalidate()
            tracked.fallbackEndTimer = scheduleFallbackEnd(
                for: activity.id,
                scheduleKey: scheduleKey,
                windowStart: tracked.windowStart,
                windowEnd: tracked.windowEnd
            )
        }
        trackedActivities[activity.id] = tracked
        updatePublishedState()

        ClientDiagnosticsLogger.log("live_activity", "scheduled_remote_activity_updates_ensured", metadata: [
            "activity_id": activity.id,
            "schedule_key": scheduleKey,
            "from": fromCRS,
            "to": toCRS,
            "previous_journey_updates_enabled": wasEnabled,
            "has_push_token": activity.pushToken != nil
        ])
        DebugLogStore.shared.log(
            "Scheduled remote activity updates ensured for \(fromCRS)→\(toCRS): wasEnabled=\(wasEnabled), schedule=\(scheduleKey)",
            category: "Scheduled"
        )

        guard let tokenData = activity.pushToken else { return }
        _ = await sendLiveActivityRegistration(
            activityID: activity.id,
            tokenString: encodePushToken(tokenData),
            fromCRS: fromCRS,
            toCRS: toCRS,
            routeTitle: activity.contentState.routeTitle,
            deepLinkFromCRS: activity.contentState.deepLinkFromCRS,
            deepLinkToCRS: activity.contentState.deepLinkToCRS,
            preferredServiceID: tracked.preferredServiceID,
            journeyUpdatesEnabled: true,
            scheduleKey: scheduleKey,
            windowStart: activity.contentState.windowStart,
            windowEnd: activity.contentState.windowEnd
        )
    }

    private func ensureNotificationLiveSessionForRemoteStartedActivity(
        _ activity: Activity<JourneyActivityAttributes>,
        fromCRS: String,
        toCRS: String
    ) async {
        guard !notificationLiveSessionEnsuredActivityIDs.contains(activity.id) else { return }
        guard let scheduleKey = scheduledActivityKey(for: activity) else {
            ClientDiagnosticsLogger.log("live_activity", "remote_started_live_session_skipped_missing_schedule", metadata: [
                "activity_id": activity.id,
                "from": fromCRS,
                "to": toCRS,
                "route_title": activity.contentState.routeTitle,
                "window_start": activity.contentState.windowStart,
                "window_end": activity.contentState.windowEnd,
                "journey_updates_enabled": activity.contentState.journeyUpdatesEnabled
            ])
            DebugLogStore.shared.log(
                "Remote-started activity skipped live session registration: missing schedule key for \(fromCRS)→\(toCRS)",
                category: "Scheduled"
            )
            return
        }

        if StationsService.shared.stations.isEmpty {
            try? await StationsService.shared.loadStations()
        }
        let fromName = stationName(for: fromCRS)
        let toName = stationName(for: toCRS)

        let liveSessionID = await ScheduledNotificationLiveSessionRegistrar.ensureLiveSession(
            existingLiveSessionID: nil,
            from: fromCRS,
            to: toCRS,
            fromName: fromName,
            toName: toName,
            scheduleKey: scheduleKey,
            windowStart: activity.contentState.windowStart,
            windowEnd: activity.contentState.windowEnd,
            source: "remote_started_live_activity",
            metadata: [
                "activity_id": activity.id,
                "schedule_key": scheduleKey,
                "from": fromCRS,
                "to": toCRS,
                "from_name": fromName,
                "to_name": toName,
                "route_title": activity.contentState.routeTitle,
                "window_start": activity.contentState.windowStart,
                "window_end": activity.contentState.windowEnd,
                "journey_updates_enabled": activity.contentState.journeyUpdatesEnabled
            ]
        )

        guard let liveSessionID else {
            ClientDiagnosticsLogger.log("live_activity", "remote_started_live_session_not_registered", metadata: [
                "activity_id": activity.id,
                "schedule_key": scheduleKey,
                "from": fromCRS,
                "to": toCRS
            ])
            DebugLogStore.shared.log(
                "Remote-started activity live session not registered for \(fromCRS)→\(toCRS); will retry if ActivityKit emits another update",
                category: "Error"
            )
            return
        }

        notificationLiveSessionEnsuredActivityIDs.insert(activity.id)
        ClientDiagnosticsLogger.log("live_activity", "remote_started_live_session_ensured", metadata: [
            "activity_id": activity.id,
            "schedule_key": scheduleKey,
            "from": fromCRS,
            "to": toCRS,
            "live_session_id": liveSessionID
        ])
        DebugLogStore.shared.log(
            "Remote-started activity live session ensured: \(liveSessionID) for \(fromCRS)→\(toCRS)",
            category: "Scheduled"
        )
    }

    private func stationName(for crs: String) -> String? {
        StationsService.shared.stations.first {
            $0.crs.caseInsensitiveCompare(crs) == .orderedSame
        }?.name
    }

    /// Scans all active system activities and registers any that aren't yet tracked.
    /// Called from the background notification handler so push-to-start activities
    /// get their update tokens registered with the server without requiring the user
    /// to foreground the app.
    func registerAnyUnregisteredActivities() async {
        let systemActivities = currentSystemActivities()
        let unregistered = systemActivities.filter { trackedActivities[$0.id] == nil }
        let scheduledSystemActivities = systemActivities.filter { scheduledActivityKey(for: $0) != nil }
        ClientDiagnosticsLogger.log("live_activity", "register_any_unregistered_activities", metadata: [
            "tracked_count": trackedActivities.count,
            "unregistered_count": unregistered.count,
            "scheduled_system_count": scheduledSystemActivities.count,
            "system_activity_ids": systemActivities.map(\.id)
        ])
        DebugLogStore.shared.log(
            "Live Activity scan: tracked=\(trackedActivities.count), system=\(systemActivities.count), unregistered=\(unregistered.count), scheduled=\(scheduledSystemActivities.count)",
            category: "Scheduled"
        )
        if !unregistered.isEmpty {
            print("📡 [LiveActivity] registerAnyUnregisteredActivities: found \(unregistered.count) unregistered activity/activities")
            for activity in unregistered {
                await registerRemoteStartedActivityIfNeeded(activity)
            }
        }

        let refreshedSystemActivities = currentSystemActivities()
        for activity in refreshedSystemActivities where scheduledActivityKey(for: activity) != nil {
            let fromCRS = activity.contentState.fromCRS.uppercased()
            let toCRS = activity.contentState.toCRS.uppercased()
            await ensureScheduledJourneyUpdatesActiveIfNeeded(activity, fromCRS: fromCRS, toCRS: toCRS)
            await ensureNotificationLiveSessionForRemoteStartedActivity(activity, fromCRS: fromCRS, toCRS: toCRS)
        }
    }

    private func replaceScheduledActivityIfNeeded(with activity: Activity<JourneyActivityAttributes>) async {
        guard let scheduleKey = activity.contentState.scheduleKey,
              !scheduleKey.isEmpty else {
            return
        }

        let trackedDuplicateIDs = trackedActivities.compactMap { entry -> String? in
            guard entry.key != activity.id,
                  entry.value.activity.contentState.scheduleKey == scheduleKey else {
                return nil
            }
            return entry.key
        }

        for activityID in trackedDuplicateIDs {
            await stopActivity(activityID: activityID)
        }

        let untrackedDuplicates = currentSystemActivities().filter {
            $0.id != activity.id
                && $0.contentState.scheduleKey == scheduleKey
                && trackedActivities[$0.id] == nil
        }

        for duplicate in untrackedDuplicates {
            await duplicate.end(nil, dismissalPolicy: .immediate)
            await sendLiveActivityUnregistration(activityID: duplicate.id)
            ScheduledLiveActivityAutoStartManager.shared.removeRecord(activityID: duplicate.id)
        }
    }

    private func describe(state: ActivityState) -> String {
        switch state {
        case .active:
            return "active"
        case .stale:
            return "stale"
        case .ended:
            return "ended"
        case .dismissed:
            return "dismissed"
        @unknown default:
            return "unknown"
        }
    }

    // Debug helper: log current attributes/content state for an Activity to aid APNs troubleshooting.
    private func logActivitySnapshot(_ activity: Activity<JourneyActivityAttributes>, context: String) {
        var payload: [String: Any] = [:]
        if let stateData = try? JSONEncoder.activityDebug.encode(activity.contentState),
           let stateObj = try? JSONSerialization.jsonObject(with: stateData) {
            payload["contentState"] = stateObj
        } else {
            payload["contentState"] = "\(activity.contentState)"
        }
        payload["attributesDisplayName"] = activity.attributes.displayName
        payload["state"] = describe(state: activity.activityState)
        if let stale = activity.content.staleDate {
            payload["staleDate"] = stale.timeIntervalSince1970
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            print("🛰️ [LiveActivity][\(context)] Snapshot:\n\(text)")
        } else {
            print("🛰️ [LiveActivity][\(context)] Snapshot could not be serialized")
        }
    }

    // When the system ends/dismisses an activity (e.g. via remote push with dismissalPolicy.immediate),
    // clean up timers/state locally so the app doesn't keep thinking it's active.
    private func cleanupAfterRemoteEnd(for activity: Activity<JourneyActivityAttributes>) {
        let activityID = activity.id
        guard let tracked = trackedActivities[activityID] else {
            print("⚠️ [LiveActivity] Cleanup requested for unknown activity \(activityID)")
            updatePublishedState()
            return
        }

        print("🧹 [LiveActivity] Cleaning up after remote end/dismiss for activity \(activityID) (\(tracked.fromCRS) → \(tracked.toCRS))")

        // Invalidate timers for this activity
        tracked.timer?.invalidate()
        tracked.fallbackEndTimer?.invalidate()

        // Cancel push token task
        pushTokenTasks[activityID]?.cancel()
        pushTokenTasks[activityID] = nil

        // Remove from tracked activities
        trackedActivities[activityID] = nil
        notificationLiveSessionEnsuredActivityIDs.remove(activityID)

        let preserveNotificationLiveSession = NotificationMuteStorage.consumePendingLiveSessionPreserveOnArrival(
            from: tracked.fromCRS,
            to: tracked.toCRS
        )

        // Unregister the ActivityKit backend record so server polling for the Live Activity
        // stops, but keep the notification live-session subscription on arrival-driven ends.
        // `/notifications/terminate` needs that record to send the welcome + muted-status pushes.
        Task { @MainActor in
            if preserveNotificationLiveSession {
                NotificationMuteRequestSender.shared.deferLiveActivityUnregistration(
                    activityID: activityID,
                    from: tracked.fromCRS,
                    to: tracked.toCRS
                )
                let msg = "Preserving notification live session on arrival for \(tracked.fromCRS)→\(tracked.toCRS)"
                DebugLogStore.shared.log(msg, category: "Mute")
                print("📍 \(msg)")
                await NotificationSubscriptionStore.shared.removeLiveSessionsLocally(containingFrom: tracked.fromCRS, to: tracked.toCRS)
            } else {
                await sendLiveActivityUnregistration(activityID: activityID)
                await NotificationSubscriptionStore.shared.deleteLiveSessions(containingFrom: tracked.fromCRS, to: tracked.toCRS)
            }
        }

        // Update published state
        updatePublishedState()
        Task { @MainActor in
            await NotificationSubscriptionStore.shared.syncGeofencesNow()
        }
        lastEndedAt = Date()
    }

    private func startPushToStartTokenObservation() {
        guard #available(iOS 17.2, *) else { return }

        pushToStartTokenTask?.cancel()
        pushToStartTokenTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if let current = Activity<JourneyActivityAttributes>.pushToStartToken {
                await self.registerPushToStartTokenIfNeeded(current, force: true)
            }

            for await tokenData in Activity<JourneyActivityAttributes>.pushToStartTokenUpdates {
                await self.registerPushToStartTokenIfNeeded(tokenData, force: true)
            }
        }
    }

    private func registerPushToStartTokenIfNeeded(_ tokenData: Data, force: Bool = false) async {
        let tokenString = encodePushToken(tokenData)
        guard force || tokenString != lastRegisteredPushToStartToken else {
            ClientDiagnosticsLogger.log("live_activity", "push_to_start_registration_skipped_same_token", metadata: [
                "token_prefix": String(tokenString.prefix(8)),
                "token_suffix": String(tokenString.suffix(8))
            ])
            return
        }
        let success = await sendPushToStartTokenRegistration(tokenString: tokenString)
        if success {
            lastRegisteredPushToStartToken = tokenString
        }
        ClientDiagnosticsLogger.log("live_activity", "push_to_start_registration_finished", metadata: [
            "success": success,
            "token_prefix": String(tokenString.prefix(8)),
            "token_suffix": String(tokenString.suffix(8))
        ])
    }

    func ensurePushToStartTokenRegistered(timeoutSeconds: Double = 8.0) async -> Bool {
        guard #available(iOS 17.2, *) else {
            logger.error("[LiveActivity] Push-to-start requires iOS 17.2 or later")
            return false
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let current = Activity<JourneyActivityAttributes>.pushToStartToken {
                await registerPushToStartTokenIfNeeded(current, force: true)
                if lastRegisteredPushToStartToken == encodePushToken(current) {
                    ClientDiagnosticsLogger.log("live_activity", "ensure_push_to_start_token_registered_success", metadata: [
                        "source": "current_token"
                    ])
                    return true
                }
            } else if let cachedToken = lastRegisteredPushToStartToken {
                let success = await sendPushToStartTokenRegistration(tokenString: cachedToken)
                ClientDiagnosticsLogger.log("live_activity", "ensure_push_to_start_cached_token_registration", metadata: [
                    "success": success,
                    "token_prefix": String(cachedToken.prefix(8)),
                    "token_suffix": String(cachedToken.suffix(8))
                ])
                if success {
                    ClientDiagnosticsLogger.log("live_activity", "ensure_push_to_start_token_registered_success", metadata: [
                        "source": "cached_token_reposted"
                    ])
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        ClientDiagnosticsLogger.log("live_activity", "ensure_push_to_start_token_registered_timeout", metadata: [
            "has_last_registered_token": lastRegisteredPushToStartToken != nil
        ])
        return lastRegisteredPushToStartToken != nil
    }

    // MARK: - Push token / backend registration
    private func watchPushToken(for activity: Activity<JourneyActivityAttributes>, fromCRS: String, toCRS: String) {
        pushTokenTasks[activity.id]?.cancel()
        pushTokenTasks[activity.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            self.logger.info("[LiveActivity] Listening for push token updates for activity \(activity.id, privacy: .public)")
            print("👂 [LiveActivity] Started watching push tokens for \(activity.id)")
            var tokenCount = 0
            var registeredTokens = Set<String>()
            @MainActor
            func register(_ tokenData: Data, source: String) async {
                let tokenString = encodePushToken(tokenData)
                guard registeredTokens.insert(tokenString).inserted else {
                    print("↩️ [LiveActivity] Skipping duplicate \(source) push token for \(activity.id)")
                    return
                }

                tokenCount += 1
                let tokenPreview = String(tokenString.prefix(8)) + "..." + String(tokenString.suffix(8))
                self.logger.info("[LiveActivity] Received \(source, privacy: .public) push token #\(tokenCount) for activity \(activity.id, privacy: .public): \(tokenPreview, privacy: .public)")
                print("📡 [LiveActivity] \(source) push token #\(tokenCount) received for \(activity.id): \(tokenString)")

                var retryCount = 0
                var success = false
                while !success && retryCount < 3 {
                    let preferredServiceID = self.trackedActivities[activity.id]?.preferredServiceID
                    success = await self.sendLiveActivityRegistration(
                        activityID: activity.id,
                        tokenString: tokenString,
                        fromCRS: fromCRS,
                        toCRS: toCRS,
                        routeTitle: activity.contentState.routeTitle,
                        deepLinkFromCRS: activity.contentState.deepLinkFromCRS,
                        deepLinkToCRS: activity.contentState.deepLinkToCRS,
                        preferredServiceID: preferredServiceID,
                        journeyUpdatesEnabled: self.trackedActivities[activity.id]?.journeyUpdatesEnabled ?? activity.contentState.journeyUpdatesEnabled,
                        scheduleKey: activity.contentState.scheduleKey,
                        windowStart: activity.contentState.windowStart,
                        windowEnd: activity.contentState.windowEnd
                    )
                    if !success {
                        retryCount += 1
                        if retryCount < 3 {
                            print("⚠️ [LiveActivity] Token registration failed, retrying (\(retryCount)/3)...")
                            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 second delay
                        }
                    }
                }

                if success {
                    print("✅ [LiveActivity] \(source) token #\(tokenCount) successfully registered with backend")
                } else {
                    print("❌ [LiveActivity] \(source) token #\(tokenCount) failed to register after 3 attempts")
                }
            }

            if let tokenData = activity.pushToken {
                await register(tokenData, source: "current")
            } else {
                print("⏳ [LiveActivity] No current push token for \(activity.id); waiting for pushTokenUpdates")
            }

            for await tokenData in activity.pushTokenUpdates {
                await register(tokenData, source: "stream")
            }
            print("👋 [LiveActivity] Stopped watching push tokens for \(activity.id) (received \(tokenCount) total)")
            self.pushTokenTasks[activity.id] = nil
        }
    }

    @discardableResult
    private func sendLiveActivityRegistration(
        activityID: Activity<JourneyActivityAttributes>.ID,
        tokenString: String,
        fromCRS: String,
        toCRS: String,
        routeTitle: String? = nil,
        deepLinkFromCRS: String? = nil,
        deepLinkToCRS: String? = nil,
        preferredServiceID: String? = nil,
        journeyUpdatesEnabled: Bool = true,
        scheduleKey: String? = nil,
        windowStart: String? = nil,
        windowEnd: String? = nil
    ) async -> Bool {
        let base = ApiHostPreference.currentBaseURL
        let urlString = "\(base)/live_activities"
        guard let url = URL(string: urlString) else {
            logger.error("[LiveActivity] Invalid live activity registration URL: \(urlString, privacy: .public)")
            print("❌ [LiveActivity] Invalid URL: \(urlString)")
            return false
        }

        let deviceID = DeviceIdentity.deviceToken
        let tokenPreview = String(tokenString.prefix(8)) + "..." + String(tokenString.suffix(8))

        // Detect if this is a debug/development build to tell server which APNs environment to use
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif

        let muteDelayMinutes = (UserDefaults.standard.object(forKey: "muteDelayMinutes") as? Int) ?? 3
        let autoEndLiveActivity = (UserDefaults.standard.object(forKey: "autoEndLiveActivity") as? Bool) ?? true
        var payload: [String: Any] = [
            "device_id": deviceID,
            "activity_id": activityID,
            "live_activity_push_token": tokenString,
            "from": fromCRS,
            "to": toCRS,
            "use_sandbox": isDebugBuild,
            "mute_on_arrival": true,
            "mute_delay_minutes": muteDelayMinutes,
            "auto_end_on_arrival": false,
            "auto_end_on_departure": autoEndLiveActivity,
            "journey_updates_enabled": journeyUpdatesEnabled
        ]
        if let routeTitle, !routeTitle.isEmpty {
            payload["display_name"] = routeTitle
        }
        if let deepLinkFromCRS, !deepLinkFromCRS.isEmpty {
            payload["deep_link_from"] = deepLinkFromCRS
        }
        if let deepLinkToCRS, !deepLinkToCRS.isEmpty {
            payload["deep_link_to"] = deepLinkToCRS
        }
        if let preferredServiceID, !preferredServiceID.isEmpty {
            payload["preferred_service_id"] = preferredServiceID
        }
        if let scheduleKey, !scheduleKey.isEmpty {
            payload["schedule_key"] = scheduleKey
        }
        if let windowStart, !windowStart.isEmpty {
            payload["window_start"] = windowStart
        }
        if let windowEnd, !windowEnd.isEmpty {
            payload["window_end"] = windowEnd
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.timeoutInterval = 30

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            logger.error("[LiveActivity] Failed to encode live activity registration payload: \(String(describing: error), privacy: .public)")
            print("❌ [LiveActivity] Failed to encode live activity payload: \(error)")
            return false
        }

        print("➡️ [LiveActivity] Registering token \(tokenPreview) for activity \(activityID) at \(urlString)")
        logger.info("[LiveActivity] Registering live activity with backend: \(urlString, privacy: .public)")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                let success = (200...299).contains(http.statusCode)
                if success {
                    print("✅ [LiveActivity] Registration successful: status=\(http.statusCode) token=\(tokenPreview)")
                    logger.info("[LiveActivity] Registration successful: status=\(http.statusCode)")
                } else {
                    print("❌ [LiveActivity] Registration failed: status=\(http.statusCode) body=\(body)")
                    logger.error("[LiveActivity] Registration failed: status=\(http.statusCode)")
                }
                return success
            } else {
                print("⚠️ [LiveActivity] Registration response was not HTTPURLResponse")
                logger.warning("[LiveActivity] Registration response not HTTPURLResponse")
                return false
            }
        } catch {
            print("❌ [LiveActivity] Network error registering live activity: \(error)")
            logger.error("[LiveActivity] Network error registering live activity: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func sendPushToStartTokenRegistration(tokenString: String) async -> Bool {
        let base = ApiHostPreference.currentBaseURL
        let urlString = "\(base)/live_activities/push_to_start_tokens"
        guard let url = URL(string: urlString) else {
            logger.error("[LiveActivity] Invalid push-to-start registration URL: \(urlString, privacy: .public)")
            return false
        }

        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif

        let payload: [String: Any] = [
            "device_id": DeviceIdentity.deviceToken,
            "push_to_start_token": tokenString,
            "use_sandbox": isDebugBuild
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.timeoutInterval = 15

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            logger.error("[LiveActivity] Failed to encode push-to-start registration payload: \(String(describing: error), privacy: .public)")
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            if (200...299).contains(http.statusCode) {
                logger.info("[LiveActivity] Push-to-start token registered successfully")
                ClientDiagnosticsLogger.log("live_activity", "push_to_start_registration_http_success", metadata: [
                    "status": http.statusCode
                ])
                return true
            }
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            logger.error("[LiveActivity] Push-to-start registration failed: status=\(http.statusCode) body=\(body, privacy: .public)")
            ClientDiagnosticsLogger.log("live_activity", "push_to_start_registration_http_failed", metadata: [
                "status": http.statusCode,
                "body": body
            ])
            return false
        } catch {
            logger.error("[LiveActivity] Network error registering push-to-start token: \(String(describing: error), privacy: .public)")
            ClientDiagnosticsLogger.log("live_activity", "push_to_start_registration_network_error", metadata: [
                "error": String(describing: error)
            ])
            return false
        }
    }

    private func sendLiveActivityUnregistration(
        activityID: String,
        preserveNotificationLiveSession: Bool = false
    ) async {
        let base = ApiHostPreference.currentBaseURL
        let urlString = "\(base)/live_activities"
        guard let url = URL(string: urlString) else {
            logger.error("[LiveActivity] Invalid live activity unregistration URL: \(urlString, privacy: .public)")
            print("❌ [LiveActivity] Invalid unregistration URL: \(urlString)")
            return
        }

        let deviceID = DeviceIdentity.deviceToken
        let payload: [String: Any] = [
            "device_id": deviceID,
            "activity_id": activityID,
            "preserve_notification_live_session": preserveNotificationLiveSession
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.timeoutInterval = 30

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            logger.error("[LiveActivity] Failed to encode live activity unregistration payload: \(String(describing: error), privacy: .public)")
            print("❌ [LiveActivity] Failed to encode unregistration payload: \(error)")
            return
        }

        let requestLog = "Live Activity unregistration request\nURL: \(urlString)\nActivity: \(activityID)\nDevice: \(deviceID)\nPreserve notification session: \(preserveNotificationLiveSession)"
        DebugLogStore.shared.log(requestLog, category: "Mute")
        print("➡️ [LiveActivity] Unregistering activity \(activityID) at \(urlString) preserveNotificationLiveSession=\(preserveNotificationLiveSession)")
        logger.info("[LiveActivity] Unregistering live activity with backend: \(urlString, privacy: .public)")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                let success = (200...299).contains(http.statusCode)
                let responseLog = "Live Activity unregistration completed with status: \(http.statusCode)\nURL: \(urlString)\nActivity: \(activityID)\nPreserve notification session: \(preserveNotificationLiveSession)\nResponse: \(body)"
                DebugLogStore.shared.log(responseLog, category: success ? "Mute" : "Error")
                if success {
                    print("✅ [LiveActivity] Unregistration successful: status=\(http.statusCode) body=\(body)")
                    logger.info("[LiveActivity] Unregistration successful: status=\(http.statusCode)")
                } else {
                    print("⚠️ [LiveActivity] Unregistration returned: status=\(http.statusCode) body=\(body)")
                    logger.warning("[LiveActivity] Unregistration returned: status=\(http.statusCode)")
                }
            }
        } catch {
            let errorLog = "Live Activity unregistration failed: \(error.localizedDescription)\nURL: \(urlString)\nActivity: \(activityID)\nPreserve notification session: \(preserveNotificationLiveSession)"
            DebugLogStore.shared.log(errorLog, category: "Error")
            print("❌ [LiveActivity] Network error unregistering live activity: \(error)")
            logger.error("[LiveActivity] Network error unregistering live activity: \(String(describing: error), privacy: .public)")
        }
    }

    func finalizeArrivalTriggeredActivityUnregistration(activityID: String, fromCRS: String, toCRS: String) async {
        let msg = "Finalizing deferred Live Activity unregistration for \(fromCRS)→\(toCRS)"
        DebugLogStore.shared.log(msg, category: "Mute")
        print("📍 \(msg)")
        await sendLiveActivityUnregistration(
            activityID: activityID,
            preserveNotificationLiveSession: false
        )
    }

    func sendImmediateBackendCheckIn(force: Bool = false) async {
        let hasAnyActivities = !trackedActivities.isEmpty || !currentSystemActivities().isEmpty
        if !force, !hasAnyActivities {
            logger.info("[LiveActivity] Skipping check-in because no activities are active")
            return
        }
        if !force, let last = lastBackendCheckInAt, Date().timeIntervalSince(last) < backendCheckInMinIntervalSeconds {
            return
        }
        lastBackendCheckInAt = Date()

        let base = ApiHostPreference.currentBaseURL
        let urlString = "\(base)/live_activities/checkin"
        guard let url = URL(string: urlString) else {
            logger.error("[LiveActivity] Invalid live activity check-in URL: \(urlString, privacy: .public)")
            return
        }

        let deviceID = DeviceIdentity.deviceToken
        let payload: [String: Any] = [
            "device_id": deviceID,
            "force_refresh": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.timeoutInterval = 15

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                logger.warning("[LiveActivity] Check-in returned status=\(http.statusCode) body=\(body, privacy: .public)")
            } else {
                logger.info("[LiveActivity] Check-in sent successfully for device \(deviceID, privacy: .public)")
            }
        } catch {
            logger.error("[LiveActivity] Failed to send check-in: \(String(describing: error), privacy: .public)")
        }
    }

    private func encodePushToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var activityDebug: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }
}
