import CoreLocation
import Combine
import Foundation
import JourneyActivityShared
import UserNotifications

@MainActor
final class JourneyTrackingCoordinator: ObservableObject {
    static let shared = JourneyTrackingCoordinator()

    static let destinationArrivalRadiusMeters: CLLocationDistance = 150
    static let arrivalNotificationBufferSeconds: TimeInterval = 90
    static let expectedStationRadiusMeters: CLLocationDistance = 250
    static let unexpectedStationDwellSeconds: TimeInterval = 90
    static let maximumActiveJourneyDuration: TimeInterval = 24 * 60 * 60
    static let completedJourneyDisplayDuration: TimeInterval = 60 * 60

    @Published private(set) var armedCandidates: [ArmedJourneyHistoryCandidate] = []
    @Published private(set) var activeJourney: ActiveJourneyHistoryCheckpoint?
    @Published private(set) var recentlyCompletedJourney: ActiveJourneyHistoryCheckpoint?
    @Published private(set) var recentlyCompleted: RecentlyCompletedJourneyCheckpoint?

    private let defaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard
    private let checkpointKey = "journeyHistoryTrackingCheckpointV1"

    private init() {
        restoreCheckpoint()
    }

    var hasActiveJourney: Bool { activeJourney != nil }
    var hasPresentableJourney: Bool {
        !armedCandidates.isEmpty || activeJourney != nil || recentlyCompleted != nil
    }

    #if DEBUG
    private static let debugSimulationSubscriptionID = "debug-journey-simulation"

    var hasDebugJourneySimulation: Bool {
        armedCandidates.contains { $0.subscriptionId == Self.debugSimulationSubscriptionID }
            || activeJourney?.subscriptionId == Self.debugSimulationSubscriptionID
            || recentlyCompletedJourney?.subscriptionId == Self.debugSimulationSubscriptionID
    }

    var debugJourneySimulationCandidate: ArmedJourneyHistoryCandidate? {
        armedCandidates.first { $0.subscriptionId == Self.debugSimulationSubscriptionID }
    }

    var hasNonDebugJourneyTracking: Bool {
        armedCandidates.contains { $0.subscriptionId != Self.debugSimulationSubscriptionID }
            || (activeJourney != nil && activeJourney?.subscriptionId != Self.debugSimulationSubscriptionID)
            || (recentlyCompletedJourney != nil && recentlyCompletedJourney?.subscriptionId != Self.debugSimulationSubscriptionID)
    }

    func setDebugJourneySimulationPhase(
        _ phase: JourneyActivityAttributes.JourneyPhase,
        group: JourneyGroup,
        departure: DepartureV2?,
        arrivalDelayMinutes: Int = 0
    ) {
        stopDebugJourneySimulation()

        let now = Date()
        switch phase {
        case .pendingStart, .atStart:
            armedCandidates.append(ArmedJourneyHistoryCandidate(
                subscriptionId: Self.debugSimulationSubscriptionID,
                source: .adhoc,
                stations: group.stationSequence,
                createdAt: now,
                activeUntil: now.addingTimeInterval(2 * 60 * 60),
                originArrivedAt: phase == .atStart ? now : nil,
                candidateDepartures: departure.map { [$0] } ?? []
            ))
        case .enRoute:
            activeJourney = debugSimulationCheckpoint(
                group: group,
                departure: departure,
                arrived: false,
                arrivalDelayMinutes: arrivalDelayMinutes,
                now: now
            )
        case .arrived:
            let checkpoint = debugSimulationCheckpoint(
                group: group,
                departure: departure,
                arrived: true,
                arrivalDelayMinutes: arrivalDelayMinutes,
                now: now
            )
            recentlyCompletedJourney = checkpoint
            recentlyCompleted = RecentlyCompletedJourneyCheckpoint(
                checkpoint: checkpoint,
                outcome: .completed,
                completedAt: now,
                autoDismissAt: now.addingTimeInterval(Self.completedJourneyDisplayDuration)
            )
        }
    }

    func stopDebugJourneySimulation() {
        armedCandidates.removeAll { $0.subscriptionId == Self.debugSimulationSubscriptionID }
        if activeJourney?.subscriptionId == Self.debugSimulationSubscriptionID {
            activeJourney = nil
        }
        if recentlyCompletedJourney?.subscriptionId == Self.debugSimulationSubscriptionID {
            recentlyCompletedJourney = nil
            recentlyCompleted = nil
        }
    }

    private func debugSimulationCheckpoint(
        group: JourneyGroup,
        departure: DepartureV2?,
        arrived: Bool,
        arrivalDelayMinutes: Int,
        now: Date
    ) -> ActiveJourneyHistoryCheckpoint {
        let simulatedJourney = arrived ? group.legs.last : group.legs.first
        let origin = simulatedJourney?.fromStation ?? group.startStation
        let destination = simulatedJourney?.toStation ?? group.endStation
        let scheduledDeparture = departure.flatMap {
            JourneyHistoryTime.date(for: $0.departureTime.scheduled, near: now)
        }
        let scheduledArrival = arrived
            ? now.addingTimeInterval(-Double(arrivalDelayMinutes) * 60)
            : nil
        let leg = JourneyHistoryLeg(
            plannedLegIndex: simulatedJourney?.legIndex ?? 0,
            fromStation: origin,
            toStation: destination,
            serviceID: arrived && group.legs.count > 1 ? nil : departure?.serviceID,
            detectedDepartureAt: now,
            detectedArrivalAt: arrived ? now : nil,
            scheduledDepartureAt: scheduledDeparture,
            estimatedDepartureTime: departure?.departureTime.estimated,
            actualDepartureAt: now,
            scheduledArrivalAt: scheduledArrival,
            actualArrivalAt: arrived ? now : nil,
            outcome: arrived ? .completed : .active
        )

        return ActiveJourneyHistoryCheckpoint(
            id: UUID(),
            subscriptionId: Self.debugSimulationSubscriptionID,
            source: .adhoc,
            plannedStations: group.stationSequence,
            createdAt: now,
            phase: arrived ? .arriving : .inTransit,
            plannedLegIndex: simulatedJourney?.legIndex ?? 0,
            originArrivedAt: now.addingTimeInterval(-60),
            detectedDepartureAt: now,
            detectedArrivalAt: arrived ? now : nil,
            lastConfirmedOnRouteStation: arrived ? group.endStation : group.startStation,
            nextExpectedCallingPointIndex: arrived ? group.stationSequence.count : 1,
            legs: [leg],
            stationEvents: [
                JourneyHistoryStationEvent(station: origin, kind: .arrival, detectedAt: now.addingTimeInterval(-60)),
                JourneyHistoryStationEvent(station: origin, kind: .departure, detectedAt: now)
            ] + (arrived ? [JourneyHistoryStationEvent(station: destination, kind: .arrival, detectedAt: now)] : []),
            approachNotificationSent: arrived,
            backendSessionID: nil,
            serviceMatchConfidence: departure == nil ? 0 : 1,
            unexpectedStation: nil,
            unexpectedStationObservedAt: nil,
            serviceDepartedStationCRS: group.startStation.crs,
            serviceDepartedStationAt: now,
            updatedAt: now
        )
    }
    #endif

    func endActiveJourney() async {
        guard activeJourney != nil else { return }
        await finishJourney(outcome: .endedEarly, completedAt: Date())
    }

    func manuallyConfirmOriginArrival(subscriptionID: String) async {
        await handleOriginArrival(subscriptionID: subscriptionID)
    }

    func manuallyBoard(subscriptionID: String, departure: DepartureV2) async {
        if armedCandidates.first(where: { $0.subscriptionId == subscriptionID })?.originArrivedAt == nil {
            await handleOriginArrival(subscriptionID: subscriptionID)
        }
        guard let candidate = armedCandidates.first(where: { $0.subscriptionId == subscriptionID }),
              candidate.stations.count >= 2 else { return }
        await handleOriginDeparture(
            subscriptionID: subscriptionID,
            from: candidate.stations[0].crs,
            to: candidate.stations[1].crs,
            preferredDeparture: departure
        )
    }

    func manuallyBoardWithoutMatchedService(subscriptionID: String) async {
        if armedCandidates.first(where: { $0.subscriptionId == subscriptionID })?.originArrivedAt == nil {
            await handleOriginArrival(subscriptionID: subscriptionID)
        }
        guard let candidate = armedCandidates.first(where: { $0.subscriptionId == subscriptionID }),
              candidate.stations.count >= 2 else { return }
        await handleOriginDeparture(
            subscriptionID: subscriptionID,
            from: candidate.stations[0].crs,
            to: candidate.stations[1].crs,
            forceUnmatchedService: true
        )
    }

    func manuallyConfirmNextLegEndpoint() async {
        guard let active = activeJourney else { return }
        let station = active.currentPlannedLegDestination
        if active.plannedLegIndex == active.plannedStations.count - 2 {
            await completeJourney(at: station, detectedAt: Date(), isDeviceBased: false)
        } else {
            await handleExpectedStationArrival(station, detectedAt: Date())
        }
    }

