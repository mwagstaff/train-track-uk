#if DEBUG
import Foundation

enum JourneyHistoryDebugDataError: LocalizedError {
    case noValidatedRoutes

    var errorDescription: String? {
        switch self {
        case .noValidatedRoutes:
            return "No complete test routes were found in the current station catalogue."
        }
    }
}

@MainActor
enum JourneyHistoryDebugDataGenerator {
    private struct RouteTemplate {
        let key: String
        let operatorName: String
        let operatorCode: String
        let stops: [(crs: String, offsetMinutes: Int)]
    }

    private struct ResolvedRoute {
        let template: RouteTemplate
        let stations: [Station]
    }

    private struct ItineraryTemplate {
        let key: String
        let legs: [RouteTemplate]
    }

    private struct ResolvedItinerary {
        let template: ItineraryTemplate
        let legStations: [[Station]]
    }

    private enum Scenario: Int, CaseIterable {
        case onTime
        case minorDelay
        case delayRepay
        case veryLate
        case cancelled
        case endedEarly
        case offCourse
        case rebound
        case officialArrivalUnavailable

        var delayMinutes: Int {
            switch self {
            case .minorDelay: return 3
            case .delayRepay: return 20
            case .veryLate: return 65
            default: return 0
            }
        }

        var outcome: JourneyHistoryOutcome {
            switch self {
            case .cancelled: return .uncertain
            case .endedEarly: return .endedEarly
            case .offCourse: return .offCourse
            default: return .completed
            }
        }

        var legOutcome: JourneyHistoryLegOutcome {
            switch self {
            case .cancelled, .offCourse: return .uncertain
            case .rebound: return .rebound
            default: return .completed
            }
        }

        var hasConfirmedOfficialArrival: Bool {
            switch self {
            case .cancelled, .endedEarly, .offCourse, .officialArrivalUnavailable:
                return false
            default:
                return true
            }
        }
    }

    static func records(count: Int, now: Date = Date()) async throws -> [JourneyHistoryRecord] {
        guard count > 0 else { return [] }
        let routes = try await validatedRoutes()

        return (0..<count).map { index in
            makeRecord(index: index, route: routes[index % routes.count], now: now)
        }
    }

