import SwiftUI
import Combine
import CoreLocation
import UIKit
import UserNotifications

struct JourneyDetailsView: View {
    let group: JourneyGroup

    @EnvironmentObject var depStore: DeparturesStore
    @EnvironmentObject var activityMgr: LiveActivityManager
    @EnvironmentObject var journeyStore: JourneyStore
    @EnvironmentObject var notificationStore: NotificationSubscriptionStore
    @EnvironmentObject var muteDebugStore: MuteRequestDebugStore
    @AppStorage("liveActivityDurationMinutes") private var liveActivityDurationMinutes: Int = 60
    @StateObject private var location = LocationManagerPhone()

    @State private var refreshing = false
    @State private var tick = Date()
    @State private var showingReverse = false
    @State private var showingNotificationSheet = false
    @State private var liveSessionInfoMessage: String?
    @State private var liveSessionActionInFlight = false
    @Environment(\.scenePhase) private var scenePhase

    private var reverseGroup: JourneyGroup? {
        journeyStore.reverseGroup(for: group)
    }

    private var currentGroup: JourneyGroup {
        if showingReverse, let reverse = reverseGroup {
            return reverse
        }
        return group
    }

    private var journeyTitle: String {
        "\(currentGroup.startStation.name) → \(currentGroup.endStation.name)"
    }
    private var legsForActivity: [Journey] {
        Array(currentGroup.legs.prefix(3))
    }

    private var notificationRouteKey: String {
        let crs = currentGroup.stationSequence.map { $0.crs.uppercased() }
        let forward = crs.joined(separator: "-")
        let reverse = crs.reversed().joined(separator: "-")
        return min(forward, reverse)
    }

    private var liveSessionRouteKey: String {
        "\(currentGroup.startStation.crs.uppercased())-\(currentGroup.endStation.crs.uppercased())"
    }

    private var notificationSubscription: NotificationSubscription? {
        notificationStore.subscription(for: notificationRouteKey)
    }

    private var liveSession: NotificationSubscription? {
        notificationStore.liveSession(for: liveSessionRouteKey)
    }

    private var canScheduleNotifications: Bool {
        notificationSubscription != nil || notificationStore.subscriptions.count < 3
    }

    private var notificationSubtitle: String {
        if let subscription = notificationSubscription {
            return "Scheduled • \(subscription.daysLabel) • \(subscription.windowLabel)"
        }
        if !canScheduleNotifications {
            return "Limit reached (max 3 journeys)"
        }
        return "Choose days, time window, and alert types"
    }

    private var notificationMuteStatus: (detail: String, isMuted: Bool)? {
        guard let subscription = liveSession ?? notificationSubscription else { return nil }
        guard let firstLeg = currentGroup.legs.first else { return nil }
        let muteOnArrival = subscription.muteOnArrival ?? true
        let startName = firstLeg.fromStation.name
        let fromCode = firstLeg.fromStation.crs.uppercased()
        let toCode = firstLeg.toStation.crs.uppercased()
        let legKey = NotificationMuteStorage.legKey(from: fromCode, to: toCode)

        if NotificationMuteStorage.isMutedToday(from: fromCode, to: toCode) {
            if let timeLabel = NotificationMuteStorage.mutedTimeLabel(from: fromCode, to: toCode) {
                return (detail: "Muted at \(timeLabel) for today", isMuted: true)
            }
            return (detail: "Muted for today", isMuted: true)
        }

        if let mutedDate = subscription.mutedByLegDay?[legKey],
           mutedDate == currentDateKeyUTC() {
            let mutedAt = subscription.mutedAtByLegDay?[legKey]
            let timeLabel = mutedAt.flatMap(formatTime) ?? "now"
            return (detail: "Muted at \(timeLabel) due to arrival at \(startName)", isMuted: true)
        }

        guard muteOnArrival else { return nil }
        return (detail: "Auto-mutes today when you arrive at \(startName)", isMuted: false)
    }

    private func departures(for leg: Journey) -> [DepartureV2] {
        depStore.departures(for: leg)
    }

    private func displayedDepartures(for leg: Journey, maxVisible: Int = 5) -> [DepartureV2] {
        let all = departures(for: leg)
        guard !all.isEmpty else { return [] }

        let pinnedIDs = Set(
            all
                .filter { depStore.isPinned($0, fromCRS: leg.fromStation.crs, toCRS: leg.toStation.crs) }
                .map(\.serviceID)
        )
        if pinnedIDs.isEmpty {
            return Array(all.prefix(maxVisible))
        }

        let baseIDs = Set(all.prefix(maxVisible).map(\.serviceID))
        let visibleIDs = baseIDs.union(pinnedIDs)

        // Preserve global time order from `all` so pinning does not reorder rows.
        return all.filter { visibleIDs.contains($0.serviceID) }
    }

