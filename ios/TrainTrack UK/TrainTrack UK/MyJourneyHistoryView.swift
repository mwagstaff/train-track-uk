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
                historyUnavailableCard {
                    ContentUnavailableView(
                        "No journey history",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Completed scheduled and ad hoc journeys will appear here.")
                    )
                }
            } else if filteredRecords.isEmpty {
                if delayRepayOnly {
                    historyUnavailableCard {
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
                    }
                } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    historyUnavailableCard {
                        ContentUnavailableView(
                            "No journeys in this range",
                            systemImage: "calendar.badge.exclamationmark",
                            description: Text("Choose a wider date range to see more history.")
                        )
                    }
                } else {
                    historyUnavailableCard {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            } else {
                List {
                    if delayRepayOnly {
                        Section {
                            Toggle("Show older eligible journeys", isOn: $showOlderDelayRepayJourneys)
                            Text("Claims must be submitted within 28 days, so older eligible journeys are hidden by default.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } header: {
                            RailwayBackgroundSectionHeader(title: "Delay Repay")
                        }
                    }

                    ForEach(groupedRecords, id: \.date) { group in
                        Section {
                            ForEach(group.records) { record in
                                VStack(spacing: 0) {
                                    NavigationLink {
                                        JourneyHistoryDetailView(record: record)
                                    } label: {
                                        JourneyHistoryRow(record: record)
                                    }
                                    if record.hasPrecedingCancellation {
                                        Divider()
                                            .padding(.top, 4)
                                        JourneyHistoryPrecedingCancellationNotice(record: record)
                                            .padding(.top, 8)
                                            .padding(.bottom, 4)
                                    }
                                    if record.isDelayRepay15Plus {
                                        Divider()
                                            .padding(.top, 4)
                                        JourneyHistoryDelayRepayActions(record: record)
                                            .padding(.top, 8)
                                            .padding(.bottom, 4)
                                    }
                                }
                            }
                        } header: {
                            RailwayBackgroundSectionHeader(
                                title: group.date.formatted(date: .complete, time: .omitted)
                            )
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
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .railwayBackgroundPOC()
    }

    private func historyUnavailableCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 20)
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
                Text(JourneyHistoryClockTime.text(record.detectedDepartureAt))
                Image(systemName: "arrow.right")
                    .accessibilityHidden(true)
                if let arrival = JourneyHistoryRowArrivalPolicy.resolve(
                    postedArrival: record.actualArrivalAt,
                    deviceBasedArrival: record.deviceBasedArrivalAt,
                    detectedArrival: record.detectedArrivalAt
                ) {
                    Text(arrival.qualifier.map {
                        "\(JourneyHistoryClockTime.text(arrival.date)) (\($0))"
                    } ?? JourneyHistoryClockTime.text(arrival.date))
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

private struct JourneyHistoryPrecedingCancellationNotice: View {
    let record: JourneyHistoryRecord

    private var affectedLegs: [JourneyHistoryLeg] {
        record.legs.filter { $0.precedingCancellation != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(affectedLegs) { leg in
                if let cancellation = leg.precedingCancellation {
                    Label {
                        Text(message(for: cancellation, leg: leg))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                }
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(record.isDelayRepay15Plus ? Color.red : Color.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func message(
        for cancellation: JourneyHistoryPrecedingCancellation,
        leg: JourneyHistoryLeg
    ) -> String {
        let caughtTime = leg.scheduledDepartureAt.map { JourneyHistoryClockTime.text($0) } ?? "the service"
        let route = record.legs.count > 1
            ? " from \(leg.fromStation.name) to \(leg.toStation.name)"
            : ""
        let eligibility = record.isDelayRepay15Plus
            ? " This disruption makes the journey eligible for Delay Repay."
            : ""
        return "The \(cancellation.scheduledDepartureTime) service before the \(caughtTime) service you caught\(route) was cancelled, adding \(cancellation.minutesBeforeCaughtService) minutes to your journey.\(eligibility)"
    }
}

struct JourneyHistoryDelayRepayActions: View {
    let record: JourneyHistoryRecord
    @EnvironmentObject private var historyStore: JourneyHistoryStore
    @Environment(\.openURL) private var openURL
    @State private var isResolvingClaimURL = false
    @State private var isChoosingClaimOperator = false
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
        return record.delayRepayClaimStatus?.displayName ?? "Claim delay repay"
    }

    private var statusSystemImage: String? {
        record.delayRepayClaimStatus?.systemImage
    }

    private var operatorOptions: [JourneyHistoryDelayRepayOperatorOption] {
        JourneyHistoryDelayPolicy.operatorOptions(in: record)
    }

    var body: some View {
        HStack(spacing: 10) {
            if record.delayRepayClaimStatus == nil {
                Button {
                    beginClaim()
                } label: {
                    statusCapsule
                }
                .buttonStyle(.plain)
                .disabled(isResolvingClaimURL)
                .accessibilityLabel(isResolvingClaimURL ? "Opening claim page" : "Claim Delay Repay")
                .accessibilityHint("Opens Delay Repay claim options")
            } else {
                statusCapsule
            }

            Spacer(minLength: 8)

            Menu {
                Button {
                    beginClaim()
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
        .sheet(isPresented: $isChoosingClaimOperator) {
            JourneyHistoryDelayRepayOperatorPicker(
                eligibleDelayMinutes: record.delayRepayEligibleDelayMinutes,
                includesPrecedingCancellation: record.hasPrecedingCancellation,
                options: operatorOptions
            ) { option in
                isChoosingClaimOperator = false
                openClaimPage(for: option)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var statusCapsule: some View {
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
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }

    private func beginClaim() {
        guard !isResolvingClaimURL else { return }
        guard let onlyOption = operatorOptions.first else {
            claimError = "No train operator was recorded for this journey."
            return
        }
        if operatorOptions.count == 1 {
            openClaimPage(for: onlyOption)
        } else {
            isChoosingClaimOperator = true
        }
    }

    private func openClaimPage(for option: JourneyHistoryDelayRepayOperatorOption) {
        guard !isResolvingClaimURL else { return }

        isResolvingClaimURL = true
        Task {
            defer { isResolvingClaimURL = false }
            do {
                let url = try await NetworkServicePhone.shared.fetchDelayRepayClaimURL(
                    operatorCode: option.operatorCode,
                    operatorName: option.operatorName
                )
                guard url.scheme?.lowercased() == "https" else {
                    claimError = "The operator’s claim page did not provide a secure link."
                    return
                }
                openURL(url) { accepted in
                    if !accepted {
                        claimError = "The operator’s claim page could not be opened."
                    }
                }
            } catch {
                claimError = "The claim page for \(option.operatorName) is currently unavailable."
            }
        }
    }
}

private struct JourneyHistoryDelayRepayOperatorPicker: View {
    let eligibleDelayMinutes: Int?
    let includesPrecedingCancellation: Bool
    let options: [JourneyHistoryDelayRepayOperatorOption]
    let onSelect: (JourneyHistoryDelayRepayOperatorOption) -> Void
    @Environment(\.dismiss) private var dismiss

    private var recommendedOption: JourneyHistoryDelayRepayOperatorOption? {
        options.first(where: \.isRecommended)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        if let eligibleDelayMinutes {
                            Label(
                                includesPrecedingCancellation
                                    ? "Qualifying disruption: \(durationText(eligibleDelayMinutes))"
                                    : "Final arrival \(delayText(eligibleDelayMinutes))",
                                systemImage: "clock.badge.exclamationmark"
                            )
                            .font(.headline)
                            .foregroundStyle(
                                eligibleDelayMinutes >= JourneyHistoryDelayPolicy.delayRepayThresholdMinutes
                                    ? Color.red
                                    : Color.primary
                            )
                        }

                        Text("Choose the operator most likely to have caused your final delay. If you pick the wrong one, they should normally forward your claim.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if let recommendedOption {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(
                                    "Timing suggests \(recommendedOption.operatorName)",
                                    systemImage: "chart.line.uptrend.xyaxis"
                                )
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let reason = recommendedOption.recommendationReason {
                                    Text(reason)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(options) { option in
                        Button {
                            dismiss()
                            onSelect(option)
                        } label: {
                            JourneyHistoryDelayRepayOperatorRow(option: option)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Choose an operator")
                }
            }
            .navigationTitle("Claim Delay Repay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func delayText(_ minutes: Int) -> String {
        minutes == 1 ? "1 minute late" : "\(minutes) minutes late"
    }

    private func durationText(_ minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

private struct JourneyHistoryDelayRepayOperatorRow: View {
    let option: JourneyHistoryDelayRepayOperatorOption

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(option.operatorName)
                    .font(.headline)
                Spacer(minLength: 8)
                if option.isRecommended {
                    Text("Most likely")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }

            ForEach(option.legAssessments) { assessment in
                VStack(alignment: .leading, spacing: 7) {
                    Text("Leg \(assessment.legNumber): \(assessment.leg.fromStation.name) → \(assessment.leg.toStation.name)")
                        .font(.subheadline.weight(.medium))

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            JourneyHistoryDelayMetric(
                                event: "Departed",
                                delayMinutes: assessment.departureDelayMinutes
                            )
                            JourneyHistoryDelayMetric(
                                event: "Arrived",
                                delayMinutes: assessment.arrivalDelayMinutes
                            )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            JourneyHistoryDelayMetric(
                                event: "Departed",
                                delayMinutes: assessment.departureDelayMinutes
                            )
                            JourneyHistoryDelayMetric(
                                event: "Arrived",
                                delayMinutes: assessment.arrivalDelayMinutes
                            )
                        }
                    }
                    if let cancellation = assessment.leg.precedingCancellation {
                        Label(
                            "Previous \(cancellation.scheduledDepartureTime) service cancelled",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                    }
                }
                .padding(10)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }

            Label("Open claim page", systemImage: "arrow.up.right.square")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the Delay Repay claim page for \(option.operatorName)")
    }
}

private struct JourneyHistoryDelayMetric: View {
    let event: String
    let delayMinutes: Int?

    private var color: Color {
        guard let delayMinutes else { return .secondary }
        if delayMinutes >= JourneyHistoryDelayPolicy.delayRepayThresholdMinutes { return .red }
        if delayMinutes > 0 { return .orange }
        return .green
    }

    private var text: String {
        guard let delayMinutes else { return "\(event) time unavailable" }
        if delayMinutes == 0 { return "\(event) on time" }
        let unit = delayMinutes == 1 ? "min" : "mins"
        return "\(event) \(delayMinutes) \(unit) late"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(delayMinutes == nil ? Color.secondary : Color.primary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct JourneyHistoryRecordDestination: View {
    let recordID: UUID
    @EnvironmentObject private var historyStore: JourneyHistoryStore

    private var record: JourneyHistoryRecord? {
        historyStore.records.first { $0.id == recordID }
    }

    var body: some View {
        if let record {
            JourneyHistoryDetailView(record: record)
        } else {
            ContentUnavailableView(
                "Journey unavailable",
                systemImage: "clock.badge.questionmark",
                description: Text("This journey is no longer available in your history.")
            )
        }
    }
}

private struct JourneyHistoryDetailView: View {
    let record: JourneyHistoryRecord
    @EnvironmentObject private var historyStore: JourneyHistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: JourneyHistoryShareItem?
    @State private var exportError: String?
    @State private var isShowingRemovalConfirmation = false
    #if DEBUG
    @State private var debugEditedLeg: JourneyHistoryLeg?
    #endif

    var body: some View {
        List {
            Section {
                LabeledContent("Planned", value: "\(record.plannedOriginName) → \(record.plannedDestinationName)")
                journeyRouteMapLink
                if record.recordedDestinationCRS != record.plannedDestinationCRS {
                    LabeledContent("Recorded to", value: record.recordedDestinationName)
                }
                LabeledContent("Source", value: record.source.displayName)
                LabeledContent("Outcome", value: record.outcome.displayName)
                LabeledContent("Departed", value: record.detectedDepartureAt.formatted(date: .abbreviated, time: .shortened))
            } header: {
                RailwayBackgroundSectionHeader(title: "Journey")
            }

            Section {
                if let scheduled = record.scheduledArrivalAt {
                    LabeledContent("Scheduled", value: scheduled.formatted(date: .omitted, time: .shortened))
                }
                if let actual = record.actualArrivalAt {
                    LabeledContent("Posted arrival time", value: actual.formatted(date: .omitted, time: .shortened))
                } else if let detectedArrival = record.detectedArrivalAt,
                          JourneyHistoryOfficialArrivalPolicy.isUnavailable(
                            actualArrival: record.actualArrivalAt,
                            detectedArrival: detectedArrival
                          ) {
                    LabeledContent("Posted arrival time", value: "Could not be determined")
                } else {
                    LabeledContent("Posted arrival time", value: "Awaiting confirmation")
                }
                LabeledContent(
                    "Device based arrival time",
                    value: record.deviceBasedArrivalAt?.formatted(date: .omitted, time: .shortened)
                        ?? "Could not be determined"
                )
                if let delay = record.delayMinutes {
                    LabeledContent("Delay", value: delay == 0 ? "On time" : "\(delay) min")
                }
            } header: {
                RailwayBackgroundSectionHeader(title: "Arrival")
            }

            if record.hasPrecedingCancellation {
                Section {
                    JourneyHistoryPrecedingCancellationNotice(record: record)
                } header: {
                    RailwayBackgroundSectionHeader(title: "Disruption")
                }
            }

            ForEach(Array(record.legs.enumerated()), id: \.element.id) { index, leg in
                Section {
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
                } header: {
                    RailwayBackgroundSectionHeader(title: legSectionTitle(for: leg, index: index))
                }
            }

            #if DEBUG
            Section {
                ForEach(Array(record.legs.enumerated()), id: \.element.id) { index, leg in
                    Button {
                        debugEditedLeg = leg
                    } label: {
                        Label(
                            record.legs.count > 1
                                ? "Edit cancelled service for Leg \(index + 1)"
                                : "Edit intended cancelled service",
                            systemImage: "pencil"
                        )
                    }
                }
                Text("Debug only. Use this to test cancellation-based Delay Repay eligibility without changing live rail data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                RailwayBackgroundSectionHeader(title: "Testing")
            }
            #endif

            Section {
                Button("Remove this journey", role: .destructive) {
                    isShowingRemovalConfirmation = true
                }
            }
        }
        .scrollContentBackground(.hidden)
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
        #if DEBUG
        .sheet(item: $debugEditedLeg) { leg in
            JourneyHistoryDebugCancellationEditor(
                leg: leg,
                onSave: { cancellation in
                    _ = historyStore.setPrecedingCancellation(
                        cancellation,
                        journeyID: record.id,
                        legID: leg.id
                    )
                }
            )
        }
        #endif
        .alert("Unable to share journey", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "The export could not be created.")
        }
        .alert(
            "Remove this journey?",
            isPresented: $isShowingRemovalConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove journey", role: .destructive) {
                historyStore.delete(record)
                dismiss()
            }
        } message: {
            Text("This cannot be undone.")
        }
        .railwayBackgroundPOC()
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
                historicalDepartureTime: historicalDepartureTime(for: leg),
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

    private func historicalDepartureTime(for leg: JourneyHistoryLeg) -> String? {
        guard let departure = leg.actualDepartureAt ?? leg.detectedDepartureAt else { return nil }
        let components = Calendar.current.dateComponents([.hour, .minute], from: departure)
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
    let historicalDepartureTime: String?
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

#if DEBUG
private struct JourneyHistoryDebugCancellationEditor: View {
    let leg: JourneyHistoryLeg
    let onSave: (JourneyHistoryPrecedingCancellation?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cancelledDepartureAt: Date

    private var caughtDepartureAt: Date {
        leg.scheduledDepartureAt ?? leg.detectedDepartureAt ?? Date()
    }

    private var selectableRange: ClosedRange<Date> {
        caughtDepartureAt.addingTimeInterval(-2 * 60 * 60)...caughtDepartureAt.addingTimeInterval(-60)
    }

    init(
        leg: JourneyHistoryLeg,
        onSave: @escaping (JourneyHistoryPrecedingCancellation?) -> Void
    ) {
        self.leg = leg
        self.onSave = onSave
        let caught = leg.scheduledDepartureAt ?? leg.detectedDepartureAt ?? Date()
        _cancelledDepartureAt = State(initialValue:
            leg.precedingCancellation?.scheduledDepartureAt
                ?? caught.addingTimeInterval(-30 * 60)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service times") {
                    LabeledContent(
                        "Service caught",
                        value: JourneyHistoryClockTime.text(caughtDepartureAt)
                    )
                    DatePicker(
                        "Intended cancelled service",
                        selection: $cancelledDepartureAt,
                        in: selectableRange,
                        displayedComponents: .hourAndMinute
                    )
                }

                Section {
                    Text("For today’s example, set this to 17:12. Saving records that service as cancelled and recalculates the History notice and Delay Repay action.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if leg.precedingCancellation != nil {
                    Section {
                        Button("Remove cancellation test data", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Edit Cancellation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let minutes = max(
                            0,
                            Int(caughtDepartureAt.timeIntervalSince(cancelledDepartureAt) / 60)
                        )
                        onSave(JourneyHistoryPrecedingCancellation(
                            serviceID: "debug-cancelled-\(Int(cancelledDepartureAt.timeIntervalSince1970))",
                            scheduledDepartureAt: cancelledDepartureAt,
                            scheduledDepartureTime: JourneyHistoryClockTime.text(cancelledDepartureAt),
                            minutesBeforeCaughtService: minutes
                        ))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
#endif

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
                            userDepartureCRS: loaded.leg.fromCRS,
                            highlightedTravelRange: loaded.leg.highlightedTravelRange,
                            historicalDepartureTime: loaded.leg.historicalDepartureTime,
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
        .disablesHorizontalTabSwipe()
        .hidesRailwayBackgroundChrome()
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