    static func randomMultiLegRecord(now: Date = Date()) async throws -> JourneyHistoryRecord {
        let itineraries = try await validatedItineraries()
        let itinerary = itineraries.randomElement()!
        let legCount = itinerary.template.legs.count
        let transferMinutes = (0..<(legCount - 1)).map { _ in Int.random(in: 6...14) }
        let delayMinutes = [0, 2, 7, 18, 35, 65].randomElement()!
        let responsibleLegIndex = Int.random(in: 0..<legCount)
        let departureAt = now.addingTimeInterval(-Double(Int.random(in: 6...72)) * 60 * 60)
        let identifier = UUID().uuidString.prefix(8)

        var scheduledLegDepartureAt = departureAt
        var legs: [JourneyHistoryLeg] = []
        var stationEvents: [JourneyHistoryStationEvent] = []

        for legIndex in 0..<legCount {
            let template = itinerary.template.legs[legIndex]
            let stations = itinerary.legStations[legIndex]
            let legDelayMinutes = legIndex >= responsibleLegIndex ? delayMinutes : 0
            let serviceCallingPoints = callingPoints(
                template: template,
                stations: stations,
                departureAt: scheduledLegDepartureAt,
                delayMinutes: legDelayMinutes
            )
            let scheduledArrivalAt = scheduledLegDepartureAt.addingTimeInterval(
                Double(template.stops.last!.offsetMinutes * 60)
            )
            let actualDepartureAt = scheduledLegDepartureAt.addingTimeInterval(Double(legDelayMinutes * 60))
            let actualArrivalAt = scheduledArrivalAt.addingTimeInterval(Double(legDelayMinutes * 60))

            legs.append(JourneyHistoryLeg(
                plannedLegIndex: legIndex,
                fromStation: stations.first!,
                toStation: stations.last!,
                serviceID: "DEBUG-\(itinerary.template.key)-\(identifier)-L\(legIndex + 1)",
                operatorName: template.operatorName,
                operatorCode: template.operatorCode,
                callingPoints: serviceCallingPoints,
                serviceCallingPoints: serviceCallingPoints,
                detectedDepartureAt: actualDepartureAt,
                detectedArrivalAt: actualArrivalAt,
                scheduledDepartureAt: scheduledLegDepartureAt,
                estimatedDepartureTime: legDelayMinutes == 0
                    ? "On time"
                    : clockString(actualDepartureAt),
                actualDepartureAt: actualDepartureAt,
                scheduledArrivalAt: scheduledArrivalAt,
                actualArrivalAt: actualArrivalAt,
                outcome: .completed
            ))
            stationEvents.append(JourneyHistoryStationEvent(
                station: stations.first!,
                kind: .departure,
                detectedAt: actualDepartureAt
            ))
            stationEvents.append(JourneyHistoryStationEvent(
                station: stations.last!,
                kind: .arrival,
                detectedAt: actualArrivalAt
            ))

            if legIndex < transferMinutes.count {
                scheduledLegDepartureAt = scheduledArrivalAt.addingTimeInterval(
                    Double(transferMinutes[legIndex] * 60)
                )
            }
        }

        let finalLeg = legs.last!
        let completedAt = finalLeg.actualArrivalAt!
        let plannedStations = [itinerary.legStations[0].first!]
            + itinerary.legStations.map { $0.last! }
        let checkpoint = ActiveJourneyHistoryCheckpoint(
            id: UUID(),
            subscriptionId: "debug-multi-leg-\(identifier)",
            source: Bool.random() ? .scheduled : .adhoc,
            plannedStations: plannedStations,
            createdAt: departureAt.addingTimeInterval(-20 * 60),
            phase: .arriving,
            plannedLegIndex: legCount - 1,
            originArrivedAt: departureAt.addingTimeInterval(-2 * 60),
            detectedDepartureAt: legs[0].detectedDepartureAt!,
            detectedArrivalAt: finalLeg.detectedArrivalAt,
            lastConfirmedOnRouteStation: plannedStations.last!,
            nextExpectedCallingPointIndex: itinerary.legStations.last!.count - 1,
            legs: legs,
            stationEvents: stationEvents,
            approachNotificationSent: true,
            backendSessionID: nil,
            serviceMatchConfidence: 0.98,
            unexpectedStation: nil,
            unexpectedStationObservedAt: nil,
            serviceDepartedStationCRS: plannedStations.last!.crs,
            serviceDepartedStationAt: completedAt,
            updatedAt: completedAt
        )
        return JourneyHistoryRecord(
            checkpoint: checkpoint,
            outcome: .completed,
            completedAt: completedAt
        )
    }

    private static func validatedRoutes() async throws -> [ResolvedRoute] {
        try await StationsService.shared.loadStations()

        var stationsByCRS: [String: Station] = [:]
        for station in StationsService.shared.stations {
            stationsByCRS[station.crs.uppercased()] = station
        }
        let routes = routeTemplates.compactMap { template -> ResolvedRoute? in
            let stations = template.stops.compactMap { stationsByCRS[$0.crs] }
            guard stations.count == template.stops.count else { return nil }
            return ResolvedRoute(template: template, stations: stations)
        }
        guard !routes.isEmpty else {
            throw JourneyHistoryDebugDataError.noValidatedRoutes
        }
        return routes
    }

    private static func validatedItineraries() async throws -> [ResolvedItinerary] {
        try await StationsService.shared.loadStations()

        var stationsByCRS: [String: Station] = [:]
        for station in StationsService.shared.stations {
            stationsByCRS[station.crs.uppercased()] = station
        }
        let itineraries = itineraryTemplates.compactMap { template -> ResolvedItinerary? in
            let legStations = template.legs.map { leg in
                leg.stops.compactMap { stationsByCRS[$0.crs] }
            }
            guard zip(template.legs, legStations).allSatisfy({ leg, stations in
                stations.count == leg.stops.count
            }) else {
                return nil
            }
            return ResolvedItinerary(template: template, legStations: legStations)
        }
        guard !itineraries.isEmpty else {
            throw JourneyHistoryDebugDataError.noValidatedRoutes
        }
        return itineraries
    }

