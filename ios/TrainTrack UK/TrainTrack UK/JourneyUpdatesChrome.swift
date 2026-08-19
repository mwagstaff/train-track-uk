import SwiftUI
import JourneyActivityShared

struct JourneyUpdatesChrome: ViewModifier {
    let includeToast: Bool

    @EnvironmentObject private var activityMgr: LiveActivityManager
    @EnvironmentObject private var notificationStore: NotificationSubscriptionStore
    @EnvironmentObject private var toastStore: ToastStore
    @EnvironmentObject private var holidayMode: HolidayModeStore
    @ObservedObject private var trackingCoordinator = JourneyTrackingCoordinator.shared
    @State private var stoppingJourneyUpdates = false
    @State private var showingEndConfirmation = false
    @State private var bottomBannerHeight: CGFloat = 0

    private var activeJourneyUpdatesBanner: ActiveJourneyUpdatesBanner? {
        if let active = trackingCoordinator.activeJourney {
            return ActiveJourneyUpdatesBanner(
                title: "Journey in progress",
                subtitle: JourneyActivityAttributes.JourneyPhase.enRoute.statusMessage(
                    startStation: active.plannedOrigin.name,
                    destinationStation: active.plannedDestination.name
                ),
                buttonTitle: "End"
            )
        }

        if activityMgr.isActive, let completed = trackingCoordinator.recentlyCompletedJourney {
            return ActiveJourneyUpdatesBanner(
                title: "Journey in progress",
                subtitle: JourneyActivityAttributes.JourneyPhase.arrived.statusMessage(
                    startStation: completed.plannedOrigin.name,
                    destinationStation: completed.plannedDestination.name
                ),
                buttonTitle: "End"
            )
        }

        #if DEBUG
        if activityMgr.isActive,
           let candidate = trackingCoordinator.debugJourneySimulationCandidate,
           let start = candidate.stations.first,
           let destination = candidate.stations.last {
            let phase: JourneyActivityAttributes.JourneyPhase = candidate.originArrivedAt == nil
                ? .pendingStart
                : .atStart
            return ActiveJourneyUpdatesBanner(
                title: "Journey in progress",
                subtitle: phase.statusMessage(
                    startStation: start.name,
                    destinationStation: destination.name
                ),
                buttonTitle: "End"
            )
        }
        #endif

        let sessions = notificationStore.liveSessions
        guard !sessions.isEmpty else { return nil }
        if sessions.count == 1, let session = sessions.first {
            let candidate = trackingCoordinator.armedCandidates.first { $0.subscriptionId == session.id }
            let phase: JourneyActivityAttributes.JourneyPhase = candidate?.originArrivedAt == nil
                ? .pendingStart
                : .atStart
            let startName = candidate?.stations.first?.name
                ?? session.legs.first?.fromName
                ?? session.legs.first?.from
                ?? "your start station"
            let destinationName = candidate?.stations.last?.name
                ?? session.legs.last?.toName
                ?? session.legs.last?.to
                ?? "your destination"
            return ActiveJourneyUpdatesBanner(
                title: "Journey in progress",
                subtitle: phase.statusMessage(
                    startStation: startName,
                    destinationStation: destinationName
                ),
                buttonTitle: "End"
            )
        }
        return ActiveJourneyUpdatesBanner(
            title: "Journey in progress",
            subtitle: "\(sessions.count) journeys currently active",
            buttonTitle: "End all"
        )
    }

    private var bottomContentClearance: CGFloat {
        holidayMode.isEnabled || activeJourneyUpdatesBanner != nil
            ? bottomBannerHeight + 16
            : 0
    }

    private var endConfirmationTitle: String {
        notificationStore.liveSessions.count <= 1 ? "End journey?" : "End all journeys?"
    }

