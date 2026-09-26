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
    @EnvironmentObject var railwayBackgroundStore: RailwayBackgroundStore
    @ObservedObject private var trackingCoordinator = JourneyTrackingCoordinator.shared
    @State private var disruptions = DisruptionMonitoringStore.shared

    // Navigation paths for each tab to enable programmatic pop-to-root
    @State private var favouritesPath = NavigationPath()
    @State private var myJourneysPath = NavigationPath()
    @State private var inProgressPath = NavigationPath()
    @State private var addJourneyPath: [AddJourneyNavigationDestination] = []
    @State private var profilePath = NavigationPath()
    @State private var journeyPlannerStore = JourneyPlannerStore()
    @State private var tabSelectionFeedbackTrigger = 0
    @State private var horizontalSwipeDisabledTabs: Set<Tab> = []
    @State private var isRailwayBackgroundViewerPresented = false

    private var hasInProgressTab: Bool {
        trackingCoordinator.hasPresentableJourney
    }

    private var showsInProgressBadge: Bool {
        trackingCoordinator.recentlyCompleted == nil
            && (trackingCoordinator.activeJourney != nil || !trackingCoordinator.armedCandidates.isEmpty)
    }

    private var visibleTabs: [Tab] {
        hasInProgressTab
            ? [.favourites, .myJourneys, .inProgress, .addJourney, .profile]
            : [.favourites, .myJourneys, .addJourney, .profile]
    }

    private var tabSelection: Binding<Tab> {
        Binding(
            get: { router.selected },
            set: { newTab in
                guard newTab != router.selected else { return }
                if newTab == .addJourney {
                    router.addJourneyPrefillFavourite = false
                }
                router.selected = newTab
                tabSelectionFeedbackTrigger += 1
            }
        )
    }

    private var isHorizontalTabSwipeEnabled: Bool {
        !horizontalSwipeDisabledTabs.contains(router.selected)
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
        @Bindable var disruptions = disruptions
        TabView(selection: tabSelection) {
            NavigationStack(path: $favouritesPath) {
                FavouritesView(onViewBackground: presentRailwayBackgroundViewer)
            }
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

            NavigationStack(path: $addJourneyPath) {
                AddJourneyEntryView(
                    plannerStore: journeyPlannerStore,
                    navigationPath: $addJourneyPath
                )
            }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .horizontalTabSwipePage(.addJourney)
                .horizontalTabSwipeDisabled(horizontalSwipeDisabledBinding(for: .addJourney))
                .tabItem { Label("New journey", systemImage: "plus") }
                .tag(Tab.addJourney)

            NavigationStack(path: $profilePath) {
                ProfileView()
                    .navigationDestination(for: JourneyHistoryNavigationTarget.self) { target in
                        if let recordID = target.recordID {
                            JourneyHistoryRecordDestination(recordID: recordID)
                        } else {
                            MyJourneyHistoryView()
                        }
                    }
            }
                .modifier(JourneyUpdatesChrome(includeToast: true))
                .horizontalTabSwipePage(.profile)
                .horizontalTabSwipeDisabled(horizontalSwipeDisabledBinding(for: .profile))
                .tabItem { Label("Profile", systemImage: "person.circle") }
                .tag(Tab.profile)
        }
        .horizontalTabSwipe(
            selection: tabSelection,
            tabs: visibleTabs,
            isEnabled: isHorizontalTabSwipeEnabled,
            onOpenBackgroundPhoto: presentRailwayBackgroundViewer
        )
        .fullScreenCover(isPresented: $isRailwayBackgroundViewerPresented) {
            RailwayBackgroundViewer(asset: railwayBackgroundStore.selectedAsset)
        }
        .fullScreenCover(item: $deepLink.routeMapDestination) { destination in
            JourneyRouteMapDeepLinkView(destination: destination)
        }
        .sheet(item: $disruptions.presentedFutureGroup) { group in
            FutureDisruptionsView(group: group)
        }
        .sensoryFeedback(.selection, trigger: tabSelectionFeedbackTrigger)
        .animation(.easeOut(duration: 0.25), value: toastStore.toast)
        .task(id: showsInProgressBadge) {
            await AppIconBadgeManager.update(isJourneyInProgress: showsInProgressBadge)
        }
        .onAppear {
            // Ensure polling starts even if App.onAppear wasn't fired
            depStore.startPolling(journeyStore: journeyStore)
            trackingCoordinator.pruneExpiredCompletion()
        }
        .onChange(of: router.navigationResetTrigger) {
            // Pop all navigation stacks to root when triggered
            favouritesPath = NavigationPath()
            myJourneysPath = NavigationPath()
            inProgressPath = NavigationPath()
            addJourneyPath = []
            profilePath = NavigationPath()
        }
        .onChange(of: router.historyTarget, initial: true) { _, target in
            guard let target else { return }
            profilePath = NavigationPath()
            profilePath.append(JourneyHistoryNavigationTarget())
            if target.recordID != nil {
                profilePath.append(target)
            }
        }
        .onChange(of: hasInProgressTab) { _, isVisible in
            if !isVisible, router.selected == .inProgress {
                router.openHistory()
            }
        }
    }

    private func presentRailwayBackgroundViewer() {
        isRailwayBackgroundViewerPresented = true
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
