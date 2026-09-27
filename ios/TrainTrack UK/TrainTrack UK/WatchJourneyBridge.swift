import Foundation

/// Projects the phone's existing journey tracker onto the watch; the phone owns all mutations.
@MainActor
enum WatchJourneyBridge {
    private static var tracker: JourneyTrackingCoordinator { .shared }
    private static var departures: DeparturesStore { .shared }

    static func snapshots() -> [WatchJourney] {
        var result: [WatchJourney] = []
        if let active = tracker.activeJourney { return [snapshot(active)] }
        else if let completed = tracker.recentlyCompleted {
            result.append(snapshot(completed.checkpoint, completed: true))
        }
        result += tracker.armedCandidates.filter { candidate in
            !result.contains { $0.id == candidate.subscriptionId }
        }.compactMap { candidate in
            guard candidate.stations.count >= 2 else { return nil }
            let route = route(candidate.stations)
            let atStart = candidate.originArrivedAt != nil
            return WatchJourney(
                id: candidate.subscriptionId, context: "\(candidate.id)-\(candidate.createdAt.timeIntervalSince1970)-\(atStart)", route: route,
                phase: atStart ? "at_start" : "pending_start",
                title: atStart ? "At \(route.origin.name)" : "Waiting for you to arrive",
                detail: atStart ? "Choose the train you caught when you leave the station."
                    : "Journey tracking is watching for your arrival at \(route.origin.name).",
                destination: route.destination.name, arrival: nil, finalArrival: nil, status: nil,
                platform: nil, length: nil,
                arrivalAction: atStart ? nil : "I’m at \(route.origin.name)",
                serviceAction: atStart ? "Choose the train I caught" : nil,
                services: services(from: candidate.stations[0], to: candidate.stations[1]), updatedAt: Date()
            )
        }
        return result
    }

    private static func route(_ stations: [Station], id: UUID = UUID()) -> WatchRoute {
        WatchRoute(id: id, stations: stations.map { WatchStation(crs: $0.crs, name: $0.name) }, favourite: false)
    }

    private static func group(_ stations: [Station]) -> JourneyGroup {
        let id = UUID()
        return JourneyGroup(id: id, legs: stations.indices.dropLast().map { index in
            Journey(id: UUID(), groupId: id, legIndex: index, fromStation: stations[index],
                    toStation: stations[index + 1], createdAt: Date(), favorite: false)
        })
    }