    private static func makeRecord(
        index: Int,
        route: ResolvedRoute,
        now: Date
    ) -> JourneyHistoryRecord {
        let scenario = Scenario.allCases[index % Scenario.allCases.count]
        let finalIndex = route.stations.count - 1
        var plannedDestinationIndex = 1 + ((index / routeTemplates.count) % finalIndex)
        if (scenario == .cancelled || scenario == .endedEarly || scenario == .offCourse),
           plannedDestinationIndex < 2 {
            plannedDestinationIndex = min(2, finalIndex)
        }
        let recordedDestinationIndex: Int
        switch scenario {
        case .cancelled, .endedEarly, .offCourse:
            recordedDestinationIndex = max(0, plannedDestinationIndex - 1)
        default:
            recordedDestinationIndex = plannedDestinationIndex
        }

        let departureAt = now.addingTimeInterval(-Double(index + 2) * 12 * 60 * 60)
        let scheduledArrivalAt = departureAt.addingTimeInterval(
            Double(route.template.stops[plannedDestinationIndex].offsetMinutes * 60)
        )
        let actualArrivalAt = scenario.hasConfirmedOfficialArrival
            ? scheduledArrivalAt.addingTimeInterval(Double(scenario.delayMinutes * 60))
            : nil
        let detectedArrivalAt: Date? = scenario == .cancelled
            ? nil
            : departureAt.addingTimeInterval(
                Double((route.template.stops[recordedDestinationIndex].offsetMinutes + scenario.delayMinutes) * 60)
            )
        let completedAt = detectedArrivalAt
            ?? departureAt.addingTimeInterval(
                Double(route.template.stops[max(1, recordedDestinationIndex)].offsetMinutes * 60)
            )

        let serviceCallingPoints = callingPoints(
            route: route,
            scenario: scenario,
            departureAt: departureAt,
            plannedDestinationIndex: plannedDestinationIndex
        )
        let plannedDestination = route.stations[plannedDestinationIndex]
        let recordedDestination = route.stations[recordedDestinationIndex]
        let serviceID = ProcessInfo.processInfo.environment["APP_STORE_SCREENSHOTS"] == "1"
            ? String(format: "1P%02d", index + 22)
            : "DEBUG-\(route.template.key)-\(index)"
        let leg = JourneyHistoryLeg(
            plannedLegIndex: 0,
            fromStation: route.stations[0],
            toStation: plannedDestination,
            serviceID: serviceID,
            operatorName: route.template.operatorName,
            operatorCode: route.template.operatorCode,
            callingPoints: Array(serviceCallingPoints[0...plannedDestinationIndex]),
            serviceCallingPoints: serviceCallingPoints,
            detectedDepartureAt: departureAt,
            detectedArrivalAt: detectedArrivalAt,
            scheduledDepartureAt: departureAt,
            estimatedDepartureTime: scenario.delayMinutes == 0
                ? "On time"
                : clockString(departureAt.addingTimeInterval(Double(scenario.delayMinutes * 60))),
            actualDepartureAt: departureAt.addingTimeInterval(Double(scenario.delayMinutes * 60)),
            scheduledArrivalAt: scheduledArrivalAt,
            actualArrivalAt: actualArrivalAt,
            outcome: scenario.legOutcome,
            reboundFromServiceID: scenario == .rebound ? "DEBUG-REBOUND-\(index)" : nil
        )
        var stationEvents = [JourneyHistoryStationEvent(
            station: route.stations[0],
            kind: .departure,
            detectedAt: departureAt
        )]
        if let detectedArrivalAt {
            stationEvents.append(JourneyHistoryStationEvent(
                station: recordedDestination,
                kind: .arrival,
                detectedAt: detectedArrivalAt
            ))
        }
        let checkpoint = ActiveJourneyHistoryCheckpoint(
            id: UUID(),
            subscriptionId: "debug-history-\(index)",
            source: index.isMultiple(of: 3) ? .adhoc : .scheduled,
            plannedStations: [route.stations[0], plannedDestination],
            createdAt: departureAt.addingTimeInterval(-20 * 60),
            phase: .arriving,
            plannedLegIndex: 0,
            originArrivedAt: departureAt.addingTimeInterval(-2 * 60),
            detectedDepartureAt: departureAt,
            detectedArrivalAt: detectedArrivalAt,
            lastConfirmedOnRouteStation: recordedDestination,
            nextExpectedCallingPointIndex: min(recordedDestinationIndex + 1, plannedDestinationIndex),
            legs: [leg],
            stationEvents: stationEvents,
            approachNotificationSent: true,
            backendSessionID: nil,
            serviceMatchConfidence: scenario == .offCourse ? 0.55 : 0.98,
            unexpectedStation: nil,
            unexpectedStationObservedAt: nil,
            serviceDepartedStationCRS: recordedDestination.crs,
            serviceDepartedStationAt: completedAt,
            updatedAt: completedAt
        )
        return JourneyHistoryRecord(
            checkpoint: checkpoint,
            outcome: scenario.outcome,
            completedAt: completedAt
        )
    }

