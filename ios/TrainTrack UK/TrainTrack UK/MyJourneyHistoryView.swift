import SwiftUI
import UIKit

struct MyJourneyHistoryView: View {
    @EnvironmentObject private var historyStore: JourneyHistoryStore
    @State private var searchText = ""
    @State private var dateFilter: JourneyHistoryDateFilter = .all
    @State private var customStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate = Date()
    @State private var showingCustomDates = false
    @State private var showingClearConfirmation = false
    @State private var shareItem: JourneyHistoryShareItem?
    @State private var exportError: String?
    @State private var delayRepayOnly = false
    @State private var showOlderDelayRepayJourneys = false
    #if DEBUG
    @State private var isGeneratingTestHistory = false
    @State private var testHistoryMessage: String?
    #endif

    private var shouldShowHistoryActions: Bool {
        #if DEBUG
        true
        #else
        !historyStore.records.isEmpty
        #endif
    }

    private var filteredRecords: [JourneyHistoryRecord] {
        historyStore.records.filter { record in
            guard record.matchesSearch(searchText), matchesDateFilter(record) else { return false }
            guard delayRepayOnly else { return true }
            guard record.isDelayRepay15Plus else { return false }
            return showOlderDelayRepayJourneys
                || JourneyHistoryDelayPolicy.isWithinSubmissionWindow(completedAt: record.completedAt)
        }
    }