    func manuallyBoardNextLeg(departure: DepartureV2) async {
        guard let active = activeJourney, active.phase == .atInterchange else { return }
        await startNextPlannedLeg(
            from: active.currentPlannedLegDestination,
            detectedAt: Date(),
            preferredDeparture: departure
        )
        if let updated = activeJourney {
            await LiveActivityManager.shared.updateJourneyPhase(
                .enRoute,
                startStation: updated.plannedOrigin,
                destinationStation: updated.plannedDestination,
                checkpoint: updated
            )
        }
    }

    func manuallyBoardNextLegWithoutMatchedService() async {
        guard let active = activeJourney, active.phase == .atInterchange else { return }
        await startNextPlannedLeg(
            from: active.currentPlannedLegDestination,
            detectedAt: Date(),
            forceUnmatchedService: true
        )
        if let updated = activeJourney {
            await LiveActivityManager.shared.updateJourneyPhase(
                .enRoute,
                startStation: updated.plannedOrigin,
                destinationStation: updated.plannedDestination,
                checkpoint: updated
            )
        }
    }

    func manuallyReplaceCurrentService(with departure: DepartureV2) async {
        guard var active = activeJourney, let index = active.legs.indices.last else { return }
        let previousBackendSessionID = active.backendSessionID
        active.backendSessionID = nil
        active.legs[index].serviceID = departure.serviceID
        active.legs[index].operatorName = nil
        active.legs[index].operatorCode = nil
        active.legs[index].callingPoints = []
        active.legs[index].serviceCallingPoints = nil
        active.legs[index].scheduledDepartureAt = JourneyHistoryTime.date(
            for: departure.departureTime.scheduled,
            near: active.detectedDepartureAt
        )
        active.legs[index].estimatedDepartureTime = departure.departureTime.estimated
        active.legs[index].actualDepartureAt = nil
        active.legs[index].outcome = .active
        active.serviceMatchConfidence = 1
        active.updatedAt = Date()
        activeJourney = active

        let context = ServiceDetailsLookupContext(
            fromCRS: active.legs[index].fromStation.crs,
            toCRS: active.legs[index].toStation.crs,
            originCRS: departure.origin?.first?.crs,
            operator: nil,
            destinationCRSs: departure.destination.compactMap(\.crs),
            length: departure.length
        )
        _ = await DeparturesStore.shared.ensureServiceDetails(
            for: [departure.serviceID],
            force: true,
            context: context
        )
        if let details = DeparturesStore.shared.serviceDetailsById[departure.serviceID],
           var updated = activeJourney {
            populate(&updated.legs[index], from: details, reference: updated.detectedDepartureAt)
            activeJourney = updated
            active = updated
        }
        persistCheckpoint()

        if let previousBackendSessionID {
            await JourneyTrackingService.shared.stop(sessionID: previousBackendSessionID)
        }
        do {
            if let sessionID = try await JourneyTrackingService.shared.register(checkpoint: active),
               var updated = activeJourney {
                updated.backendSessionID = sessionID
                activeJourney = updated
                persistCheckpoint()
            }
        } catch {
            log("manual_service_registration_failed", "Manual service correction could not register backend tracking", metadata: [
                "journey_id": active.id.uuidString,
                "service_id": departure.serviceID,
                "error": error.localizedDescription
            ])
        }
        if let updated = activeJourney {
            await LiveActivityManager.shared.updateJourneyPhase(
                .enRoute,
                startStation: updated.plannedOrigin,
                destinationStation: updated.plannedDestination,
                checkpoint: updated
            )
        }
        await refreshMonitoringConditions()
    }

    func manuallyUseUnlistedService() async {
        guard var active = activeJourney, let index = active.legs.indices.last else { return }
        let previousBackendSessionID = active.backendSessionID
        active.backendSessionID = nil
        active.legs[index].serviceID = nil
        active.legs[index].operatorName = nil
        active.legs[index].operatorCode = nil
        active.legs[index].callingPoints = []
        active.legs[index].serviceCallingPoints = nil
        active.legs[index].scheduledDepartureAt = nil
        active.legs[index].estimatedDepartureTime = nil
        active.legs[index].actualDepartureAt = nil
        active.legs[index].scheduledArrivalAt = nil
        active.legs[index].actualArrivalAt = nil
        active.legs[index].outcome = .uncertain
        active.serviceMatchConfidence = 0
        active.updatedAt = Date()
        activeJourney = active
        persistCheckpoint()

        if let previousBackendSessionID {
            await JourneyTrackingService.shared.stop(sessionID: previousBackendSessionID)
        }
        await LiveActivityManager.shared.updateJourneyPhase(
            .enRoute,
            startStation: active.plannedOrigin,
            destinationStation: active.plannedDestination,
            checkpoint: active
        )
        await refreshMonitoringConditions()
    }

    func clearRecentlyCompletedJourney() {
        recentlyCompletedJourney = nil
        recentlyCompleted = nil
        persistCheckpoint()
    }

    func pruneExpiredCompletion(now: Date = Date()) {
        guard let recentlyCompleted, recentlyCompleted.autoDismissAt <= now else { return }
        self.recentlyCompleted = nil
        recentlyCompletedJourney = nil
        persistCheckpoint()
    }

    func boardingNotificationBody(from: String, to: String) -> String? {
        guard let leg = activeJourney?.currentLeg,
              leg.fromStation.crs.caseInsensitiveCompare(from) == .orderedSame,
              leg.toStation.crs.caseInsensitiveCompare(to) == .orderedSame,
              let scheduledDeparture = leg.scheduledDepartureAt else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return JourneyHistoryNotificationText.boarding(
            scheduledDeparture: formatter.string(from: scheduledDeparture),
            estimatedDeparture: leg.estimatedDepartureTime,
            destinationName: leg.toStation.name
        )
    }

    func logDiagnosticSnapshot(reason: String) async {
        let geofence = NotificationGeofenceManager.shared.debugSnapshot
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        let active = activeJourney
        let conditions = locationConditions()
        let message = [
            "Journey diagnostic snapshot (\(reason))",
            "Armed candidates: \(armedCandidates.count)",
            "Active journey: \(active?.id.uuidString ?? "none")",
            "Phase: \(active?.phase.rawValue ?? "none")",
            "Route: \(active.map { "\($0.plannedOrigin.crs)→\($0.plannedDestination.crs)" } ?? "none")",
            "Service: \(active?.currentLeg?.serviceID ?? "none")",
            "Backend session: \(active?.backendSessionID ?? "none")",
            "Last confirmed station: \(active?.lastConfirmedOnRouteStation.crs ?? "none")",
            "History conditions: \(conditions.map(\.identifier).joined(separator: ", "))",
            "Location authorization: \(geofence.authorizationStatus)",
            "Notification authorization: \(notificationAuthorizationDescription(notificationSettings.authorizationStatus))",
            "Tracking mode: \(geofence.trackingMode)"
        ].joined(separator: "\n")
        log("diagnostic_snapshot", message, metadata: [
            "reason": reason,
            "armed_candidate_count": armedCandidates.count,
            "active_journey_id": active?.id.uuidString,
            "phase": active?.phase.rawValue,
            "planned_route": active.map { "\($0.plannedOrigin.crs)-\($0.plannedDestination.crs)" },
            "planned_leg_index": active?.plannedLegIndex,
            "service_id": active?.currentLeg?.serviceID,
            "backend_session_id": active?.backendSessionID,
            "last_confirmed_station_crs": active?.lastConfirmedOnRouteStation.crs,
            "history_condition_ids": conditions.map(\.identifier),
            "monitored_condition_ids": geofence.monitoredRegionIdentifiers,
            "location_authorization": geofence.authorizationStatus,
            "notification_authorization": notificationAuthorizationDescription(notificationSettings.authorizationStatus),
            "tracking_mode": geofence.trackingMode,
            "notification_push_token_present": !(NotificationPushTokenStore.token ?? "").isEmpty
        ])
    }