    private static func callingPoints(
        route: ResolvedRoute,
        scenario: Scenario,
        departureAt: Date,
        plannedDestinationIndex: Int
    ) -> [JourneyHistoryCallingPoint] {
        let cancellationIndex = max(1, plannedDestinationIndex / 2)
        return route.template.stops.enumerated().map { index, stop in
            let scheduledDate = departureAt.addingTimeInterval(Double(stop.offsetMinutes * 60))
            let scheduledTime = clockString(scheduledDate)
            if scenario == .cancelled, index >= cancellationIndex {
                return JourneyHistoryCallingPoint(
                    locationName: route.stations[index].name,
                    crs: stop.crs,
                    scheduledTime: scheduledTime,
                    estimatedTime: "Cancelled",
                    actualTime: "Cancelled"
                )
            }
            let delayedTime = scheduledDate.addingTimeInterval(Double(scenario.delayMinutes * 60))
            let actualTime: String?
            if scenario == .officialArrivalUnavailable, index == plannedDestinationIndex {
                actualTime = nil
            } else if scenario.delayMinutes == 0 {
                actualTime = "On time"
            } else {
                actualTime = clockString(delayedTime)
            }
            return JourneyHistoryCallingPoint(
                locationName: route.stations[index].name,
                crs: stop.crs,
                scheduledTime: scheduledTime,
                estimatedTime: scenario.delayMinutes == 0 ? "On time" : clockString(delayedTime),
                actualTime: actualTime
            )
        }
    }

    private static func callingPoints(
        template: RouteTemplate,
        stations: [Station],
        departureAt: Date,
        delayMinutes: Int
    ) -> [JourneyHistoryCallingPoint] {
        template.stops.enumerated().map { index, stop in
            let scheduledDate = departureAt.addingTimeInterval(Double(stop.offsetMinutes * 60))
            let actualDate = scheduledDate.addingTimeInterval(Double(delayMinutes * 60))
            return JourneyHistoryCallingPoint(
                locationName: stations[index].name,
                crs: stop.crs,
                scheduledTime: clockString(scheduledDate),
                estimatedTime: delayMinutes == 0 ? "On time" : clockString(actualDate),
                actualTime: delayMinutes == 0 ? "On time" : clockString(actualDate)
            )
        }
    }

