import Foundation
import SwiftUI
import Combine
import UIKit

@MainActor
final class DeepLinkRouter: ObservableObject {
    @Published var pendingJourneyGroup: JourneyGroup? = nil

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
        guard let from, let to else { return }

        Task { await openJourney(from: from, to: to) }
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

    private func openJourney(from: String, to: String) async {
        if StationsService.shared.stations.isEmpty { await ensureStations() }
        if let group = findOrCreateJourneyGroup(from: from, to: to) {
            pendingJourneyGroup = group
        }
    }
}