    func arm(
        subscription: NotificationSubscription,
        source: JourneyHistorySource,
        cachedStationsByCRS: [String: Station] = [:]
    ) async {
        pruneExpiredCompletion()
        if StationsService.shared.stations.isEmpty && cachedStationsByCRS.isEmpty {
            do {
                try await StationsService.shared.loadStations()
            } catch {
                log("candidate_station_load_failed", "Station catalogue load failed while arming journey history: \(error.localizedDescription)", metadata: [
                    "subscription_id": subscription.id,
                    "error": error.localizedDescription
                ])
            }
        }
        let enabledLegs = subscription.legs.filter(\.enabled)
        guard let first = enabledLegs.first else {
            log("candidate_arm_skipped", "Journey history was not armed because the subscription has no enabled legs", metadata: [
                "subscription_id": subscription.id,
                "source": source.rawValue
            ])
            return
        }

        var stations = [station(
            crs: first.from,
            fallbackName: first.fromName,
            cachedStationsByCRS: cachedStationsByCRS
        )]
        stations.append(contentsOf: enabledLegs.map {
            station(crs: $0.to, fallbackName: $0.toName, cachedStationsByCRS: cachedStationsByCRS)
        })
        guard stations.count >= 2, stations.allSatisfy(\.hasUsableCoordinate) else {
            log("candidate_arm_skipped", "Journey history was not armed because fewer than two stations were resolved", metadata: [
                "subscription_id": subscription.id,
                "source": source.rawValue
            ])
            return
        }

        let stationCodes = stations.map { $0.crs.uppercased() }
        if let completed = recentlyCompleted?.checkpoint,
           completed.subscriptionId == subscription.id,
           completed.plannedStations.map({ $0.crs.uppercased() }) == stationCodes {
            return
        }

        let previousCandidate = armedCandidates.first {
            $0.subscriptionId == subscription.id
                && $0.stations.map { $0.crs.uppercased() } == stationCodes
        }

        let candidate = ArmedJourneyHistoryCandidate(
            subscriptionId: subscription.id,
            source: source,
            stations: stations,
            createdAt: subscription.createdAt ?? Date(),
            activeUntil: subscription.activeUntil,
            originArrivedAt: previousCandidate?.originArrivedAt,
            candidateDepartures: previousCandidate?.candidateDepartures ?? []
        )
        armedCandidates.removeAll { $0.subscriptionId == subscription.id }
        armedCandidates.append(candidate)
        armedCandidates = Array(armedCandidates.filter(\.isCurrent).suffix(5))
        recentlyCompletedJourney = nil
        recentlyCompleted = nil
        persistCheckpoint()
        log("candidate_armed", "Armed \(source.displayName.lowercased()) journey history for \(stations.map(\.crs).joined(separator: "→"))", metadata: [
            "subscription_id": subscription.id,
            "source": source.rawValue,
            "station_crs": stations.map(\.crs),
            "active_until": subscription.activeUntil,
            "armed_candidate_count": armedCandidates.count
        ])
        if let startStation = candidate.stations.first,
           let destinationStation = candidate.stations.last {
            await LiveActivityManager.shared.updateJourneyPhase(
                .pendingStart,
                startStation: startStation,
                destinationStation: destinationStation
            )
        }
    }

    func disarm(subscriptionID: String) {
        let previousCount = armedCandidates.count
        armedCandidates.removeAll { $0.subscriptionId == subscriptionID }
        persistCheckpoint()
        log("candidate_disarmed", "Disarmed journey history candidate \(subscriptionID)", metadata: [
            "subscription_id": subscriptionID,
            "removed": armedCandidates.count < previousCount,
            "armed_candidate_count": armedCandidates.count
        ])
    }

    func handleOriginArrival(subscriptionID: String, detectedAt: Date = Date()) async {
        guard let index = armedCandidates.firstIndex(where: { $0.subscriptionId == subscriptionID }) else {
            log("origin_arrival_ignored", "Origin arrival could not arm history because candidate \(subscriptionID) was not found", metadata: [
                "subscription_id": subscriptionID,
                "armed_candidate_count": armedCandidates.count
            ])
            return
        }
        if armedCandidates[index].originArrivedAt != nil {
            return
        }
        armedCandidates[index].originArrivedAt = detectedAt
        persistCheckpoint()
        let first = armedCandidates[index].stations[0]
        let second = armedCandidates[index].stations[1]
        log("origin_arrival_detected", "Detected arrival at \(first.crs); capturing departures towards \(second.crs)", metadata: [
            "subscription_id": subscriptionID,
            "from": first.crs,
            "to": second.crs,
            "detected_at": detectedAt
        ])
        do {
            let snapshot = try await NetworkServicePhone.shared.fetchDeparturesAggregated(
                pairs: [(from: first.crs, to: second.crs)],
                delayBeforeEachBatch: false
            )
            let departures = snapshot[pairKey(from: first.crs, to: second.crs)]?.departures ?? []
            if let currentIndex = armedCandidates.firstIndex(where: { $0.subscriptionId == subscriptionID }) {
                armedCandidates[currentIndex].candidateDepartures = departures
            }
            log("origin_departures_captured", "Captured \(departures.count) departure candidate(s) for \(first.crs)→\(second.crs)", metadata: [
                "subscription_id": subscriptionID,
                "candidate_count": departures.count,
                "candidates": departureDiagnosticSummary(departures)
            ])
        } catch {
            log("origin_departures_failed", "Departure snapshot failed for \(first.crs)→\(second.crs): \(error.localizedDescription)", metadata: [
                "subscription_id": subscriptionID,
                "from": first.crs,
                "to": second.crs,
                "error": error.localizedDescription
            ])
        }
        let destination = armedCandidates.first { $0.subscriptionId == subscriptionID }?.stations.last ?? second
        await LiveActivityManager.shared.updateJourneyPhase(
            .atStart,
            startStation: first,
            destinationStation: destination
        )
        LiveActivityJourneyStatusSender.shared.send(
            phase: .atStart,
            from: first.crs,
            to: destination.crs
        )
    }

    func handleOriginDeparture(
        subscriptionID: String,
        from: String,
        to: String,
        detectedAt: Date = Date(),
        preferredDeparture: DepartureV2? = nil,
        forceUnmatchedService: Bool = false
    ) async {
        guard activeJourney == nil else {
            log("origin_departure_ignored", "Ignored \(from)→\(to) departure because another journey is already active", metadata: [
                "subscription_id": subscriptionID,
                "active_journey_id": activeJourney?.id.uuidString,
                "active_subscription_id": activeJourney?.subscriptionId
            ])
            return
        }
        guard let candidate = armedCandidates.first(where: { $0.subscriptionId == subscriptionID }) else {
            log("origin_departure_ignored", "Ignored \(from)→\(to) departure because its history candidate was not found", metadata: [
                "subscription_id": subscriptionID,
                "armed_candidate_count": armedCandidates.count
            ])
            return
        }
        guard candidate.stations.first?.crs.caseInsensitiveCompare(from) == .orderedSame else {
            log("origin_departure_ignored", "Ignored departure because detected origin \(from) did not match planned origin \(candidate.stations.first?.crs ?? "unknown")", metadata: [
                "subscription_id": subscriptionID,
                "detected_from": from,
                "planned_from": candidate.stations.first?.crs
            ])
            return
        }

        let origin = candidate.stations[0]
        activeJourney = ActiveJourneyHistoryCheckpoint(
            id: UUID(),
            subscriptionId: candidate.subscriptionId,
            source: candidate.source,
            plannedStations: candidate.stations,
            createdAt: candidate.createdAt,
            phase: .matchingService,
            plannedLegIndex: 0,
            originArrivedAt: candidate.originArrivedAt,
            detectedDepartureAt: detectedAt,
            detectedArrivalAt: nil,
            lastConfirmedOnRouteStation: origin,
            nextExpectedCallingPointIndex: 1,
            legs: [],
            stationEvents: [JourneyHistoryStationEvent(station: origin, kind: .departure, detectedAt: detectedAt)],
            approachNotificationSent: false,
            backendSessionID: nil,
            serviceMatchConfidence: 0,
            unexpectedStation: nil,
            unexpectedStationObservedAt: nil,
            serviceDepartedStationCRS: nil,
            serviceDepartedStationAt: nil,
            updatedAt: detectedAt
        )
        armedCandidates.removeAll()
        persistCheckpoint()
        log("journey_started", "Started journey history \(activeJourney?.id.uuidString ?? "unknown") for \(candidate.stations.map(\.crs).joined(separator: "→"))", metadata: [
            "journey_id": activeJourney?.id.uuidString,
            "subscription_id": subscriptionID,
            "source": candidate.source.rawValue,
            "detected_at": detectedAt,
            "planned_station_crs": candidate.stations.map(\.crs),
            "cached_departure_count": candidate.candidateDepartures.count
        ])

        // Install the minimum durable destination/interchange conditions before
        // service matching performs any optional network work.
        await refreshMonitoringConditions()

        await matchCurrentLeg(
            cachedDepartures: candidate.candidateDepartures,
            detectedAt: detectedAt,
            reboundFromServiceID: nil,
            preferredDeparture: preferredDeparture,
            forceUnmatchedService: forceUnmatchedService
        )
        if let activeJourney {
            await LiveActivityManager.shared.updateJourneyPhase(
                .enRoute,
                startStation: activeJourney.plannedOrigin,
                destinationStation: activeJourney.plannedDestination,
                checkpoint: activeJourney
            )
            LiveActivityJourneyStatusSender.shared.send(
                phase: .enRoute,
                from: activeJourney.plannedOrigin.crs,
                to: activeJourney.plannedDestination.crs
            )
        }
        await refreshMonitoringConditions()
    }

