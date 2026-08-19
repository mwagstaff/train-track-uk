import Foundation
import SwiftData

enum JourneyHistorySource: String, Codable, CaseIterable {
    case scheduled
    case adhoc

    var displayName: String {
        switch self {
        case .scheduled: return "Scheduled"
        case .adhoc: return "Ad hoc"
        }
    }
}

enum JourneyHistoryOutcome: String, Codable, CaseIterable {
    case completed
    case endedEarly = "ended_early"
    case offCourse = "off_course"
    case uncertain

    var displayName: String {
        switch self {
        case .completed: return "Completed"
        case .endedEarly: return "Ended early"
        case .offCourse: return "Off course"
        case .uncertain: return "Service uncertain"
        }
    }
}

enum JourneyTrackingPhase: String, Codable {
    case matchingService = "matching_service"
    case inTransit = "in_transit"
    case atInterchange = "at_interchange"
    case arriving
}

enum JourneyHistoryLegOutcome: String, Codable {
    case active
    case completed
    case rebound
    case uncertain
}

enum JourneyHistoryDelayRepayClaimStatus: String, Codable, CaseIterable, Identifiable {
    case processing
    case successful
    case rejected
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .processing: return "Claim processing"
        case .successful: return "Claim successful"
        case .rejected: return "Claim rejected"
        case .hidden: return "Claim action hidden"
        }
    }

    var actionName: String {
        switch self {
        case .processing: return "Mark claim as processing"
        case .successful: return "Mark claim as successful"
        case .rejected: return "Mark claim as rejected"
        case .hidden: return "Hide claim action"
        }
    }

    var systemImage: String {
        switch self {
        case .processing: return "hourglass"
        case .successful: return "checkmark.circle"
        case .rejected: return "xmark.circle"
        case .hidden: return "eye.slash"
        }
    }
}

struct JourneyHistoryCallingPoint: Codable, Hashable, Identifiable {
    let locationName: String
    let crs: String
    let scheduledTime: String
    let estimatedTime: String?
    let actualTime: String?

    var id: String { "\(crs)-\(scheduledTime)" }
}

struct JourneyHistoryLeg: Codable, Hashable, Identifiable {
    let id: UUID
    let plannedLegIndex: Int
    let fromStation: Station
    let toStation: Station
    var serviceID: String?
    var operatorName: String?
    var operatorCode: String?
    var callingPoints: [JourneyHistoryCallingPoint]
    var serviceCallingPoints: [JourneyHistoryCallingPoint]?
    var detectedDepartureAt: Date?
    var detectedArrivalAt: Date?
    var scheduledDepartureAt: Date?
    var estimatedDepartureTime: String?
    var actualDepartureAt: Date?
    var scheduledArrivalAt: Date?
    var actualArrivalAt: Date?
    var outcome: JourneyHistoryLegOutcome
    var reboundFromServiceID: String?

    init(
        id: UUID = UUID(),
        plannedLegIndex: Int,
        fromStation: Station,
        toStation: Station,
        serviceID: String? = nil,
        operatorName: String? = nil,
        operatorCode: String? = nil,
        callingPoints: [JourneyHistoryCallingPoint] = [],
        serviceCallingPoints: [JourneyHistoryCallingPoint]? = nil,
        detectedDepartureAt: Date? = nil,
        detectedArrivalAt: Date? = nil,
        scheduledDepartureAt: Date? = nil,
        estimatedDepartureTime: String? = nil,
        actualDepartureAt: Date? = nil,
        scheduledArrivalAt: Date? = nil,
        actualArrivalAt: Date? = nil,
        outcome: JourneyHistoryLegOutcome = .active,
        reboundFromServiceID: String? = nil
    ) {
        self.id = id
        self.plannedLegIndex = plannedLegIndex
        self.fromStation = fromStation
        self.toStation = toStation
        self.serviceID = serviceID
        self.operatorName = operatorName
        self.operatorCode = operatorCode
        self.callingPoints = callingPoints
        self.serviceCallingPoints = serviceCallingPoints
        self.detectedDepartureAt = detectedDepartureAt
        self.detectedArrivalAt = detectedArrivalAt
        self.scheduledDepartureAt = scheduledDepartureAt
        self.estimatedDepartureTime = estimatedDepartureTime
        self.actualDepartureAt = actualDepartureAt
        self.scheduledArrivalAt = scheduledArrivalAt
        self.actualArrivalAt = actualArrivalAt
        self.outcome = outcome
        self.reboundFromServiceID = reboundFromServiceID
    }
}