    private var journeySummaryOptions: [JourneySummary] {
        let legs = currentGroup.legs
        guard legs.count > 1, let firstLeg = legs.first else { return [] }
        let firstDepartures = departures(for: firstLeg).filter { !$0.isCancelled }
        guard !firstDepartures.isEmpty else { return [] }
        var summaries: [JourneySummary] = []
        for dep in firstDepartures.prefix(5) {
            if let summary = buildSummary(startingWith: dep, legs: legs) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    private func selections(for summary: JourneySummary) -> [JourneyLegSelection] {
        summary.legs.map { JourneyLegSelection(leg: $0.leg, departure: $0.departure) }
    }

    private func isSummaryPinned(_ summary: JourneySummary) -> Bool {
        depStore.isJourneySelectionPinned(selections(for: summary))
    }

    private func pinSummary(_ summary: JourneySummary) {
        let selectedLegs = selections(for: summary)
        guard !selectedLegs.isEmpty else { return }
        depStore.pinJourneySelections(selectedLegs, journeyGroupID: currentGroup.id)
    }

    private func unpinSummary(_ summary: JourneySummary) {
        depStore.unpinJourneySelections(selections(for: summary))
    }

    private func buildSummary(startingWith firstDeparture: DepartureV2, legs: [Journey]) -> JourneySummary? {
        var summaries: [JourneySummaryLeg] = []
        var transfers: [JourneyTransfer] = []
        var previousArrivalDate: Date? = nil
        var previousArrivalTime: String? = nil
        var previousDepartureDate: Date? = nil

        for (index, leg) in legs.enumerated() {
            let dep: DepartureV2
            if index == 0 {
                dep = firstDeparture
            } else {
                let earliest = previousArrivalDate ?? previousDepartureDate
                guard let nextDep = selectDeparture(for: leg, earliest: earliest) else { return nil }
                dep = nextDep
            }
            let depTime = departureDisplayTime(dep)
            let depDate = departureDate(dep)
            let (arrTime, arrDate) = arrivalInfo(for: dep, toCRS: leg.toStation.crs)

            if index > 0 {
                let minutes = connectionMinutes(from: previousArrivalDate, to: depDate)
                transfers.append(JourneyTransfer(
                    station: leg.fromStation,
                    arrivalTime: previousArrivalTime,
                    departureTime: depTime,
                    minutes: minutes
                ))
            }

            summaries.append(JourneySummaryLeg(
                leg: leg,
                departure: dep,
                departureTime: depTime,
                arrivalTime: arrTime
            ))

            previousArrivalDate = arrDate
            previousArrivalTime = arrTime
            previousDepartureDate = depDate
        }

        return JourneySummary(legs: summaries, transfers: transfers)
    }

    private func selectDeparture(for leg: Journey, earliest: Date?) -> DepartureV2? {
        let deps = departures(for: leg)
        if let earliest {
            if let match = deps.first(where: { dep in
                guard !dep.isCancelled, let depDate = departureDate(dep) else { return false }
                return depDate >= earliest
            }) {
                return match
            }
        }
        return deps.first(where: { !$0.isCancelled }) ?? deps.first
    }

    private func departureDisplayTime(_ dep: DepartureV2) -> String {
        let est = dep.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = est.lowercased()
        if est.isEmpty || lower == "delayed" || lower == "cancelled" || lower == "on time" {
            return dep.departureTime.scheduled
        }
        return est
    }

    private func arrivalInfo(for dep: DepartureV2, toCRS: String) -> (String?, Date?) {
        guard let details = depStore.serviceDetailsById[dep.serviceID] else { return (nil, nil) }
        let targetCRS = toCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let cp = details.allStations.first(where: { $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS }) {
            let display: String = {
                if let at = cp.at, at != "Cancelled" { return at == "On time" ? cp.st : at }
                if let et = cp.et, et != "Cancelled" { return et == "On time" ? cp.st : et }
                return cp.st
            }()
            return (display, parseHHmm(display))
        }
        if details.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS {
            let display: String? = {
                if let ata = details.ata, ata != "Cancelled" { return ata == "On time" ? details.sta : ata }
                if let sta = details.sta { return sta }
                return nil
            }()
            return (display, parseHHmm(display))
        }
        if let targetName = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(toCRS) == .orderedSame })?.name {
            let normalizedTarget = normalizeStationName(targetName)
            if let cp = details.allStations.first(where: { normalizeStationName($0.locationName) == normalizedTarget }) {
                let display: String = {
                    if let at = cp.at, at != "Cancelled" { return at == "On time" ? cp.st : at }
                    if let et = cp.et, et != "Cancelled" { return et == "On time" ? cp.st : et }
                    return cp.st
                }()
                return (display, parseHHmm(display))
            }
        }
        return (nil, nil)
    }

    private func normalizeStationName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private func connectionMinutes(from arrival: Date?, to departure: Date?) -> Int? {
        guard let arrival, let departure else { return nil }
        let minutes = Calendar.current.dateComponents([.minute], from: arrival, to: departure).minute
        guard let mins = minutes else { return nil }
        return max(0, mins)
    }

    private func departureDate(_ dep: DepartureV2) -> Date? {
        parseHHmm(departureDisplayTime(dep))
    }

