import Foundation
import Combine

enum Tab: Hashable {
    case favourites
    case myJourneys
    case addJourney
    case profile
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

    func resetToFavourites() {
        selected = .favourites
        navigationResetTrigger += 1
    }
}