struct JourneyHistoryStationEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case arrival
        case departure
    }

    let id: UUID
    let station: Station
    let kind: Kind
    let detectedAt: Date

    init(id: UUID = UUID(), station: Station, kind: Kind, detectedAt: Date) {
        self.id = id
        self.station = station
        self.kind = kind
        self.detectedAt = detectedAt
    }
}

struct ArmedJourneyHistoryCandidate: Codable, Hashable, Identifiable {
    var id: String { subscriptionId }
    let subscriptionId: String
    let source: JourneyHistorySource
    let stations: [Station]
    let createdAt: Date
    let activeUntil: Date?
    var originArrivedAt: Date?
    var candidateDepartures: [DepartureV2]

    var isCurrent: Bool {
        activeUntil.map { $0 > Date() } ?? true
    }
}

struct ActiveJourneyHistoryCheckpoint: Codable, Hashable, Identifiable {
    let id: UUID
    let subscriptionId: String
    let source: JourneyHistorySource
    var plannedStations: [Station]
    let createdAt: Date
    var phase: JourneyTrackingPhase
    var plannedLegIndex: Int
    var originArrivedAt: Date?
    var detectedDepartureAt: Date
    var detectedArrivalAt: Date?
    var lastConfirmedOnRouteStation: Station
    var nextExpectedCallingPointIndex: Int
    var legs: [JourneyHistoryLeg]
    var stationEvents: [JourneyHistoryStationEvent]
    var approachNotificationSent: Bool
    var backendSessionID: String?
    var serviceMatchConfidence: Double
    var unexpectedStation: Station?
    var unexpectedStationObservedAt: Date?
    var serviceDepartedStationCRS: String?
    var serviceDepartedStationAt: Date?
    var updatedAt: Date

    var plannedOrigin: Station { plannedStations.first! }
    var plannedDestination: Station { plannedStations.last! }
    var currentPlannedLegDestination: Station {
        plannedStations[min(plannedLegIndex + 1, plannedStations.count - 1)]
    }
    var currentLeg: JourneyHistoryLeg? { legs.last }
}

struct JourneyHistoryCheckpointEnvelope: Codable {
    var armedCandidates: [ArmedJourneyHistoryCandidate]
    var activeJourney: ActiveJourneyHistoryCheckpoint?
}

struct JourneyHistoryLocationCondition: Hashable {
    enum Kind: String {
        case approach
        case arrival
        case station
    }

    let identifier: String
    let kind: Kind
    let journeyID: UUID
    let station: Station
    let radius: Double
}

@Model
final class JourneyHistoryRecord {
    @Attribute(.unique) var id: UUID
    var sourceRawValue: String
    var outcomeRawValue: String
    var createdAt: Date
    var completedAt: Date
    var plannedOriginCRS: String
    var plannedOriginName: String
    var plannedDestinationCRS: String
    var plannedDestinationName: String
    var recordedDestinationCRS: String
    var recordedDestinationName: String
    var detectedDepartureAt: Date
    var detectedArrivalAt: Date?
    var scheduledArrivalAt: Date?
    var actualArrivalAt: Date?
    var delayMinutes: Int?
    var delayRepayClaimStatusRawValue: String?
    var operatorSearchText: String
    var serviceMatchConfidence: Double
    var legsData: Data
    var stationEventsData: Data

    init(
        checkpoint: ActiveJourneyHistoryCheckpoint,
        outcome: JourneyHistoryOutcome,
        completedAt: Date
    ) {
        let finalLeg = checkpoint.legs.last
        let recordedDestination = checkpoint.lastConfirmedOnRouteStation
        id = checkpoint.id
        sourceRawValue = checkpoint.source.rawValue
        outcomeRawValue = outcome.rawValue
        createdAt = checkpoint.createdAt
        self.completedAt = completedAt
        plannedOriginCRS = checkpoint.plannedOrigin.crs
        plannedOriginName = checkpoint.plannedOrigin.name
        plannedDestinationCRS = checkpoint.plannedDestination.crs
        plannedDestinationName = checkpoint.plannedDestination.name
        recordedDestinationCRS = recordedDestination.crs
        recordedDestinationName = recordedDestination.name
        detectedDepartureAt = checkpoint.detectedDepartureAt
        detectedArrivalAt = checkpoint.detectedArrivalAt
        scheduledArrivalAt = finalLeg?.scheduledArrivalAt
        actualArrivalAt = finalLeg?.actualArrivalAt
        delayMinutes = JourneyHistoryDelayPolicy.confirmedDelayMinutes(
            scheduledArrival: finalLeg?.scheduledArrivalAt,
            actualArrival: finalLeg?.actualArrivalAt
        )
        delayRepayClaimStatusRawValue = nil
        operatorSearchText = checkpoint.legs.compactMap(\.operatorName).joined(separator: " ")
        serviceMatchConfidence = checkpoint.serviceMatchConfidence
        legsData = (try? JSONEncoder().encode(checkpoint.legs)) ?? Data()
        stationEventsData = (try? JSONEncoder().encode(checkpoint.stationEvents)) ?? Data()
    }
}

