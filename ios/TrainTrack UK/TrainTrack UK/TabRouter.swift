import Foundation
import Combine

enum Tab: Hashable, CaseIterable {
    case favourites
    case myJourneys
    case inProgress
    case addJourney
    case history
    case profile

    var title: String {
        switch self {
        case .favourites: "Favourites"
        case .myJourneys: "My Journeys"
        case .inProgress: "In Progress"
        case .addJourney: "Add Journey"
        case .history: "History"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .favourites: "heart.fill"
        case .myJourneys: "list.bullet"
        case .inProgress: "location.fill"
        case .addJourney: "plus.circle"
        case .history: "clock.arrow.circlepath"
        case .profile: "person.circle"
        }
    }
}

struct JourneyHistoryNavigationTarget: Hashable {
    let recordID: UUID
    private let requestID = UUID()
}

final class TabRouter: ObservableObject {
    static let shared = TabRouter()

    @Published var selected: Tab = .favourites
    // Track the most recent non-Add tab so we can return on cancel
    @Published var lastNonAddTab: Tab = .favourites
    // Navigation path reset trigger - increment to pop to root
    @Published var navigationResetTrigger: Int = 0
    // One-shot preference when opening Add Journey from favourites
    @Published var addJourneyPrefillFavourite: Bool = false
    @Published var historyTarget: JourneyHistoryNavigationTarget?

    func resetToFavourites() {
        selected = .favourites
        navigationResetTrigger += 1
    }

    func openHistoryRecord(id: UUID) {
        historyTarget = JourneyHistoryNavigationTarget(recordID: id)
        selected = .history
    }
}
