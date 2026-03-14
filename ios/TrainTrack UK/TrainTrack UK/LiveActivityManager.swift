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

    // Live Activity lifetime; set to nil to disable auto-expiry and rely on manual dismissal.
    private let activityExpiryInterval: TimeInterval? = nil
    // Local fallback end if remote end push never arrives. Computed from preference.
    private var fallbackEndInterval: TimeInterval? { durationSeconds }
    // Force end any lingering activity after this many seconds as a last-resort safety (align with preference).
    private var forceEndAfterSeconds: TimeInterval { durationSeconds }

    // Global monitor timer for all activities
    private var monitorTimer: Timer? = nil

    // User-configurable duration in minutes (default 60). Reads from UserDefaults.
    private var durationSeconds: TimeInterval {
        let storedMinutes = UserDefaults.standard.integer(forKey: durationKey)
        let minutes = storedMinutes == 0 ? 60 : storedMinutes
        let seconds = Double(minutes * 60)
        print("🔧 [LiveActivity] Duration preference: \(minutes) minute\(minutes == 1 ? "" : "s") (\(seconds) seconds)")
        return seconds
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
        scheduleGlobalActivityMonitor()
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

    /// Get the count of currently active Live Activities
    var activeCount: Int {
        return Set(
            Activity<JourneyActivityAttributes>.activities.map { $0.id }
                + trackedActivities.keys
        ).count
    }

    func refreshIfActive(journeyStore: JourneyStore, depStore: DeparturesStore) async {
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
        allowAutomaticStart: Bool = false
    ) async {
        guard triggeredByUser || allowAutomaticStart else {
            print("🚫 [LiveActivity] Start ignored (not user-triggered; auto-starts disabled)")
            return
        }
        if !bypassSuppression, let lastEndedAt, Date().timeIntervalSince(lastEndedAt) < autoRestartSuppressionWindow {
            print("🚫 [LiveActivity] Start suppressed to avoid immediate auto-restart (last end \(Date().timeIntervalSince(lastEndedAt))s ago)")
            return
        }

        // Check if already tracking this journey. If a preferred service was provided,
        // update the tracked preference and refresh immediately.
        if let existingActivityID = activityID(for: journey) {
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
                        preferredServiceID: preferredServiceID
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
        let initial = await contentState(for: journey, depStore: depStore, preferredServiceID: preferredServiceID)
        print("🚂 [LiveActivity] Initial state: platform=\(initial.platform), est=\(initial.estimated), dest=\(initial.destinationTitle)")
        os_log("[LiveActivity] Initial content state: fromCRS=%{public}@, toCRS=%{public}@, dest=%{public}@, platform=%{public}@, est=%{public}@",
               initial.fromCRS, initial.toCRS, initial.destinationTitle, initial.platform, initial.estimated)

        do {
            // Use station names in the activity heading
            let attr = JourneyActivityAttributes(displayName: "\(journey.fromStation.name) → \(journey.toStation.name)")
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
                    preferredServiceID: preferredServiceID
                )
            }

            // Create tracked activity with its own timers
            var tracked = TrackedActivity(
                activity: act,
                fromCRS: journey.fromStation.crs,
                toCRS: journey.toStation.crs,
                startedAt: Date(),
                preferredServiceID: preferredServiceID
            )

            // Schedule update timer for this activity
            tracked.timer = scheduleUpdates(for: journey, depStore: depStore, activityID: act.id)

            // Schedule fallback end timer for this activity
            tracked.fallbackEndTimer = scheduleFallbackEnd(for: act.id)

            // Store the tracked activity
            trackedActivities[act.id] = tracked

            // Update published state
            updatePublishedState()

            // Check all active activities
            let allActivities = Activity<JourneyActivityAttributes>.activities
            print("✅ [LiveActivity] Total active activities: \(allActivities.count)")
            os_log("[LiveActivity] Total active activities: %{public}d", allActivities.count)
            for (index, activity) in allActivities.enumerated() {
                print("✅ [LiveActivity] Activity [\(index)]: id=\(activity.id), state=\(activity.activityState)")
                os_log("[LiveActivity] Activity [%{public}d]: id=%{public}@, state=%{public}@",
                       index, activity.id, String(describing: activity.activityState))
            }

            print("✅ [LiveActivity] ===== START COMPLETED SUCCESSFULLY =====")
            print("✅ [LiveActivity] Now tracking \(trackedActivities.count) activities")
            os_log("[LiveActivity] ===== START COMPLETED SUCCESSFULLY =====")
        } catch {
            print("❌ [LiveActivity] ===== START FAILED =====")
            print("❌ [LiveActivity] Error: \(error)")
            print("❌ [LiveActivity] Error localizedDescription: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("❌ [LiveActivity] Error domain: \(nsError.domain), code: \(nsError.code)")
                print("❌ [LiveActivity] Error userInfo: \(nsError.userInfo)")
            }
            lastMessage = "Unable to start Live Activity: \(error.localizedDescription)"
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

        lastEndedAt = Date()
        os_log("[LiveActivity] All activities stopped")
    }

    /// Stop a specific Live Activity by its ID
    func stopActivity(activityID: String) async {
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
        ScheduledLiveActivityAutoStartManager.shared.removeRecord(activityID: activityID)

        // Unregister from backend so server stops polling
        await sendLiveActivityUnregistration(activityID: activityID)

        // Update published state
        updatePublishedState()

        lastEndedAt = Date()
        os_log("[LiveActivity] Activity %{public}@ stopped", activityID)
    }

    /// Stop the Live Activity for a specific journey
    func stop(for journey: Journey) async {
        let fromCRS = journey.fromStation.crs.uppercased()
        let toCRS = journey.toStation.crs.uppercased()

        let trackedIDs = trackedActivities.compactMap { entry -> String? in
            let tracked = entry.value
            guard tracked.fromCRS.uppercased() == fromCRS, tracked.toCRS.uppercased() == toCRS else { return nil }
            return entry.key
        }
        if !trackedIDs.isEmpty {
            for activityID in trackedIDs {
                await stopActivity(activityID: activityID)
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
            await sendLiveActivityUnregistration(activityID: activity.id)
        }
        updatePublishedState()
        lastEndedAt = Date()
    }

    /// Update the published state based on tracked activities
    private func updatePublishedState() {
        let trackedPairs = trackedActivities.values.map { ($0.fromCRS.uppercased(), $0.toCRS.uppercased()) }
        let systemPairs = Activity<JourneyActivityAttributes>.activities.map {
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
        print("📊 [LiveActivity] State updated: isActive=\(isActive), activeJourneys=\(activeJourneys.map { "\($0.fromCRS)→\($0.toCRS)" })")
    }

    private func systemActivities(forFromCRS fromCRS: String, toCRS: String) -> [Activity<JourneyActivityAttributes>] {
        Activity<JourneyActivityAttributes>.activities.filter {
            $0.contentState.fromCRS.uppercased() == fromCRS && $0.contentState.toCRS.uppercased() == toCRS
        }
    }

    private func scheduleFallbackEnd(for activityID: String) -> Timer? {
        guard let interval = fallbackEndInterval else {
            print("⚠️ [LiveActivity] Fallback end timer NOT scheduled for \(activityID) (interval is nil)")
            return nil
        }
        let minutes = Int(interval / 60)
        print("⏰ [LiveActivity] Scheduling fallback end timer for activity \(activityID): \(minutes) minute\(minutes == 1 ? "" : "s") (\(interval) seconds)")
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            print("⏳ [LiveActivity] Fallback end fired for \(activityID) after \(interval)s (\(minutes) min); ending locally")
            Task { await self.stopActivity(activityID: activityID) }
        }
        print("✅ [LiveActivity] Fallback end timer scheduled for activity \(activityID) at \(Date().addingTimeInterval(interval))")
        return timer
    }

    private func scheduleGlobalActivityMonitor() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            let list = Activity<JourneyActivityAttributes>.activities
            let states = list.map { "\($0.id): \($0.activityState)" }.joined(separator: "; ")
            print("🛰️ [LiveActivity] Monitor tick - activities: \(states)")

            // Check each tracked activity for force-end on the main actor
            Task { @MainActor in
                let now = Date()
                for (activityID, tracked) in self.trackedActivities {
                    let elapsed = now.timeIntervalSince(tracked.startedAt)
                    if elapsed > self.forceEndAfterSeconds {
                        print("⏳ [LiveActivity] Force-ending activity \(activityID) after \(Int(elapsed))s")
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
        print("🔄 [LiveActivity] Found \(deps.count) departures after refresh")
        if let selectedDep = selectPrimaryDeparture(preferredServiceID: preferredServiceID, allDepartures: deps, filteredDepartures: deps) {
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
        let state = await contentState(for: journey, depStore: depStore, preferredServiceID: preferredServiceID)

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

    private func contentState(for journey: Journey, depStore: DeparturesStore, preferredServiceID: String? = nil) async -> JourneyActivityAttributes.ContentState {
        let allDeps = depStore.departures(for: journey)
        // Filter out trains that have already departed (1 minute grace period)
        let now = Date()
        let gracePeriodSeconds: TimeInterval = 60
        let departureStillRelevant: (DepartureV2) -> Bool = { dep in
            guard let depTime = self.parseHHmmToDate(dep.departureTime.estimated ?? dep.departureTime.scheduled) else {
                return true // Keep if we can't parse time
            }
            return depTime.timeIntervalSince(now) > -gracePeriodSeconds
        }
        let deps = allDeps.filter(departureStillRelevant)
        let next = selectPrimaryDeparture(preferredServiceID: preferredServiceID, allDepartures: allDeps, filteredDepartures: deps)
        let title: String = {
            if let first = next?.destination.first {
                if let via = first.via, !via.isEmpty { return "\(first.locationName) \(via)" }
                return first.locationName
            }
            return "\(journey.toStation.name)"
        }()
        var arrival: String? = nil
        var statusText: String? = nil
        var delayMins: Int = 0
        if let n = next {
            if n.isCancelled {
                statusText = nil
            } else if let details = depStore.serviceDetailsById[n.serviceID] {
                if let cp = details.allStations.first(where: { $0.crs == journey.toStation.crs }) {
                    if let et = cp.et, !et.isEmpty, et.lowercased() != "on time" { arrival = "Arr \(et)" } else { arrival = "Arr \(cp.st)" }
                }
                if let live = computeLiveStatus(from: details, within: journey.fromStation.crs, toCRS: journey.toStation.crs) {
                    statusText = live.text
                    delayMins = live.delayMinutes
                }
            }
        }
        let platform = next?.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (next?.platform ?? "TBC") : "TBC"
        let est = displayDepartureTime(for: next)
        let scheduledDeparture = next?.departureTime.scheduled
        let length = next?.length

        // Build upcoming departures (skip the first one as it's the main departure, get next 3)
        var upcoming: [JourneyActivityAttributes.UpcomingDeparture] = []
        let upcomingDeps: [DepartureV2] = {
            if let next,
               let selectedIndex = allDeps.firstIndex(where: { $0.serviceID == next.serviceID }) {
                let tail = Array(allDeps.suffix(from: selectedIndex + 1))
                return Array(tail.filter(departureStillRelevant).prefix(3))
            }
            return Array(deps.dropFirst().prefix(3))
        }()
        for (index, dep) in upcomingDeps.enumerated() {
            let depDelayMins = calculateDelayMinutes(scheduled: dep.departureTime.scheduled, estimated: dep.departureTime.estimated)
            // Only check departures that come after this one in the list
            let laterDeps = Array(upcomingDeps.dropFirst(index + 1))
            let hasFaster = checkForFasterLaterService(dep: dep, allDeps: laterDeps, fromCRS: journey.fromStation.crs, toCRS: journey.toStation.crs, depStore: depStore)
            upcoming.append(JourneyActivityAttributes.UpcomingDeparture(
                time: dep.departureTime.estimated ?? dep.departureTime.scheduled,
                delayMinutes: depDelayMins,
                isCancelled: dep.isCancelled,
                platform: dep.platform,
                hasFasterLaterService: hasFaster
            ))
        }

        let state = JourneyActivityAttributes.ContentState(
            fromCRS: journey.fromStation.crs,
            toCRS: journey.toStation.crs,
            destinationTitle: title,
            arrivalLabel: arrival,
            scheduledDeparture: scheduledDeparture,
            length: length,
            platform: platform,
            estimated: est,
            isCancelled: next?.isCancelled ?? false,
            statusText: statusText,
            delayMinutes: delayMins,
            upcomingDepartures: upcoming,
            lastUpdated: Date()
        )
        return state
    }

    private func selectPrimaryDeparture(preferredServiceID: String?, allDepartures: [DepartureV2], filteredDepartures: [DepartureV2]) -> DepartureV2? {
        if let preferredServiceID,
           let preferred = allDepartures.first(where: { $0.serviceID == preferredServiceID }) {
            return preferred
        }
        return filteredDepartures.first
    }

    private func calculateDelayMinutes(scheduled: String, estimated: String?) -> Int {
        guard let est = estimated, !est.isEmpty, est.lowercased() != "on time" else { return 0 }
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
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = h
        components.minute = m
        components.second = 0
        return calendar.date(from: components)
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
        guard trackedActivities[activity.id] == nil else { return }

        let fromCRS = activity.contentState.fromCRS.uppercased()
        let toCRS = activity.contentState.toCRS.uppercased()

        var tracked = TrackedActivity(
            activity: activity,
            fromCRS: fromCRS,
            toCRS: toCRS,
            startedAt: Date(),
            preferredServiceID: nil
        )
        tracked.fallbackEndTimer = scheduleFallbackEnd(for: activity.id)
        trackedActivities[activity.id] = tracked
        watchPushToken(for: activity, fromCRS: fromCRS, toCRS: toCRS)
        if let tokenData = activity.pushToken {
            let tokenString = encodePushToken(tokenData)
            Task { @MainActor in
                _ = await self.sendLiveActivityRegistration(
                    activityID: activity.id,
                    tokenString: tokenString,
                    fromCRS: fromCRS,
                    toCRS: toCRS,
                    scheduleKey: activity.contentState.scheduleKey,
                    windowStart: activity.contentState.windowStart,
                    windowEnd: activity.contentState.windowEnd
                )
            }
        }
        updatePublishedState()
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

        let untrackedDuplicates = Activity<JourneyActivityAttributes>.activities.filter {
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

        // Unregister from backend so server stops polling
        Task {
            await sendLiveActivityUnregistration(activityID: activityID)
        }

        // Update published state
        updatePublishedState()
        lastEndedAt = Date()
    }

    private func startPushToStartTokenObservation() {
        guard #available(iOS 17.2, *) else { return }

        pushToStartTokenTask?.cancel()
        pushToStartTokenTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if let current = Activity<JourneyActivityAttributes>.pushToStartToken {
                await self.registerPushToStartTokenIfNeeded(current)
            }

            for await tokenData in Activity<JourneyActivityAttributes>.pushToStartTokenUpdates {
                await self.registerPushToStartTokenIfNeeded(tokenData)
            }
        }
    }

    private func registerPushToStartTokenIfNeeded(_ tokenData: Data) async {
        let tokenString = encodePushToken(tokenData)
        guard tokenString != lastRegisteredPushToStartToken else { return }
        let success = await sendPushToStartTokenRegistration(tokenString: tokenString)
        if success {
            lastRegisteredPushToStartToken = tokenString
        }
    }

    // MARK: - Push token / backend registration
    private func watchPushToken(for activity: Activity<JourneyActivityAttributes>, fromCRS: String, toCRS: String) {
        pushTokenTasks[activity.id]?.cancel()
        pushTokenTasks[activity.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            self.logger.info("[LiveActivity] Listening for push token updates for activity \(activity.id, privacy: .public)")
            print("👂 [LiveActivity] Started watching push tokens for \(activity.id)")
            var tokenCount = 0
            do {
                for await tokenData in activity.pushTokenUpdates {
                    tokenCount += 1
                    let tokenString = encodePushToken(tokenData)
                    let tokenPreview = String(tokenString.prefix(8)) + "..." + String(tokenString.suffix(8))
                    self.logger.info("[LiveActivity] Received push token #\(tokenCount) for activity \(activity.id, privacy: .public): \(tokenPreview, privacy: .public)")
                    print("📡 [LiveActivity] Push token #\(tokenCount) received for \(activity.id): \(tokenString)")

                    // Send token to backend with retry logic
                    var retryCount = 0
                    var success = false
                    while !success && retryCount < 3 {
                        let preferredServiceID = self.trackedActivities[activity.id]?.preferredServiceID
                        success = await self.sendLiveActivityRegistration(
                            activityID: activity.id,
                            tokenString: tokenString,
                            fromCRS: fromCRS,
                            toCRS: toCRS,
                            preferredServiceID: preferredServiceID,
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
                        print("✅ [LiveActivity] Token #\(tokenCount) successfully registered with backend")
                    } else {
                        print("❌ [LiveActivity] Token #\(tokenCount) failed to register after 3 attempts")
                    }
                }
            } catch {
                self.logger.error("[LiveActivity] Error while listening for push token updates: \(String(describing: error), privacy: .public)")
                print("❌ [LiveActivity] Error listening for push tokens: \(error)")
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
        preferredServiceID: String? = nil,
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

        let muteOnArrival = (UserDefaults.standard.object(forKey: "autoMuteOnArrival") as? Bool) ?? true
        let muteDelayMinutes = (UserDefaults.standard.object(forKey: "muteDelayMinutes") as? Int) ?? 3
        let autoEndLiveActivity = (UserDefaults.standard.object(forKey: "autoEndLiveActivity") as? Bool) ?? true
        var payload: [String: Any] = [
            "device_id": deviceID,
            "activity_id": activityID,
            "live_activity_push_token": tokenString,
            "from": fromCRS,
            "to": toCRS,
            "use_sandbox": isDebugBuild,
            "mute_on_arrival": muteOnArrival,
            "mute_delay_minutes": muteDelayMinutes,
            "auto_end_on_arrival": false,
            "auto_end_on_departure": autoEndLiveActivity
        ]
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
                return true
            }
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            logger.error("[LiveActivity] Push-to-start registration failed: status=\(http.statusCode) body=\(body, privacy: .public)")
            return false
        } catch {
            logger.error("[LiveActivity] Network error registering push-to-start token: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func sendLiveActivityUnregistration(activityID: String) async {
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
            "activity_id": activityID
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

        print("➡️ [LiveActivity] Unregistering activity \(activityID) at \(urlString)")
        logger.info("[LiveActivity] Unregistering live activity with backend: \(urlString, privacy: .public)")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                let success = (200...299).contains(http.statusCode)
                if success {
                    print("✅ [LiveActivity] Unregistration successful: status=\(http.statusCode) body=\(body)")
                    logger.info("[LiveActivity] Unregistration successful: status=\(http.statusCode)")
                } else {
                    print("⚠️ [LiveActivity] Unregistration returned: status=\(http.statusCode) body=\(body)")
                    logger.warning("[LiveActivity] Unregistration returned: status=\(http.statusCode)")
                }
            }
        } catch {
            print("❌ [LiveActivity] Network error unregistering live activity: \(error)")
            logger.error("[LiveActivity] Network error unregistering live activity: \(String(describing: error), privacy: .public)")
        }
    }

    func sendImmediateBackendCheckIn(force: Bool = false) async {
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