extension JourneyHistoryRecord {
    var source: JourneyHistorySource {
        JourneyHistorySource(rawValue: sourceRawValue) ?? .adhoc
    }

    var outcome: JourneyHistoryOutcome {
        JourneyHistoryOutcome(rawValue: outcomeRawValue) ?? .uncertain
    }

    var legs: [JourneyHistoryLeg] {
        (try? JSONDecoder().decode([JourneyHistoryLeg].self, from: legsData)) ?? []
    }

    var stationEvents: [JourneyHistoryStationEvent] {
        (try? JSONDecoder().decode([JourneyHistoryStationEvent].self, from: stationEventsData)) ?? []
    }

    var isDelayRepay15Plus: Bool {
        guard let delayMinutes else { return false }
        return delayMinutes >= JourneyHistoryDelayPolicy.delayRepayThresholdMinutes
    }

    var delayRepayClaimStatus: JourneyHistoryDelayRepayClaimStatus? {
        get {
            delayRepayClaimStatusRawValue.flatMap(JourneyHistoryDelayRepayClaimStatus.init(rawValue:))
        }
        set {
            delayRepayClaimStatusRawValue = newValue?.rawValue
        }
    }

    var routeTitle: String {
        let destination = outcome == .completed ? plannedDestinationName : recordedDestinationName
        return "\(plannedOriginName) → \(destination)"
    }

    var operatorDisplayText: String {
        JourneyHistoryOperatorSummary.text(for: legs.map(\.operatorName))
    }

    func matchesSearch(_ rawTerm: String) -> Bool {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return true }
        let stationText = stationEvents.flatMap { [$0.station.name, $0.station.crs] }
        let legText = legs.flatMap {
            [$0.fromStation.name, $0.fromStation.crs, $0.toStation.name, $0.toStation.crs, $0.operatorName ?? ""]
        }
        return ([
            plannedOriginName,
            plannedOriginCRS,
            plannedDestinationName,
            plannedDestinationCRS,
            recordedDestinationName,
            recordedDestinationCRS,
            operatorSearchText
        ] + stationText + legText).contains { $0.lowercased().contains(term) }
    }
}

enum JourneyHistoryOperatorSummary {
    static func text(for operatorNames: [String?]) -> String {
        var seen = Set<String>()
        let uniqueNames = operatorNames.compactMap { rawName -> String? in
            guard let rawName else { return nil }
            let name = rawName
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !name.isEmpty else { return nil }

            let deduplicationKey = name.lowercased()
            guard seen.insert(deduplicationKey).inserted else { return nil }
            return name
        }

        guard let firstName = uniqueNames.first else { return "" }
        let additionalCount = uniqueNames.count - 1
        return additionalCount == 0 ? firstName : "\(firstName) +\(additionalCount) more"
    }
}

struct JourneyHistoryDelayRepayLegAssessment: Hashable, Identifiable {
    let leg: JourneyHistoryLeg
    let departureDelayMinutes: Int?
    let arrivalDelayMinutes: Int?

    var id: UUID { leg.id }
    var legNumber: Int { leg.plannedLegIndex + 1 }
}

struct JourneyHistoryDelayRepayOperatorOption: Hashable, Identifiable {
    let id: String
    let operatorName: String
    let operatorCode: String?
    let legAssessments: [JourneyHistoryDelayRepayLegAssessment]
    let isRecommended: Bool
    let recommendationReason: String?

    var claimLeg: JourneyHistoryLeg? { legAssessments.first?.leg }
}