    static func snapshot(_ active: ActiveJourneyHistoryCheckpoint, completed: Bool = false) -> WatchJourney {
        let leg = active.currentLeg
        let destination = active.currentPlannedLegDestination
        let details = leg?.serviceID.flatMap { departures.serviceDetailsById[$0] }
        let point = details?.stationBranches.flatMap { $0 }.first {
            $0.crs.caseInsensitiveCompare(destination.crs) == .orderedSame
        }
        let fallbackPoint = leg?.callingPoints.first { $0.crs.caseInsensitiveCompare(destination.crs) == .orderedSame }
        let arrival = point?.displayTime ?? fallbackPoint.map { $0.actualTime ?? $0.estimatedTime ?? $0.scheduledTime }
        let status = details.flatMap { computeLiveStatus(from: $0, within: leg?.fromStation.crs, toCRS: destination.crs)?.text }
        let atChange = active.phase == .atInterchange
        let contextIndex = active.plannedLegIndex + (atChange ? 1 : 0)
        let contextStations = Array(active.plannedStations.dropFirst(contextIndex))
        let recent = contextStations.count >= 2 ? services(from: contextStations[0], to: contextStations[1]) : []
        let departure = activeDeparture(active)
        let remaining = group(Array(active.plannedStations.dropFirst(active.plannedLegIndex)))
        let itinerary = departure.flatMap { JourneyItineraryBuilder.build(
            group: remaining, firstDeparture: $0, departuresForJourney: departures.departures(for:),
            serviceDetailsByID: departures.serviceDetailsById
        ) }
        let serviceDescription = [leg?.scheduledDepartureAt.map(clock), details?.operator]
            .compactMap { $0 }.joined(separator: " ")
        return WatchJourney(
            id: active.subscriptionId,
            context: "\(active.id)-\(active.plannedLegIndex)-\(active.phase.rawValue)-\(leg?.id.uuidString ?? "none")-\(leg?.serviceID ?? "none")-\(completed)",
            route: route(active.plannedStations, id: active.id), phase: completed ? "completed" : active.phase.rawValue,
            title: completed ? "Journey finished" : atChange ? "At \(destination.name)" : "Journey underway",
            detail: completed ? "Your journey has been saved on your iPhone."
                : atChange ? "Choose your next train to \(active.plannedDestination.name)."
                : serviceDescription.isEmpty ? "Your train hasn’t been confirmed yet."
                : "You’re on the \(serviceDescription) to \(destination.name).",
            destination: destination.name,
            arrival: arrival.map { "ETA \(JourneyCardPresentation.arrivalTimeLabel($0))" },
            finalArrival: active.plannedLegIndex < active.plannedStations.count - 2
                ? "\(active.plannedDestination.name): \(InProgressJourneyPresentation.finalDestinationETAText(time: itinerary?.finalArrivalTime, delayMinutes: itinerary?.finalArrivalDelayMinutes))" : nil,
            status: status ?? "Live status unavailable", platform: point?.platform, length: details?.length,
            arrivalAction: completed || atChange ? nil : "I’ve arrived at \(destination.name)",
            serviceAction: completed ? nil : atChange ? "Choose my next train" : "Change the train I’m on",
            services: recent, updatedAt: Date(),
            nextDepartureRoute: !completed && active.plannedLegIndex + 2 < active.plannedStations.count
                ? route(Array(active.plannedStations[(active.plannedLegIndex + 1)...]), id: active.id) : nil
        )
    }

    private static func activeDeparture(_ active: ActiveJourneyHistoryCheckpoint) -> DepartureV2? {
        guard let leg = active.currentLeg, let id = leg.serviceID else { return nil }
        if let departure = departures.departure(serviceID: id, fromCRS: leg.fromStation.crs, toCRS: leg.toStation.crs) {
            return departure
        }
        return DepartureV2(
            departureTime: DepartureTimeV2(scheduled: leg.scheduledDepartureAt.map(clock) ?? "Service",
                                          estimated: leg.estimatedDepartureTime ?? leg.scheduledDepartureAt.map(clock) ?? "Service"),
            serviceType: "train", platform: nil, isCancelled: false, length: nil,
            destination: [PlaceInfoV2(crs: leg.toStation.crs, locationName: leg.toStation.name, via: nil)],
            origin: [PlaceInfoV2(crs: leg.fromStation.crs, locationName: leg.fromStation.name, via: nil)],
            serviceID: id, delayReason: nil, cancelReason: nil, timestamp: nil
        )
    }

    private static func services(from: Station, to: Station) -> [WatchJourneyService] {
        RecentServiceStore.shared.departures(fromCRS: from.crs, toCRS: to.crs).prefix(20).map {
            WatchJourneyService(id: $0.id, departure: $0.scheduledDeparture,
                                status: $0.isCancelled ? "Cancelled" : $0.actualDeparture.map { "Departed \($0)" } ?? $0.estimatedDeparture ?? "Scheduled",
                                platform: $0.platform, cancelled: $0.isCancelled)
        }
    }

