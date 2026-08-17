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
                                NavigationLink {
                                    JourneyHistoryDetailView(record: record)
                                } label: {
                                    JourneyHistoryRow(record: record)
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

                if !historyStore.records.isEmpty {
                    Menu {
                        Button("Share history", systemImage: "square.and.arrow.up") {
                            share(records: historyStore.records)
                        }
                        Button("Clear all history", role: .destructive) {
                            showingClearConfirmation = true
                        }
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
                    if !record.operatorSearchText.isEmpty {
                        Text(record.operatorSearchText)
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

private struct JourneyHistoryDetailView: View {
    let record: JourneyHistoryRecord
    @EnvironmentObject private var historyStore: JourneyHistoryStore
    @State private var shareItem: JourneyHistoryShareItem?
    @State private var exportError: String?

    var body: some View {
        List {
            Section("Journey") {
                LabeledContent("Planned", value: "\(record.plannedOriginName) → \(record.plannedDestinationName)")
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
                    LabeledContent("Delay", value: "\(delay) min")
                }
            }

            ForEach(Array(record.legs.enumerated()), id: \.element.id) { index, leg in
                Section("Leg \(index + 1)") {
                    LabeledContent("Route", value: "\(leg.fromStation.name) → \(leg.toStation.name)")
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
                    routeMapLink(for: leg, index: index)
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
                Label("View service route map", systemImage: "map")
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
        (leg.serviceCallingPoints ?? leg.callingPoints).map {
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
