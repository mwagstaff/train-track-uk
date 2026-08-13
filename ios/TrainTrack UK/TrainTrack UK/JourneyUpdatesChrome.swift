import SwiftUI

struct JourneyUpdatesChrome: ViewModifier {
    let includeToast: Bool

    @EnvironmentObject private var activityMgr: LiveActivityManager
    @EnvironmentObject private var notificationStore: NotificationSubscriptionStore
    @EnvironmentObject private var deepLink: DeepLinkRouter
    @EnvironmentObject private var toastStore: ToastStore
    @EnvironmentObject private var holidayMode: HolidayModeStore
    @State private var stoppingJourneyUpdates = false

    private var activeJourneyUpdatesBanner: ActiveJourneyUpdatesBanner? {
        let sessions = notificationStore.liveSessions
        guard !sessions.isEmpty else { return nil }
        if sessions.count == 1, let session = sessions.first {
            let route = session.primaryRoute
            return ActiveJourneyUpdatesBanner(
                title: "Live updates active",
                subtitle: session.routeTitle,
                buttonTitle: "Stop",
                viewRoute: route
            )
        }
        return ActiveJourneyUpdatesBanner(
            title: "Live updates active",
            subtitle: "\(sessions.count) journeys currently active",
            buttonTitle: "Stop all",
            viewRoute: nil
        )
    }

    func body(content: Content) -> some View {
        content
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
                                onView: banner.viewRoute == nil ? nil : { openJourney(for: banner) },
                                onStop: { stopActiveJourneyUpdates() }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
            }
            .animation(.easeOut(duration: 0.25), value: holidayMode.isEnabled)
            .animation(.easeOut(duration: 0.25), value: notificationStore.liveSessions)
            .animation(.easeOut(duration: 0.25), value: toastStore.toast)
    }

    private func openJourney(for banner: ActiveJourneyUpdatesBanner) {
        guard let route = banner.viewRoute else { return }
        Task {
            await deepLink.openJourney(from: route.fromCRS, to: route.toCRS)
        }
    }

    private func stopActiveJourneyUpdates() {
        guard !stoppingJourneyUpdates else { return }
        stoppingJourneyUpdates = true
        Task {
            defer { stoppingJourneyUpdates = false }
            let sessions = notificationStore.liveSessions
            guard !sessions.isEmpty else { return }

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
    let viewRoute: JourneyRouteIdentity?
}

private struct JourneyUpdatesBannerView: View {
    let banner: ActiveJourneyUpdatesBanner
    let isStopping: Bool
    let onView: (() -> Void)?
    let onStop: () -> Void

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
            if let onView {
                Button(action: onView) {
                    Text("View")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button(role: .destructive, action: onStop) {
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

private extension NotificationSubscription {
    var primaryRoute: JourneyRouteIdentity? {
        guard let first = legs.first, let last = legs.last else { return nil }
        return JourneyRouteIdentity(from: first.from, to: last.to)
    }
}