    static func refresh() async {
        let pairs: [(Station, Station)]
        if let active = tracker.activeJourney {
            let index = active.plannedLegIndex + (active.phase == .atInterchange ? 1 : 0)
            pairs = zip(active.plannedStations.dropFirst(index), active.plannedStations.dropFirst(index + 1)).map { ($0, $1) }
        } else {
            pairs = tracker.armedCandidates.compactMap { $0.stations.count >= 2 ? ($0.stations[0], $0.stations[1]) : nil }
        }
        for (from, to) in pairs {
            guard !Task.isCancelled else { return }
            await departures.refreshSpecificJourney(fromCRS: from.crs, toCRS: to.crs)
            await RecentServiceStore.shared.refresh(fromCRS: from.crs, toCRS: to.crs)
        }
        if let leg = tracker.activeJourney?.currentLeg, let id = leg.serviceID, leg.serviceDetailsMayBeAvailable() {
            _ = await departures.ensureServiceDetails(for: [id], force: true)
        }
    }

    static func perform(_ command: WatchJourneyCommand) async throws {
        guard let snapshot = snapshots().first(where: { command.matches($0) }) else {
            throw BridgeError.message("This journey changed on your iPhone. Refresh and try again.")
        }
        let active = tracker.activeJourney
        let candidate = tracker.armedCandidates.first { $0.subscriptionId == command.journeyID }
        switch command.action {
        case .arrive:
            guard snapshot.arrivalAction != nil else { throw BridgeError.message("Refresh this journey before confirming arrival.") }
            if active?.subscriptionId == command.journeyID {
                await tracker.manuallyConfirmNextLegEndpoint()
            } else {
                await tracker.manuallyConfirmOriginArrival(subscriptionID: command.journeyID)
            }
        case .end:
            let stations = active?.subscriptionId == command.journeyID ? active?.plannedStations : candidate?.stations
            guard let stations else { throw BridgeError.message("This journey has already ended.") }
            await NotificationSubscriptionStore.shared.endJourneyUpdates(subscriptionID: command.journeyID, group: group(stations))
        case .selectService, .unlistedService:
            guard snapshot.serviceAction != nil else { throw BridgeError.message("Choose a train after arriving at the station.") }
            var departure: DepartureV2?
            if command.action == .selectService {
                let index = (active?.plannedLegIndex ?? 0) + (active?.phase == .atInterchange ? 1 : 0)
                let stations = active?.plannedStations ?? candidate?.stations ?? []
                guard stations.indices.contains(index + 1),
                      let recent = RecentServiceStore.shared.departures(fromCRS: stations[index].crs, toCRS: stations[index + 1].crs)
                        .first(where: { $0.id == command.serviceID && !$0.isCancelled }) else {
                    throw BridgeError.message("That train is no longer available. Refresh and choose again.")
                }
                departure = DepartureV2(
                    departureTime: DepartureTimeV2(scheduled: recent.scheduledDeparture,
                        estimated: recent.actualDeparture ?? recent.estimatedDeparture ?? recent.scheduledDeparture),
                    serviceType: recent.serviceType, platform: recent.platform, isCancelled: recent.isCancelled, length: nil,
                    destination: [PlaceInfoV2(crs: stations[index + 1].crs, locationName: stations[index + 1].name, via: nil)],
                    origin: [PlaceInfoV2(crs: stations[index].crs, locationName: stations[index].name, via: nil)],
                    serviceID: recent.serviceID, delayReason: nil, cancelReason: nil, timestamp: recent.lastObservedAt
                )
            }
            if let departure {
                if active?.phase == .atInterchange { await tracker.manuallyBoardNextLeg(departure: departure) }
                else if active != nil { await tracker.manuallyReplaceCurrentService(with: departure) }
                else { await tracker.manuallyBoard(subscriptionID: command.journeyID, departure: departure) }
            } else {
                if active?.phase == .atInterchange { await tracker.manuallyBoardNextLegWithoutMatchedService() }
                else if active != nil { await tracker.manuallyUseUnlistedService() }
                else { await tracker.manuallyBoardWithoutMatchedService(subscriptionID: command.journeyID) }
            }
        }
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    enum BridgeError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
    }
}