    private var groupedRecords: [(date: Date, records: [JourneyHistoryRecord])] {
        let calendar = Calendar.current
        return Dictionary(grouping: filteredRecords) { calendar.startOfDay(for: $0.completedAt) }
            .map { ($0.key, $0.value.sorted { $0.completedAt > $1.completedAt }) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        Group {
            if historyStore.records.isEmpty {
                ContentUnavailableView(
                    "No journey history",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed scheduled and ad hoc journeys will appear here.")
                )
            } else if filteredRecords.isEmpty {
                if delayRepayOnly {
                    ContentUnavailableView {
                        Label("No current Delay Repay journeys", systemImage: "checkmark.circle")
                    } description: {
                        Text("Eligible journeys older than 28 days are hidden because the submission deadline has passed.")
                    } actions: {
                        if !showOlderDelayRepayJourneys {
                            Button("Show older eligible journeys") {
                                showOlderDelayRepayJourneys = true
                            }
                        }
                    }
                } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "No journeys in this range",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Choose a wider date range to see more history.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                List {
                    if delayRepayOnly {
                        Section("Delay Repay") {
                            Toggle("Show older eligible journeys", isOn: $showOlderDelayRepayJourneys)
                            Text("Claims must be submitted within 28 days, so older eligible journeys are hidden by default.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(groupedRecords, id: \.date) { group in
                        Section(group.date.formatted(date: .complete, time: .omitted)) {
                            ForEach(group.records) { record in
                                VStack(spacing: 0) {
                                    NavigationLink {
                                        JourneyHistoryDetailView(record: record)
                                    } label: {
                                        JourneyHistoryRow(record: record)
                                    }
                                    if record.isDelayRepay15Plus {
                                        Divider()
                                            .padding(.top, 4)
                                        JourneyHistoryDelayRepayActions(record: record)
                                            .padding(.top, 8)
                                            .padding(.bottom, 4)
                                    }
                                }
                                .swipeActions {
                                    Button("Delete", role: .destructive) {
                                        historyStore.delete(record)
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        Text("\(historyStore.records.count.formatted()) of \(JourneyHistoryStore.maximumRecordCount.formatted()) journeys stored locally")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Station, CRS, or operator")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    ForEach(JourneyHistoryDateFilter.allCases.filter { $0 != .custom }) { filter in
                        Button {
                            dateFilter = filter
                        } label: {
                            if dateFilter == filter {
                                Label(filter.displayName, systemImage: "checkmark")
                            } else {
                                Text(filter.displayName)
                            }
                        }
                    }
                    Button("Custom range…") {
                        showingCustomDates = true
                    }
                    Divider()
                    Toggle("Delay Repay eligible only", isOn: $delayRepayOnly)
                    if delayRepayOnly {
                        Toggle("Show older eligible journeys", isOn: $showOlderDelayRepayJourneys)
                    }
                } label: {
                    Image(systemName: delayRepayOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : (dateFilter == .all ? "calendar" : "calendar.badge.clock"))
                }
                .accessibilityLabel("Filter journey history")

                if shouldShowHistoryActions {
                    Menu {
                        if !historyStore.records.isEmpty {
                            Button("Share history", systemImage: "square.and.arrow.up") {
                                share(records: historyStore.records)
                            }
                            Button("Clear all history", role: .destructive) {
                                showingClearConfirmation = true
                            }
                        }
                        #if DEBUG
                        Divider()
                        Button(
                            isGeneratingTestHistory ? "Generating test history…" : "Generate test history to 2,000",
                            systemImage: "hammer"
                        ) {
                            generateTestHistory()
                        }
                        .disabled(isGeneratingTestHistory || historyStore.records.count >= JourneyHistoryStore.maximumRecordCount)
                        Button("Generate random multi-leg journey", systemImage: "arrow.triangle.branch") {
                            generateRandomMultiLegJourney()
                        }
                        .disabled(isGeneratingTestHistory)
                        #endif
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Journey history actions")
                }
            }
        }
        .sheet(isPresented: $showingCustomDates) {
            NavigationStack {
                Form {
                    DatePicker("From", selection: $customStartDate, displayedComponents: .date)
                        .onChange(of: customStartDate) { _, newStartDate in
                            if customEndDate < newStartDate {
                                customEndDate = newStartDate
                            }
                        }
                    DatePicker("To", selection: $customEndDate, in: customStartDate..., displayedComponents: .date)
                }
                .navigationTitle("Date Range")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingCustomDates = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            dateFilter = .custom
                            showingCustomDates = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $shareItem) { item in
            JourneyHistoryShareSheet(url: item.url)
        }
        .alert("Unable to share history", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "The export could not be created.")
        }
        #if DEBUG
        .alert("Test journey history", isPresented: Binding(
            get: { testHistoryMessage != nil },
            set: { if !$0 { testHistoryMessage = nil } }
        )) {
            Button("OK", role: .cancel) { testHistoryMessage = nil }
        } message: {
            Text(testHistoryMessage ?? "")
        }
        #endif
        .confirmationDialog(
            "Clear all journey history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear all history", role: .destructive) {
                historyStore.clear()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes all locally stored journey history.")
        }
    }

    private func matchesDateFilter(_ record: JourneyHistoryRecord) -> Bool {
        let calendar = Calendar.current
        switch dateFilter {
        case .all:
            return true
        case .last30Days:
            return record.completedAt >= (calendar.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast)
        case .last90Days:
            return record.completedAt >= (calendar.date(byAdding: .day, value: -90, to: Date()) ?? .distantPast)
        case .lastYear:
            return record.completedAt >= (calendar.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast)
        case .custom:
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customEndDate)) ?? customEndDate
            return record.completedAt >= calendar.startOfDay(for: customStartDate)
                && record.completedAt < endExclusive
        }
    }

    private func share(records: [JourneyHistoryRecord]) {
        do {
            shareItem = JourneyHistoryShareItem(url: try JourneyHistoryExporter.makeCSVFile(records: records))
        } catch {
            exportError = error.localizedDescription
        }
    }

    #if DEBUG
    private func generateTestHistory() {
        guard !isGeneratingTestHistory else { return }
        isGeneratingTestHistory = true
        Task {
            defer { isGeneratingTestHistory = false }
            do {
                let count = try await historyStore.generateDebugHistoryToCapacity()
                testHistoryMessage = count == 0
                    ? "Journey history already contains 2,000 records."
                    : "Generated \(count.formatted()) test journeys. History now contains \(historyStore.records.count.formatted()) records."
            } catch {
                testHistoryMessage = "Test history could not be generated: \(error.localizedDescription)"
            }
        }
    }

    private func generateRandomMultiLegJourney() {
        guard !isGeneratingTestHistory else { return }
        isGeneratingTestHistory = true
        Task {
            defer { isGeneratingTestHistory = false }
            do {
                let record = try await historyStore.generateRandomDebugMultiLegJourney()
                testHistoryMessage = "Generated \(record.routeTitle) with \(record.legs.count) legs."
            } catch {
                testHistoryMessage = "The multi-leg test journey could not be generated: \(error.localizedDescription)"
            }
        }
    }
    #endif
}

private enum JourneyHistoryDateFilter: String, CaseIterable, Identifiable {
    case all
    case last30Days
    case last90Days
    case lastYear
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All dates"
        case .last30Days: return "Last 30 days"
        case .last90Days: return "Last 90 days"
        case .lastYear: return "Last year"
        case .custom: return "Custom range"
        }
    }
}

private struct JourneyHistoryRow: View {
    let record: JourneyHistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.routeTitle)
                    .font(.headline)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                Text(record.detectedDepartureAt, style: .time)
                Image(systemName: "arrow.right")
                    .accessibilityHidden(true)
                if let arrival = record.detectedArrivalAt {
                    Text(arrival, style: .time)
                } else {
                    Text(record.outcome.displayName)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 10) {
                HStack(spacing: 6) {
                    if !record.operatorDisplayText.isEmpty {
                        Text(record.operatorDisplayText)
                            .lineLimit(1)
                    }
                    if record.outcome != .completed {
                        Label(record.outcome.displayName, systemImage: "exclamationmark.circle")
                    }
                }
                .foregroundStyle(record.outcome == .completed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                Spacer(minLength: 8)
                JourneyHistoryArrivalStatusLabel(record: record)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

private struct JourneyHistoryArrivalStatusLabel: View {
    let record: JourneyHistoryRecord

    private var dotColor: Color {
        guard record.actualArrivalAt != nil else {
            return record.outcome == .completed ? .secondary : .orange
        }
        guard let delay = record.delayMinutes else { return .green }
        if delay >= JourneyHistoryDelayPolicy.delayRepayThresholdMinutes { return .red }
        if delay > 0 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(JourneyHistoryArrivalStatusText.text(
                actualArrival: record.actualArrivalAt,
                detectedArrival: record.detectedArrivalAt,
                delayMinutes: record.delayMinutes,
                outcome: record.outcome
            ))
            .multilineTextAlignment(.trailing)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct JourneyHistoryDelayRepayActions: View {
    let record: JourneyHistoryRecord
    @EnvironmentObject private var historyStore: JourneyHistoryStore
    @Environment(\.openURL) private var openURL
    @State private var isResolvingClaimURL = false
    @State private var claimError: String?
    @ScaledMetric(relativeTo: .subheadline) private var actionControlHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var actionMenuWidth: CGFloat = 52

    private var statusColor: Color {
        switch record.delayRepayClaimStatus {
        case .processing: return .orange
        case .successful: return .green
        case .rejected: return .red
        case .hidden: return .secondary
        case nil: return .accentColor
        }
    }

    private var statusText: String {
        if isResolvingClaimURL {
            return "Opening claim page…"
        }
        return record.delayRepayClaimStatus?.displayName ?? "Delay Repay eligible"
    }

    private var statusSystemImage: String? {
        record.delayRepayClaimStatus?.systemImage
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                if isResolvingClaimURL {
                    ProgressView()
                        .controlSize(.small)
                } else if let statusSystemImage {
                    Image(systemName: statusSystemImage)
                } else {
                    Text("£")
                }

                Text(statusText)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 12)
            .frame(height: actionControlHeight)
            .background(statusColor.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            Menu {
                Button {
                    openClaimPage()
                } label: {
                    Label("Claim Delay Repay", systemImage: "sterlingsign.circle")
                }

                Divider()

                ForEach([
                    JourneyHistoryDelayRepayClaimStatus.processing,
                    .successful,
                    .rejected
                ]) { status in
                    Button {
                        historyStore.setDelayRepayClaimStatus(status, for: record)
                    } label: {
                        if record.delayRepayClaimStatus == status {
                            Label(status.actionName, systemImage: "checkmark")
                        } else {
                            Label(status.actionName, systemImage: status.systemImage)
                        }
                    }
                }
                if record.delayRepayClaimStatus != nil {
                    Divider()
                    Button("Reset claim status", systemImage: "arrow.counterclockwise") {
                        historyStore.setDelayRepayClaimStatus(nil, for: record)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: actionMenuWidth, height: actionControlHeight)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isResolvingClaimURL)
            .accessibilityLabel("Delay Repay claim options")
        }
        .alert("Unable to open Delay Repay", isPresented: Binding(
            get: { claimError != nil },
            set: { if !$0 { claimError = nil } }
        )) {
            Button("OK", role: .cancel) { claimError = nil }
        } message: {
            Text(claimError ?? "The claim page could not be opened.")
        }
    }

    private func openClaimPage() {
        guard !isResolvingClaimURL else { return }
        guard let leg = JourneyHistoryDelayPolicy.responsibleOperatorLeg(in: record) else {
            claimError = "No train operator was recorded for this journey."
            return
        }

        isResolvingClaimURL = true
        Task {
            defer { isResolvingClaimURL = false }
            do {
                let url = try await NetworkServicePhone.shared.fetchDelayRepayClaimURL(
                    operatorCode: leg.operatorCode,
                    operatorName: leg.operatorName
                )
                openURL(url) { accepted in
                    if !accepted {
                        claimError = "The operator’s claim page could not be opened."
                    }
                }
            } catch {
                claimError = "The claim page for \(leg.operatorName ?? "this operator") is currently unavailable."
            }
        }
    }
}

private struct JourneyHistoryDetailView: View {
    let record: JourneyHistoryRecord
    @EnvironmentObject private var historyStore: JourneyHistoryStore
    @State private var shareItem: JourneyHistoryShareItem?
    @State private var exportError: String?

    var body: some View {
        List {
            Section("Journey") {
                LabeledContent("Planned", value: "\(record.plannedOriginName) → \(record.plannedDestinationName)")
                journeyRouteMapLink
                if record.recordedDestinationCRS != record.plannedDestinationCRS {
                    LabeledContent("Recorded to", value: record.recordedDestinationName)
                }
                LabeledContent("Source", value: record.source.displayName)
                LabeledContent("Outcome", value: record.outcome.displayName)
                LabeledContent("Departed", value: record.detectedDepartureAt.formatted(date: .abbreviated, time: .shortened))
                if let arrival = record.detectedArrivalAt {
                    LabeledContent("Arrived", value: arrival.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section("Official arrival") {
                if let scheduled = record.scheduledArrivalAt {
                    LabeledContent("Scheduled", value: scheduled.formatted(date: .omitted, time: .shortened))
                }
                if let actual = record.actualArrivalAt {
                    LabeledContent("Actual", value: actual.formatted(date: .omitted, time: .shortened))
                } else if let detectedArrival = record.detectedArrivalAt,
                          JourneyHistoryOfficialArrivalPolicy.isUnavailable(
                            actualArrival: record.actualArrivalAt,
                            detectedArrival: detectedArrival
                          ) {
                    Text(JourneyHistoryArrivalStatusText.text(
                        actualArrival: nil,
                        detectedArrival: detectedArrival,
                        delayMinutes: nil,
                        outcome: record.outcome
                    ))
                    .foregroundStyle(.secondary)
                } else {
                    Text("Awaiting confirmed official arrival")
                        .foregroundStyle(.secondary)
                }
                if let delay = record.delayMinutes {
                    LabeledContent("Delay", value: delay == 0 ? "On time" : "\(delay) min")
                }
            }

            ForEach(Array(record.legs.enumerated()), id: \.element.id) { index, leg in
                Section(legSectionTitle(for: leg, index: index)) {
                    if record.legs.count > 1 {
                        routeMapLink(for: leg, index: index)
                    }
                    if let operatorName = leg.operatorName {
                        LabeledContent("Operator", value: operatorName)
                    }
                    if let serviceID = leg.serviceID {
                        LabeledContent("Service", value: serviceID)
                    }
                    if let departed = leg.detectedDepartureAt {
                        LabeledContent("Detected departure", value: departed.formatted(date: .omitted, time: .shortened))
                    }
                    if let arrived = leg.detectedArrivalAt {
                        LabeledContent("Detected arrival", value: arrived.formatted(date: .omitted, time: .shortened))
                    }
                }
            }
        }
        .navigationTitle(record.routeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Share journey", systemImage: "square.and.arrow.up") {
                    do {
                        shareItem = JourneyHistoryShareItem(
                            url: try JourneyHistoryExporter.makeCSVFile(records: [record])
                        )
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
            }
        }
        .task(id: record.id) {
            _ = await historyStore.refreshOfficialArrival(for: record)
        }
        .sheet(item: $shareItem) { item in
            JourneyHistoryShareSheet(url: item.url)
        }
        .alert("Unable to share journey", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "The export could not be created.")
        }
    }

    @ViewBuilder
    private var journeyRouteMapLink: some View {
        if !journeyRouteMapLegs.isEmpty {
            NavigationLink {
                journeyRouteMapDestination
            } label: {
                Label("View Route Map", systemImage: "map")
            }
        }
    }

    @ViewBuilder
    private var journeyRouteMapDestination: some View {
        if record.legs.count == 1,
           let leg = record.legs.first,
           let serviceID = leg.serviceID {
            let departure = leg.scheduledDepartureAt ?? leg.detectedDepartureAt ?? record.detectedDepartureAt
            ServiceMapView(
                serviceID: serviceID,
                fromCRS: leg.fromStation.crs,
                toCRS: record.recordedDestinationCRS,
                departureTime: departure.formatted(date: .omitted, time: .shortened),
                destinationName: record.recordedDestinationName,
                isHistorical: true,
                fallbackCallingPoints: mapCallingPoints(for: leg),
                historicalArrivalTime: historicalArrivalTime(for: leg)
            )
        } else {
            JourneyHistoryCombinedRouteMapView(legs: journeyRouteMapLegs)
        }
    }

    private var journeyRouteMapLegs: [JourneyHistoryRouteMapLeg] {
        let mapLegs = record.legs.enumerated().compactMap { index, leg -> JourneyHistoryRouteMapLeg? in
            let stations = mapCallingPoints(for: leg)
            guard stations.count >= 2 else { return nil }
            return JourneyHistoryRouteMapLeg(
                id: leg.id,
                stations: stations,
                fromCRS: leg.fromStation.crs,
                toCRS: travelledDestinationCRS(for: leg, index: index),
                historicalArrivalTime: historicalArrivalTime(for: leg)
            )
        }.filter {
            $0.highlightedTravelRange != nil
        }
        return mapLegs.count == record.legs.count ? mapLegs : []
    }

    private func legSectionTitle(for leg: JourneyHistoryLeg, index: Int) -> String {
        let route = "\(leg.fromStation.name) → \(leg.toStation.name)"
        return record.legs.count > 1 ? "Leg \(index + 1): \(route)" : route
    }

    private func travelledDestinationCRS(for leg: JourneyHistoryLeg, index: Int) -> String {
        index == record.legs.count - 1 ? record.recordedDestinationCRS : leg.toStation.crs
    }

    @ViewBuilder
    private func routeMapLink(for leg: JourneyHistoryLeg, index: Int) -> some View {
        if let serviceID = leg.serviceID {
            let departure = leg.scheduledDepartureAt ?? leg.detectedDepartureAt ?? record.detectedDepartureAt
            let destinationCRS = travelledDestinationCRS(for: leg, index: index)
            let destinationName = travelledDestinationName(for: leg, index: index)
            let callingPoints = mapCallingPoints(for: leg)
            let arrivalTime = historicalArrivalTime(for: leg)
            NavigationLink {
                ServiceMapView(
                    serviceID: serviceID,
                    fromCRS: leg.fromStation.crs,
                    toCRS: destinationCRS,
                    departureTime: departure.formatted(date: .omitted, time: .shortened),
                    destinationName: destinationName,
                    isHistorical: true,
                    fallbackCallingPoints: callingPoints,
                    historicalArrivalTime: arrivalTime
                )
            } label: {
                Label("View Journey Leg Map", systemImage: "map")
            }
        }
    }

    private func travelledDestinationName(for leg: JourneyHistoryLeg, index: Int) -> String {
        index == record.legs.count - 1 ? record.recordedDestinationName : leg.toStation.name
    }

    private func historicalArrivalTime(for leg: JourneyHistoryLeg) -> String? {
        guard let arrival = leg.actualArrivalAt ?? leg.detectedArrivalAt else { return nil }
        let components = Calendar.current.dateComponents([.hour, .minute], from: arrival)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    private func mapCallingPoints(for leg: JourneyHistoryLeg) -> [CallingPoint] {
        let storedCallingPoints = leg.serviceCallingPoints.flatMap { $0.isEmpty ? nil : $0 }
            ?? leg.callingPoints
        return storedCallingPoints.map {
            CallingPoint(
                locationName: $0.locationName,
                crs: $0.crs,
                st: $0.scheduledTime,
                et: $0.estimatedTime,
                at: $0.actualTime,
                isCancelled: $0.actualTime?.caseInsensitiveCompare("Cancelled") == .orderedSame
                    || $0.estimatedTime?.caseInsensitiveCompare("Cancelled") == .orderedSame,
                cancelReason: nil,
                platform: nil,
                length: nil,
                detachFront: nil,
                affectedByDiversion: nil,
                rerouteDelay: nil
            )
        }
    }
}

struct JourneyHistoryRouteMapLeg: Identifiable {
    let id: UUID
    let stations: [CallingPoint]
    let fromCRS: String
    let toCRS: String
    let historicalArrivalTime: String?

    var highlightedTravelRange: ClosedRange<Int>? {
        let normalizedFrom = normalizedCRS(fromCRS)
        let normalizedTo = normalizedCRS(toCRS)
        guard let start = stations.firstIndex(where: { normalizedCRS($0.crs) == normalizedFrom }),
              let end = stations.indices.first(where: { index in
                index >= start && normalizedCRS(stations[index].crs) == normalizedTo
              }) else {
            return nil
        }
        return start...end
    }

    private func normalizedCRS(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

private struct JourneyHistoryCombinedRouteMapView: View {
    let legs: [JourneyHistoryRouteMapLeg]

    @State private var loadedRoutes: [LoadedRoute] = []
    @State private var isLoading = true
    @State private var routeError: String?
    @State private var loadRequestID = UUID()

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading journey route map…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let primary = loadedRoutes.first,
                      let firstLeg = legs.first,
                      let lastLeg = legs.last {
                ServiceRailwayMapView(
                    route: primary.route,
                    stations: primary.leg.stations,
                    additionalRoutes: loadedRoutes.dropFirst().map { loaded in
                        ServiceRailwayMapBranch(
                            id: "journey-leg-\(loaded.leg.id.uuidString)",
                            route: loaded.route,
                            stations: loaded.leg.stations,
                            highlightedTravelRange: loaded.leg.highlightedTravelRange,
                            historicalArrivalTime: loaded.leg.historicalArrivalTime,
                            omitsFirstStationAnnotation: false
                        )
                    },
                    progress: .unavailable,
                    estimatedTrainCoordinate: nil,
                    currentDelayMinutes: nil,
                    fromCRS: firstLeg.fromCRS,
                    toCRS: lastLeg.toCRS,
                    highlightedTravelRange: primary.leg.highlightedTravelRange,
                    historicalArrivalTime: primary.leg.historicalArrivalTime
                )
            } else {
                ContentUnavailableView {
                    Label("Journey map unavailable", systemImage: "map")
                } description: {
                    Text(routeError ?? "The recorded route could not be mapped.")
                } actions: {
                    Button("Try again") {
                        loadRequestID = UUID()
                    }
                }
            }
        }
        .navigationTitle("Journey Route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: loadRequestID) {
            await loadRoutes()
        }
    }

    private func loadRoutes() async {
        isLoading = true
        routeError = nil
        loadedRoutes = []

        var routes: [LoadedRoute] = []
        do {
            for leg in legs {
                try Task.checkCancellation()
                let route = try await RailwayRoutingService.shared.route(
                    forStationCRSs: leg.stations.map(\.crs)
                )
                routes.append(LoadedRoute(leg: leg, route: route))
            }
            try Task.checkCancellation()
            loadedRoutes = routes
        } catch is CancellationError {
            return
        } catch {
            routeError = error.localizedDescription
        }
        isLoading = false
    }

    private struct LoadedRoute: Identifiable {
        var id: UUID { leg.id }
        let leg: JourneyHistoryRouteMapLeg
        let route: ServiceRailwayRoute
    }
}

private struct JourneyHistoryShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct JourneyHistoryShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

#Preview {
    NavigationStack {
        MyJourneyHistoryView()
            .environmentObject(JourneyHistoryStore.shared)
    }
}