    func locationConditions() -> [JourneyHistoryLocationCondition] {
        guard let active = activeJourney else { return [] }
        let destination = active.plannedDestination
        var conditions = [
            JourneyHistoryLocationCondition(
                identifier: historyIdentifier(kind: .arrival, journeyID: active.id, stationCRS: destination.crs),
                kind: .arrival,
                journeyID: active.id,
                station: destination,
                radius: Self.destinationArrivalRadiusMeters
            )
        ]

        let routeStations = resolvedCurrentRouteStations(active)
        let nextStations: ArraySlice<Station>
        if active.phase == .atInterchange {
            nextStations = [active.currentPlannedLegDestination][...]
        } else {
            nextStations = routeStations
                .dropFirst(min(active.nextExpectedCallingPointIndex, routeStations.count))
                .prefix(2)
        }
        for station in nextStations where station.crs.caseInsensitiveCompare(destination.crs) != .orderedSame {
            guard station.hasUsableCoordinate else { continue }
            conditions.append(JourneyHistoryLocationCondition(
                identifier: historyIdentifier(kind: .station, journeyID: active.id, stationCRS: station.crs),
                kind: .station,
                journeyID: active.id,
                station: station,
                radius: Self.expectedStationRadiusMeters
            ))
        }
        return conditions.filter { $0.station.hasUsableCoordinate }
    }

    func handleConditionEntry(identifier: String, detectedAt: Date = Date()) async -> Bool {
        guard let parsed = parseHistoryIdentifier(identifier),
              let active = activeJourney,
              active.id == parsed.journeyID else {
            return false
        }
        let station = station(crs: parsed.stationCRS, fallbackName: nil)
        log("condition_entered", "Journey condition entered: \(parsed.kind.rawValue) at \(station.crs)", metadata: [
            "journey_id": active.id.uuidString,
            "condition_id": identifier,
            "condition_kind": parsed.kind.rawValue,
            "station_crs": station.crs,
            "detected_at": detectedAt,
            "phase": active.phase.rawValue
        ])
        switch parsed.kind {
        case .approach:
            // Kept for checkpoint and already-monitored-region compatibility. Approach
            // notifications were replaced by a buffered, confirmed-arrival message.
            return true
        case .arrival:
            guard active.plannedLegIndex == active.plannedStations.count - 2 else { return true }
            await completeJourney(at: station, detectedAt: detectedAt, isDeviceBased: false)
        case .station:
            await handleExpectedStationArrival(station, detectedAt: detectedAt)
        }
        return true
    }

    func handleConditionExit(identifier: String, detectedAt: Date = Date()) async -> Bool {
        guard let parsed = parseHistoryIdentifier(identifier),
              parsed.kind == .station,
              let active = activeJourney,
              active.id == parsed.journeyID else {
            return false
        }
        let station = station(crs: parsed.stationCRS, fallbackName: nil)
        log("condition_exited", "Journey station condition exited at \(station.crs)", metadata: [
            "journey_id": active.id.uuidString,
            "condition_id": identifier,
            "station_crs": station.crs,
            "detected_at": detectedAt,
            "phase": active.phase.rawValue
        ])
        guard active.phase == .atInterchange,
              station.crs.caseInsensitiveCompare(active.currentPlannedLegDestination.crs) == .orderedSame else {
            return true
        }
        await startNextPlannedLeg(from: station, detectedAt: detectedAt)
        return true
    }

    func evaluateLocation(_ location: CLLocation, detectedAt: Date = Date()) async {
        guard var active = activeJourney,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= RailwayOnboardLocationResolver.maximumHorizontalAccuracy else { return }
        let locationAge = detectedAt.timeIntervalSince(location.timestamp)
        guard locationAge >= -30,
              locationAge <= RailwayOnboardLocationResolver.maximumLocationAge else { return }
        if detectedAt.timeIntervalSince(active.detectedDepartureAt) > Self.maximumActiveJourneyDuration {
            log("journey_safety_expired", "Journey monitoring exceeded its 24-hour safety limit", metadata: [
                "journey_id": active.id.uuidString,
                "detected_departure_at": active.detectedDepartureAt,
                "detected_at": detectedAt
            ])
            await finishJourney(outcome: .uncertain, completedAt: detectedAt)
            return
        }

        if active.plannedDestination.distance(from: location) <= Self.destinationArrivalRadiusMeters,
           active.plannedLegIndex == active.plannedStations.count - 2 {
            await completeJourney(
                at: active.plannedDestination,
                detectedAt: detectedAt,
                isDeviceBased: true
            )
            return
        }

        guard let nearest = StationsService.shared.stations
            .map({ ($0, $0.distance(from: location)) })
            .filter({ $0.1 <= Self.destinationArrivalRadiusMeters })
            .min(by: { $0.1 < $1.1 })?.0 else {
            if let unexpected = active.unexpectedStation {
                log("unexpected_station_cleared", "No longer near unexpected station \(unexpected.crs)", metadata: [
                    "journey_id": active.id.uuidString,
                    "station_crs": unexpected.crs,
                    "horizontal_accuracy": location.horizontalAccuracy
                ])
            }
            active.unexpectedStation = nil
            active.unexpectedStationObservedAt = nil
            activeJourney = active
            persistCheckpoint()
            return
        }

        if let departedCRS = active.serviceDepartedStationCRS,
           nearest.crs.caseInsensitiveCompare(departedCRS) == .orderedSame,
           let departedAt = active.serviceDepartedStationAt,
           detectedAt.timeIntervalSince(departedAt) >= Self.unexpectedStationDwellSeconds,
           max(location.speed, 0) < 3 {
            log("early_exit_confirmed", "Ending journey because the user remained at \(nearest.crs) after the matched service departed", metadata: [
                "journey_id": active.id.uuidString,
                "station_crs": nearest.crs,
                "service_departed_at": departedAt,
                "dwell_seconds": detectedAt.timeIntervalSince(departedAt),
                "speed_mps": max(location.speed, 0),
                "horizontal_accuracy": location.horizontalAccuracy
            ])
            await finishJourney(outcome: .endedEarly, completedAt: detectedAt)
            return
        }

        let remainingRouteCodes = Set(resolvedCurrentRouteStations(active)
            .dropFirst(min(active.nextExpectedCallingPointIndex, resolvedCurrentRouteStations(active).count))
            .map { $0.crs.uppercased() })
        if remainingRouteCodes.contains(nearest.crs.uppercased()) {
            active.unexpectedStation = nil
            active.unexpectedStationObservedAt = nil
            activeJourney = active
            await handleExpectedStationArrival(nearest, detectedAt: detectedAt)
            return
        }

        if active.unexpectedStation?.crs.caseInsensitiveCompare(nearest.crs) != .orderedSame {
            active.unexpectedStation = nearest
            active.unexpectedStationObservedAt = detectedAt
            log("unexpected_station_observed", "Observed unexpected station \(nearest.crs); waiting for dwell confirmation", metadata: [
                "journey_id": active.id.uuidString,
                "station_crs": nearest.crs,
                "detected_at": detectedAt,
                "speed_mps": max(location.speed, 0),
                "horizontal_accuracy": location.horizontalAccuracy,
                "remaining_route_crs": Array(remainingRouteCodes).sorted()
            ])
        } else if let observedAt = active.unexpectedStationObservedAt,
                  detectedAt.timeIntervalSince(observedAt) >= Self.unexpectedStationDwellSeconds,
                  max(location.speed, 0) < 3 {
            log("unexpected_station_confirmed", "Unexpected station \(nearest.crs) met dwell threshold; attempting service rebind", metadata: [
                "journey_id": active.id.uuidString,
                "station_crs": nearest.crs,
                "dwell_seconds": detectedAt.timeIntervalSince(observedAt),
                "speed_mps": max(location.speed, 0),
                "horizontal_accuracy": location.horizontalAccuracy
            ])
            activeJourney = active
            await attemptRebind(at: nearest, detectedAt: detectedAt)
            return
        }
        active.updatedAt = detectedAt
        activeJourney = active
        persistCheckpoint()
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard (userInfo["alert_type"] as? String) == "journey_tracking_update" else {
            return false
        }
        guard let journeyID = userInfo["journey_id"] as? String,
              let journeyUUID = UUID(uuidString: journeyID) else {
            log("remote_update_ignored", "Journey progress push had no valid journey identifier", metadata: remoteNotificationMetadata(userInfo))
            return false
        }

        if var active = activeJourney, active.id == journeyUUID {
            let reference = active.detectedArrivalAt ?? active.detectedDepartureAt
            if let actualArrival = userInfo["actual_arrival"] as? String,
               let index = active.legs.indices.last {
                active.legs[index].actualArrivalAt = JourneyHistoryTime.date(for: actualArrival, near: reference)
            }
            if let scheduledArrival = userInfo["scheduled_arrival"] as? String,
               let index = active.legs.indices.last {
                active.legs[index].scheduledArrivalAt = JourneyHistoryTime.date(for: scheduledArrival, near: reference)
            }
            if let operatorName = userInfo["operator"] as? String,
               let index = active.legs.indices.last {
                active.legs[index].operatorName = operatorName
            }
            if let operatorCode = userInfo["operator_code"] as? String,
               let index = active.legs.indices.last {
                active.legs[index].operatorCode = operatorCode
            }
            if let stationCRS = userInfo["station_crs"] as? String,
               (userInfo["journey_event"] as? String) == "station_departed" {
                active.serviceDepartedStationCRS = stationCRS.uppercased()
                active.serviceDepartedStationAt = Date()
            }
            active.updatedAt = Date()
            activeJourney = active
            persistCheckpoint()
            log("remote_update_applied", "Applied journey progress update \(userInfo["journey_event"] as? String ?? "unknown") at \(userInfo["station_crs"] as? String ?? "unknown station")", metadata: remoteNotificationMetadata(userInfo).merging([
                "active_phase": active.phase.rawValue
            ]) { _, new in new })
            return true
        }

        guard let record = JourneyHistoryStore.shared.records.first(where: { $0.id == journeyUUID }) else {
            var metadata = remoteNotificationMetadata(userInfo)
            metadata["active_journey_id"] = activeJourney?.id.uuidString
            log("remote_update_ignored", "Journey progress push matched neither an active journey nor stored history", metadata: metadata)
            return false
        }
        let reference = record.detectedArrivalAt ?? record.completedAt
        let scheduledArrival = (userInfo["scheduled_arrival"] as? String).flatMap {
            JourneyHistoryTime.date(for: $0, near: reference)
        }
        let actualArrival = (userInfo["actual_arrival"] as? String).flatMap {
            JourneyHistoryTime.date(for: $0, near: reference)
        }
        guard let updated = JourneyHistoryStore.shared.applyOfficialArrival(
            journeyID: journeyUUID,
            scheduledArrival: scheduledArrival,
            actualArrival: actualArrival,
            operatorName: userInfo["operator"] as? String,
            operatorCode: userInfo["operator_code"] as? String
        ) else {
            return false
        }
        log("completed_journey_remote_update_applied", "Applied official timing update to completed journey \(journeyUUID.uuidString)", metadata: remoteNotificationMetadata(userInfo).merging([
            "delay_minutes": updated.delayMinutes,
            "delay_repay_eligible": updated.isDelayRepay15Plus
        ]) { _, new in new })
        if actualArrival != nil, updated.isDelayRepay15Plus {
            await postDelayRepayNotification(for: updated)
        }
        return true
    }

