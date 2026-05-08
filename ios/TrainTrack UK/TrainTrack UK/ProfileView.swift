import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var notificationStore: NotificationSubscriptionStore
    @State private var pendingDeleteUpdate: NotificationSubscription? = nil
    @State private var showUpdateDeleteDialog = false
    @State private var viewingScheduledRoute: IdentifiableScheduledRoute? = nil
    @State private var viewingLiveSession: NotificationSubscription? = nil

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    PreferencesView()
                } label: {
                    profileRow(
                        title: "Preferences",
                        subtitle: "Notifications, Live Activity, journey sorting, and display settings.",
                        systemImage: "slider.horizontal.3"
                    )
                }

                NavigationLink {
                    AboutView()
                } label: {
                    profileRow(
                        title: "About",
                        subtitle: "Version info, feedback, credits, and data sources.",
                        systemImage: "info.circle"
                    )
                }
            }

            Section("Journey Updates") {
                if notificationStore.isLoading && !notificationStore.hasLoadedOnce {
                    ProgressView("Loading…")
                } else if !notificationStore.hasAuthoritativeRemoteState {
                    Text("Unable to refresh journey updates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if notificationStore.combinedSubscriptions.isEmpty {
                    Text("No active journey updates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(notificationStore.combinedSubscriptions) { sub in
                        journeyUpdateCard(for: sub)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                }
            }
        }
        .navigationTitle("Profile")
        .task {
            await notificationStore.refresh()
            try? await StationsService.shared.loadStations()
        }
        .alert("Delete journey update?", isPresented: $showUpdateDeleteDialog, presenting: pendingDeleteUpdate) { sub in
            Button("Delete", role: .destructive) {
                deleteUpdate(sub)
            }
            Button("Cancel", role: .cancel) { }
        } message: { sub in
            Text(isScheduled(sub)
                ? "This will remove the scheduled notifications for this journey."
                : "This will stop live journey update notifications.")
        }
        .sheet(item: $viewingScheduledRoute) { route in
            NotificationScheduleView(group: route.group, reverseGroup: route.reverseGroup)
                .environmentObject(notificationStore)
        }
        .sheet(item: $viewingLiveSession) { session in
            LiveSessionInfoSheet(session: session)
        }
    }

    private func profileRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func journeyUpdateCard(for sub: NotificationSubscription) -> some View {
        let scheduled = isScheduled(sub)
        let active = isActive(sub)
        let legs = chronologicalLegs(from: sub.legs)
        HStack(alignment: .center, spacing: 0) {
            Button {
                if scheduled, let route = resolvedScheduledRoute(for: sub) {
                    viewingScheduledRoute = IdentifiableScheduledRoute(group: route.group, reverseGroup: route.reverseGroup)
                } else if !scheduled {
                    viewingLiveSession = sub
                }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 14)
                        }
                        legContent(leg: leg, scheduled: scheduled, active: active)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color(.separator))
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 10)

            Button {
                pendingDeleteUpdate = sub
                showUpdateDeleteDialog = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(.red)
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func legContent(leg: NotificationLeg, scheduled: Bool, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(leg.fromName ?? leg.from) → \(leg.toName ?? leg.to)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                Text(scheduled ? "Scheduled" : "Adhoc")
                    .font(.caption)
                    .foregroundStyle(scheduled ? .blue : .orange)
                if leg.enabled {
                    Text("• \(leg.windowStart)–\(leg.windowEnd)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Text("Active")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func isScheduled(_ sub: NotificationSubscription) -> Bool {
        notificationStore.subscriptions.contains(where: { $0.id == sub.id })
    }

    private func isActive(_ sub: NotificationSubscription) -> Bool {
        guard !isScheduled(sub) else { return false }
        guard let activeUntil = sub.activeUntil else { return true }
        return activeUntil > Date()
    }

    private func deleteUpdate(_ sub: NotificationSubscription) {
        Task {
            if isScheduled(sub) {
                try? await notificationStore.delete(id: sub.id)
            } else {
                try? await notificationStore.deleteLiveSession(id: sub.id)
            }
        }
    }

    private func resolvedScheduledRoute(for subscription: NotificationSubscription) -> ProfileResolvedScheduledRoute? {
        let legs = chronologicalLegs(from: subscription.legs)
        guard !legs.isEmpty else { return nil }
        if let splitIndex = returnSplitIndex(for: legs) {
            let outbound = Array(legs.prefix(splitIndex))
            let inbound = Array(legs.dropFirst(splitIndex))
            return ProfileResolvedScheduledRoute(
                group: makeJourneyGroup(from: outbound),
                reverseGroup: makeJourneyGroup(from: inbound)
            )
        }
        return ProfileResolvedScheduledRoute(
            group: makeJourneyGroup(from: legs),
            reverseGroup: nil
        )
    }

    private func returnSplitIndex(for legs: [NotificationLeg]) -> Int? {
        guard legs.count >= 2 else { return nil }
        for splitIndex in 1..<legs.count {
            let outbound = Array(legs.prefix(splitIndex))
            let inbound = Array(legs.dropFirst(splitIndex))
            if stationSequence(for: inbound) == stationSequence(for: outbound).reversed() {
                return splitIndex
            }
        }
        return nil
    }

    private func chronologicalLegs(from legs: [NotificationLeg]) -> [NotificationLeg] {
        legs.enumerated()
            .sorted { lhs, rhs in
                let lhsMinutes = minutesSinceMidnight(lhs.element.windowStart)
                let rhsMinutes = minutesSinceMidnight(rhs.element.windowStart)
                switch (lhsMinutes, rhsMinutes) {
                case let (lhsMinutes?, rhsMinutes?) where lhsMinutes != rhsMinutes:
                    return lhsMinutes < rhsMinutes
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    private func minutesSinceMidnight(_ time: String) -> Int? {
        let parts = time.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    private func stationSequence(for legs: [NotificationLeg]) -> [String] {
        guard let first = legs.first else { return [] }
        return [first.from.uppercased()] + legs.map { $0.to.uppercased() }
    }

    private func makeJourneyGroup(from legs: [NotificationLeg]) -> JourneyGroup {
        let groupId = UUID()
        let journeys = legs.enumerated().map { index, leg in
            Journey(
                id: UUID(),
                groupId: groupId,
                legIndex: index,
                fromStation: station(from: leg.from, name: leg.fromName),
                toStation: station(from: leg.to, name: leg.toName),
                createdAt: Date(),
                favorite: false
            )
        }
        return JourneyGroup(id: groupId, legs: journeys)
    }

    private func station(from crs: String, name: String?) -> Station {
        if let actual = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(crs) == .orderedSame }) {
            return actual
        }
        return Station(
            crs: crs.uppercased(),
            name: name ?? crs.uppercased(),
            longitude: "0",
            latitude: "0"
        )
    }
}

private struct ProfileResolvedScheduledRoute {
    let group: JourneyGroup
    let reverseGroup: JourneyGroup?
}

private struct IdentifiableScheduledRoute: Identifiable {
    let id = UUID()
    let group: JourneyGroup
    let reverseGroup: JourneyGroup?
}

private struct LiveSessionInfoSheet: View {
    let session: NotificationSubscription
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Journey") {
                    let from = session.legs.first?.fromName ?? session.legs.first?.from ?? "Unknown"
                    let to = session.legs.last?.toName ?? session.legs.last?.to ?? "Unknown"
                    LabeledContent("From", value: from)
                    LabeledContent("To", value: to)
                    if session.legs.count > 1 {
                        LabeledContent("Legs", value: "\(session.legs.count)")
                    }
                }
                Section("Status") {
                    if let activeUntil = session.activeUntil {
                        let active = activeUntil > Date()
                        LabeledContent("Active", value: active ? "Yes" : "No (expired)")
                        LabeledContent("Active until", value: activeUntil.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        LabeledContent("Active", value: "Yes")
                    }
                }
            }
            .navigationTitle("Adhoc Journey Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProfileView()
            .environmentObject(NotificationSubscriptionStore.shared)
    }
}