    private static func clockString(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private static let routeTemplates: [RouteTemplate] = [
        RouteTemplate(
            key: "VIC-ORP",
            operatorName: "Southeastern",
            operatorCode: "SE",
            stops: [
                ("VIC", 0), ("BRX", 7), ("HNH", 9), ("WDU", 12), ("SYH", 15),
                ("PNE", 18), ("KTH", 20), ("BKJ", 23), ("SRT", 26), ("BMS", 29),
                ("BKL", 33), ("PET", 36), ("ORP", 40)
            ]
        ),
        RouteTemplate(
            key: "LBG-BTN",
            operatorName: "Southern",
            operatorCode: "SN",
            stops: [("LBG", 0), ("ECR", 14), ("GTW", 29), ("HHE", 41), ("BTN", 58)]
        ),
        RouteTemplate(
            key: "KGX-CBG",
            operatorName: "Great Northern",
            operatorCode: "GN",
            stops: [
                ("KGX", 0), ("FPK", 7), ("SVG", 27), ("HIT", 33), ("RYS", 49), ("CBG", 65)
            ]
        ),
        RouteTemplate(
            key: "EUS-BHM",
            operatorName: "Avanti West Coast",
            operatorCode: "VT",
            stops: [("EUS", 0), ("MKC", 32), ("RUG", 54), ("COV", 66), ("BHI", 76), ("BHM", 88)]
        ),
        RouteTemplate(
            key: "EDB-GLQ",
            operatorName: "ScotRail",
            operatorCode: "SR",
            stops: [
                ("EDB", 0), ("HYM", 4), ("LIN", 20), ("PMT", 26), ("FKK", 32),
                ("CRO", 40), ("GLQ", 51)
            ]
        ),
        RouteTemplate(
            key: "MAN-LIV",
            operatorName: "TransPennine Express",
            operatorCode: "TP",
            stops: [("MAN", 0), ("MCO", 3), ("WAC", 26), ("LPY", 43), ("LIV", 52)]
        )
    ]

    private static let itineraryTemplates: [ItineraryTemplate] = [
        ItineraryTemplate(
            key: "KTH-ZFD",
            legs: [
                RouteTemplate(
                    key: "KTH-HNH",
                    operatorName: "Southeastern",
                    operatorCode: "SE",
                    stops: [("KTH", 0), ("PNE", 2), ("SYH", 5), ("WDU", 8), ("HNH", 11)]
                ),
                RouteTemplate(
                    key: "HNH-ZFD",
                    operatorName: "Thameslink",
                    operatorCode: "TL",
                    stops: [("HNH", 0), ("LGJ", 4), ("EPH", 8), ("BFR", 12), ("CTK", 14), ("ZFD", 17)]
                )
            ]
        ),
        ItineraryTemplate(
            key: "VIC-WAT",
            legs: [
                RouteTemplate(
                    key: "VIC-CLJ",
                    operatorName: "Southern",
                    operatorCode: "SN",
                    stops: [("VIC", 0), ("BAK", 4), ("CLJ", 7)]
                ),
                RouteTemplate(
                    key: "CLJ-WAT",
                    operatorName: "South Western Railway",
                    operatorCode: "SW",
                    stops: [("CLJ", 0), ("VXH", 5), ("WAT", 9)]
                )
            ]
        ),
        ItineraryTemplate(
            key: "ECR-CHX",
            legs: [
                RouteTemplate(
                    key: "ECR-LBG",
                    operatorName: "Thameslink",
                    operatorCode: "TL",
                    stops: [("ECR", 0), ("NWD", 5), ("LBG", 14)]
                ),
                RouteTemplate(
                    key: "LBG-CHX",
                    operatorName: "Southeastern",
                    operatorCode: "SE",
                    stops: [("LBG", 0), ("WAE", 3), ("CHX", 7)]
                )
            ]
        ),
        ItineraryTemplate(
            key: "KTH-PAD",
            legs: [
                RouteTemplate(
                    key: "KTH-HNH",
                    operatorName: "Southeastern",
                    operatorCode: "SE",
                    stops: [("KTH", 0), ("PNE", 2), ("SYH", 5), ("WDU", 8), ("HNH", 11)]
                ),
                RouteTemplate(
                    key: "HNH-ZFD",
                    operatorName: "Thameslink",
                    operatorCode: "TL",
                    stops: [("HNH", 0), ("LGJ", 4), ("EPH", 8), ("BFR", 12), ("CTK", 14), ("ZFD", 17)]
                ),
                RouteTemplate(
                    key: "ZFD-PAD",
                    operatorName: "Elizabeth line",
                    operatorCode: "XR",
                    stops: [("ZFD", 0), ("BDS", 4), ("PAD", 8)]
                )
            ]
        )
    ]
}
#endif