    func restoreAfterLaunch() async {
        let expiredCandidateCount = armedCandidates.filter { !$0.isCurrent }.count
        armedCandidates.removeAll { !$0.isCurrent }
        if let active = activeJourney,
           Date().timeIntervalSince(active.detectedDepartureAt) > Self.maximumActiveJourneyDuration {
            log("journey_restore_expired", "Restored journey exceeded the 24-hour safety limit", metadata: [
                "journey_id": active.id.uuidString,
                "detected_departure_at": active.detectedDepartureAt
            ])
            await finishJourney(outcome: .uncertain, completedAt: Date())
            return
        }
        persistCheckpoint()
        log("checkpoint_restored", "Restored \(armedCandidates.count) journey candidate(s); active journey \(activeJourney?.id.uuidString ?? "none")", metadata: [
            "armed_candidate_count": armedCandidates.count,
            "expired_candidate_count": expiredCandidateCount,
            "active_journey_id": activeJourney?.id.uuidString,
            "phase": activeJourney?.phase.rawValue,
            "service_id": activeJourney?.currentLeg?.serviceID,
            "backend_session_id": activeJourney?.backendSessionID
        ])
        if activeJourney != nil {
            await refreshMonitoringConditions()
        }
    }

    private func matchCurrentLeg(
        cachedDepartures: [DepartureV2],
        detectedAt: Date,
        reboundFromServiceID: String?,
        fromOverride: Station? = nil,
        preferredDeparture: DepartureV2? = nil,
        forceUnmatchedService: Bool = false
    ) async {
        guard var active = activeJourney else { return }
        let from = fromOverride ?? active.plannedStations[active.plannedLegIndex]
        let to = active.currentPlannedLegDestination
        let previousBackendSessionID = active.backendSessionID
        active.backendSessionID = nil
        var departures = forceUnmatchedService ? [] : cachedDepartures
        var departureSource = forceUnmatchedService
            ? "manual_unlisted"
            : (departures.isEmpty ? "network" : "origin_cache")
        if departures.isEmpty && !forceUnmatchedService {
            do {
                let snapshots = try await NetworkServicePhone.shared.fetchDeparturesAggregated(
                    pairs: [(from: from.crs, to: to.crs)],
                    delayBeforeEachBatch: false
                )
                departures = snapshots[pairKey(from: from.crs, to: to.crs)]?.departures ?? []
            } catch {
                departureSource = "network_failed"
                log("service_candidates_failed", "Could not refresh service candidates for \(from.crs)→\(to.crs): \(error.localizedDescription)", metadata: [
                    "journey_id": active.id.uuidString,
                    "from": from.crs,
                    "to": to.crs,
                    "error": error.localizedDescription
                ])
            }
        }

        log("service_candidates_evaluated", "Evaluating \(departures.count) service candidate(s) for \(from.crs)→\(to.crs)", metadata: [
            "journey_id": active.id.uuidString,
            "planned_leg_index": active.plannedLegIndex,
            "from": from.crs,
            "to": to.crs,
            "source": departureSource,
            "candidate_count": departures.count,
            "candidates": departureDiagnosticSummary(departures)
        ])

        let preferredServiceID = LiveActivityManager.shared.preferredServiceID(fromCRS: from.crs, toCRS: to.crs)
        let viable = departures.filter { !$0.isCancelled }
        let selected: DepartureV2?
        let confidence: Double
        if forceUnmatchedService {
            selected = nil
            confidence = 0
        } else if let preferredDeparture,
           !preferredDeparture.isCancelled {
            selected = preferredDeparture
            confidence = 1
        } else if let preferredServiceID,
           let preferred = viable.first(where: { $0.serviceID == preferredServiceID }) {
            selected = preferred
            confidence = 0.98
        } else {
            selected = viable.min { left, right in
                serviceTimeDifference(left, detectedAt: detectedAt) < serviceTimeDifference(right, detectedAt: detectedAt)
            }
            let difference = selected.map { serviceTimeDifference($0, detectedAt: detectedAt) } ?? Int.max
            switch difference {
            case 0...2: confidence = 0.9
            case 3...5: confidence = 0.75
            case 6...10: confidence = 0.55
            default: confidence = selected == nil ? 0 : 0.35
            }
        }
        let selectedDifference = selected.map { serviceTimeDifference($0, detectedAt: detectedAt) }
        log("service_match_resolved", selected.map {
            "Matched service \($0.serviceID) for \(from.crs)→\(to.crs) with confidence \(String(format: "%.2f", confidence))"
        } ?? "No viable service match found for \(from.crs)→\(to.crs)", metadata: [
            "journey_id": active.id.uuidString,
            "planned_leg_index": active.plannedLegIndex,
            "from": from.crs,
            "to": to.crs,
            "preferred_service_id": preferredServiceID,
            "selected_service_id": selected?.serviceID,
            "selected_scheduled_departure": selected?.departureTime.scheduled,
            "selected_display_departure": selected.map(JourneyItineraryBuilder.departureDisplayTime),
            "time_difference_minutes": selectedDifference,
            "confidence": confidence,
            "rebound_from_service_id": reboundFromServiceID
        ])

        var leg = JourneyHistoryLeg(
            plannedLegIndex: active.plannedLegIndex,
            fromStation: from,
            toStation: to,
            serviceID: selected?.serviceID,
            detectedDepartureAt: detectedAt,
            scheduledDepartureAt: selected.flatMap { JourneyHistoryTime.date(for: $0.departureTime.scheduled, near: detectedAt) },
            estimatedDepartureTime: selected?.departureTime.estimated,
            outcome: selected == nil ? .uncertain : .active,
            reboundFromServiceID: reboundFromServiceID
        )

        if let selected {
            let context = ServiceDetailsLookupContext(
                fromCRS: from.crs,
                toCRS: to.crs,
                originCRS: selected.origin?.first?.crs,
                operator: nil,
                destinationCRSs: selected.destination.compactMap(\.crs),
                length: selected.length
            )
            _ = await DeparturesStore.shared.ensureServiceDetails(
                for: [selected.serviceID],
                force: true,
                context: context
            )
            if let details = DeparturesStore.shared.serviceDetailsById[selected.serviceID] {
                populate(&leg, from: details, reference: detectedAt)
                log("service_details_loaded", "Loaded service details for \(selected.serviceID): \(leg.callingPoints.count) calling point(s), operator \(leg.operatorName ?? "unknown")", metadata: [
                    "journey_id": active.id.uuidString,
                    "service_id": selected.serviceID,
                    "operator": leg.operatorName,
                    "operator_code": leg.operatorCode,
                    "calling_point_count": leg.callingPoints.count,
                    "calling_point_crs": leg.callingPoints.map(\.crs),
                    "scheduled_arrival": leg.scheduledArrivalAt,
                    "actual_arrival": leg.actualArrivalAt
                ])
            } else {
                log("service_details_unavailable", "Service details unavailable for matched service \(selected.serviceID)", metadata: [
                    "journey_id": active.id.uuidString,
                    "service_id": selected.serviceID
                ])
            }
        }

        if reboundFromServiceID != nil, let lastIndex = active.legs.indices.last {
            active.legs[lastIndex].outcome = .rebound
        }
        active.legs.append(leg)
        active.phase = .inTransit
        active.nextExpectedCallingPointIndex = 1
        active.serviceMatchConfidence = active.legs.count == 1
            ? confidence
            : min(active.serviceMatchConfidence, confidence)
        active.updatedAt = Date()
        activeJourney = active
        persistCheckpoint()

        if let previousBackendSessionID {
            await JourneyTrackingService.shared.stop(sessionID: previousBackendSessionID)
        }
        do {
            if let sessionID = try await JourneyTrackingService.shared.register(checkpoint: active),
               var updated = activeJourney {
                updated.backendSessionID = sessionID
                activeJourney = updated
                persistCheckpoint()
            }
        } catch {
            log("backend_registration_failed", "Journey will continue with on-device monitoring after backend registration failed: \(error.localizedDescription)", metadata: [
                "journey_id": active.id.uuidString,
                "service_id": active.currentLeg?.serviceID,
                "error": error.localizedDescription
            ])
        }
    }

