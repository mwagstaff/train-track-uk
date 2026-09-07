import Foundation

enum JourneyStatsPeriod: String, CaseIterable, Identifiable {
    case week = "7D", month = "30D", quarter = "3M", year = "1Y", all = "All"
    var id: String { rawValue }

    func startDate(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)
        case .quarter: return calendar.date(byAdding: .month, value: -3, to: today)
        case .year: return calendar.date(byAdding: .year, value: -1, to: today)
        case .all: return nil
        }
    }
}

enum JourneyStatsArrivalBand: String, CaseIterable, Identifiable {
    case onTime = "On time", mild = "1–14 mins late", severe = "15+ mins late"
    var id: String { rawValue }

    static func band(for delay: Int) -> Self {
        if delay >= JourneyHistoryDelayPolicy.delayRepayThresholdMinutes { return .severe }
        return delay > 0 ? .mild : .onTime
    }
}

struct JourneyHistoryStats {
    struct Sample {
        let date: Date
        let delay: Int
        var recordID: UUID? = nil
    }

    struct Arrival: Identifiable {
        var id: String { "\(date.timeIntervalSince1970)-\(band.rawValue)" }
        let date: Date
        let band: JourneyStatsArrivalBand
        let count: Int
        let fraction: Double
    }

    struct Distribution: Identifiable {
        var id: String { label }
        let label: String
        let band: JourneyStatsArrivalBand
        let count: Int
        let fraction: Double
    }

    struct OperatorShare: Identifiable {
        let id: String
        let name: String
        let count: Int
        let fraction: Double
        let journeyIDs: Set<UUID>
    }

    let samples: [Sample]
    let totalCount: Int
    let operatorShares: [OperatorShare]
    let arrivals: [Arrival]
    let distribution: [Distribution]
    let bucketUnit: Calendar.Component

    var excludedCount: Int { totalCount - samples.count }
    var onTimeCount: Int { samples.filter { $0.delay == 0 }.count }
    var lateCount: Int { samples.count - onTimeCount }
    var onTimeFraction: Double { fraction(onTimeCount) }
    var lateFraction: Double { fraction(lateCount) }
    var averageLateDelay: Double {
        lateCount == 0 ? 0 : Double(samples.reduce(0) { $0 + $1.delay }) / Double(lateCount)
    }
    var worst: Sample? { samples.max { $0.delay < $1.delay } }

    init(records: [JourneyHistoryRecord], calendar: Calendar = .current) {
        let completed = records.filter { $0.outcome == .completed }
        let samples = completed.compactMap { record -> Sample? in
            guard record.actualArrivalAt != nil, let delay = record.delayMinutes else { return nil }
            return Sample(date: record.completedAt, delay: max(0, delay), recordID: record.id)
        }
        let options = JourneyHistoryDelayPolicy.operatorOptions(for: completed.flatMap(\.legs)
            .filter { $0.outcome == .completed })
        let legCount = options.reduce(0) { $0 + $1.legAssessments.count }
        var shares: [OperatorShare] = []
        for option in options {
            let legIDs: Set<UUID> = Set(option.legAssessments.map { $0.id })
            var journeyIDs = Set<UUID>()
            for record in completed where record.legs.contains(where: { legIDs.contains($0.id) }) {
                journeyIDs.insert(record.id)
            }
            shares.append(OperatorShare(id: option.id, name: option.operatorName,
                                        count: option.legAssessments.count,
                                        fraction: Double(option.legAssessments.count) / Double(legCount),
                                        journeyIDs: journeyIDs))
        }
        shares.sort { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
        self.init(samples: samples, totalCount: records.count,
                  operatorShares: shares, calendar: calendar)
    }

    init(samples: [Sample], totalCount: Int, operatorShares: [OperatorShare] = [], calendar: Calendar = .current) {
        self.samples = samples.sorted { $0.date < $1.date }
        self.totalCount = totalCount
        self.operatorShares = operatorShares
        let first = samples.map(\.date).min() ?? Date()
        let last = samples.map(\.date).max() ?? first
        let days = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        let unit: Calendar.Component = days <= 31 ? .day : days <= 370 ? .weekOfYear : .month
        bucketUnit = unit
        let grouped = Dictionary(grouping: samples) {
            calendar.dateInterval(of: unit, for: $0.date)?.start ?? calendar.startOfDay(for: $0.date)
        }
        arrivals = grouped.keys.sorted().flatMap { date in
            let values = grouped[date] ?? []
            return JourneyStatsArrivalBand.allCases.map { band in
                let count = values.filter { JourneyStatsArrivalBand.band(for: $0.delay) == band }.count
                return Arrival(date: date, band: band, count: count,
                               fraction: Double(count) / Double(values.count))
            }
        }
        let bins: [(String, ClosedRange<Int>, JourneyStatsArrivalBand)] = [
            ("0", 0...0, .onTime), ("1–5", 1...5, .mild), ("6–10", 6...10, .mild),
            ("11–14", 11...14, .mild), ("15–30", 15...30, .severe), ("31+", 31...Int.max, .severe)
        ]
        distribution = bins.map { label, range, band in
            let count = samples.filter { range.contains($0.delay) }.count
            return Distribution(label: label, band: band, count: count,
                                fraction: samples.isEmpty ? 0 : Double(count) / Double(samples.count))
        }
    }

    private func fraction(_ count: Int) -> Double {
        samples.isEmpty ? 0 : Double(count) / Double(samples.count)
    }
}