    private func parseHHmm(_ t: String?) -> Date? {
        guard let t = t else { return nil }
        let lower = t.lowercased()
        if lower == "delayed" || lower == "cancelled" || lower == "on time" { return nil }
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let now = Date()
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = h; comps.minute = m
        guard var candidate = Calendar.current.date(from: comps) else { return nil }
        if candidate < now && now.timeIntervalSince(candidate) > 6 * 3600 {
            candidate = Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    var body: some View {
        List {
            Section {
                LiveJourneySessionRow(
                    isActive: liveSession != nil,
                    isBusy: liveSessionActionInFlight,
                    activeCount: notificationStore.liveSessions.count,
                    infoMessage: liveSessionInfoMessage
                ) {
                    toggleLiveSession()
                }
                NotificationScheduleRow(
                    subtitle: notificationSubtitle,
                    detail: notificationMuteStatus?.detail,
                    isMuted: notificationMuteStatus?.isMuted ?? false,
                    isScheduled: notificationSubscription != nil,
                    isDisabled: !canScheduleNotifications
                ) {
                    showingNotificationSheet = true
                }
            }

            if currentGroup.legs.count > 1 {
                let summaries = journeySummaryOptions
                if summaries.isEmpty {
                    Section("Journey Overview: Next Departures") {
                        Text("Journey summary unavailable right now.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(summaries.indices, id: \.self) { optionIndex in
                        let summary = summaries[optionIndex]
                        Section {
                            JourneySummaryOptionHeader(
                                optionNumber: optionIndex + 1,
                                summary: summary,
                                isPinned: isSummaryPinned(summary),
                                onPin: { pinSummary(summary) },
                                onUnpin: { unpinSummary(summary) }
                            )
                            ForEach(summary.legs.indices, id: \.self) { index in
                                let legSummary = summary.legs[index]
                                NavigationLink(destination: ServiceMapView(serviceID: legSummary.departure.serviceID,
                                                                          fromCRS: legSummary.leg.fromStation.crs,
                                                                          toCRS: legSummary.leg.toStation.crs)) {
                                    JourneySummaryLegRow(
                                        summary: legSummary,
                                        transfer: index == 0 ? nil : summary.transfers[index - 1],
                                        legNumber: index + 1
                                    )
                                }
                            }
                        } header: {
                            if optionIndex == 0 {
                                Text("Journey Overview: Next Departures")
                            }
                        }
                    }
                }
            }

            ForEach(currentGroup.legs) { leg in
                Section(header: Text("\(leg.fromStation.name) → \(leg.toStation.name)")) {
                    let legDepartures = departures(for: leg)
                    if legDepartures.isEmpty {
                        if #available(iOS 17.0, *) {
                            ContentUnavailableView("No departures found",
                                                   systemImage: "train.side.front.car",
                                                   description: Text("Pull to refresh or try again soon."))
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "train.side.front.car").font(.system(size: 34)).foregroundStyle(.secondary)
                                Text("No departures found").font(.headline)
                                Text("Pull to refresh or try again soon.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                        }
                    } else {
                        let visibleDepartures = displayedDepartures(for: leg)
                        ForEach(visibleDepartures) { dep in
                            HStack(spacing: 10) {
                                NavigationLink(destination: ServiceMapView(serviceID: dep.serviceID, fromCRS: leg.fromStation.crs, toCRS: leg.toStation.crs)) {
                                    DepartureRow(
                                        dep: dep,
                                        fromCRS: leg.fromStation.crs,
                                        toCRS: leg.toStation.crs,
                                        fromName: leg.fromStation.name,
                                        toName: leg.toStation.name,
                                        allDepartures: Array(legDepartures.prefix(8))
                                    )
                                }
                                .buttonStyle(.plain)

                                if currentGroup.legs.count == 1 {
                                    DeparturePinButton(dep: dep, leg: leg)
                                }
                            }
                        }
                    }
                }
            }

            #if DEBUG
            // Debug: Proximity & Geofence Status
            if let firstLeg = currentGroup.legs.first {
                Section(header: Text("Debug: Proximity & Geofence")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let coord = location.coordinate {
                            let fromDistMeters = distanceMeters(from: coord, to: firstLeg.fromStation)
                            let toDistMeters = distanceMeters(from: coord, to: firstLeg.toStation)
                            let geofenceRadius: Double = 250
                            let withinGeofence = fromDistMeters <= geofenceRadius

                            HStack {
                                Circle()
                                    .fill(withinGeofence ? Color.green : Color.secondary)
                                    .frame(width: 10, height: 10)
                                Text("Distance to \(firstLeg.fromStation.name):")
                                    .font(.caption)
                                Spacer()
                                Text(formatDistanceDebug(fromDistMeters))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(withinGeofence ? .green : .primary)
                            }

                            if withinGeofence {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Within geofence (250m)")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                        .fontWeight(.medium)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(6)
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "location.circle")
                                        .foregroundStyle(.secondary)
                                    Text("Outside geofence (250m)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            // Actual CLLocationManager monitoring status — distinct from
                            // the GPS distance check above.
                            if let subscription = notificationSubscription {
                                let expectedId = "tt_notify_mute:\(subscription.id):\(firstLeg.fromStation.crs.uppercased()):\(firstLeg.toStation.crs.uppercased())"
                                let monitoredIds = NotificationGeofenceManager.shared.monitoredRegionIdentifiers
                                let isRegistered = monitoredIds.contains(expectedId)
                                HStack(spacing: 6) {
                                    Image(systemName: isRegistered ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                        .foregroundStyle(isRegistered ? .green : .orange)
                                    Text("CLLocation monitoring: \(isRegistered ? "Active ✓" : "NOT registered ⚠️")")
                                        .font(.caption2)
                                        .foregroundStyle(isRegistered ? .green : .orange)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text("\(monitoredIds.count) region(s)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 2)
                            }

                            Divider().padding(.vertical, 4)

                            Text("Distance to \(firstLeg.toStation.name): \(formatDistanceDebug(toDistMeters))")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("Coordinates: \(String(format: "%.5f", coord.latitude)), \(String(format: "%.5f", coord.longitude))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "location.slash")
                                    .foregroundStyle(.orange)
                                Text("Location not available")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Divider().padding(.vertical, 6)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Debug actions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button("Simulate arrival now") {
                                    debugSimulateArrival()
                                }
                                .buttonStyle(.bordered)

                                Button("Simulate arrival in 30s") {
                                    debugSimulateArrival(delaySeconds: 30)
                                }
                                .buttonStyle(.bordered)
                            }
                            HStack(spacing: 8) {
                                Button("Send test notification") {
                                    debugSendLegNotification()
                                }
                                .buttonStyle(.bordered)

                                Button("Clear local mute") {
                                    debugClearLocalMute()
                                }
                                .buttonStyle(.bordered)
                            }
                            HStack(spacing: 8) {
                                Button("Re-sync geofences") {
                                    Task {
                                        await notificationStore.refresh()
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if let last = muteDebugStore.last {
                            Divider().padding(.vertical, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Last mute request")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Status: \(last.status)")
                                    .font(.caption2)
                                Text("Time: \(last.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                Text("Payload: \(last.payload)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let response = last.response, !response.isEmpty {
                                    Text("Response: \(response)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            #endif
        }
        .sheet(isPresented: $showingNotificationSheet) {
            let otherGroup = showingReverse ? group : reverseGroup
            NotificationScheduleView(group: currentGroup, reverseGroup: otherGroup)
                .environmentObject(notificationStore)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(journeyTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .toolbar { toolbar }
        .onAppear {
            location.request()
            if reverseGroup == nil {
                showingReverse = false
            }
        }
        .task {
            await notificationStore.refresh()
            await prefetchServiceDetailsIfNeeded()
        }
        .refreshable { await manualRefresh() }
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { _ in
            tick = Date()
            Task { await refreshServiceDetails() }
        }
        .alert(item: Binding(get: {
            activityMgr.lastMessage.map { AlertMsg(text: $0) }
        }, set: { _ in activityMgr.lastMessage = nil })) { m in
            Alert(title: Text(m.text))
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Force UI refresh when app becomes active
                tick = Date()
            }
        }
        .onChange(of: showingReverse) { _ in
            Task {
                await prefetchServiceDetailsIfNeeded()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if let reverseGroup {
                Button {
                    showingReverse.toggle()
                } label: {
                    Image(systemName: showingReverse ? "arrow.uturn.backward" : "arrow.left.arrow.right")
                }
                .accessibilityLabel(showingReverse ? "Original journey" : "Reverse journey")
                .accessibilityHint("Switch to the return leg")
            }
            if refreshing { ProgressView() }
        }
    }

    private func toggleLiveSession() {
        guard !liveSessionActionInFlight else { return }
        Task {
            if liveSession != nil {
                await stopCurrentLiveSession()
            } else {
                await startCurrentLiveSession()
            }
        }
    }

    private func startCurrentLiveSession() async {
        guard !liveSessionActionInFlight else { return }
        liveSessionActionInFlight = true
        defer { liveSessionActionInFlight = false }

        liveSessionInfoMessage = nil

        let allowed = await NotificationAuthorizationManager.ensureAuthorized()
        guard allowed else {
            let message = "Notifications are disabled in Settings"
            activityMgr.lastMessage = message
            ToastStore.shared.show(message, icon: "bell.slash.fill")
            return
        }

        guard let pushToken = await NotificationPushTokenStore.waitForToken(timeoutSeconds: 6.0) else {
            let message = "Waiting for a notification token. Try again in a moment."
            activityMgr.lastMessage = message
            ToastStore.shared.show(message, icon: "exclamationmark.triangle.fill")
            return
        }

        var replacement: NotificationSubscription?
        if liveSession == nil,
           notificationStore.liveSessions.count >= 3 {
            replacement = notificationStore.liveSessions
                .filter { $0.routeKey != liveSessionRouteKey }
                .sorted(by: { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) })
                .first
        }

        if let replacement {
            do {
                try await stopLiveSession(replacement)
                let replacedTitle = sessionTitle(for: replacement)
                liveSessionInfoMessage = "Replaced the oldest active session (\(replacedTitle)) to make room for this one."
                ToastStore.shared.show("Replaced oldest live session", icon: "arrow.triangle.2.circlepath")
            } catch {
                activityMgr.lastMessage = error.localizedDescription
                ToastStore.shared.show("Unable to replace oldest live session", icon: "exclamationmark.triangle.fill")
                return
            }
        }

        guard await startLiveActivitiesForCurrentGroup() else {
            ToastStore.shared.show("Unable to start Live Activity", icon: "exclamationmark.triangle.fill")
            return
        }

        do {
            _ = try await notificationStore.upsertLiveSession(buildLiveSessionRequest(pushToken: pushToken))
            ToastStore.shared.show("Live Activity + notifications started", icon: "dot.radiowaves.left.and.right")
        } catch {
            await stopLiveActivities(for: legsForActivity)
            activityMgr.lastMessage = error.localizedDescription
            ToastStore.shared.show("Unable to start notifications", icon: "exclamationmark.triangle.fill")
        }
    }

    private func stopCurrentLiveSession() async {
        guard let liveSession else { return }
        liveSessionActionInFlight = true
        defer { liveSessionActionInFlight = false }

        do {
            try await stopLiveSession(liveSession)
            liveSessionInfoMessage = nil
            ToastStore.shared.show("Live Activity + notifications stopped", icon: "stop.fill")
        } catch {
            activityMgr.lastMessage = error.localizedDescription
            ToastStore.shared.show("Unable to stop live session", icon: "exclamationmark.triangle.fill")
        }
    }

    private func stopLiveSession(_ session: NotificationSubscription) async throws {
        try await notificationStore.deleteLiveSession(id: session.id)
        await stopLiveActivities(for: session)
    }

    private func startLiveActivitiesForCurrentGroup() async -> Bool {
        var newlyStarted: [Journey] = []
        for leg in legsForActivity {
            if activityMgr.isActive(for: leg) { continue }
            await activityMgr.start(for: leg, depStore: depStore, triggeredByUser: true, bypassSuppression: true)
            if activityMgr.isActive(for: leg) {
                newlyStarted.append(leg)
            }
        }

        let allActive = legsForActivity.allSatisfy { activityMgr.isActive(for: $0) }
        if !allActive {
            await stopLiveActivities(for: newlyStarted)
        }
        return allActive
    }

    private func stopLiveActivities(for session: NotificationSubscription) async {
        if StationsService.shared.stations.isEmpty {
            try? await StationsService.shared.loadStations()
        }

        let stationsByCRS = StationsService.shared.stations.reduce(into: [String: Station]()) { result, station in
            let key = station.crs.uppercased()
            if result[key] == nil {
                result[key] = station
            }
        }

        for leg in Array(session.legs.prefix(3)) {
            guard let fromStation = stationsByCRS[leg.from.uppercased()],
                  let toStation = stationsByCRS[leg.to.uppercased()] else {
                continue
            }
            let journey = Journey(fromStation: fromStation, toStation: toStation, favorite: false)
            await activityMgr.stop(for: journey)
        }
    }

    private func stopLiveActivities(for journeys: [Journey]) async {
        for leg in journeys {
            await activityMgr.stop(for: leg)
        }
    }

    private func buildLiveSessionRequest(pushToken: String) -> NotificationSubscriptionRequest {
        let today = currentDayOfWeek()
        let defaultLegs = currentGroup.legs.map { leg in
            NotificationLeg(
                from: leg.fromStation.crs.uppercased(),
                to: leg.toStation.crs.uppercased(),
                fromName: leg.fromStation.name,
                toName: leg.toStation.name,
                enabled: true,
                windowStart: "00:00",
                windowEnd: "23:59"
            )
        }

        let scheduledByLegID = Dictionary(
            uniqueKeysWithValues: (notificationSubscription?.legs ?? []).map { ($0.id, $0) }
        )
        let resolvedLegs = defaultLegs.map { leg in
            guard let existing = scheduledByLegID[leg.id] else { return leg }
            return NotificationLeg(
                from: leg.from,
                to: leg.to,
                fromName: leg.fromName,
                toName: leg.toName,
                enabled: existing.enabled,
                windowStart: leg.windowStart,
                windowEnd: leg.windowEnd
            )
        }
        let liveSessionLegs: [NotificationLeg]
        if resolvedLegs.contains(where: { $0.enabled }) {
            liveSessionLegs = resolvedLegs
        } else if let firstLeg = resolvedLegs.first {
            liveSessionLegs = [NotificationLeg(
                from: firstLeg.from,
                to: firstLeg.to,
                fromName: firstLeg.fromName,
                toName: firstLeg.toName,
                enabled: true,
                windowStart: firstLeg.windowStart,
                windowEnd: firstLeg.windowEnd
            )] + Array(resolvedLegs.dropFirst())
        } else {
            liveSessionLegs = resolvedLegs
        }

        let notificationTypes = NotificationPreferences.effectiveTypes(for: .liveSession)
        let muteOnArrival = (UserDefaults.standard.object(forKey: "autoMuteOnArrival") as? Bool) ?? true
        let activeUntil = Date().addingTimeInterval(Double(liveActivityDurationMinutes * 60))

        #if DEBUG
        let useSandbox = true
        #else
        let useSandbox = false
        #endif

        return NotificationSubscriptionRequest(
            subscriptionId: liveSession?.id,
            deviceId: DeviceIdentity.deviceToken,
            pushToken: pushToken,
            routeKey: liveSessionRouteKey,
            daysOfWeek: [today],
            notificationTypes: notificationTypes,
            legs: liveSessionLegs,
            windowStart: "00:00",
            windowEnd: "23:59",
            from: currentGroup.startStation.crs.uppercased(),
            to: currentGroup.endStation.crs.uppercased(),
            fromName: currentGroup.startStation.name,
            toName: currentGroup.endStation.name,
            useSandbox: useSandbox,
            muteOnArrival: muteOnArrival,
            activeUntil: activeUntil
        )
    }

    private func sessionTitle(for session: NotificationSubscription) -> String {
        let first = session.legs.first
        let last = session.legs.last
        let from = first?.fromName ?? first?.from ?? currentGroup.startStation.name
        let to = last?.toName ?? last?.to ?? currentGroup.endStation.name
        return "\(from) → \(to)"
    }

    private func currentDayOfWeek() -> DayOfWeek {
        switch Calendar.current.component(.weekday, from: Date()) {
        case 1: return .sun
        case 2: return .mon
        case 3: return .tue
        case 4: return .wed
        case 5: return .thu
        case 6: return .fri
        default: return .sat
        }
    }

    private func distanceMeters(from coord: CLLocationCoordinate2D, to station: Station) -> Double {
        let from = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let to = CLLocation(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude)
        return from.distance(from: to)
    }

    private func formatDistanceDebug(_ meters: Double) -> String {
        if meters < 1000 {
            return String(format: "%.0fm", meters)
        } else {
            return String(format: "%.2fkm", meters / 1000)
        }
    }

    private func debugSimulateArrival(delaySeconds: TimeInterval = 0) {
        guard let leg = currentGroup.legs.first else { return }
        Task {
            if delaySeconds > 0 {
                let allowed = await NotificationAuthorizationManager.ensureAuthorized()
                if allowed {
                    scheduleSimulatedArrivalNotification(delaySeconds: delaySeconds, leg: leg)
                }
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            var subscriptionId = (liveSession ?? notificationSubscription)?.id
            if subscriptionId == nil {
                if notificationStore.combinedSubscriptions.isEmpty {
                    await notificationStore.refresh()
                }
                subscriptionId = notificationStore.combinedSubscriptions.first(where: { sub in
                    sub.legs.contains(where: { $0.from.uppercased() == leg.fromStation.crs.uppercased() && $0.to.uppercased() == leg.toStation.crs.uppercased() })
                })?.id
            }
            guard let subscriptionId else {
                ToastStore.shared.show("No active notifications found for this journey", icon: "exclamationmark.triangle.fill")
                return
            }
            NotificationGeofenceManager.shared.simulateArrival(
                subscriptionId: subscriptionId,
                from: leg.fromStation.crs,
                to: leg.toStation.crs,
                sendNotification: delaySeconds == 0
            )
            await notificationStore.refresh()
            ToastStore.shared.show("Simulated arrival for \(leg.fromStation.name) → \(leg.toStation.name)", icon: "checkmark.circle.fill")
        }
    }

    private func scheduleSimulatedArrivalNotification(delaySeconds: TimeInterval, leg: Journey) {
        let content = UNMutableNotificationContent()
        content.title = "Simulated arrival at \(leg.fromStation.name)"
        content.body = "Tap to mute notifications for \(leg.toStation.name) today."
        content.sound = .default
        content.categoryIdentifier = NotificationCategoryId.stationArrival

        var info: [AnyHashable: Any] = [
            NotificationPayloadKeys.from: leg.fromStation.crs.uppercased(),
            NotificationPayloadKeys.to: leg.toStation.crs.uppercased(),
            NotificationPayloadKeys.fromName: leg.fromStation.name,
            NotificationPayloadKeys.toName: leg.toStation.name,
            NotificationPayloadKeys.legKey: NotificationMuteStorage.legKey(from: leg.fromStation.crs, to: leg.toStation.crs),
            NotificationPayloadKeys.alertType: "simulated_arrival"
        ]
        if let subscriptionId = (liveSession ?? notificationSubscription)?.id {
            info[NotificationPayloadKeys.subscriptionId] = subscriptionId
        }
        content.userInfo = info

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1.0, delaySeconds), repeats: false)
        let request = UNNotificationRequest(
            identifier: "debug_simulated_arrival_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func debugSendLegNotification(delaySeconds: TimeInterval = 1.5) {
        guard let leg = currentGroup.legs.first else { return }
        let subscriptionId = (liveSession ?? notificationSubscription)?.id
        Task {
            let allowed = await NotificationAuthorizationManager.ensureAuthorized()
            guard allowed else {
                ToastStore.shared.show("Notifications are disabled", icon: "bell.slash.fill")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "\(leg.fromStation.name) → \(leg.toStation.name)"
            content.body = "Debug alert: long-press to mute this journey leg for today."
            content.sound = .default
            content.categoryIdentifier = NotificationCategoryId.journeyLegAlert

            var info: [AnyHashable: Any] = [
                NotificationPayloadKeys.from: leg.fromStation.crs.uppercased(),
                NotificationPayloadKeys.to: leg.toStation.crs.uppercased(),
                NotificationPayloadKeys.fromName: leg.fromStation.name,
                NotificationPayloadKeys.toName: leg.toStation.name,
                NotificationPayloadKeys.legKey: NotificationMuteStorage.legKey(from: leg.fromStation.crs, to: leg.toStation.crs),
                NotificationPayloadKeys.alertType: "debug"
            ]
            if let subscriptionId {
                info[NotificationPayloadKeys.subscriptionId] = subscriptionId
            }
            content.userInfo = info

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(0.5, delaySeconds), repeats: false)
            let request = UNNotificationRequest(
                identifier: "debug_leg_notification_\(Date().timeIntervalSince1970)",
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
            ToastStore.shared.show("Scheduled debug notification", icon: "bell.badge.fill")
        }
    }

    private func debugClearLocalMute() {
        guard let leg = currentGroup.legs.first else { return }
        NotificationMuteStorage.clearMute(from: leg.fromStation.crs, to: leg.toStation.crs)
        Task { await notificationStore.refresh() }
        ToastStore.shared.show("Cleared local mute for today", icon: "bell")
    }

    private func currentDateKeyUTC() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func formatTime(_ isoString: String) -> String? {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoString) else { return nil }
        let output = DateFormatter()
        output.dateFormat = "HH:mm"
        return output.string(from: date)
    }

    private func manualRefresh() async {
        refreshing = true
        let ids = currentGroup.legs.flatMap { departures(for: $0).prefix(5).map { $0.serviceID } }
        await depStore.ensureServiceDetails(for: Array(Set(ids)), force: true)
        refreshing = false
    }

    private func prefetchServiceDetailsIfNeeded() async {
        let ids = currentGroup.legs.flatMap { departures(for: $0).prefix(5).map { $0.serviceID } }
        await depStore.ensureServiceDetails(for: Array(Set(ids)))
    }

    private func refreshServiceDetails() async {
        let ids = currentGroup.legs.flatMap { departures(for: $0).prefix(5).map { $0.serviceID } }
        await depStore.ensureServiceDetails(for: Array(Set(ids)), force: true)
    }
}

private struct AlertMsg: Identifiable { let id = UUID(); let text: String }

private struct JourneySummary {
    let legs: [JourneySummaryLeg]
    let transfers: [JourneyTransfer]
}

private struct JourneySummaryOptionHeader: View {
    let optionNumber: Int
    let summary: JourneySummary
    let isPinned: Bool
    let onPin: () -> Void
    let onUnpin: () -> Void
    @EnvironmentObject var depStore: DeparturesStore
    @State private var showingUnpinConfirmation = false

    private var departureTime: String {
        summary.legs.first?.departureTime ?? "—"
    }

    private var finalArrivalTime: String {
        guard let last = summary.legs.last else { return "—" }
        return arrivalTime(for: last) ?? "—"
    }

    private func arrivalTime(for legSummary: JourneySummaryLeg) -> String? {
        guard let details = depStore.serviceDetailsById[legSummary.departure.serviceID] else {
            return legSummary.arrivalTime
        }
        let targetCRS = legSummary.leg.toStation.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let cp = details.allStations.first(where: { $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS }) {
            return callingPointDisplayTime(cp)
        }
        if details.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS {
            if let ata = details.ata, ata != "Cancelled" {
                if ata == "On time", let sta = details.sta { return sta }
                return ata
            }
            if let sta = details.sta { return sta }
        }
        let normalizedTarget = normalizeStationName(legSummary.leg.toStation.name)
        if let cp = details.allStations.first(where: { normalizeStationName($0.locationName) == normalizedTarget }) {
            return callingPointDisplayTime(cp)
        }
        return legSummary.arrivalTime
    }

    private func callingPointDisplayTime(_ cp: CallingPoint) -> String {
        if let at = cp.at, at != "Cancelled" { return at == "On time" ? cp.st : at }
        if let et = cp.et, et != "Cancelled" { return et == "On time" ? cp.st : et }
        return cp.st
    }

    private func normalizeStationName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private var routeLabel: String {
        let start = summary.legs.first?.leg.fromStation.name ?? "journey"
        let end = summary.legs.last?.leg.toStation.name ?? "journey"
        return "\(start) → \(end)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Option \(optionNumber)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Spacer()
            Text("Dep \(departureTime)")
            Text("Arr \(finalArrivalTime)")
            Button {
                if isPinned {
                    showingUnpinConfirmation = true
                } else {
                    onPin()
                }
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isPinned ? .orange : .secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPinned ? "Unpin journey option" : "Pin journey option")
            .accessibilityHint(isPinned ? "Removes this pinned multi-leg journey." : "Pins this full multi-leg journey so all legs appear together in Pinned.")
            .confirmationDialog(
                "Remove pinned journey?",
                isPresented: $showingUnpinConfirmation
            ) {
                Button("Unpin journey", role: .destructive) {
                    onUnpin()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will remove the pinned \(routeLabel) journey option.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }
}

private struct JourneySummaryLeg: Identifiable {
    let id = UUID()
    let leg: Journey
    let departure: DepartureV2
    let departureTime: String
    let arrivalTime: String?
}

private struct JourneyTransfer: Identifiable {
    let id = UUID()
    let station: Station
    let arrivalTime: String?
    let departureTime: String
    let minutes: Int?
}

private struct JourneySummaryLegRow: View {
    let summary: JourneySummaryLeg
    let transfer: JourneyTransfer?
    let legNumber: Int
    @EnvironmentObject var depStore: DeparturesStore
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4
    @AppStorage("showTransferWarnings") private var showTransferWarnings: Bool = true
    @AppStorage("transferWarningThresholdMinutes") private var transferWarningThresholdMinutes: Int = 3

    private var isCancelledDeparture: Bool {
        if summary.departure.isCancelled { return true }
        return summary.departure.departureTime.estimated
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "cancelled"
    }

    private var originalScheduledLabel: String {
        let scheduled = summary.departure.departureTime.scheduled
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = scheduled.isEmpty ? summary.departureTime : scheduled
        return "Originally scheduled for \(value)"
    }

    private var arrivalTimeText: String {
        summary.arrivalTime ?? arrivalTimeFromDetails() ?? "—"
    }

    private func arrivalTimeFromDetails() -> String? {
        guard let details = depStore.serviceDetailsById[summary.departure.serviceID] else { return nil }
        let targetCRS = summary.leg.toStation.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let cp = details.allStations.first(where: { $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS }) {
            return callingPointDisplayTime(cp)
        }
        if details.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS {
            if let ata = details.ata, ata != "Cancelled" {
                if ata == "On time", let sta = details.sta { return sta }
                return ata
            }
            if let sta = details.sta { return sta }
        }
        let normalizedTarget = normalizeStationName(summary.leg.toStation.name)
        if let cp = details.allStations.first(where: { normalizeStationName($0.locationName) == normalizedTarget }) {
            return callingPointDisplayTime(cp)
        }
        return nil
    }

    private func callingPointDisplayTime(_ cp: CallingPoint) -> String {
        if let at = cp.at, at != "Cancelled" { return at == "On time" ? cp.st : at }
        if let et = cp.et, et != "Cancelled" { return et == "On time" ? cp.st : et }
        return cp.st
    }

    private func normalizeStationName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private var timeColor: Color {
        colorForDelay(estimated: summary.departure.departureTime.estimated,
                      scheduled: summary.departure.departureTime.scheduled)
    }

    private var isBus: Bool {
        summary.departure.serviceType.lowercased() == "bus" || (summary.departure.platform?.uppercased() == "BUS")
    }

    private var destinationLabel: String {
        if let first = summary.departure.destination.first {
            if let via = first.via, !via.isEmpty {
                return "\(first.locationName) \(via)"
            }
            return first.locationName
        }
        return "\(summary.leg.fromStation.name) → \(summary.leg.toStation.name)"
    }

    private var headingText: String {
        "\(summary.leg.fromStation.name) → \(destinationLabel)"
    }

    private var legBadge: some View {
        Text("\(legNumber)")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color(.systemTeal).opacity(0.25)))
    }

    private func statusInfo() -> (text: String, color: Color)? {
        if let mins = departureDelayMinutes(
            estimated: summary.departure.departureTime.estimated,
            scheduled: summary.departure.departureTime.scheduled
        ), mins > 0 {
            return ("Departure delayed by \(mins) minute\(mins == 1 ? "" : "s")", .yellow)
        }
        let estimated = summary.departure.departureTime.estimated
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if estimated == "delayed" {
            return ("Departure status unknown at present", .yellow)
        }
        guard let details = depStore.serviceDetailsById[summary.departure.serviceID] else { return nil }
        if let live = computeLiveStatus(from: details, within: summary.leg.fromStation.crs, toCRS: summary.leg.toStation.crs) {
            let c: Color = live.delayMinutes >= 5 ? .red : (live.delayMinutes > 0 ? .yellow : .green)
            return (live.text, c)
        }
        return nil
    }

    private func transferInfo(_ transfer: JourneyTransfer) -> some View {
        // Display transfer info with warning if tight connection
        let minutesText = transfer.minutes.map { "\($0) minute connection time" } ?? "—"
        let threshold = max(1, transferWarningThresholdMinutes)
        let isTight = showTransferWarnings && (transfer.minutes ?? Int.max) < threshold
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if isTight {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.blue)
                Text("Change at \(transfer.station.name) • \(minutesText)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var metaLine: some View {
        if isCancelledDeparture {
            Text(originalScheduledLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let length = summary.departure.length
            HStack(spacing: 10) {
                Text("Arr \(arrivalTimeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isBus {
                    EmptyView()
                } else if let l = length, l > 0 {
                    HStack(spacing: 4) {
                        Text("\(l) cars")
                        if l <= minShortTrainCars {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Text("Unknown length")
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let transfer {
                transferInfo(transfer)
                    .padding(.bottom, 10)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        legBadge
                        Text(headingText)
                            .lineLimit(2)
                    }
                    metaLine
                    if let info = statusInfo() {
                        HStack(spacing: 6) {
                            Circle().fill(info.color).frame(width: 8, height: 8)
                            Text(info.text)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    if !isCancelledDeparture {
                        PlatformBadge(platform: summary.departure.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (summary.departure.platform ?? "TBC") : "TBC", isBus: isBus)
                    }
                    Text(summary.departureTime)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(timeColor)
                        .monospacedDigit()
                }
            }
            .padding(.top, transfer == nil ? 0 : 8)
        }
        .contentShape(Rectangle())
        .task { await depStore.ensureServiceDetails(for: [summary.departure.serviceID]) }
    }
}

private struct DeparturePinButton: View {
    let dep: DepartureV2
    let leg: Journey
    @EnvironmentObject var depStore: DeparturesStore
    @EnvironmentObject var activityMgr: LiveActivityManager
    @State private var showingUnpinConfirmation = false

    private var isPinned: Bool {
        depStore.isPinned(dep, fromCRS: leg.fromStation.crs, toCRS: leg.toStation.crs)
    }

    private var destination: String {
        dep.destination.first?.locationName ?? leg.toStation.name
    }

    var body: some View {
        Button {
            if isPinned {
                showingUnpinConfirmation = true
            } else {
                depStore.pin(dep, fromCRS: leg.fromStation.crs, toCRS: leg.toStation.crs)
                Task {
                    await activityMgr.start(
                        for: leg,
                        depStore: depStore,
                        preferredServiceID: dep.serviceID,
                        triggeredByUser: true,
                        bypassSuppression: true
                    )
                }
            }
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.body.weight(.semibold))
                .foregroundStyle(isPinned ? .orange : .secondary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPinned ? "Unpin departure" : "Pin departure")
        .accessibilityHint(isPinned ? "Removes this departure from pinned list after confirmation." : "Keeps this departure visible after its departure time.")
        .confirmationDialog(
            "Remove pinned departure?",
            isPresented: $showingUnpinConfirmation
        ) {
            Button("Unpin departure", role: .destructive) {
                depStore.unpin(dep, fromCRS: leg.fromStation.crs, toCRS: leg.toStation.crs)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove the pinned \(leg.fromStation.name) → \(destination) departure.")
        }
    }
}

private struct DepartureRow: View {
    let dep: DepartureV2
    let fromCRS: String
    let toCRS: String
    let fromName: String
    let toName: String
    let allDepartures: [DepartureV2]
    @EnvironmentObject var depStore: DeparturesStore
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4

    private var isCancelledDeparture: Bool {
        if dep.isCancelled { return true }
        return dep.departureTime.estimated
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "cancelled"
    }

    private var originalScheduledLabel: String {
        let scheduled = dep.departureTime.scheduled
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = scheduled.isEmpty ? dep.departureTime.estimated : scheduled
        return "Originally scheduled for \(value)"
    }

    private var timeColor: Color {
        colorForDelay(estimated: dep.departureTime.estimated, scheduled: dep.departureTime.scheduled)
    }

    private var isBus: Bool {
        dep.serviceType.lowercased() == "bus" || (dep.platform?.uppercased() == "BUS")
    }

    private var destinationLabel: String {
        if let first = dep.destination.first {
            if let via = first.via, !via.isEmpty {
                return "\(first.locationName) \(via)"
            }
            return first.locationName
        }
        // Fallback to the journey segment if destination missing
        return "\(fromName) → \(toName)"
    }

    @ViewBuilder
    private var metaLine: some View {
        if isCancelledDeparture {
            Text(originalScheduledLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let length = dep.length
            HStack(spacing: 10) {

                // Estimated arrival at destination station
                if let arr = arrivalLabel() {
                    Text(arr)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isBus {
                    EmptyView()
                } else if let l = length, l > 0 {
                    HStack(spacing: 4) {
                        Text("\(l) cars")
                        if l <= minShortTrainCars {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Text("Unknown length")
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusInfo() -> (text: String, color: Color)? {
        if let mins = departureDelayMinutes(
            estimated: dep.departureTime.estimated,
            scheduled: dep.departureTime.scheduled
        ), mins > 0 {
            return ("Departure delayed by \(mins) minute\(mins == 1 ? "" : "s")", .yellow)
        }
        let estimated = dep.departureTime.estimated
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if estimated == "delayed" {
            return ("Departure status unknown at present", .yellow)
        }
        guard let details = depStore.serviceDetailsById[dep.serviceID] else { return nil }
        if let live = computeLiveStatus(from: details, within: fromCRS, toCRS: toCRS) {
            let c: Color = live.delayMinutes >= 5 ? .red : (live.delayMinutes > 0 ? .yellow : .green)
            return (live.text, c)
        }
        return nil
    }

    private func arrivalLabel() -> String? {
        guard let details = depStore.serviceDetailsById[dep.serviceID] else { return nil }
        if let cp = details.allStations.first(where: { $0.crs == toCRS }) {
            if let et = cp.et, !et.isEmpty, et.lowercased() != "on time" { return "Arr \(et)" }
            return "Arr \(cp.st)"
        }
        return nil
    }

    // MARK: - Slower than later service detection
    private func parseHHmm(_ t: String?) -> Date? {
        guard let t = t else { return nil }
        let lower = t.lowercased()
        if lower == "delayed" || lower == "cancelled" || lower == "on time" { return nil }
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let now = Date()
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = h; comps.minute = m
        guard var candidate = Calendar.current.date(from: comps) else { return nil }
        if candidate < now && now.timeIntervalSince(candidate) > 6 * 3600 {
            candidate = Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private func departureDate(_ d: DepartureV2) -> Date? {
        return parseHHmm(d.departureTime.estimated) ?? parseHHmm(d.departureTime.scheduled)
    }

    private func arrivalDate(_ d: DepartureV2) -> Date? {
        guard let details = depStore.serviceDetailsById[d.serviceID] else { return nil }
        guard let cp = details.allStations.first(where: { $0.crs == toCRS }) else { return nil }
        let t: String = {
            if let et = cp.et, !et.isEmpty, et.lowercased() != "on time" { return et }
            return cp.st
        }()
        return parseHHmm(t)
    }

    private func fasterLaterLabel() -> String? {
        guard let thisArr = arrivalDate(dep), let thisDep = departureDate(dep) else { return nil }
        var bestArrival: Date? = nil
        var bestArrivalStr: String? = nil
        for other in allDepartures {
            guard let oDep = departureDate(other), oDep > thisDep else { continue }
            guard let oArr = arrivalDate(other) else { continue }
            if oArr < thisArr { // later but arrives earlier
                if bestArrival == nil || oArr < bestArrival! {
                    bestArrival = oArr
                    let df = DateFormatter(); df.dateFormat = "HH:mm"
                    bestArrivalStr = df.string(from: oArr)
                }
            }
        }
        if let best = bestArrivalStr { return "Faster later service (arr \(best))" }
        return nil
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(destinationLabel)
                metaLine
                if let warn = fasterLaterLabel() {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(warn)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                if let info = statusInfo() {
                    HStack(spacing: 6) {
                        Circle().fill(info.color).frame(width: 8, height: 8)
                        Text(info.text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if !isCancelledDeparture {
                    PlatformBadge(platform: dep.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (dep.platform ?? "TBC") : "TBC", isBus: isBus)
                }
                Text(dep.departureTime.estimated)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(timeColor)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .task { await depStore.ensureServiceDetails(for: [dep.serviceID]) }
    }
}

// MARK: - Live Session Row
private struct LiveJourneySessionRow: View {
    let isActive: Bool
    let isBusy: Bool
    let activeCount: Int
    let infoMessage: String?
    var onToggle: () -> Void

    private var subtitle: String {
        if isActive {
            return "Notifications are running for this journey"
        }
        if activeCount >= 3 {
            return "Starting a new session will replace the oldest active one"
        }
        return "Manually start Live Activity + notifications"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(isActive ? .green : .secondary)
                    .symbolEffect(.pulse)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Activity + Notifications")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: isActive ? .destructive : nil) {
                    onToggle()
                } label: {
                    if isBusy {
                        ProgressView()
                    } else {
                        Text(isActive ? "Stop" : "Start")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.bordered)
                .tint(isActive ? .red : .blue)
                .disabled(isBusy)
            }

            if let infoMessage, !infoMessage.isEmpty {
                Label(infoMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NotificationScheduleRow: View {
    let subtitle: String
    let detail: String?
    let isMuted: Bool
    let isScheduled: Bool
    let isDisabled: Bool
    var onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isScheduled ? (isMuted ? "bell.slash.fill" : "bell.badge.fill") : "bell.badge")
                    .foregroundStyle(isDisabled ? Color.secondary : (isMuted ? Color.orange : Color.blue))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Schedule notifications")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let detail {
                        HStack(spacing: 4) {
                            if isMuted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption2)
                            }
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(isMuted ? .orange : .secondary)
                                .fontWeight(isMuted ? .medium : .regular)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .padding(.vertical, 4)
    }
}
