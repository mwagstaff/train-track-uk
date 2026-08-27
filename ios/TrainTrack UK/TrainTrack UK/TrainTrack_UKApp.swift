//
//  TrainTrackUKApp.swift
//  TrainTrackUK
//
//  Created by Mike Wagstaff on 03/11/2025.
//

import SwiftUI

@main
struct TrainTrackUKApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) var notificationDelegate
    @StateObject private var deepLink = DeepLinkRouter.shared
    @StateObject private var railwayBackgroundStore = RailwayBackgroundStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoReturnToFavouritesMinutes") private var autoReturnMinutes: Int = 0

    // Track when app went to background for auto-return feature
    @State private var backgroundedAt: Date?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(TabRouter.shared)
                .environmentObject(JourneyStore.shared)
                .environmentObject(DeparturesStore.shared)
                .environmentObject(LiveActivityManager.shared)
                .environmentObject(NotificationSubscriptionStore.shared)
                .environmentObject(ToastStore.shared)
                .environmentObject(HolidayModeStore.shared)
                .environmentObject(JourneyHistoryStore.shared)
                .environmentObject(RecentServiceStore.shared)
                .environmentObject(railwayBackgroundStore)
                .environmentObject(deepLink)
                .onAppear {
                    // Defer to next runloop to avoid "Publishing changes from within view updates" warnings
                    DispatchQueue.main.async {
                        DeparturesStore.shared.startPolling(journeyStore: JourneyStore.shared)
                    }
                    Task {
                        await railwayBackgroundStore.ensureFresh()
                    }
                }
                .onOpenURL { url in
                    deepLink.handle(url: url)
                    Task {
                        await LiveActivityManager.shared.sendImmediateBackendCheckIn(force: true)
                    }
                }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                debugLog("🔄 [App] App became active - triggering Live Activity refresh")
                Task {
                    await LiveActivityManager.shared.registerAnyUnregisteredActivities()
                    await LiveActivityManager.shared.sendImmediateBackendCheckIn()
                    await LiveActivityManager.shared.refreshIfActive(
                        journeyStore: JourneyStore.shared,
                        depStore: DeparturesStore.shared
                    )
                }
                // Refresh server-side config (subscription limits etc.) so the client
                // stays in sync without requiring an app update.
                Task {
                    await ServerConfigStore.shared.refresh()
                }

                Task {
                    await railwayBackgroundStore.ensureFresh()
                }

                Task {
                    await DevicePreferencesSync.syncCurrent()
                }

                Task {
                    await HolidayModeStore.shared.syncToServer()
                }

                // Re-sync subscriptions and geofences each time the app comes to the
                // foreground. This ensures geofences are registered after the app was
                // killed/re-launched and stations need to be reloaded, and keeps the
                // geofence set in step with any subscription changes made elsewhere.
                debugLog("📍 [App] App became active - refreshing notification subscriptions & geofences")
                Task {
                    NotificationMuteRequestSender.shared.retryPendingMuteRequests(trigger: "app-active")
                    await NotificationGeofenceManager.shared.reconcileAfterBackgroundWake(
                        trigger: "foreground"
                    )
                    await NotificationSubscriptionStore.shared.refresh()
                }

                // Check if we should auto-return to favourites
                if autoReturnMinutes > 0, let bgTime = backgroundedAt {
                    let elapsed = Date().timeIntervalSince(bgTime)
                    let thresholdSeconds = Double(autoReturnMinutes * 60)
                    if elapsed >= thresholdSeconds {
                        debugLog("🏠 [App] Auto-returning to Favourites after \(Int(elapsed / 60)) minutes in background")
                        TabRouter.shared.resetToFavourites()
                    }
                }
                backgroundedAt = nil
            } else if newPhase == .background {
                backgroundedAt = Date()
                debugLog("💤 [App] App moved to background at \(backgroundedAt!)")
                NotificationGeofenceManager.shared.stopLocationActivityIfIdle()
            }
        }
    }
}
