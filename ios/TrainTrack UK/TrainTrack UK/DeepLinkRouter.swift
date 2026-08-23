import Foundation
import SwiftUI
import Combine
import UIKit

@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    @Published var routeMapDestination: JourneyRouteMapDestination?

    func handle(url: URL) {
        guard url.scheme == "traintrack" else { return }
        let host = url.host?.lowercased()

        // Handle refresh-live-activity deep link
        if host == "refresh-live-activity" {
            Task {
                debugLog("🔄 [DeepLink] Refreshing Live Activity from deep link")

                // Provide haptic feedback to confirm the tap
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()

                await LiveActivityManager.shared.refreshIfActive(
                    journeyStore: JourneyStore.shared,
                    depStore: DeparturesStore.shared
                )

                debugLog("✅ [DeepLink] Refresh complete")
            }
            return
        }

        if host == "history" {
            openHistory()
            return
        }

        if host == "in-progress" {
            openInProgress()
            return
        }

        // Supported: traintrack://journey?from=VIC&to=KTH
        //            traintrack://journey-route?from=VIC&to=KTH
        //            traintrack://in-progress
        //            traintrack://history
        guard host == "journey" || host == "journey-route" else { return }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let from = comps?.queryItems?.first(where: { $0.name == "from" })?.value
        let to = comps?.queryItems?.first(where: { $0.name == "to" })?.value
        let activateUpdates = comps?.queryItems?.first(where: { $0.name == "activate_updates" })?.value == "1"
        guard let from, let to else { return }

        Task {
            await openJourney(
                from: from,
                to: to,
                activateUpdates: activateUpdates,
                showRouteMap: host == "journey-route"
            )
        }
    }

    func openHistory() {
        routeMapDestination = nil
        TabRouter.shared.selected = .history
        TabRouter.shared.navigationResetTrigger += 1
    }

    func openInProgress() {
        routeMapDestination = nil
        TabRouter.shared.selected = .inProgress
        TabRouter.shared.navigationResetTrigger += 1
    }

    private func station(for crs: String) -> Station? {
        StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(crs) == .orderedSame })
    }

    private func findOrCreateJourneyGroup(from fromCRS: String, to toCRS: String) -> JourneyGroup? {
        if let existing = JourneyStore.shared.journeyGroups().first(where: { $0.startStation.crs == fromCRS && $0.endStation.crs == toCRS }) {
            return existing
        }
        guard let f = station(for: fromCRS), let t = station(for: toCRS) else { return nil }
        let leg = Journey(fromStation: f, toStation: t, favorite: false)
        return JourneyGroup(id: leg.groupId, legs: [leg])
    }

    private func ensureStations() async {
        do { try await StationsService.shared.loadStations() } catch { }
    }

    func openJourney(
        from: String,
        to: String,
        activateUpdates: Bool = false,
        showRouteMap: Bool = false
    ) async {
        if StationsService.shared.stations.isEmpty { await ensureStations() }
        if showRouteMap,
           let destination = JourneyRouteMapDestination(
               checkpoint: JourneyTrackingCoordinator.shared.activeJourney,
               fromCRS: from,
               toCRS: to
           ) {
            TabRouter.shared.selected = .myJourneys
            routeMapDestination = destination
            return
        }
        if let group = findOrCreateJourneyGroup(from: from, to: to) {
            TabRouter.shared.selected = group.favorite ? .favourites : .myJourneys
            if activateUpdates {
                let notificationStore = NotificationSubscriptionStore.shared
                _ = await JourneyUpdateActions.start(
                    group: group,
                    scheduledSubscription: notificationStore.subscription(
                        for: JourneyUpdateActions.scheduledRouteKey(for: group)
                    ),
                    liveSession: notificationStore.liveSession(
                        for: JourneyUpdateActions.liveSessionRouteKey(for: group)
                    ),
                    liveActivityDurationMinutes: UserDefaults.standard.object(
                        forKey: "liveActivityDurationMinutes"
                    ) as? Int ?? 60,
                    notificationStore: notificationStore,
                    activityManager: LiveActivityManager.shared,
                    departuresStore: DeparturesStore.shared
                )
            }
        }
    }

}

struct JourneyRouteMapDestination: Identifiable {
    let id = UUID()
    let serviceID: String
    let fromCRS: String
    let toCRS: String
    let departureTime: String
    let destinationName: String
    let fallbackCallingPoints: [CallingPoint]

    init?(checkpoint: ActiveJourneyHistoryCheckpoint?, fromCRS: String, toCRS: String) {
        guard let checkpoint,
              checkpoint.plannedOrigin.crs.caseInsensitiveCompare(fromCRS) == .orderedSame,
              checkpoint.plannedDestination.crs.caseInsensitiveCompare(toCRS) == .orderedSame,
              let leg = checkpoint.currentLeg,
              let serviceID = leg.serviceID else {
            return nil
        }
        self.serviceID = serviceID
        self.fromCRS = leg.fromStation.crs
        self.toCRS = leg.toStation.crs
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        let departureDate = leg.scheduledDepartureAt ?? leg.detectedDepartureAt ?? Date()
        self.departureTime = formatter.string(from: departureDate)
        self.destinationName = leg.toStation.name
        self.fallbackCallingPoints = leg.callingPoints.map {
            CallingPoint(
                locationName: $0.locationName,
                crs: $0.crs,
                st: $0.scheduledTime,
                et: $0.estimatedTime,
                at: $0.actualTime,
                isCancelled: nil,
                cancelReason: nil,
                platform: nil,
                length: nil,
                detachFront: nil,
                affectedByDiversion: nil,
                rerouteDelay: nil
            )
        }
    }
}

struct JourneyRouteIdentity: Equatable {
    let fromCRS: String
    let toCRS: String

    init(from: String, to: String) {
        self.fromCRS = from.uppercased()
        self.toCRS = to.uppercased()
    }

    init(group: JourneyGroup) {
        self.init(from: group.startStation.crs, to: group.endStation.crs)
    }
}
