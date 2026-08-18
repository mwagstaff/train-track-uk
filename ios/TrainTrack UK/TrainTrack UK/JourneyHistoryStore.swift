import Combine
import Foundation
import SwiftData

@MainActor
final class JourneyHistoryStore: ObservableObject {
    static let shared = JourneyHistoryStore()
    static let maximumRecordCount = 2_000

    @Published private(set) var records: [JourneyHistoryRecord] = []
    @Published private(set) var persistenceError: String?

    private let container: ModelContainer
    private let isUsingInMemoryFallback: Bool
    #if DEBUG
    private var debugFixtureJourneyID: UUID?
    #endif

    private init() {
        let result = Self.makeContainer()
        container = result.container
        isUsingInMemoryFallback = result.isInMemoryOnly
        reload()
        #if DEBUG
        applyVICToKTHDebugFixtureIfPresent()
        #endif
        log(
            isUsingInMemoryFallback ? "history_store_fallback" : "history_store_ready",
            isUsingInMemoryFallback
                ? "Journey history store is using the in-memory fallback"
                : "Journey history store ready with \(records.count) record(s)",
            metadata: [
                "record_count": records.count,
                "in_memory_only": isUsingInMemoryFallback,
                "persistent_store_error": result.persistentStoreError
            ]
        )
    }