enum JourneyHistoryDelayPolicy {
    static let delayRepayThresholdMinutes = 15
    static let submissionDeadlineDays = 28

    static func confirmedDelayMinutes(scheduledArrival: Date?, actualArrival: Date?) -> Int? {
        guard let scheduledArrival, let actualArrival else { return nil }
        return max(0, Int(actualArrival.timeIntervalSince(scheduledArrival) / 60))
    }

    static func isWithinSubmissionWindow(
        completedAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let cutoff = calendar.date(
            byAdding: .day,
            value: -submissionDeadlineDays,
            to: now
        ) ?? now.addingTimeInterval(-Double(submissionDeadlineDays) * 24 * 60 * 60)
        return completedAt >= cutoff
    }

    static func responsibleOperatorLeg(in record: JourneyHistoryRecord) -> JourneyHistoryLeg? {
        operatorOptions(in: record).first(where: \.isRecommended)?.claimLeg
            ?? record.legs.sorted { $0.plannedLegIndex < $1.plannedLegIndex }.last
    }

    static func operatorOptions(in record: JourneyHistoryRecord) -> [JourneyHistoryDelayRepayOperatorOption] {
        operatorOptions(for: record.legs)
    }

    static func operatorOptions(for legs: [JourneyHistoryLeg]) -> [JourneyHistoryDelayRepayOperatorOption] {
        let sortedLegs = legs.sorted { lhs, rhs in
            if lhs.plannedLegIndex == rhs.plannedLegIndex {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.plannedLegIndex < rhs.plannedLegIndex
        }
        let assessments = sortedLegs.map { leg in
            JourneyHistoryDelayRepayLegAssessment(
                leg: leg,
                departureDelayMinutes: confirmedDelayMinutes(
                    scheduledArrival: leg.scheduledDepartureAt,
                    actualArrival: leg.actualDepartureAt ?? leg.detectedDepartureAt
                ),
                arrivalDelayMinutes: confirmedDelayMinutes(
                    scheduledArrival: leg.scheduledArrivalAt,
                    actualArrival: leg.actualArrivalAt
                )
            )
        }
        let recommendation = recommendation(for: assessments)

        struct OperatorGroup {
            var name: String
            var nameKey: String
            var code: String?
            var codeKey: String?
            var assessments: [JourneyHistoryDelayRepayLegAssessment]
        }

        var groups: [OperatorGroup] = []
        for assessment in assessments {
            let name = normalizedOperatorValue(assessment.leg.operatorName)
            let code = normalizedOperatorValue(assessment.leg.operatorCode)
            guard name != nil || code != nil else { continue }

            let displayName = name ?? code ?? "Unknown operator"
            let nameKey = name?.lowercased() ?? ""
            let codeKey = code?.lowercased()
            if let groupIndex = groups.firstIndex(where: { group in
                (!nameKey.isEmpty && group.nameKey == nameKey)
                    || (codeKey != nil && group.codeKey == codeKey)
            }) {
                groups[groupIndex].assessments.append(assessment)
                if groups[groupIndex].code == nil {
                    groups[groupIndex].code = code
                    groups[groupIndex].codeKey = codeKey
                }
            } else {
                groups.append(OperatorGroup(
                    name: displayName,
                    nameKey: nameKey,
                    code: code,
                    codeKey: codeKey,
                    assessments: [assessment]
                ))
            }
        }

        return groups.map { group in
            let isRecommended = group.assessments.contains { $0.leg.id == recommendation.legID }
            let stableKey = group.codeKey ?? group.nameKey
            return JourneyHistoryDelayRepayOperatorOption(
                id: stableKey,
                operatorName: group.name,
                operatorCode: group.code,
                legAssessments: group.assessments,
                isRecommended: isRecommended,
                recommendationReason: isRecommended ? recommendation.reason : nil
            )
        }
    }

    private static func recommendation(
        for assessments: [JourneyHistoryDelayRepayLegAssessment]
    ) -> (legID: UUID?, reason: String?) {
        guard !assessments.isEmpty else { return (nil, nil) }

        var contributionByLegID: [UUID: Int] = [:]
        var missedConnectionLegIDs = Set<UUID>()
        for (index, assessment) in assessments.enumerated() {
            let previousDelay = index > 0 ? assessments[index - 1].arrivalDelayMinutes ?? 0 : 0
            let currentDelay = assessment.arrivalDelayMinutes ?? assessment.departureDelayMinutes ?? previousDelay
            let increase = max(0, currentDelay - previousDelay)

            if index > 0,
               let previousArrival = assessments[index - 1].leg.actualArrivalAt
                    ?? assessments[index - 1].leg.detectedArrivalAt,
               let scheduledDeparture = assessment.leg.scheduledDepartureAt,
               previousArrival >= scheduledDeparture {
                let precedingLegID = assessments[index - 1].leg.id
                contributionByLegID[precedingLegID, default: 0] += increase
                missedConnectionLegIDs.insert(precedingLegID)
            } else {
                contributionByLegID[assessment.leg.id, default: 0] += increase
            }
        }

        let recommended = assessments.enumerated().max { lhs, rhs in
            let lhsScore = contributionByLegID[lhs.element.leg.id, default: 0]
            let rhsScore = contributionByLegID[rhs.element.leg.id, default: 0]
            if lhsScore == rhsScore {
                return lhs.offset > rhs.offset
            }
            return lhsScore < rhsScore
        }?.element ?? assessments[0]
        let legNumber = recommended.legNumber
        let reason: String
        if missedConnectionLegIDs.contains(recommended.leg.id) {
            reason = "Leg \(legNumber) arrived after Leg \(legNumber + 1) was scheduled to depart."
        } else {
            reason = "Leg \(legNumber) shows the largest increase in recorded delay."
        }
        return (recommended.leg.id, reason)
    }

    private static func normalizedOperatorValue(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return value.isEmpty ? nil : value
    }
}

enum JourneyHistoryArrivalStatusText {
    static func text(
        actualArrival: Date?,
        detectedArrival: Date?,
        delayMinutes: Int?,
        outcome: JourneyHistoryOutcome,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if let actualArrival {
            let time = timeLabel(actualArrival, calendar: calendar)
            guard let delayMinutes else { return "Arrived at \(time)" }
            if delayMinutes == 0 {
                return "Arrived on time, at \(time)"
            }
            let unit = delayMinutes == 1 ? "min" : "mins"
            return "Arrived \(delayMinutes) \(unit) late, at \(time)"
        }
        if let detectedArrival {
            let time = timeLabel(detectedArrival, calendar: calendar)
            if JourneyHistoryOfficialArrivalPolicy.isUnavailable(
                actualArrival: actualArrival,
                detectedArrival: detectedArrival,
                now: now
            ) {
                return "Detected at \(time) (official arrival unavailable)"
            }
            return "Official arrival pending, detected at \(time)"
        }
        return outcome.displayName
    }

