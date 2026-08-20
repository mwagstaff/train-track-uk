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

    // Navigation paths for each tab to enable programmatic pop-to-root
    @State private var favouritesPath = NavigationPath()
    @State private var myJourneysPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var tabSelectionFeedbackTrigger = 0
    @State private var horizontalSwipeDisabledTabs: Set<Tab> = []

    private let visibleTabs: [Tab] = [.favourites, .myJourneys, .history, .profile]

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
                .horizontalTabSwipeDisabled(horizontalSwipeDisabledBinding(for: .favourites))
                .tabItem { Label("Favourites", systemImage: "heart.fill") }
                .tag(Tab.favourites)

            NavigationStack(path: $myJourneysPath) { MyJourneysView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .horizontalTabSwipeDisabled(horizontalSwipeDisabledBinding(for: .myJourneys))
                .tabItem { Label("My Journeys", systemImage: "list.bullet") }
                .tag(Tab.myJourneys)

            NavigationStack(path: $historyPath) { MyJourneyHistoryView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .horizontalTabSwipeDisabled(horizontalSwipeDisabledBinding(for: .history))
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)

            NavigationStack(path: $profilePath) { ProfileView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
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
        }
        .onChange(of: router.selected) { _, newTab in
            // Remember the last tab that isn't Add Journey so we can return there
            if newTab != .addJourney { router.lastNonAddTab = newTab }
        }
        .onChange(of: router.navigationResetTrigger) {
            // Pop all navigation stacks to root when triggered
            favouritesPath = NavigationPath()
            myJourneysPath = NavigationPath()
            historyPath = NavigationPath()
            profilePath = NavigationPath()
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