    private static func makeContainer() -> (
        container: ModelContainer,
        isInMemoryOnly: Bool,
        persistentStoreError: String?
    ) {
        let schema = Schema([JourneyHistoryRecord.self])
        do {
            return (
                try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration("JourneyHistory", schema: schema)]
                ),
                false,
                nil
            )
        } catch {
            let persistentStoreError = error.localizedDescription
            do {
                return (
                    try ModelContainer(
                        for: schema,
                        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                    ),
                    true,
                    persistentStoreError
                )
            } catch {
                fatalError("Unable to create journey history store: \(error.localizedDescription)")
            }
        }
    }

    func reload() {
        do {
            var descriptor = FetchDescriptor<JourneyHistoryRecord>()
            descriptor.sortBy = [SortDescriptor(\JourneyHistoryRecord.completedAt, order: .reverse)]
            records = try container.mainContext.fetch(descriptor)
            persistenceError = nil
        } catch {
            records = []
            persistenceError = error.localizedDescription
            log("history_reload_failed", "Journey history reload failed: \(error.localizedDescription)", metadata: [
                "error": error.localizedDescription
            ])
        }
    }

    func add(_ record: JourneyHistoryRecord) {
        container.mainContext.insert(record)
        saveAndPrune(addedRecord: record)
    }

    func delete(_ record: JourneyHistoryRecord) {
        container.mainContext.delete(record)
        saveAndReload(event: "history_record_deleted", message: "Deleted journey history record \(record.id.uuidString)", metadata: [
            "journey_id": record.id.uuidString
        ])
    }

    func clear() {
        do {
            try container.mainContext.delete(model: JourneyHistoryRecord.self)
            try container.mainContext.save()
            reload()
            log("history_cleared", "Cleared all locally stored journey history", metadata: [
                "record_count": records.count
            ])
        } catch {
            persistenceError = error.localizedDescription
            log("history_clear_failed", "Clearing journey history failed: \(error.localizedDescription)", metadata: [
                "error": error.localizedDescription
            ])
        }
    }

    func setDelayRepayClaimStatus(
        _ status: JourneyHistoryDelayRepayClaimStatus?,
        for record: JourneyHistoryRecord
    ) {
        record.delayRepayClaimStatus = status
        saveAndReload(
            event: "delay_repay_claim_status_updated",
            message: "Updated Delay Repay claim status for journey \(record.id.uuidString)",
            metadata: [
                "journey_id": record.id.uuidString,
                "claim_status": status?.rawValue
            ]
        )
    }

    @discardableResult
    func refreshOfficialArrival(for record: JourneyHistoryRecord) async -> JourneyHistoryRecord? {
        #if DEBUG
        if debugFixtureJourneyID == record.id {
            return record
        }
        #endif
        guard let leg = record.legs.last(where: { $0.serviceID != nil }),
              let serviceID = leg.serviceID else {
            return nil
        }
        let context = ServiceDetailsLookupContext(
            fromCRS: leg.fromStation.crs,
            toCRS: leg.toStation.crs,
            originCRS: nil,
            operator: nil,
            destinationCRSs: [record.plannedDestinationCRS],
            length: nil
        )
        _ = await DeparturesStore.shared.ensureServiceDetails(
            for: [serviceID],
            force: true,
            context: context
        )
        guard let details = DeparturesStore.shared.serviceDetailsById[serviceID] else {
            log("official_arrival_refresh_unavailable", "No service details were returned for journey \(record.id.uuidString)", metadata: [
                "journey_id": record.id.uuidString,
                "service_id": serviceID,
                "destination_crs": record.plannedDestinationCRS
            ])
            return nil
        }
        let reference = record.detectedArrivalAt ?? record.completedAt
        let serviceBranch = details.stationBranches.first(where: { points in
            points.contains { $0.crs.caseInsensitiveCompare(leg.fromStation.crs) == .orderedSame }
                && points.contains { $0.crs.caseInsensitiveCompare(leg.toStation.crs) == .orderedSame }
        }) ?? details.allStations
        let serviceCallingPoints = serviceBranch.map {
            JourneyHistoryCallingPoint(
                locationName: $0.locationName,
                crs: $0.crs.uppercased(),
                scheduledTime: $0.st,
                estimatedTime: $0.et,
                actualTime: $0.at
            )
        }
        guard let point = JourneyHistoryOfficialArrivalResolver.destinationCallingPoint(
            in: details,
            destinationCRS: record.plannedDestinationCRS
        ) else {
            log("official_arrival_refresh_unavailable", "No destination calling point was returned for journey \(record.id.uuidString)", metadata: [
                "journey_id": record.id.uuidString,
                "service_id": serviceID,
                "destination_crs": record.plannedDestinationCRS,
                "service_calling_point_count": serviceCallingPoints.count
            ])
            return applyOfficialArrival(
                journeyID: record.id,
                scheduledArrival: nil,
                actualArrival: nil,
                operatorName: details.operator,
                operatorCode: details.operatorCode,
                serviceCallingPoints: serviceCallingPoints
            )
        }
        return applyOfficialArrival(
            journeyID: record.id,
            scheduledArrival: JourneyHistoryTime.date(for: point.st, near: reference),
            actualArrival: JourneyHistoryOfficialArrivalResolver.resolvedActualDate(for: point, near: reference),
            operatorName: details.operator,
            operatorCode: details.operatorCode,
            serviceCallingPoints: serviceCallingPoints
        )
    }

    @discardableResult
    func applyOfficialArrival(
        journeyID: UUID,
        scheduledArrival: Date?,
        actualArrival: Date?,
        operatorName: String?,
        operatorCode: String?,
        serviceCallingPoints: [JourneyHistoryCallingPoint]? = nil
    ) -> JourneyHistoryRecord? {
        guard let record = records.first(where: { $0.id == journeyID }) else { return nil }
        var legs = record.legs
        if let index = legs.indices.last {
            if let scheduledArrival {
                legs[index].scheduledArrivalAt = scheduledArrival
            }
            if let actualArrival {
                legs[index].actualArrivalAt = actualArrival
            }
            if let operatorName, !operatorName.isEmpty {
                legs[index].operatorName = operatorName
            }
            if let operatorCode, !operatorCode.isEmpty {
                legs[index].operatorCode = operatorCode
            }
            if let serviceCallingPoints, !serviceCallingPoints.isEmpty {
                legs[index].serviceCallingPoints = serviceCallingPoints
            }
            record.legsData = (try? JSONEncoder().encode(legs)) ?? record.legsData
        }
        if let scheduledArrival {
            record.scheduledArrivalAt = scheduledArrival
        }
        if let actualArrival {
            record.actualArrivalAt = actualArrival
        }
        record.delayMinutes = JourneyHistoryDelayPolicy.confirmedDelayMinutes(
            scheduledArrival: record.scheduledArrivalAt,
            actualArrival: record.actualArrivalAt
        )
        record.operatorSearchText = legs.compactMap(\.operatorName).joined(separator: " ")
        saveAndReload(
            event: "official_arrival_reconciled",
            message: actualArrival == nil
                ? "Refreshed scheduled arrival for journey \(journeyID.uuidString); confirmed actual arrival is still pending"
                : "Reconciled confirmed official arrival for journey \(journeyID.uuidString)",
            metadata: [
                "journey_id": journeyID.uuidString,
                "scheduled_arrival": record.scheduledArrivalAt,
                "actual_arrival": record.actualArrivalAt,
                "delay_minutes": record.delayMinutes,
                "delay_repay_eligible": record.isDelayRepay15Plus
            ]
        )
        return records.first(where: { $0.id == journeyID })
    }

    #if DEBUG
    func generateDebugHistoryToCapacity() async throws -> Int {
        let requestedCount = max(0, Self.maximumRecordCount - records.count)
        guard requestedCount > 0 else { return 0 }
        let generatedRecords = try await JourneyHistoryDebugDataGenerator.records(count: requestedCount)
        for record in generatedRecords {
            container.mainContext.insert(record)
        }
        do {
            try container.mainContext.save()
            reload()
            log("debug_history_generated", "Generated \(generatedRecords.count) journey history test records", metadata: [
                "generated_count": generatedRecords.count,
                "record_count": records.count
            ])
            return generatedRecords.count
        } catch {
            persistenceError = error.localizedDescription
            throw error
        }
    }

    func generateRandomDebugMultiLegJourney() async throws -> JourneyHistoryRecord {
        let record = try await JourneyHistoryDebugDataGenerator.randomMultiLegRecord()
        add(record)
        return record
    }

    private func applyVICToKTHDebugFixtureIfPresent() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        guard let record = records.first(where: { record in
            let components = calendar.dateComponents([.year, .month, .day], from: record.detectedDepartureAt)
            return record.plannedOriginCRS.caseInsensitiveCompare("VIC") == .orderedSame
                && record.plannedDestinationCRS.caseInsensitiveCompare("KTH") == .orderedSame
                && components.year == 2026
                && components.month == 8
                && components.day == 17
        }), let scheduledArrival = JourneyHistoryTime.date(
            for: "17:47",
            near: record.detectedArrivalAt ?? record.completedAt,
            calendar: calendar
        ) else {
            return
        }

        debugFixtureJourneyID = record.id
        _ = applyOfficialArrival(
            journeyID: record.id,
            scheduledArrival: scheduledArrival,
            actualArrival: scheduledArrival,
            operatorName: "Southeastern",
            operatorCode: "SE",
            serviceCallingPoints: Self.vicToOrpingtonDebugCallingPoints
        )
        log("debug_fixture_applied", "Applied VIC to Orpington route and on-time Kent House arrival fixture", metadata: [
            "journey_id": record.id.uuidString,
            "calling_point_count": Self.vicToOrpingtonDebugCallingPoints.count,
            "official_arrival": scheduledArrival
        ])
    }

    private static let vicToOrpingtonDebugCallingPoints: [JourneyHistoryCallingPoint] = [
        debugCallingPoint("London Victoria", "VIC", "17:27", departed: true),
        debugCallingPoint("Brixton", "BRX", "17:34", departed: true),
        debugCallingPoint("Herne Hill", "HNH", "17:36", departed: true),
        debugCallingPoint("West Dulwich", "WDU", "17:39", departed: true),
        debugCallingPoint("Sydenham Hill", "SYH", "17:42", departed: true),
        debugCallingPoint("Penge East", "PNE", "17:45", departed: true),
        JourneyHistoryCallingPoint(
            locationName: "Kent House",
            crs: "KTH",
            scheduledTime: "17:47",
            estimatedTime: "On time",
            actualTime: "17:47"
        ),
        debugCallingPoint("Beckenham Junction", "BKJ", "17:50"),
        debugCallingPoint("Shortlands", "SRT", "17:53"),
        debugCallingPoint("Bromley South", "BMS", "17:56"),
        debugCallingPoint("Bickley", "BKL", "18:00"),
        debugCallingPoint("Petts Wood", "PET", "18:03"),
        debugCallingPoint("Orpington", "ORP", "18:07")
    ]

    private static func debugCallingPoint(
        _ name: String,
        _ crs: String,
        _ scheduledTime: String,
        departed: Bool = false
    ) -> JourneyHistoryCallingPoint {
        JourneyHistoryCallingPoint(
            locationName: name,
            crs: crs,
            scheduledTime: scheduledTime,
            estimatedTime: "On time",
            actualTime: departed ? "On time" : nil
        )
    }
    #endif

    private func saveAndPrune(addedRecord: JourneyHistoryRecord) {
        do {
            try container.mainContext.save()
            var descriptor = FetchDescriptor<JourneyHistoryRecord>()
            descriptor.sortBy = [SortDescriptor(\JourneyHistoryRecord.completedAt, order: .reverse)]
            let stored = try container.mainContext.fetch(descriptor)
            let prunedCount = max(0, stored.count - Self.maximumRecordCount)
            if stored.count > Self.maximumRecordCount {
                for record in stored.dropFirst(Self.maximumRecordCount) {
                    container.mainContext.delete(record)
                }
                try container.mainContext.save()
            }
            reload()
            log("history_record_saved", "Saved journey \(addedRecord.routeTitle) with outcome \(addedRecord.outcome.displayName)", metadata: [
                "journey_id": addedRecord.id.uuidString,
                "outcome": addedRecord.outcome.rawValue,
                "recorded_destination_crs": addedRecord.recordedDestinationCRS,
                "leg_count": addedRecord.legs.count,
                "delay_minutes": addedRecord.delayMinutes,
                "delay_repay_eligible": addedRecord.isDelayRepay15Plus,
                "record_count": records.count,
                "pruned_count": prunedCount,
                "in_memory_only": isUsingInMemoryFallback
            ])
        } catch {
            persistenceError = error.localizedDescription
            log("history_record_save_failed", "Saving journey history failed: \(error.localizedDescription)", metadata: [
                "journey_id": addedRecord.id.uuidString,
                "error": error.localizedDescription
            ])
        }
    }

    private func saveAndReload(
        event: String,
        message: String,
        metadata: [String: Any?]
    ) {
        do {
            try container.mainContext.save()
            reload()
            var enriched = metadata
            enriched["record_count"] = records.count
            log(event, message, metadata: enriched)
        } catch {
            persistenceError = error.localizedDescription
            log("history_persistence_failed", "Journey history persistence failed: \(error.localizedDescription)", metadata: [
                "event": event,
                "error": error.localizedDescription
            ])
        }
    }

    private func log(_ event: String, _ message: String, metadata: [String: Any?] = [:]) {
        DebugLogStore.shared.log(message, category: "JourneyHistory")
        ClientDiagnosticsLogger.log("journey_history", event, metadata: metadata)
    }
}
