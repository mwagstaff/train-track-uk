#if (DEBUG || APP_STORE_CAPTURE) && targetEnvironment(simulator)
import Foundation

/// Opt-in data for the dedicated App Store screenshot simulators. Never compiled into device releases.
@MainActor
enum AppStoreScreenshotFixture {
    private static var prepared = false

    static func prepareIfRequested() async {
        guard !prepared,
              let screen = ProcessInfo.processInfo.environment["RELEASE_SCREENSHOT_SCREEN"] else { return }
        prepared = true
        do {
            try await StationsService.shared.loadStations()
            let allStations = StationsService.shared.stations
            func stations(_ codes: [String]) -> [Station] {
                codes.compactMap { code in allStations.first { $0.crs == code } }
            }
            let store = JourneyStore.shared
            let routes: [([String], Bool)] = [
                (["ECR", "GTW"], true),
                (["GTW", "ECR"], true),
                (["CLK", "LBG"], false),
                (["KTH", "HNH", "ZFD"], false)
            ]
            for group in store.journeyGroups() {
                if !routes.contains(where: { $0.0 == group.stationSequence.map(\.crs) }) {
                    store.remove(group: group)
                }
            }
            for (codes, favourite) in routes {
                let route = stations(codes)
                guard route.count == codes.count else { continue }
                store.addJourneyGroup(stations: route, favorite: favourite, saveReturn: false)
            }

            let history = JourneyHistoryStore.shared
            let sampleID = UUID(uuidString: "05092026-0000-0000-0000-000000000001")!
            let statsIDs = (2...9).compactMap {
                UUID(uuidString: String(format: "05092026-0000-0000-0000-%012d", $0))
            }
            for record in history.records {
                history.delete(record)
            }
            let clockHouseRoute = stations(["CLK", "LBG"])
            if clockHouseRoute.count == 2 {
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                let departure = Calendar.current.date(bySettingHour: 8, minute: 5, second: 0, of: yesterday)!
                addHistoryRecord(
                    id: sampleID, route: clockHouseRoute, departure: departure,
                    durationMinutes: 25, delayMinutes: 20, to: history
                )
            }
            if screen == "journey-stats" {
                let gatwickRoute = stations(["ECR", "GTW"])
                let samples: [(daysAgo: Int, hour: Int, delay: Int, usesGatwickRoute: Bool)] = [
                    (2, 17, 0, true), (4, 8, 3, false), (6, 18, 8, true),
                    (9, 7, 0, false), (12, 16, 14, true), (16, 9, 5, false),
                    (21, 18, 0, true), (27, 8, 9, false)
                ]
                for (index, sample) in samples.enumerated() {
                    let route = sample.usesGatwickRoute ? gatwickRoute : clockHouseRoute
                    guard route.count == 2,
                          let day = Calendar.current.date(byAdding: .day, value: -sample.daysAgo, to: Date()),
                          let departure = Calendar.current.date(
                            bySettingHour: sample.hour, minute: 5, second: 0, of: day
                          ) else { continue }
                    addHistoryRecord(
                        id: statsIDs[index], route: route, departure: departure,
                        durationMinutes: sample.usesGatwickRoute ? 23 : 25,
                        delayMinutes: sample.delay, to: history
                    )
                }
            }

            switch screen {
            case "favourites": TabRouter.shared.selected = .favourites
            case "history": TabRouter.shared.selected = .history
            case "journey-stats": TabRouter.shared.selected = .history
            case "in-progress", "route-map":
                let route = stations(["ECR", "GTW"])
                if route.count == 2 {
                    JourneyTrackingCoordinator.shared.installScreenshotCheckpoint(checkpoint(
                        id: UUID(), route: route,
                        departure: Date().addingTimeInterval(-8 * 60),
                        durationMinutes: 23, delayMinutes: 0, completed: false
                    ))
                    if let checkpoint = JourneyTrackingCoordinator.shared.activeJourney,
                       let leg = checkpoint.currentLeg {
                        let point = leg.callingPoints.last!
                        let details = ServiceDetails(
                            previousCallingPoints: nil,
                            subsequentCallingPoints: [CallingPointList(callingPoint: [CallingPoint(
                                locationName: point.locationName, crs: point.crs,
                                st: point.scheduledTime, et: "On time", at: nil,
                                isCancelled: false, cancelReason: nil, platform: "3", length: 12,
                                detachFront: nil, affectedByDiversion: nil, rerouteDelay: nil
                            )], serviceType: "train", serviceChangeRequired: false, assocIsCancelled: false)],
                            generatedAt: ISO8601DateFormatter().string(from: Date()),
                            serviceType: "train", locationName: route[0].name, crs: route[0].crs,
                            operator: "Thameslink", operatorCode: "TL", isCancelled: false,
                            length: 12, detachFront: nil, isReverseFormation: nil, platform: "6",
                            sta: nil, eta: nil, ata: nil,
                            std: leg.callingPoints.first?.scheduledTime, etd: "On time",
                            atd: leg.callingPoints.first?.actualTime,
                            delayReason: nil, cancelReason: nil
                        )
                        DeparturesStore.shared.installScreenshotServiceDetails(details, serviceID: leg.serviceID!)
                    }
                    try await Task.sleep(for: .milliseconds(300))
                    TabRouter.shared.selected = .inProgress
                    if screen == "route-map" {
                        DeepLinkRouter.shared.routeMapDestination = JourneyRouteMapDestination(
                            checkpoint: JourneyTrackingCoordinator.shared.activeJourney,
                            fromCRS: "ECR", toCRS: "GTW"
                        )
                    }
                }
            case "bus-route-map":
                let route = stations(["ECR", "NWD", "ANZ", "PNW", "SYD", "FOH", "HPA", "NXG", "LBG"])
                if route.count == 9 {
                    JourneyTrackingCoordinator.shared.installScreenshotCheckpoint(checkpoint(
                        id: UUID(), route: route,
                        departure: Date().addingTimeInterval(-8 * 60),
                        durationMinutes: 36, delayMinutes: 0, completed: false
                    ))
                    if let checkpoint = JourneyTrackingCoordinator.shared.activeJourney,
                       let leg = checkpoint.currentLeg,
                       let serviceID = leg.serviceID,
                       let current = leg.callingPoints.first {
                        let subsequent = leg.callingPoints.dropFirst().map { point in
                            CallingPoint(
                                locationName: point.locationName, crs: point.crs,
                                st: point.scheduledTime, et: point.estimatedTime, at: point.actualTime,
                                isCancelled: false, cancelReason: nil, platform: nil, length: nil,
                                detachFront: nil, affectedByDiversion: nil, rerouteDelay: nil
                            )
                        }
                        let details = ServiceDetails(
                            previousCallingPoints: nil,
                            subsequentCallingPoints: [CallingPointList(
                                callingPoint: subsequent,
                                serviceType: "bus",
                                serviceChangeRequired: false,
                                assocIsCancelled: false
                            )],
                            generatedAt: ISO8601DateFormatter().string(from: Date()),
                            serviceType: "bus", locationName: current.locationName, crs: current.crs,
                            operator: "Rail replacement", operatorCode: "BUS", isCancelled: false,
                            length: nil, detachFront: nil, isReverseFormation: nil, platform: nil,
                            sta: nil, eta: nil, ata: nil,
                            std: current.scheduledTime, etd: "On time", atd: current.actualTime,
                            delayReason: nil, cancelReason: nil
                        )
                        DeparturesStore.shared.installScreenshotServiceDetails(details, serviceID: serviceID)
                        try await Task.sleep(for: .milliseconds(300))
                        TabRouter.shared.selected = .inProgress
                        DeepLinkRouter.shared.routeMapDestination = JourneyRouteMapDestination(
                            checkpoint: checkpoint,
                            fromCRS: route.first!.crs,
                            toCRS: route.last!.crs
                        )
                    }
                }
            default: TabRouter.shared.selected = .myJourneys
            }
        } catch {
            debugLog("Screenshot fixture failed: \(error)")
        }
    }

