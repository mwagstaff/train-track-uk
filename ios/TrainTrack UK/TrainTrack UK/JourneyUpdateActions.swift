import Foundation

@MainActor
enum JourneyUpdateActions {
    static func scheduledRouteKey(for group: JourneyGroup) -> String {
        let crs = group.stationSequence.map { $0.crs.uppercased() }
        let forward = crs.joined(separator: "-")
        let reverse = crs.reversed().joined(separator: "-")
        return min(forward, reverse)
    }

    static func liveSessionRouteKey(for group: JourneyGroup) -> String {
        "\(group.startStation.crs.uppercased())-\(group.endStation.crs.uppercased())"
    }

    static func start(
        group: JourneyGroup,
        scheduledSubscription: NotificationSubscription?,
        liveSession: NotificationSubscription?,
        liveActivityDurationMinutes: Int,
        notificationStore: NotificationSubscriptionStore,
        activityManager: LiveActivityManager,
        departuresStore: DeparturesStore
    ) async -> Bool {
        let allowed = await NotificationAuthorizationManager.ensureAuthorized()
        guard allowed else {
            let message = "Notifications are disabled in Settings"
            activityManager.lastMessage = message
            ToastStore.shared.show(message, icon: "bell.slash.fill")
            return false
        }

        guard let pushToken = await NotificationPushTokenStore.waitForToken(timeoutSeconds: 6.0) else {
            let message = "Waiting for a notification token. Try again in a moment."
            activityManager.lastMessage = message
            ToastStore.shared.show(message, icon: "exclamationmark.triangle.fill")
            return false
        }

        NotificationGeofenceManager.shared.requestAlwaysAuthorizationIfNeeded()

        if liveSession == nil,
           notificationStore.liveSessions.count >= 5,
           let replacement = notificationStore.liveSessions
            .filter({ $0.routeKey != liveSessionRouteKey(for: group) })
            .sorted(by: { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) })
            .first {
            do {
                try await stop(
                    session: replacement,
                    notificationStore: notificationStore,
                    activityManager: activityManager
                )
                ToastStore.shared.show("Replaced oldest live update", icon: "arrow.triangle.2.circlepath")
            } catch {
                activityManager.lastMessage = error.localizedDescription
                ToastStore.shared.show("Unable to replace oldest live update", icon: "exclamationmark.triangle.fill")
                return false
            }
        }

        let legsForActivity = Array(group.legs.prefix(3))
        guard await startLiveActivities(
            for: legsForActivity,
            activityManager: activityManager,
            departuresStore: departuresStore
        ) else {
            ToastStore.shared.show("Unable to start journey updates", icon: "exclamationmark.triangle.fill")
            return false
        }

