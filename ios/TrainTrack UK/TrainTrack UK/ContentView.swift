//
//  ContentView.swift
//  TrainTrackUK
//
//  Created by Mike Wagstaff on 03/11/2025.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var router: TabRouter
    @EnvironmentObject var journeyStore: JourneyStore
    @EnvironmentObject var depStore: DeparturesStore
    @EnvironmentObject var toastStore: ToastStore
    @EnvironmentObject var deepLink: DeepLinkRouter
    @ObservedObject private var trackingCoordinator = JourneyTrackingCoordinator.shared

    // Navigation paths for each tab to enable programmatic pop-to-root
    @State private var favouritesPath = NavigationPath()
    @State private var myJourneysPath = NavigationPath()
    @State private var inProgressPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var tabSelectionFeedbackTrigger = 0
    @State private var horizontalSwipeDisabledTabs: Set<Tab> = []

    private var hasInProgressTab: Bool {
        trackingCoordinator.hasPresentableJourney
    }

    private var showsInProgressBadge: Bool {
        trackingCoordinator.recentlyCompleted == nil
            && (trackingCoordinator.activeJourney != nil || !trackingCoordinator.armedCandidates.isEmpty)
    }

    private var visibleTabs: [Tab] {
        hasInProgressTab
            ? [.favourites, .myJourneys, .inProgress, .history, .profile]
            : [.favourites, .myJourneys, .history, .profile]
    }

    private var tabSelection: Binding<Tab> {
        Binding(
            get: {
                router.selected == .addJourney
                    ? router.lastNonAddTab
                    : router.selected
            },
            set: { newTab in
                guard newTab != router.selected else { return }
                router.selected = newTab
                tabSelectionFeedbackTrigger += 1
            }
        )
    }

    private var addJourneyPresented: Binding<Bool> {
        Binding(
            get: { router.selected == .addJourney },
            set: { isPresented in
                guard !isPresented, router.selected == .addJourney else { return }
                router.selected = router.lastNonAddTab
            }
        )
    }

    private var isHorizontalTabSwipeEnabled: Bool {
        let selectedTab = router.selected == .addJourney
            ? router.lastNonAddTab
            : router.selected
        return !horizontalSwipeDisabledTabs.contains(selectedTab)
    }

    private func horizontalSwipeDisabledBinding(for tab: Tab) -> Binding<Bool> {
        Binding(
            get: { horizontalSwipeDisabledTabs.contains(tab) },
            set: { isDisabled in
                if isDisabled {
                    horizontalSwipeDisabledTabs.insert(tab)
                } else {
                    horizontalSwipeDisabledTabs.remove(tab)
                }
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            NavigationStack(path: $favouritesPath) { FavouritesView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .horizontalTabSwipePage(.favourites)
                .horizontalTabSwipeDisabled(horizontalSwipeDisabledBinding(for: .favourites))
                .tabItem { Label("Favourites", systemImage: "heart.fill") }
                .tag(Tab.favourites)

            NavigationStack(path: $myJourneysPath) { MyJourneysView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .horizontalTabSwipePage(.myJourneys)
                .horizontalTabSwipeDisabled(horizontalSwipeDisabledBinding(for: .myJourneys))
                .tabItem { Label("My Journeys", systemImage: "list.bullet") }
                .tag(Tab.myJourneys)

            if hasInProgressTab {
                NavigationStack(path: $inProgressPath) { InProgressJourneyView() }
                    .modifier(JourneyUpdatesChrome(includeToast: true))
                    .horizontalTabSwipePage(.inProgress)
                    .horizontalTabSwipeDisabled(horizontalSwipeDisabledBinding(for: .inProgress))
                    .tabItem { Label("In Progress", systemImage: "location.fill") }
                    .modifier(InProgressBadgeModifier(isVisible: showsInProgressBadge))
                    .tag(Tab.inProgress)
            }

            NavigationStack(path: $historyPath) {
                MyJourneyHistoryView()
                    .navigationDestination(for: JourneyHistoryNavigationTarget.self) { target in
                        JourneyHistoryRecordDestination(recordID: target.recordID)
                    }
            }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .horizontalTabSwipePage(.history)
                .horizontalTabSwipeDisabled(horizontalSwipeDisabledBinding(for: .history))
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)

            NavigationStack(path: $profilePath) { ProfileView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .horizontalTabSwipePage(.profile)
                .horizontalTabSwipeDisabled(horizontalSwipeDisabledBinding(for: .profile))
                .tabItem { Label("Profile", systemImage: "person.circle") }
                .tag(Tab.profile)
        }
        .horizontalTabSwipe(
            selection: tabSelection,
            tabs: visibleTabs,
            isEnabled: isHorizontalTabSwipeEnabled
        )
        .fullScreenCover(isPresented: addJourneyPresented) {
            NavigationStack { AddJourneyView() }
        }
        .fullScreenCover(item: $deepLink.routeMapDestination) { destination in
            JourneyRouteMapDeepLinkView(destination: destination)
        }
        .sensoryFeedback(.selection, trigger: tabSelectionFeedbackTrigger)
        .animation(.easeOut(duration: 0.25), value: toastStore.toast)
        .onAppear {
            // Ensure polling starts even if App.onAppear wasn't fired
            depStore.startPolling(journeyStore: journeyStore)
            trackingCoordinator.pruneExpiredCompletion()
        }
        .onChange(of: router.selected) { _, newTab in
            // Remember the last tab that isn't Add Journey so we can return there
            if newTab != .addJourney { router.lastNonAddTab = newTab }
        }
        .onChange(of: router.navigationResetTrigger) {
            // Pop all navigation stacks to root when triggered
            favouritesPath = NavigationPath()
            myJourneysPath = NavigationPath()
            inProgressPath = NavigationPath()
            historyPath = NavigationPath()
            profilePath = NavigationPath()
        }
        .onChange(of: router.historyTarget) { _, target in
            guard let target else { return }
            historyPath = NavigationPath()
            historyPath.append(target)
        }
        .onChange(of: hasInProgressTab) { _, isVisible in
            if !isVisible, router.selected == .inProgress {
                router.selected = .history
            }
        }
    }
}

private struct InProgressBadgeModifier: ViewModifier {
    let isVisible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isVisible {
            content.badge("•")
        } else {
            content
        }
    }
}

private struct JourneyRouteMapDeepLinkView: View {
    let destination: JourneyRouteMapDestination
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ServiceMapView(
                serviceID: destination.serviceID,
                fromCRS: destination.fromCRS,
                toCRS: destination.toCRS,
                departureTime: destination.departureTime,
                destinationName: destination.destinationName,
                fallbackCallingPoints: destination.fallbackCallingPoints
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