    private static func addHistoryRecord(
        id: UUID,
        route: [Station],
        departure: Date,
        durationMinutes: Int,
        delayMinutes: Int,
        to history: JourneyHistoryStore
    ) {
        let value = checkpoint(
            id: id, route: route, departure: departure,
            durationMinutes: durationMinutes, delayMinutes: delayMinutes, completed: true
        )
        history.add(JourneyHistoryRecord(
            checkpoint: value, outcome: .completed,
            completedAt: value.detectedArrivalAt!
        ))
    }

    private static func checkpoint(
        id: UUID, route: [Station], departure: Date,
        durationMinutes: Int, delayMinutes: Int, completed: Bool
    ) -> ActiveJourneyHistoryCheckpoint {
        let scheduledArrival = departure.addingTimeInterval(Double(durationMinutes * 60))
        let arrival = scheduledArrival.addingTimeInterval(Double(delayMinutes * 60))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let legDuration = max(durationMinutes, route.count - 1)
        let points = route.enumerated().map { index, station in
            let progress = route.count > 1 ? Double(index) / Double(route.count - 1) : 0
            let scheduledTime = departure.addingTimeInterval(Double(legDuration * 60) * progress)
            let estimatedTime = scheduledTime.addingTimeInterval(Double(delayMinutes * 60))
            return JourneyHistoryCallingPoint(
                locationName: station.name,
                crs: station.crs,
                scheduledTime: formatter.string(from: scheduledTime),
                estimatedTime: index == 0 ? "On time" : formatter.string(from: estimatedTime),
                actualTime: index == 0
                    ? formatter.string(from: departure)
                    : (completed ? formatter.string(from: estimatedTime) : nil)
            )
        }
        let leg = JourneyHistoryLeg(
            plannedLegIndex: 0, fromStation: route[0], toStation: route[route.count - 1],
            serviceID: completed ? nil : "SCREENSHOT-ECR-GTW",
            operatorName: route[0].crs == "CLK" ? "Southeastern" : "Thameslink",
            operatorCode: route[0].crs == "CLK" ? "SE" : "TL",
            callingPoints: points, serviceCallingPoints: points,
            detectedDepartureAt: departure, detectedArrivalAt: completed ? arrival : nil,
            scheduledDepartureAt: departure, estimatedDepartureTime: "On time",
            actualDepartureAt: departure, scheduledArrivalAt: scheduledArrival,
            actualArrivalAt: completed ? arrival : nil,
            outcome: completed ? .completed : .active
        )
        return ActiveJourneyHistoryCheckpoint(
            id: id, subscriptionId: "debug-journey-simulation", source: .adhoc,
            plannedStations: route, createdAt: departure, phase: completed ? .arriving : .inTransit,
            plannedLegIndex: 0, originArrivedAt: departure.addingTimeInterval(-120),
            detectedDepartureAt: departure, detectedArrivalAt: completed ? arrival : nil,
            lastConfirmedOnRouteStation: completed ? route[1] : route[0],
            nextExpectedCallingPointIndex: 1, legs: [leg], stationEvents: [],
            approachNotificationSent: completed, backendSessionID: nil,
            serviceMatchConfidence: 1, unexpectedStation: nil, unexpectedStationObservedAt: nil,
            serviceDepartedStationCRS: route[0].crs, serviceDepartedStationAt: departure,
            updatedAt: completed ? arrival : Date()
        )
    }
}
#endif