        do {
            let request = buildLiveSessionRequest(
                group: group,
                scheduledSubscription: scheduledSubscription,
                liveSession: liveSession,
                pushToken: pushToken,
                liveActivityDurationMinutes: liveActivityDurationMinutes
            )
            _ = try await notificationStore.upsertLiveSession(request)
            await activityManager.setJourneyUpdatesEnabled(
                for: legsForActivity,
                enabled: true,
                depStore: departuresStore
            )
            clearMute(for: group)
            ToastStore.shared.show("Live updates are active for your journey", icon: "dot.radiowaves.left.and.right")
            return true
        } catch {
            await stopLiveActivities(for: legsForActivity, activityManager: activityManager)
            activityManager.lastMessage = error.localizedDescription
            ToastStore.shared.show("Unable to start notifications", icon: "exclamationmark.triangle.fill")
            return false
        }
    }

    static func stop(
        session: NotificationSubscription,
        notificationStore: NotificationSubscriptionStore,
        activityManager: LiveActivityManager
    ) async throws {
        try await notificationStore.deleteLiveSession(id: session.id)
        await stopLiveActivities(for: session, activityManager: activityManager)
    }

    private static func startLiveActivities(
        for journeys: [Journey],
        activityManager: LiveActivityManager,
        departuresStore: DeparturesStore
    ) async -> Bool {
        guard let primaryLeg = journeys.first else { return false }

        let staleLegs = Array(journeys.dropFirst()).filter { activityManager.isActive(for: $0) }
        await stopLiveActivities(for: staleLegs, activityManager: activityManager)

        let wasAlreadyActive = activityManager.isActive(for: primaryLeg)
        if !wasAlreadyActive {
            await activityManager.start(
                for: primaryLeg,
                depStore: departuresStore,
                triggeredByUser: true,
                bypassSuppression: true
            )
        }

        let isActive = activityManager.isActive(for: primaryLeg)
        if !isActive && !wasAlreadyActive {
            await stopLiveActivities(for: [primaryLeg], activityManager: activityManager)
        }
        return isActive
    }

    private static func stopLiveActivities(
        for session: NotificationSubscription,
        activityManager: LiveActivityManager
    ) async {
        if StationsService.shared.stations.isEmpty {
            try? await StationsService.shared.loadStations()
        }

        let stationsByCRS = StationsService.shared.stations.reduce(into: [String: Station]()) { result, station in
            let key = station.crs.uppercased()
            if result[key] == nil {
                result[key] = station
            }
        }

        let journeys = Array(session.legs.prefix(3)).compactMap { leg -> Journey? in
            guard let from = stationsByCRS[leg.from.uppercased()],
                  let to = stationsByCRS[leg.to.uppercased()] else {
                return nil
            }
            return Journey(fromStation: from, toStation: to, favorite: false)
        }
        await stopLiveActivities(for: journeys, activityManager: activityManager)
    }

    private static func stopLiveActivities(
        for journeys: [Journey],
        activityManager: LiveActivityManager
    ) async {
        for journey in journeys {
            await activityManager.stop(for: journey)
        }
    }

    private static func clearMute(for group: JourneyGroup) {
        for leg in group.legs {
            let from = leg.fromStation.crs.uppercased()
            let to = leg.toStation.crs.uppercased()
            NotificationMuteStorage.clearMute(from: from, to: to)
            NotificationMuteStorage.clearPendingLiveSessionPreserveOnArrival(from: from, to: to)
            NotificationMuteStorage.clearPendingStationDepartureCleanup(from: from, to: to)
        }
    }

    private static func buildLiveSessionRequest(
        group: JourneyGroup,
        scheduledSubscription: NotificationSubscription?,
        liveSession: NotificationSubscription?,
        pushToken: String,
        liveActivityDurationMinutes: Int
    ) -> NotificationSubscriptionRequest {
        let defaultLegs = group.legs.map { leg in
            NotificationLeg(
                from: leg.fromStation.crs.uppercased(),
                to: leg.toStation.crs.uppercased(),
                fromName: leg.fromStation.name,
                toName: leg.toStation.name,
                enabled: true,
                windowStart: "00:00",
                windowEnd: "23:59"
            )
        }
        let scheduledByLegID = Dictionary(
            uniqueKeysWithValues: (scheduledSubscription?.legs ?? []).map { ($0.id, $0) }
        )
        let resolvedLegs = defaultLegs.map { leg in
            guard let existing = scheduledByLegID[leg.id] else { return leg }
            return NotificationLeg(
                from: leg.from,
                to: leg.to,
                fromName: leg.fromName,
                toName: leg.toName,
                enabled: existing.enabled,
                windowStart: leg.windowStart,
                windowEnd: leg.windowEnd
            )
        }
        let liveSessionLegs: [NotificationLeg]
        if resolvedLegs.contains(where: { $0.enabled }) {
            liveSessionLegs = resolvedLegs
        } else if let firstLeg = resolvedLegs.first {
            liveSessionLegs = [NotificationLeg(
                from: firstLeg.from,
                to: firstLeg.to,
                fromName: firstLeg.fromName,
                toName: firstLeg.toName,
                enabled: true,
                windowStart: firstLeg.windowStart,
                windowEnd: firstLeg.windowEnd
            )] + Array(resolvedLegs.dropFirst())
        } else {
            liveSessionLegs = resolvedLegs
        }

        #if DEBUG
        let useSandbox = true
        #else
        let useSandbox = false
        #endif

        let durationMinutes = min(120, max(1, liveActivityDurationMinutes))
        return NotificationSubscriptionRequest(
            subscriptionId: liveSession?.id,
            deviceId: DeviceIdentity.deviceToken,
            pushToken: pushToken,
            routeKey: liveSessionRouteKey(for: group),
            daysOfWeek: [currentDayOfWeek()],
            notificationTypes: NotificationPreferences.effectiveTypes(for: .liveSession),
            legs: liveSessionLegs,
            windowStart: "00:00",
            windowEnd: "23:59",
            from: group.startStation.crs.uppercased(),
            to: group.endStation.crs.uppercased(),
            fromName: group.startStation.name,
            toName: group.endStation.name,
            useSandbox: useSandbox,
            muteOnArrival: true,
            liveSessionOrigin: .manual,
            activeUntil: Date().addingTimeInterval(Double(durationMinutes * 60))
        )
    }

    private static func currentDayOfWeek() -> DayOfWeek {
        switch Calendar.current.component(.weekday, from: Date()) {
        case 1: return .sun
        case 2: return .mon
        case 3: return .tue
        case 4: return .wed
        case 5: return .thu
        case 6: return .fri
        default: return .sat
        }
    }
}