    private var endConfirmationMessage: String {
        notificationStore.liveSessions.count <= 1
            ? "Are you sure you want to end this journey? Live updates will stop."
            : "Are you sure you want to end all journeys? Live updates will stop."
    }

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, bottomContentClearance, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) {
                if includeToast, let toast = toastStore.toast {
                    ToastView(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                        .padding(.horizontal, 16)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if holidayMode.isEnabled || activeJourneyUpdatesBanner != nil {
                    VStack(spacing: 8) {
                        if holidayMode.isEnabled {
                            HolidayModeBannerView(onDisable: { holidayMode.setEnabled(false) })
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if let banner = activeJourneyUpdatesBanner {
                            JourneyUpdatesBannerView(
                                banner: banner,
                                isStopping: stoppingJourneyUpdates,
                                onEnd: { showingEndConfirmation = true }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        bottomBannerHeight = height
                    }
                }
            }
            .alert(endConfirmationTitle, isPresented: $showingEndConfirmation) {
                Button(activeJourneyUpdatesBanner?.buttonTitle ?? "End", role: .destructive) {
                    stopActiveJourneyUpdates()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(endConfirmationMessage)
            }
            .animation(.easeOut(duration: 0.25), value: holidayMode.isEnabled)
            .animation(.easeOut(duration: 0.25), value: notificationStore.liveSessions)
            .animation(.easeOut(duration: 0.25), value: toastStore.toast)
    }

    private func stopActiveJourneyUpdates() {
        guard !stoppingJourneyUpdates else { return }
        stoppingJourneyUpdates = true
        Task {
            defer { stoppingJourneyUpdates = false }
            #if DEBUG
            if trackingCoordinator.hasDebugJourneySimulation || activityMgr.hasDebugJourneySimulation {
                await activityMgr.stopDebugJourneySimulation()
                trackingCoordinator.stopDebugJourneySimulation()
                ToastStore.shared.show("Journey simulation ended", icon: "stop.fill")
                return
            }
            #endif
            let sessions = notificationStore.liveSessions
            let trackedJourney = trackingCoordinator.activeJourney
                ?? trackingCoordinator.recentlyCompletedJourney
            guard !sessions.isEmpty || trackedJourney != nil else { return }

            if StationsService.shared.stations.isEmpty {
                try? await StationsService.shared.loadStations()
            }
            let stationsByCRS = StationsService.shared.stations.reduce(into: [String: Station]()) { result, station in
                let key = station.crs.uppercased()
                if result[key] == nil {
                    result[key] = station
                }
            }

            for session in sessions {
                do {
                    try await notificationStore.deleteLiveSession(id: session.id)
                } catch {
                    continue
                }
                for leg in session.legs where leg.enabled {
                    guard let fromStation = stationsByCRS[leg.from.uppercased()],
                          let toStation = stationsByCRS[leg.to.uppercased()] else {
                        continue
                    }
                    await activityMgr.stop(for: Journey(fromStation: fromStation, toStation: toStation, favorite: false))
                }
            }

            if let trackedJourney {
                await activityMgr.stopJourneyActivities(
                    deepLinkFromCRS: trackedJourney.plannedOrigin.crs,
                    deepLinkToCRS: trackedJourney.plannedDestination.crs
                )
            }
            await trackingCoordinator.endActiveJourney()
            trackingCoordinator.clearRecentlyCompletedJourney()

            ToastStore.shared.show("Journey updates stopped", icon: "stop.fill")
        }
    }
}

private struct HolidayModeBannerView: View {
    let onDisable: () -> Void

    var body: some View {
        Button(action: onDisable) {
            HStack(spacing: 12) {
                Image(systemName: "beach.umbrella")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Holiday mode enabled")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text("Tap to disable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}

private struct ActiveJourneyUpdatesBanner {
    let title: String
    let subtitle: String
    let buttonTitle: String
}

private struct JourneyUpdatesBannerView: View {
    let banner: ActiveJourneyUpdatesBanner
    let isStopping: Bool
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(banner.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(role: .destructive, action: onEnd) {
                if isStopping {
                    ProgressView()
                        .frame(minWidth: 44)
                } else {
                    Text(banner.buttonTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .disabled(isStopping)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 16)
    }
}
