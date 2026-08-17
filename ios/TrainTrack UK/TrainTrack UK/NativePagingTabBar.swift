import SwiftUI
import UIKit

private let visibleTabs: [Tab] = [.favourites, .myJourneys, .history, .profile]

/// Keeps the system tab-bar appearance and accessibility while the content uses
/// SwiftUI's native horizontal page interaction.
struct NativePagingTabBar: UIViewRepresentable {
    @Binding var selection: Tab

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeUIView(context: Context) -> UITabBar {
        let tabBar = UITabBar()
        tabBar.delegate = context.coordinator
        tabBar.items = visibleTabs.enumerated().map { index, tab in
            let item = UITabBarItem(
                title: tab.title,
                image: UIImage(systemName: tab.systemImage),
                tag: index
            )
            item.accessibilityIdentifier = "tab.\(tab.accessibilityIdentifier)"
            return item
        }
        updateSelection(in: tabBar)
        return tabBar
    }

    func updateUIView(_ tabBar: UITabBar, context: Context) {
        context.coordinator.selection = $selection
        updateSelection(in: tabBar)
    }

    private func updateSelection(in tabBar: UITabBar) {
        guard let index = visibleTabs.firstIndex(of: selection),
              tabBar.items?.indices.contains(index) == true else {
            return
        }
        tabBar.selectedItem = tabBar.items?[index]
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        var selection: Binding<Tab>

        init(selection: Binding<Tab>) {
            self.selection = selection
        }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            guard visibleTabs.indices.contains(item.tag) else { return }
            selection.wrappedValue = visibleTabs[item.tag]
        }
    }
}

private extension Tab {
    var accessibilityIdentifier: String {
        switch self {
        case .favourites: "favourites"
        case .myJourneys: "my-journeys"
        case .addJourney: "add-journey"
        case .history: "history"
        case .profile: "profile"
        }
    }
}
