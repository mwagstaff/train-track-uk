import Foundation
import SwiftUI
import Combine
import UIKit

@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    @Published var pendingJourneyGroup: JourneyGroup? = nil
    @Published private(set) var pendingJourneyActivation: JourneyActivationRequest? = nil
    @Published private(set) var visibleJourneyRoute: JourneyRouteIdentity? = nil

    func handle(url: URL) {
        guard url.scheme == "traintrack" else { return }
        let host = url.host?.lowercased()

        // Handle refresh-live-activity deep link
        if host == "refresh-live-activity" {
            Task {
                print("🔄 [DeepLink] Refreshing Live Activity from deep link")

                // Provide haptic feedback to confirm the tap
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()

                await LiveActivityManager.shared.refreshIfActive(
                    journeyStore: JourneyStore.shared,
                    depStore: DeparturesStore.shared
                )

                print("✅ [DeepLink] Refresh complete")
            }
            return
        }

        // Supported: traintrack://journey?from=VIC&to=KTH
        guard host == "journey" else { return }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let from = comps?.queryItems?.first(where: { $0.name == "from" })?.value
        let to = comps?.queryItems?.first(where: { $0.name == "to" })?.value
        let activateUpdates = comps?.queryItems?.first(where: { $0.name == "activate_updates" })?.value == "1"
        guard let from, let to else { return }

        Task { await openJourney(from: from, to: to, activateUpdates: activateUpdates) }
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

    func openJourney(from: String, to: String, activateUpdates: Bool = false) async {
        if StationsService.shared.stations.isEmpty { await ensureStations() }
        if let group = findOrCreateJourneyGroup(from: from, to: to) {
            pendingJourneyGroup = group
            pendingJourneyActivation = activateUpdates
                ? JourneyActivationRequest(from: from, to: to)
                : nil
        }
    }

    func consumeJourneyActivationIfNeeded(for group: JourneyGroup) -> JourneyActivationRequest? {
        guard let activation = pendingJourneyActivation else { return nil }
        let start = group.startStation.crs.uppercased()
        let end = group.endStation.crs.uppercased()
        guard activation.fromCRS == start, activation.toCRS == end else { return nil }
        pendingJourneyActivation = nil
        return activation
    }

    func setVisibleJourney(_ group: JourneyGroup) {
        visibleJourneyRoute = JourneyRouteIdentity(group: group)
    }

    func clearVisibleJourney(_ group: JourneyGroup) {
        let route = JourneyRouteIdentity(group: group)
        if visibleJourneyRoute == route {
            visibleJourneyRoute = nil
        }
    }
}

struct JourneyActivationRequest: Equatable {
    let fromCRS: String
    let toCRS: String

    init(from: String, to: String) {
        self.fromCRS = from.uppercased()
        self.toCRS = to.uppercased()
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