    private func handleExpectedStationArrival(_ station: Station, detectedAt: Date) async {
        guard var active = activeJourney else { return }
        let route = resolvedCurrentRouteStations(active)
        guard let routeIndex = route.firstIndex(where: {
            $0.crs.caseInsensitiveCompare(station.crs) == .orderedSame
        }), routeIndex >= active.nextExpectedCallingPointIndex else { return }

        active.lastConfirmedOnRouteStation = station
        active.nextExpectedCallingPointIndex = min(routeIndex + 1, route.count)
        if active.stationEvents.last?.station.crs.caseInsensitiveCompare(station.crs) != .orderedSame
            || active.stationEvents.last?.kind != .arrival {
            active.stationEvents.append(JourneyHistoryStationEvent(station: station, kind: .arrival, detectedAt: detectedAt))
        }
        if station.crs.caseInsensitiveCompare(active.currentPlannedLegDestination.crs) == .orderedSame,
           active.plannedLegIndex < active.plannedStations.count - 2 {
            if let index = active.legs.indices.last {
                active.legs[index].detectedArrivalAt = detectedAt
                active.legs[index].outcome = .completed
            }
            active.phase = .atInterchange
        }
        active.updatedAt = detectedAt
        activeJourney = active
        persistCheckpoint()
        log("station_arrival_confirmed", "Confirmed journey arrival at \(station.crs)", metadata: [
            "journey_id": active.id.uuidString,
            "station_crs": station.crs,
            "route_index": routeIndex,
            "next_expected_calling_point_index": active.nextExpectedCallingPointIndex,
            "phase": active.phase.rawValue,
            "is_interchange": active.phase == .atInterchange,
            "detected_at": detectedAt
        ])
        await refreshMonitoringConditions()
    }

    private func startNextPlannedLeg(
        from station: Station,
        detectedAt: Date,
        preferredDeparture: DepartureV2? = nil,
        forceUnmatchedService: Bool = false
    ) async {
        guard var active = activeJourney else { return }
        if let previousIndex = active.legs.indices.last,
           let serviceID = active.legs[previousIndex].serviceID {
            _ = await DeparturesStore.shared.ensureServiceDetails(for: [serviceID], force: true)
            if let details = DeparturesStore.shared.serviceDetailsById[serviceID] {
                populate(&active.legs[previousIndex], from: details, reference: detectedAt)
            }
        }
        active.plannedLegIndex += 1
        active.stationEvents.append(JourneyHistoryStationEvent(station: station, kind: .departure, detectedAt: detectedAt))
        active.phase = .matchingService
        active.updatedAt = detectedAt
        let previousServiceID = active.legs.last?.serviceID
        activeJourney = active
        persistCheckpoint()
        log("next_leg_started", "Detected departure from interchange \(station.crs); matching planned leg \(active.plannedLegIndex + 1)", metadata: [
            "journey_id": active.id.uuidString,
            "station_crs": station.crs,
            "planned_leg_index": active.plannedLegIndex,
            "previous_service_id": previousServiceID,
            "detected_at": detectedAt
        ])
        await matchCurrentLeg(
            cachedDepartures: preferredDeparture.map { [$0] } ?? [],
            detectedAt: detectedAt,
            reboundFromServiceID: previousServiceID,
            preferredDeparture: preferredDeparture,
            forceUnmatchedService: forceUnmatchedService
        )
        await refreshMonitoringConditions()
    }

    private func attemptRebind(at station: Station, detectedAt: Date) async {
        guard var active = activeJourney else { return }
        let previousServiceID = active.legs.last?.serviceID
        if station.crs.caseInsensitiveCompare(active.currentPlannedLegDestination.crs) == .orderedSame,
           active.plannedLegIndex < active.plannedStations.count - 2 {
            activeJourney = active
            await startNextPlannedLeg(from: station, detectedAt: detectedAt)
            return
        }

        let destination = active.currentPlannedLegDestination
        let departures: [DepartureV2]
        do {
            let snapshots = try await NetworkServicePhone.shared.fetchDeparturesAggregated(
                pairs: [(from: station.crs, to: destination.crs)],
                delayBeforeEachBatch: false
            )
            departures = snapshots[pairKey(from: station.crs, to: destination.crs)]?.departures ?? []
        } catch {
            log("service_rebind_lookup_failed", "Service rebind lookup failed at \(station.crs): \(error.localizedDescription)", metadata: [
                "journey_id": active.id.uuidString,
                "station_crs": station.crs,
                "destination_crs": destination.crs,
                "previous_service_id": previousServiceID,
                "error": error.localizedDescription
            ])
            activeJourney = active
            await finishJourney(outcome: .offCourse, completedAt: detectedAt)
            return
        }
        if !departures.isEmpty {
            if let index = active.legs.indices.last {
                active.legs[index].detectedArrivalAt = detectedAt
                active.legs[index].outcome = .rebound
            }
            active.lastConfirmedOnRouteStation = station
            active.stationEvents.append(JourneyHistoryStationEvent(station: station, kind: .arrival, detectedAt: detectedAt))
            activeJourney = active
            persistCheckpoint()
            log("service_rebind_available", "Found \(departures.count) replacement service candidate(s) from \(station.crs) to \(destination.crs)", metadata: [
                "journey_id": active.id.uuidString,
                "station_crs": station.crs,
                "destination_crs": destination.crs,
                "previous_service_id": previousServiceID,
                "candidates": departureDiagnosticSummary(departures)
            ])
            await matchCurrentLeg(
                cachedDepartures: departures,
                detectedAt: detectedAt,
                reboundFromServiceID: previousServiceID,
                fromOverride: station
            )
            await refreshMonitoringConditions()
            return
        }
        activeJourney = active
        log("service_rebind_unavailable", "No replacement service from \(station.crs) to \(destination.crs); ending off course", metadata: [
            "journey_id": active.id.uuidString,
            "station_crs": station.crs,
            "destination_crs": destination.crs,
            "previous_service_id": previousServiceID
        ])
        await finishJourney(outcome: .offCourse, completedAt: detectedAt)
    }

