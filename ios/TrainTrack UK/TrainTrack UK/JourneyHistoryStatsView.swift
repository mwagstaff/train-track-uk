import SwiftUI
import Charts

struct JourneyHistoryStatsView: View {
    @EnvironmentObject private var historyStore: JourneyHistoryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedOperatorID: String?
    @State private var period: JourneyStatsPeriod = .all
    @State private var showingDates = false
    @State private var usesCustomDates = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var draftStartDate = Date()
    @State private var draftEndDate = Date()

    var body: some View {
        let records = selectedRecords
        let allStats = JourneyHistoryStats(records: records)
        let selectedOperator = allStats.operatorShares.first { $0.id == selectedOperatorID }
        let filteredRecords = selectedOperator.map { selection in
            records.filter { selection.journeyIDs.contains($0.id) }
        } ?? records
        let stats = JourneyHistoryStats(records: filteredRecords)
        ScrollView {
            VStack(spacing: 16) {
                Picker("Date range", selection: $period) {
                    ForEach(JourneyStatsPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: period) { _, _ in usesCustomDates = false }

                VStack(spacing: 4) {
                    Text(rangeLabel(records: records)).font(.subheadline.weight(.medium))
                    Text(journeyCount(records.count))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if usesCustomDates {
                        Button("Use selected preset") { usesCustomDates = false }
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                if !allStats.operatorShares.isEmpty {
                    operatorShareChart(allStats)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedOperator.map { "Journeys with \($0.name)" } ?? "All journeys")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if selectedOperator != nil {
                        Text(journeyCount(filteredRecords.count)).font(.subheadline).foregroundStyle(.secondary)
                        Button("Show all journeys") { selectedOperatorID = nil }
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                if stats.samples.isEmpty {
                    card {
                        ContentUnavailableView("No arrival stats yet", systemImage: "chart.bar.xaxis",
                            description: Text(records.isEmpty
                                ? "Choose a wider date range or complete a journey to see your stats."
                                : "Stats need completed journeys with confirmed arrival times."))
                    }
                } else {
                    summary(stats)
                    arrivalsChart(stats)
                    distributionChart(stats)
                }
                card {
                    Text("Arrival stats use completed journeys with confirmed arrival times. Early arrivals count as on time. Average delay includes late journeys only.")
                    if stats.excludedCount > 0 {
                        Text("\(stats.excludedCount.formatted()) journeys excluded because they are incomplete or have no confirmed arrival delay.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Journey Stats")
        .navigationBarTitleDisplayMode(.inline)
        .railwayBackgroundPOC()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Custom date range", systemImage: "calendar") {
                    draftStartDate = startDate
                    draftEndDate = endDate
                    showingDates = true
                }
            }
        }
        .sheet(isPresented: $showingDates) {
            NavigationStack {
                Form {
                    DatePicker("From", selection: $draftStartDate, in: ...Date(), displayedComponents: .date)
                        .onChange(of: draftStartDate) { _, value in
                            if draftEndDate < value { draftEndDate = value }
                        }
                    DatePicker("To", selection: $draftEndDate, in: draftStartDate...max(draftStartDate, Date()), displayedComponents: .date)
                }
                .navigationTitle("Date Range")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingDates = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            startDate = draftStartDate
                            endDate = draftEndDate
                            usesCustomDates = true
                            showingDates = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var selectedRecords: [JourneyHistoryRecord] {
        let calendar = Calendar.current
        let now = Date()
        let start = usesCustomDates ? calendar.startOfDay(for: startDate) : period.startDate(now: now, calendar: calendar)
        let end = usesCustomDates
            ? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? now)
            : now
        return historyStore.records.filter { record in
            (start.map { record.completedAt >= $0 } ?? true) && record.completedAt < end
        }
    }

    private func rangeLabel(records: [JourneyHistoryRecord]) -> String {
        let start = usesCustomDates ? startDate
            : period.startDate(now: Date(), calendar: .current) ?? records.map(\.completedAt).min()
        guard let start else { return "All dates" }
        let end = usesCustomDates ? endDate : (period == .all ? records.map(\.completedAt).max() ?? Date() : Date())
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        return "\(start.formatted(format)) – \(end.formatted(format))"
    }

    private func summary(_ stats: JourneyHistoryStats) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top),
                                 count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
            metric("On time", value: percent(stats.onTimeFraction),
                   detail: "\(stats.onTimeCount) / \(journeyCount(stats.samples.count))", icon: "clock", color: .green)
            metric("Late", value: percent(stats.lateFraction),
                   detail: journeyCount(stats.lateCount), icon: "clock.badge.exclamationmark", color: .red)
            metric("Average delay", value: minutes(stats.averageLateDelay),
                   detail: "when late", icon: "hourglass", color: .yellow)
            if let worst = stats.worst, worst.delay > 0,
               let record = historyStore.records.first(where: { $0.id == worst.recordID }) {
                NavigationLink {
                    JourneyHistoryDetailView(record: record)
                } label: {
                    metric("Worst delay", value: minutes(Double(worst.delay)),
                           detail: worst.date.formatted(date: .abbreviated, time: .omitted),
                           icon: "exclamationmark.triangle", color: .red, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("View the journey with the worst delay")
            } else {
                metric("Worst delay", value: minutes(0), detail: "No late journeys",
                       icon: "exclamationmark.triangle", color: .red)
            }
        }
    }

    private func metric(_ title: String, value: String, detail: String, icon: String, color: Color, showsChevron: Bool = false) -> some View {
        card {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(color)
            HStack {
                Text(value).font(.title2.bold()).monospacedDigit()
                if showsChevron {
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func arrivalsChart(_ stats: JourneyHistoryStats) -> some View {
        card {
            Text("Arrivals over time").font(.headline)
            Text(stats.bucketUnit == .day ? "Daily share of arrivals" : stats.bucketUnit == .weekOfYear
                 ? "Weekly share of arrivals" : "Monthly share of arrivals")
                .font(.caption).foregroundStyle(.secondary)
            Chart(stats.arrivals) { arrival in
                BarMark(x: .value("Date", arrival.date, unit: stats.bucketUnit),
                        y: .value("Share of arrivals", arrival.fraction))
                    .foregroundStyle(by: .value("Arrival", arrival.band.rawValue))
                    .accessibilityLabel("\(arrival.date.formatted(date: .abbreviated, time: .omitted)), \(arrival.band.rawValue)")
                    .accessibilityValue("\(arrival.count) journeys, \(percent(arrival.fraction))")
            }
            .chartForegroundStyleScale(domain: JourneyStatsArrivalBand.allCases.map(\.rawValue),
                                       range: [Color.green, .yellow, .red])
            .chartYScale(domain: 0...1)
            .chartYAxis { AxisMarks(values: [0.0, 0.5, 1.0]) { value in
                AxisGridLine()
                AxisValueLabel { if let fraction = value.as(Double.self) { Text(percent(fraction)) } }
            } }
            .chartXAxis {
                AxisMarks(values: arrivalAxisDates(stats)) {
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 230)
        }
    }

    private func distributionChart(_ stats: JourneyHistoryStats) -> some View {
        card {
            Text("Delay distribution").font(.headline)
            Chart(stats.distribution) { bin in
                BarMark(x: .value("Minutes late", bin.label), y: .value("Share of arrivals", bin.fraction))
                    .foregroundStyle(color(for: bin.band))
                    .annotation(position: .top) { Text(percent(bin.fraction)).font(.caption2) }
                    .accessibilityLabel("\(bin.label) minutes late")
                    .accessibilityValue("\(bin.count) journeys, \(percent(bin.fraction))")
            }
            .chartYScale(domain: 0...1.15)
            .chartYAxis { AxisMarks(values: [0.0, 0.5, 1.0]) { value in
                AxisGridLine()
                AxisValueLabel { if let fraction = value.as(Double.self) { Text(percent(fraction)) } }
            } }
            .frame(height: 210)
            Text("Minutes late").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private func operatorShareChart(_ stats: JourneyHistoryStats) -> some View {
        card {
            Text("Operators travelled with").font(.headline)
            Chart(stats.operatorShares) { item in
                BarMark(x: .value("Share of legs", item.fraction), y: .value("Travel", "Operators"))
                    .foregroundStyle(by: .value("Operator", item.name))
                    .accessibilityLabel(item.name)
                    .accessibilityValue(percent(item.fraction))
            }
            .chartForegroundStyleScale(domain: stats.operatorShares.map(\.name),
                                       range: stats.operatorShares.indices.map(operatorShareColor))
            .chartXScale(domain: 0...1)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plotFrame = proxy.plotFrame,
                                  let fraction: Double = proxy.value(atX: location.x - geometry[plotFrame].minX),
                                  (0...1).contains(fraction) else { return }
                            var cumulative = 0.0
                            for item in stats.operatorShares {
                                cumulative += item.fraction
                                if fraction <= cumulative {
                                    selectedOperatorID = item.id
                                    break
                                }
                            }
                        }
                }
            }
            .frame(height: 28)
            ForEach(Array(stats.operatorShares.enumerated()), id: \.element.id) { index, item in
                Button {
                    selectedOperatorID = selectedOperatorID == item.id ? nil : item.id
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(operatorShareColor(index)).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.name)
                                Spacer(minLength: 8)
                                Text(percent(item.fraction)).monospacedDigit()
                            }
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text(percent(item.fraction)).monospacedDigit()
                            }
                        }
                        .font(.subheadline)
                        Image(systemName: selectedOperatorID == item.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedOperatorID == item.id ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.name)
                .accessibilityValue("\(percent(item.fraction))\(selectedOperatorID == item.id ? ", selected" : "")")
                .accessibilityHint("Filter journey stats by this operator. Tap again to show all journeys.")
            }
            Text("Share of completed legs with a recorded operator")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func operatorShareColor(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .brown]
        return colors[index % colors.count]
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func color(for band: JourneyStatsArrivalBand) -> Color {
        switch band { case .onTime: .green; case .mild: .yellow; case .severe: .red }
    }

    private func arrivalAxisDates(_ stats: JourneyHistoryStats) -> [Date] {
        let dates = stats.arrivals.filter { $0.band == .onTime }.map(\.date)
        let step = max(1, (dates.count + 3) / 4)
        return dates.enumerated().filter { $0.offset % step == 0 }.map(\.element)
    }

    private func journeyCount(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "journey" : "journeys")"
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }

    private func minutes(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) mins"
    }
}

#Preview {
    NavigationStack {
        JourneyHistoryStatsView().environmentObject(JourneyHistoryStore.shared)
    }
}
