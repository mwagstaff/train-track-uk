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

    // Navigation paths for each tab to enable programmatic pop-to-root
    @State private var favouritesPath = NavigationPath()
    @State private var myJourneysPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var pageCommitFeedbackTrigger = 0

    private var pagingSelection: Binding<Tab> {
        Binding(
            get: {
                router.selected == .addJourney
                    ? router.lastNonAddTab
                    : router.selected
            },
            set: { newTab in
                guard newTab != router.selected else { return }
                router.selected = newTab
                pageCommitFeedbackTrigger += 1
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

    var body: some View {
        TabView(selection: pagingSelection) {
            NavigationStack(path: $favouritesPath) { FavouritesView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .tag(Tab.favourites)

            NavigationStack(path: $myJourneysPath) { MyJourneysView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .tag(Tab.myJourneys)

            NavigationStack(path: $historyPath) { MyJourneyHistoryView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .tag(Tab.history)

            NavigationStack(path: $profilePath) { ProfileView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .tag(Tab.profile)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if router.selected != .addJourney {
                NativePagingTabBar(selection: $router.selected)
                    .frame(height: 49)
            }
        }
        .fullScreenCover(isPresented: addJourneyPresented) {
            NavigationStack { AddJourneyView() }
        }
        .sensoryFeedback(.selection, trigger: pageCommitFeedbackTrigger)
        .animation(.easeOut(duration: 0.25), value: toastStore.toast)
        .onAppear {
            // Ensure polling starts even if App.onAppear wasn't fired
            depStore.startPolling(journeyStore: journeyStore)
        }
        .task(id: depStore.isInitialLoadInProgress, priority: .utility) {
            guard !depStore.isInitialLoadInProgress,
                  !journeyStore.journeys.isEmpty,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(1))
                try await RailwayRoutingService.shared.prepare()
            } catch {
                // Pre-warming is opportunistic; route loading reports real failures on demand.
            }
        }
        .onChange(of: router.selected) { newTab in
            // Remember the last tab that isn't Add Journey so we can return there
            if newTab != .addJourney { router.lastNonAddTab = newTab }
        }
        .onChange(of: router.navigationResetTrigger) { _ in
            // Pop all navigation stacks to root when triggered
            favouritesPath = NavigationPath()
            myJourneysPath = NavigationPath()
            historyPath = NavigationPath()
            profilePath = NavigationPath()
        }
    }
}

#Preview {
    ContentView()
}