    private func completeJourney(
        at station: Station,
        detectedAt: Date,
        isDeviceBased: Bool
    ) async {
        guard var active = activeJourney else { return }
        log("destination_arrival_detected", "Detected final arrival at \(station.crs)", metadata: [
            "journey_id": active.id.uuidString,
            "station_crs": station.crs,
            "detected_at": detectedAt,
            "service_id": active.currentLeg?.serviceID
        ])
        active.lastConfirmedOnRouteStation = station
        active.detectedArrivalAt = detectedAt
        active.deviceBasedArrivalAt = isDeviceBased ? detectedAt : nil
        active.stationEvents.append(JourneyHistoryStationEvent(station: station, kind: .arrival, detectedAt: detectedAt))
        if let index = active.legs.indices.last {
            active.legs[index].detectedArrivalAt = detectedAt
            active.legs[index].outcome = .completed
            if let serviceID = active.legs[index].serviceID {
                _ = await DeparturesStore.shared.ensureServiceDetails(for: [serviceID], force: true)
                if let details = DeparturesStore.shared.serviceDetailsById[serviceID] {
                    populate(&active.legs[index], from: details, reference: detectedAt)
                }
            }
        }
        active.updatedAt = detectedAt
        activeJourney = active
        await LiveActivityManager.shared.updateJourneyPhase(
            .arrived,
            startStation: active.plannedOrigin,
            destinationStation: active.plannedDestination,
            checkpoint: active
        )
        LiveActivityJourneyStatusSender.shared.send(
            phase: .arrived,
            from: active.plannedOrigin.crs,
            to: active.plannedDestination.crs
        )
        log("destination_arrival_correlated", "Final arrival correlated with official timing data", metadata: [
            "journey_id": active.id.uuidString,
            "station_crs": station.crs,
            "service_id": active.currentLeg?.serviceID,
            "operator": active.currentLeg?.operatorName,
            "scheduled_arrival": active.currentLeg?.scheduledArrivalAt,
            "actual_arrival": active.currentLeg?.actualArrivalAt,
            "confirmed_delay_minutes": JourneyHistoryDelayPolicy.confirmedDelayMinutes(
                scheduledArrival: active.currentLeg?.scheduledArrivalAt,
                actualArrival: active.currentLeg?.actualArrivalAt
            )
        ])
        await finishJourney(outcome: .completed, completedAt: detectedAt)
    }

    private func finishJourney(outcome: JourneyHistoryOutcome, completedAt: Date) async {
        guard let active = activeJourney else { return }
        log("journey_finishing", "Finishing journey \(active.id.uuidString) as \(outcome.displayName), recorded to \(active.lastConfirmedOnRouteStation.crs)", metadata: [
            "journey_id": active.id.uuidString,
            "subscription_id": active.subscriptionId,
            "outcome": outcome.rawValue,
            "recorded_destination_crs": active.lastConfirmedOnRouteStation.crs,
            "planned_destination_crs": active.plannedDestination.crs,
            "leg_count": active.legs.count,
            "backend_session_id": active.backendSessionID,
            "completed_at": completedAt
        ])
        let record = JourneyHistoryRecord(
            checkpoint: active,
            outcome: outcome,
            completedAt: completedAt
        )
        JourneyHistoryStore.shared.add(record)
        if outcome == .completed {
            reconcileScheduledNotificationMuteAfterCompletion(active)
        }
        let isAwaitingOfficialArrival = outcome == .completed
            && record.actualArrivalAt == nil
            && active.backendSessionID != nil
        if let backendSessionID = active.backendSessionID, !isAwaitingOfficialArrival {
            await JourneyTrackingService.shared.stop(sessionID: backendSessionID)
        } else if isAwaitingOfficialArrival {
            log("official_arrival_monitoring_continues", "Keeping the backend session active until confirmed destination arrival data is published", metadata: [
                "journey_id": active.id.uuidString,
                "backend_session_id": active.backendSessionID,
                "service_id": active.currentLeg?.serviceID,
                "destination_crs": active.plannedDestination.crs
            ])
        }
        recentlyCompletedJourney = active
        recentlyCompleted = RecentlyCompletedJourneyCheckpoint(
            checkpoint: active,
            outcome: outcome,
            completedAt: completedAt,
            autoDismissAt: completedAt.addingTimeInterval(Self.completedJourneyDisplayDuration)
        )
        activeJourney = nil
        persistCheckpoint()
        await refreshMonitoringConditions()
        log("journey_finished", "Journey \(active.id.uuidString) finished and active checkpoint cleared", metadata: [
            "journey_id": active.id.uuidString,
            "outcome": outcome.rawValue,
            "recorded_destination_crs": active.lastConfirmedOnRouteStation.crs
        ])
        if outcome == .completed {
            await postArrivalConfirmedNotification(active, detectedAt: active.detectedArrivalAt ?? completedAt)
            if record.isDelayRepay15Plus {
                await postDelayRepayNotification(for: record)
            }
        } else {
            await postTrackingStoppedNotification(active, outcome: outcome)
        }
    }

    private func reconcileScheduledNotificationMuteAfterCompletion(
        _ active: ActiveJourneyHistoryCheckpoint
    ) {
        guard active.source == .scheduled, let leg = active.currentLeg else { return }

        let from = leg.fromStation.crs.uppercased()
        let to = leg.toStation.crs.uppercased()
        NotificationMuteStorage.removePendingMuteRequests(
            subscriptionId: active.subscriptionId,
            from: from,
            to: to
        )
        NotificationMuteStorage.markMuted(from: from, to: to)
        NotificationMuteStorage.clearArrivalDetectionPending(from: from, to: to)
        NotificationMuteStorage.clearPendingStationDepartureCleanup(from: from, to: to)
        NotificationMuteRequestSender.shared.enqueueMute(
            subscriptionId: active.subscriptionId,
            from: from,
            to: to,
            reason: "journey_completed_reconciliation",
            transition: "station_exit",
            detectionSource: "journey_tracking"
        )
        log("scheduled_notification_mute_reconciled", "Reconciled scheduled notifications after completing \(from)→\(to)", metadata: [
            "journey_id": active.id.uuidString,
            "subscription_id": active.subscriptionId,
            "from": from,
            "to": to
        ])
    }

    private func populate(_ leg: inout JourneyHistoryLeg, from details: ServiceDetails, reference: Date) {
        if let operatorName = details.operator {
            leg.operatorName = operatorName
        }
        if let operatorCode = details.operatorCode {
            leg.operatorCode = operatorCode
        }
        let branch = details.stationBranches.first(where: { points in
            points.contains { $0.crs.caseInsensitiveCompare(leg.toStation.crs) == .orderedSame }
        }) ?? details.allStations
        let originIndex = branch.firstIndex { $0.crs.caseInsensitiveCompare(leg.fromStation.crs) == .orderedSame } ?? 0
        let destinationIndex = branch.lastIndex { $0.crs.caseInsensitiveCompare(leg.toStation.crs) == .orderedSame } ?? max(0, branch.count - 1)
        let lower = min(originIndex, destinationIndex)
        let upper = max(originIndex, destinationIndex)
        let selectedPoints = branch.isEmpty ? [] : Array(branch[lower...upper])
        let historyCallingPoint: (CallingPoint) -> JourneyHistoryCallingPoint = {
            JourneyHistoryCallingPoint(
                locationName: $0.locationName,
                crs: $0.crs.uppercased(),
                scheduledTime: $0.st,
                estimatedTime: $0.et,
                actualTime: $0.at
            )
        }
        leg.serviceCallingPoints = branch.map(historyCallingPoint)
        leg.callingPoints = selectedPoints.map(historyCallingPoint)
        if let actualDeparture = resolvedOfficialDate(actual: details.atd, scheduled: details.std, near: reference) {
            leg.actualDepartureAt = actualDeparture
        }
        if let destination = JourneyHistoryOfficialArrivalResolver.destinationCallingPoint(
            in: details,
            destinationCRS: leg.toStation.crs
        ) {
            if let scheduledArrival = JourneyHistoryTime.date(for: destination.st, near: reference) {
                leg.scheduledArrivalAt = scheduledArrival
            }
            if let actualArrival = JourneyHistoryOfficialArrivalResolver.resolvedActualDate(
                for: destination,
                near: reference
            ) {
                leg.actualArrivalAt = actualArrival
            }
        } else {
            if let scheduledArrival = JourneyHistoryTime.date(for: details.sta, near: reference) {
                leg.scheduledArrivalAt = scheduledArrival
            }
            if let actualArrival = resolvedOfficialDate(actual: details.ata, scheduled: details.sta, near: reference) {
                leg.actualArrivalAt = actualArrival
            }
        }
    }

    private func resolvedCurrentRouteStations(_ active: ActiveJourneyHistoryCheckpoint) -> [Station] {
        guard let leg = active.currentLeg, !leg.callingPoints.isEmpty else {
            return [active.plannedStations[active.plannedLegIndex], active.currentPlannedLegDestination]
        }
        return leg.callingPoints.map { station(crs: $0.crs, fallbackName: $0.locationName) }
    }

