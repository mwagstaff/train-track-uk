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
    @State private var addJourneyPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var pageCommitFeedbackTrigger = 0

    private var pagingSelection: Binding<Tab> {
        Binding(
            get: { router.selected },
            set: { newTab in
                guard newTab != router.selected else { return }
                router.selected = newTab
                pageCommitFeedbackTrigger += 1
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

            NavigationStack(path: $addJourneyPath) { AddJourneyView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .tag(Tab.addJourney)

            NavigationStack(path: $profilePath) { ProfileView() }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .tag(Tab.profile)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NativePagingTabBar(selection: $router.selected)
                .frame(height: 49)
        }
        .sensoryFeedback(.selection, trigger: pageCommitFeedbackTrigger)
        .animation(.easeOut(duration: 0.25), value: toastStore.toast)
        .onAppear {
            // Ensure polling starts even if App.onAppear wasn't fired
            depStore.startPolling(journeyStore: journeyStore)
        }
        .onChange(of: router.selected) { newTab in
            // Remember the last tab that isn't Add Journey so we can return there
            if newTab != .addJourney { router.lastNonAddTab = newTab }
        }
        .onChange(of: router.navigationResetTrigger) { _ in
            // Pop all navigation stacks to root when triggered
            favouritesPath = NavigationPath()
            myJourneysPath = NavigationPath()
            addJourneyPath = NavigationPath()
            profilePath = NavigationPath()
        }
    }
}

#Preview {
    ContentView()
}