    private static func timeLabel(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

enum JourneyHistoryOfficialArrivalPolicy {
    static let availabilityTimeout: TimeInterval = 60 * 60

    static func isUnavailable(
        actualArrival: Date?,
        detectedArrival: Date?,
        now: Date = Date()
    ) -> Bool {
        guard actualArrival == nil, let detectedArrival else { return false }
        return now.timeIntervalSince(detectedArrival) >= availabilityTimeout
    }
}

enum JourneyHistoryNotificationText {
    static func boarding(
        scheduledDeparture: String,
        estimatedDeparture: String?,
        destinationName: String
    ) -> String {
        let scheduled = scheduledDeparture.trimmingCharacters(in: .whitespacesAndNewlines)
        let estimated = estimatedDeparture?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "\(scheduled) to \(destinationName)"

        if let delay = departureDelayMinutes(scheduled: scheduled, estimated: estimated), delay > 0 {
            let unit = delay == 1 ? "minute" : "minutes"
            return "You’re on the delayed \(base), currently \(delay) \(unit) late. Enjoy your journey!"
        }
        if let estimated,
           estimated.caseInsensitiveCompare("On time") != .orderedSame,
           estimated != scheduled {
            return "You’re on the delayed \(base). Enjoy your journey!"
        }
        return "You’re on the \(base). Enjoy your journey!"
    }

    static func arrival(destinationName: String, detectedAt: Date, calendar: Calendar = .current) -> String {
        "Welcome to \(destinationName), arrived \(timeLabel(for: detectedAt, calendar: calendar))"
    }

    static func delayRepay(delayMinutes: Int) -> String {
        "Arrival was \(delayMinutes) minutes late, so you may be eligible for Delay Repay."
    }

    private static func departureDelayMinutes(scheduled: String, estimated: String?) -> Int? {
        guard let estimated,
              let scheduledMinutes = minutesSinceMidnight(scheduled),
              let estimatedMinutes = minutesSinceMidnight(estimated) else {
            return nil
        }
        let difference = (estimatedMinutes - scheduledMinutes + 24 * 60) % (24 * 60)
        return difference <= 12 * 60 ? difference : nil
    }

    private static func minutesSinceMidnight(_ value: String) -> Int? {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    private static func timeLabel(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

enum JourneyHistoryOfficialArrivalResolver {
    static func destinationCallingPoint(
        in details: ServiceDetails,
        destinationCRS: String
    ) -> CallingPoint? {
        let normalizedDestination = destinationCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let previous = details.previousCallingPoints?.flatMap(\.callingPoint) ?? []
        let subsequent = details.subsequentCallingPoints?.flatMap(\.callingPoint) ?? []
        let current = CallingPoint(
            locationName: details.locationName,
            crs: details.crs,
            st: details.sta ?? details.std ?? "Unknown",
            et: details.eta ?? details.etd,
            at: details.ata ?? details.atd,
            isCancelled: details.isCancelled,
            cancelReason: details.cancelReason,
            platform: details.platform,
            length: details.length,
            detachFront: details.detachFront,
            affectedByDiversion: false,
            rerouteDelay: 0
        )
        let matches = (previous + [current] + subsequent).filter {
            $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedDestination
        }
        return matches.last(where: { hasConfirmedActual($0.at) }) ?? matches.last
    }

    static func resolvedActualDate(for point: CallingPoint, near reference: Date) -> Date? {
        guard let actual = point.at?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actual.isEmpty,
              actual.caseInsensitiveCompare("Cancelled") != .orderedSame else {
            return nil
        }
        return JourneyHistoryTime.date(
            for: actual.caseInsensitiveCompare("On time") == .orderedSame ? point.st : actual,
            near: reference
        )
    }

    private static func hasConfirmedActual(_ actual: String?) -> Bool {
        guard let value = actual?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return false
        }
        return value.caseInsensitiveCompare("Cancelled") != .orderedSame
    }
}

enum JourneyHistoryExporter {
    static func csv(records: [JourneyHistoryRecord]) -> String {
        let header = [
            "Source", "Outcome", "Planned origin",
            "Planned destination",
            "Recorded destination", "Detected departure", "Detected arrival", "Scheduled arrival",
            "Official arrival", "Delay minutes", "Leg", "Operator", "Service",
            "Leg origin", "Leg destination"
        ]
        var rows = [header]
        for record in records {
            let legs = record.legs.isEmpty ? [JourneyHistoryLeg?](arrayLiteral: nil) : record.legs.map(Optional.some)
            for (index, leg) in legs.enumerated() {
                rows.append([
                    record.source.displayName,
                    record.outcome.displayName,
                    record.plannedOriginName,
                    record.plannedDestinationName,
                    record.recordedDestinationName,
                    dateString(record.detectedDepartureAt),
                    dateString(record.detectedArrivalAt),
                    dateString(record.scheduledArrivalAt),
                    dateString(record.actualArrivalAt),
                    record.delayMinutes.map(String.init) ?? "",
                    leg == nil ? "" : String(index + 1),
                    leg?.operatorName ?? "",
                    leg?.serviceID ?? "",
                    leg?.fromStation.name ?? "",
                    leg?.toStation.name ?? ""
                ])
            }
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func makeCSVFile(records: [JourneyHistoryRecord]) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrainTrack-Journey-History-\(formatter.string(from: Date())).csv")
        try Data(csv(records: records).utf8).write(to: url, options: .atomic)
        return url
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    nonisolated private static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

enum JourneyHistoryTime {
    static func date(for time: String?, near reference: Date, calendar: Calendar = .current) -> Date? {
        guard let time else { return nil }
        let parts = time.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        let startOfDay = calendar.startOfDay(for: reference)
        return (-1...1).compactMap { dayOffset -> Date? in
            calendar.date(byAdding: .day, value: dayOffset, to: startOfDay)?
                .addingTimeInterval(TimeInterval((hour * 60 + minute) * 60))
        }.min {
            abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference))
        }
    }

    static func circularMinuteDifference(_ time: String, from reference: Date, calendar: Calendar = .current) -> Int? {
        guard let candidate = date(for: time, near: reference, calendar: calendar) else { return nil }
        return Int(abs(candidate.timeIntervalSince(reference)) / 60)
    }
}
