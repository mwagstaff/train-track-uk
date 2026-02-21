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
    @EnvironmentObject var deepLink: DeepLinkRouter
    @EnvironmentObject var toastStore: ToastStore

    // Navigation paths for each tab to enable programmatic pop-to-root
    @State private var pinnedPath = NavigationPath()
    @State private var favouritesPath = NavigationPath()
    @State private var myJourneysPath = NavigationPath()
    @State private var addJourneyPath = NavigationPath()
    @State private var preferencesPath = NavigationPath()
    @State private var aboutPath = NavigationPath()

    var body: some View {
        TabView(selection: $router.selected) {
            if depStore.hasPinnedItems {
                NavigationStack(path: $pinnedPath) { PinnedJourneysView() }
                    .tabItem { Label("Pinned", systemImage: "pin.fill") }
                    .tag(Tab.pinned)
            }

            NavigationStack(path: $favouritesPath) { FavouritesView() }
                .tabItem { Label("Favourites", systemImage: "star.fill") }
                .tag(Tab.favourites)

            NavigationStack(path: $myJourneysPath) { MyJourneysView() }
                .tabItem { Label("My Journeys", systemImage: "list.bullet") }
                .tag(Tab.myJourneys)

            NavigationStack(path: $addJourneyPath) { AddJourneyView() }
                .tabItem { Label("Add Journey", systemImage: "plus.circle") }
                .tag(Tab.addJourney)

            NavigationStack(path: $preferencesPath) { PreferencesView() }
                .tabItem { Label("Preferences", systemImage: "gear") }
                .tag(Tab.preferences)

            NavigationStack(path: $aboutPath) { AboutView() }
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .overlay(alignment: .top) {
            if let toast = toastStore.toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: toastStore.toast)
        .onAppear {
            // Ensure polling starts even if App.onAppear wasn't fired
            depStore.startPolling(journeyStore: journeyStore)
        }
        .sheet(item: $deepLink.pendingJourneyGroup) { group in
            DeepLinkJourneySheet(group: group)
                .environmentObject(depStore)
        }
        .onChange(of: depStore.hasPinnedItems) { hasPinned in
            if !hasPinned && router.selected == .pinned {
                router.selected = .favourites
            }
        }
        .onChange(of: router.selected) { newTab in
            // Remember the last tab that isn't Add Journey so we can return there
            if newTab != .addJourney { router.lastNonAddTab = newTab }
        }
        .onChange(of: router.navigationResetTrigger) { _ in
            // Pop all navigation stacks to root when triggered
            pinnedPath = NavigationPath()
            favouritesPath = NavigationPath()
            myJourneysPath = NavigationPath()
            addJourneyPath = NavigationPath()
            preferencesPath = NavigationPath()
            aboutPath = NavigationPath()
        }
    }
}

#Preview {
    ContentView()
}