    private func postArrivalConfirmedNotification(
        _ active: ActiveJourneyHistoryCheckpoint,
        detectedAt: Date
    ) async {
        let content = UNMutableNotificationContent()
        content.title = "Arrived at \(active.plannedDestination.name)"
        content.body = JourneyHistoryNotificationText.arrival(
            destinationName: active.plannedDestination.name,
            detectedAt: detectedAt
        )
        content.sound = .default
        content.categoryIdentifier = NotificationCategoryId.journeyHistory
        content.userInfo = [
            NotificationPayloadKeys.alertType: NotificationAlertType.journeyArrivalConfirmed,
            "journey_id": active.id.uuidString
        ]
        let request = UNNotificationRequest(
            identifier: "journey_arrival_\(active.id.uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: Self.arrivalNotificationBufferSeconds,
                repeats: false
            )
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            log("arrival_notification_scheduled", "Scheduled confirmed-arrival notification for \(active.plannedDestination.crs)", metadata: [
                "journey_id": active.id.uuidString,
                "destination_crs": active.plannedDestination.crs,
                "detected_at": detectedAt,
                "buffer_seconds": Self.arrivalNotificationBufferSeconds,
                "notification_id": request.identifier
            ])
        } catch {
            log("arrival_notification_failed", "Confirmed-arrival notification failed: \(error.localizedDescription)", metadata: [
                "journey_id": active.id.uuidString,
                "destination_crs": active.plannedDestination.crs,
                "error": error.localizedDescription
            ])
        }
    }

    private func postDelayRepayNotification(for record: JourneyHistoryRecord) async {
        guard let delayMinutes = record.delayMinutes,
              delayMinutes >= JourneyHistoryDelayPolicy.delayRepayThresholdMinutes else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Journey delay"
        content.body = JourneyHistoryNotificationText.delayRepay(delayMinutes: delayMinutes)
        content.sound = .default
        content.categoryIdentifier = NotificationCategoryId.journeyHistory
        content.userInfo = [
            NotificationPayloadKeys.alertType: NotificationAlertType.journeyDelayRepay,
            "journey_id": record.id.uuidString,
            "delay_minutes": delayMinutes
        ]
        let preferredDelivery = record.completedAt
            .addingTimeInterval(Self.arrivalNotificationBufferSeconds + 5)
        let delay = max(1, preferredDelivery.timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: "journey_delay_repay_\(record.id.uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            log("delay_repay_notification_scheduled", "Scheduled Delay Repay notification for journey \(record.id.uuidString)", metadata: [
                "journey_id": record.id.uuidString,
                "delay_minutes": delayMinutes,
                "delivery_delay_seconds": delay,
                "notification_id": request.identifier
            ])
        } catch {
            log("delay_repay_notification_failed", "Delay Repay notification failed: \(error.localizedDescription)", metadata: [
                "journey_id": record.id.uuidString,
                "delay_minutes": delayMinutes,
                "error": error.localizedDescription
            ])
        }
    }

    private func postTrackingStoppedNotification(
        _ active: ActiveJourneyHistoryCheckpoint,
        outcome: JourneyHistoryOutcome
    ) async {
        let content = UNMutableNotificationContent()
        content.title = outcome == .endedEarly ? "Journey recording ended" : "Journey route changed"
        content.body = "History was saved up to \(active.lastConfirmedOnRouteStation.name)."
        content.sound = .default
        content.categoryIdentifier = NotificationCategoryId.journeyHistory
        content.userInfo = [
            NotificationPayloadKeys.alertType: NotificationAlertType.journeyTrackingStopped,
            "journey_id": active.id.uuidString
        ]
        let request = UNNotificationRequest(
            identifier: "journey_stopped_\(active.id.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            log("tracking_stopped_notification_posted", "Posted tracking-stopped notification for journey \(active.id.uuidString)", metadata: [
                "journey_id": active.id.uuidString,
                "outcome": outcome.rawValue,
                "recorded_destination_crs": active.lastConfirmedOnRouteStation.crs,
                "notification_id": request.identifier
            ])
        } catch {
            log("tracking_stopped_notification_failed", "Tracking-stopped notification failed: \(error.localizedDescription)", metadata: [
                "journey_id": active.id.uuidString,
                "outcome": outcome.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    private func refreshMonitoringConditions() async {
        let conditions = locationConditions()
        log("monitoring_plan_refreshed", "Refreshing \(conditions.count) journey condition(s): \(conditions.map { "\($0.kind.rawValue):\($0.station.crs)@\(Int($0.radius))m" }.joined(separator: ", "))", metadata: [
            "journey_id": activeJourney?.id.uuidString,
            "phase": activeJourney?.phase.rawValue,
            "condition_count": conditions.count,
            "conditions": conditions.map { condition in
                [
                    "id": condition.identifier,
                    "kind": condition.kind.rawValue,
                    "station_crs": condition.station.crs,
                    "radius_m": Int(condition.radius)
                ] as [String: Any]
            }
        ])
        await NotificationGeofenceManager.shared.refreshJourneyConditions()
    }

    private func station(
        crs: String,
        fallbackName: String?,
        cachedStationsByCRS: [String: Station] = [:]
    ) -> Station {
        cachedStationsByCRS[crs.uppercased()] ?? StationsService.shared.stations.first {
            $0.crs.caseInsensitiveCompare(crs) == .orderedSame
        } ?? Station(
            crs: crs.uppercased(),
            name: fallbackName ?? crs.uppercased(),
            longitude: "0",
            latitude: "0"
        )
    }

    private func serviceTimeDifference(_ departure: DepartureV2, detectedAt: Date) -> Int {
        JourneyHistoryTime.circularMinuteDifference(
            JourneyItineraryBuilder.departureDisplayTime(departure),
            from: detectedAt
        ) ?? Int.max
    }

    private func resolvedOfficialDate(actual: String?, scheduled: String?, near reference: Date) -> Date? {
        guard let actual else { return nil }
        if actual.caseInsensitiveCompare("On time") == .orderedSame {
            return JourneyHistoryTime.date(for: scheduled, near: reference)
        }
        guard actual.caseInsensitiveCompare("Cancelled") != .orderedSame else { return nil }
        return JourneyHistoryTime.date(for: actual, near: reference)
    }

    private func pairKey(from: String, to: String) -> String {
        "\(from.uppercased())_\(to.uppercased())"
    }

    private func historyIdentifier(
        kind: JourneyHistoryLocationCondition.Kind,
        journeyID: UUID,
        stationCRS: String
    ) -> String {
        "tt_history_\(kind.rawValue):\(journeyID.uuidString):\(stationCRS.uppercased())"
    }

    private func parseHistoryIdentifier(_ identifier: String) -> (
        kind: JourneyHistoryLocationCondition.Kind,
        journeyID: UUID,
        stationCRS: String
    )? {
        let parts = identifier.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].hasPrefix("tt_history_"),
              let kind = JourneyHistoryLocationCondition.Kind(rawValue: String(parts[0].dropFirst("tt_history_".count))),
              let journeyID = UUID(uuidString: String(parts[1])) else {
            return nil
        }
        return (kind, journeyID, String(parts[2]).uppercased())
    }

    private func persistCheckpoint() {
        let envelope = JourneyHistoryCheckpointEnvelope(
            armedCandidates: armedCandidates,
            activeJourney: activeJourney,
            recentlyCompleted: recentlyCompleted
        )
        do {
            let data = try JSONEncoder().encode(envelope)
            defaults.set(data, forKey: checkpointKey)
        } catch {
            log("checkpoint_persistence_failed", "Journey checkpoint persistence failed: \(error.localizedDescription)", metadata: [
                "active_journey_id": activeJourney?.id.uuidString,
                "armed_candidate_count": armedCandidates.count,
                "error": error.localizedDescription
            ])
        }
    }

    private func restoreCheckpoint() {
        guard let data = defaults.data(forKey: checkpointKey),
              let envelope = try? JSONDecoder().decode(JourneyHistoryCheckpointEnvelope.self, from: data) else {
            return
        }
        armedCandidates = envelope.armedCandidates.filter(\.isCurrent)
        activeJourney = envelope.activeJourney
        recentlyCompleted = envelope.recentlyCompleted
        recentlyCompletedJourney = envelope.recentlyCompleted?.checkpoint
        pruneExpiredCompletion()
    }

    private func log(_ event: String, _ message: String, metadata: [String: Any?] = [:]) {
        DebugLogStore.shared.log(message, category: "JourneyHistory")
        ClientDiagnosticsLogger.log("journey_history", event, metadata: metadata)
    }

    private func departureDiagnosticSummary(_ departures: [DepartureV2]) -> [[String: Any]] {
        departures.prefix(8).map { departure in
            [
                "service_id": departure.serviceID,
                "scheduled": departure.departureTime.scheduled,
                "estimated": departure.departureTime.estimated,
                "display_time": JourneyItineraryBuilder.departureDisplayTime(departure),
                "cancelled": departure.isCancelled
            ]
        }
    }

    private func remoteNotificationMetadata(_ userInfo: [AnyHashable: Any]) -> [String: Any?] {
        [
            "journey_id": userInfo["journey_id"] as? String,
            "journey_event": userInfo["journey_event"] as? String,
            "subscription_id": userInfo["subscription_id"] as? String,
            "service_id": userInfo["service_id"] as? String,
            "station_crs": userInfo["station_crs"] as? String,
            "destination_crs": userInfo["destination_crs"] as? String,
            "operator": userInfo["operator"] as? String,
            "operator_code": userInfo["operator_code"] as? String,
            "scheduled_arrival": userInfo["scheduled_arrival"] as? String,
            "actual_arrival": userInfo["actual_arrival"] as? String
        ]
    }

    private func notificationAuthorizationDescription(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}
