import SwiftUI

struct JourneyItinerary: Hashable {
    let group: JourneyGroup
    let legs: [JourneyItineraryLeg]

    var hasServicesForAllLegs: Bool {
        legs.count == group.legs.count && legs.allSatisfy { leg in
            guard let departure = leg.departure else { return false }
            return !JourneyItineraryBuilder.isCancelled(departure)
        }
    }

    var finalArrivalTime: String? {
        guard hasServicesForAllLegs else { return nil }
        return legs.last?.arrivalTime
    }
}

struct JourneyItineraryLeg: Identifiable, Hashable {
    let journey: Journey
    let departure: DepartureV2?
    let departureDate: Date?
    let arrivalTime: String?
    let arrivalDate: Date?
    let disruptionNotes: [String]

    var id: UUID { journey.id }
}

struct JourneyConnectionSelection {
    let departure: DepartureV2?
    let disruptionNotes: [String]
}

struct JourneyCancellation: Hashable {
    let reason: String?
    let cancelledFrom: String?
    let destinationName: String?
    let serviceContinuesBeyondDestination: Bool

    var isPartial: Bool {
        cancelledFrom != nil && destinationName != nil
    }
}

enum JourneyItineraryBuilder {
    static func build(
        group: JourneyGroup,
        firstDeparture: DepartureV2,
        departuresForJourney: (Journey) -> [DepartureV2],
        serviceDetailsByID: [String: ServiceDetails],
        now: Date = Date()
    ) -> JourneyItinerary {
        var itineraryLegs: [JourneyItineraryLeg] = []
        var earliestConnection: Date?
        var earliestScheduledConnection: Date?
        var canSelectConnection = true

        for (index, journey) in group.legs.enumerated() {
            let departure: DepartureV2?
            let disruptionNotes: [String]
            if index == 0 {
                departure = firstDeparture
                disruptionNotes = []
            } else if canSelectConnection {
                let selection = selectConnection(
                    from: departuresForJourney(journey),
                    noEarlierThan: earliestConnection,
                    scheduledNoEarlierThan: earliestScheduledConnection,
                    destinationName: journey.toStation.name,
                    changeStationName: journey.fromStation.name,
                    now: now
                )
                departure = selection.departure
                disruptionNotes = selection.disruptionNotes
            } else {
                departure = nil
                disruptionNotes = []
            }

            guard let departure else {
                itineraryLegs.append(JourneyItineraryLeg(
                    journey: journey,
                    departure: nil,
                    departureDate: nil,
                    arrivalTime: nil,
                    arrivalDate: nil,
                    disruptionNotes: disruptionNotes
                ))
                canSelectConnection = false
                continue
            }

            let departureDate = date(for: departureDisplayTime(departure), now: now)
                ?? date(for: departure.departureTime.scheduled, now: now)
            let arrival: (time: String?, date: Date?, scheduledDate: Date?) = isCancelled(departure)
                ? (nil, nil, nil)
                : arrivalInfo(
                    for: departure,
                    at: journey.toStation.crs,
                    serviceDetailsByID: serviceDetailsByID,
                    now: now
                )

            itineraryLegs.append(JourneyItineraryLeg(
                journey: journey,
                departure: departure,
                departureDate: departureDate,
                arrivalTime: arrival.time,
                arrivalDate: arrival.date,
                disruptionNotes: disruptionNotes
            ))

            earliestConnection = arrival.date ?? departureDate
            earliestScheduledConnection = arrival.scheduledDate ?? arrival.date
            if index < group.legs.count - 1, arrival.date == nil {
                canSelectConnection = false
            }
        }

        return JourneyItinerary(group: group, legs: itineraryLegs)
    }

    static func selectDeparture(
        from departures: [DepartureV2],
        noEarlierThan earliest: Date?,
        now: Date = Date()
    ) -> DepartureV2? {
        selectConnection(
            from: departures,
            noEarlierThan: earliest,
            scheduledNoEarlierThan: nil,
            destinationName: "destination",
            changeStationName: nil,
            now: now
        ).departure
    }

    static func selectConnection(
        from departures: [DepartureV2],
        noEarlierThan earliest: Date?,
        scheduledNoEarlierThan scheduledEarliest: Date? = nil,
        destinationName: String,
        changeStationName: String? = nil,
        now: Date = Date()
    ) -> JourneyConnectionSelection {
        let viableDepartures = departures.filter { departure in
            !isCancelled(departure) && normalizedEstimate(departure) != "delayed"
        }

        guard let earliest else {
            return JourneyConnectionSelection(
                departure: viableDepartures.first,
                disruptionNotes: []
            )
        }

        let selected = viableDepartures
            .compactMap { departure -> (DepartureV2, Date)? in
                guard let departureDate = date(
                    for: departureDisplayTime(departure),
                    now: now
                ) ?? date(for: departure.departureTime.scheduled, now: now),
                departureDate >= earliest else {
                    return nil
                }
                return (departure, departureDate)
            }
            .min { $0.1 < $1.1 }

        guard let selected else {
            return JourneyConnectionSelection(departure: nil, disruptionNotes: [])
        }

        let disruption = departures
            .compactMap { departure -> (Date, String)? in
                let scheduledBaseline = scheduledEarliest ?? earliest
                guard departure.serviceID != selected.0.serviceID,
                      let scheduledDate = date(for: departure.departureTime.scheduled, now: now),
                      scheduledDate >= scheduledBaseline,
                      scheduledDate < selected.1 else {
                    return nil
                }

                let scheduledTime = departure.departureTime.scheduled
                if isCancelled(departure) {
                    return (
                        scheduledDate,
                        "\(scheduledTime) to \(destinationName) would have been faster, but was cancelled"
                    )
                }

                let estimated = normalizedEstimate(departure)
                if estimated == "delayed" {
                    return (
                        scheduledDate,
                        "\(scheduledTime) to \(destinationName) would have been faster, but is delayed with no revised time"
                    )
                }

                guard let effectiveDate = date(for: departureDisplayTime(departure), now: now) else {
                    return nil
                }
                if effectiveDate < earliest,
                   earliest > scheduledBaseline,
                   let changeStationName {
                    return (
                        scheduledDate,
                        "\(scheduledTime) to \(destinationName) would have been faster, but the delayed arrival at \(changeStationName) means this connection will be missed"
                    )
                }
                guard effectiveDate > selected.1, effectiveDate > scheduledDate else { return nil }
                return (
                    scheduledDate,
                    "\(scheduledTime) to \(destinationName) would have been faster, but is now delayed until \(departureDisplayTime(departure))"
                )
            }
            .min { $0.0 < $1.0 }?
            .1

        return JourneyConnectionSelection(
            departure: selected.0,
            disruptionNotes: disruption.map { [$0] } ?? []
        )
    }

    static func connectionMinutes(
        arrivingAt arrivalDate: Date?,
        departingAt departureDate: Date?
    ) -> Int? {
        guard let arrivalDate, let departureDate, departureDate >= arrivalDate else { return nil }
        return Int(departureDate.timeIntervalSince(arrivalDate) / 60)
    }

    static func departureDisplayTime(_ departure: DepartureV2) -> String {
        let estimated = departure.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = estimated.lowercased()
        if estimated.isEmpty || lower == "delayed" || lower == "cancelled" || lower == "on time" {
            return departure.departureTime.scheduled
        }
        return estimated
    }

    static func isCancelled(_ departure: DepartureV2) -> Bool {
        departure.isCancelled || normalizedEstimate(departure) == "cancelled"
    }

    static func cancellation(
        for departure: DepartureV2,
        at destinationCRS: String,
        serviceDetailsByID: [String: ServiceDetails]
    ) -> JourneyCancellation? {
        let targetCRS = destinationCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let details = serviceDetailsByID[departure.serviceID],
           let branch = details.stationBranches.first(where: { branch in
               branch.contains {
                   $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS
               }
           }),
           let targetIndex = branch.firstIndex(where: {
               $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS
           }) {
            let destination = branch[targetIndex]
            if destination.isCancelledAtStation {
                guard branch.contains(where: { !$0.isCancelledAtStation }) else {
                    return JourneyCancellation(
                        reason: departure.cancelReason ?? destination.cancelReason ?? details.cancelReason,
                        cancelledFrom: nil,
                        destinationName: nil,
                        serviceContinuesBeyondDestination: false
                    )
                }

                var cancelledFromIndex = targetIndex
                while cancelledFromIndex > branch.startIndex,
                      branch[branch.index(before: cancelledFromIndex)].isCancelledAtStation {
                    cancelledFromIndex = branch.index(before: cancelledFromIndex)
                }

                return JourneyCancellation(
                    reason: destination.cancelReason ?? details.cancelReason ?? departure.cancelReason,
                    cancelledFrom: branch[cancelledFromIndex].locationName,
                    destinationName: destination.locationName,
                    serviceContinuesBeyondDestination: branch.suffix(from: branch.index(after: targetIndex))
                        .contains { !$0.isCancelledAtStation }
                )
            }
        }

        guard isCancelled(departure) else { return nil }
        return JourneyCancellation(
            reason: departure.cancelReason,
            cancelledFrom: nil,
            destinationName: nil,
            serviceContinuesBeyondDestination: false
        )
    }

    private static func normalizedEstimate(_ departure: DepartureV2) -> String {
        departure.departureTime.estimated
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func date(for value: String?, now: Date = Date()) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        guard var candidate = Calendar.current.date(from: components) else { return nil }
        if candidate < now && now.timeIntervalSince(candidate) > 6 * 3600 {
            candidate = Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private static func arrivalInfo(
        for departure: DepartureV2,
        at destinationCRS: String,
        serviceDetailsByID: [String: ServiceDetails],
        now: Date
    ) -> (time: String?, date: Date?, scheduledDate: Date?) {
        guard cancellation(
            for: departure,
            at: destinationCRS,
            serviceDetailsByID: serviceDetailsByID
        ) == nil else {
            return (nil, nil, nil)
        }
        guard let details = serviceDetailsByID[departure.serviceID] else { return (nil, nil, nil) }
        let targetCRS = destinationCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if let callingPoint = details.allStations.first(where: {
            $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS
        }) {
            let display: String = {
                if let actual = callingPoint.at, actual != "Cancelled" {
                    return actual == "On time" ? callingPoint.st : actual
                }
                if let estimated = callingPoint.et, estimated != "Cancelled" {
                    return estimated == "On time" ? callingPoint.st : estimated
                }
                return callingPoint.st
            }()
            return (
                display,
                date(for: display, now: now),
                date(for: callingPoint.st, now: now)
            )
        }

        guard details.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS else {
            return (nil, nil, nil)
        }
        let display: String? = {
            if let actual = details.ata, actual != "Cancelled" {
                return actual == "On time" ? details.sta : actual
            }
            return details.sta
        }()
        return (
            display,
            date(for: display, now: now),
            date(for: details.sta, now: now)
        )
    }
}

struct JourneyItineraryView: View {
    let group: JourneyGroup
    let firstDeparture: DepartureV2

    @EnvironmentObject private var depStore: DeparturesStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct StatusPresentation {
        let compactText: String
        let detailedText: String
        let color: Color
    }

    private var itinerary: JourneyItinerary {
        JourneyItineraryBuilder.build(
            group: group,
            firstDeparture: firstDeparture,
            departuresForJourney: depStore.departures(for:),
            serviceDetailsByID: depStore.serviceDetailsById
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                journeyHeader

                VStack(spacing: 0) {
                    ForEach(Array(itinerary.legs.enumerated()), id: \.element.id) { index, leg in
                        serviceRow(leg, index: index)

                        if index < itinerary.legs.count - 1 {
                            Divider().padding(.horizontal, 16)
                            changeRow(after: leg, before: itinerary.legs[index + 1])
                            Divider().padding(.horizontal, 16)
                        }
                    }
                }
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                }
            }
            .padding(16)
        }
        .background(Color.clear)
        .navigationTitle("Journey details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: serviceDetailsTaskID) {
            await depStore.ensureServiceDetails(for: selectedServiceIDs)
        }
        .railwayBackgroundPOC()
    }

    private var journeyHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(group.startStation.name) → \(group.endStation.name)")
                .font(.title2.bold())
            Text("\(group.legs.count) legs • Change at \(changeStationNames)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var changeStationNames: String {
        group.viaStations.map(\.name).joined(separator: ", ")
    }

    @ViewBuilder
    private func serviceRow(_ leg: JourneyItineraryLeg, index: Int) -> some View {
        if let departure = leg.departure {
            NavigationLink {
                ServiceMapView(
                    serviceID: departure.serviceID,
                    fromCRS: leg.journey.fromStation.crs,
                    toCRS: leg.journey.toStation.crs,
                    departureTime: JourneyItineraryBuilder.departureDisplayTime(departure),
                    destinationName: leg.journey.toStation.name
                )
            } label: {
                serviceRowContent(leg, departure: departure, index: index)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the route map for this service.")
        } else {
            unavailableServiceRow(leg, index: index)
        }
    }

    private func serviceRowContent(
        _ leg: JourneyItineraryLeg,
        departure: DepartureV2,
        index: Int
    ) -> some View {
        let status = statusPresentation(for: departure, journey: leg.journey)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Leg \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("\(leg.journey.fromStation.name) → \(leg.journey.toStation.name)")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    timing(for: leg, departure: departure)
                    HStack(spacing: 12) {
                        platform(for: departure)
                        compactStatus(status)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    timing(for: leg, departure: departure)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    platform(for: departure)
                    compactStatus(status)
                        .frame(minWidth: 86, alignment: .leading)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                Text(status.detailedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(leg.disruptionNotes, id: \.self) { note in
                Label(note, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Journey disruption: \(note)")
            }
        }
        .padding(16)
        .contentShape(Rectangle())
    }

    private func timing(for leg: JourneyItineraryLeg, departure: DepartureV2) -> some View {
        let displayTime = JourneyItineraryBuilder.departureDisplayTime(departure)
        return VStack(alignment: .leading, spacing: 2) {
            Text(displayTime)
                .font(.title3)
                .monospacedDigit()
                .strikethrough(JourneyItineraryBuilder.isCancelled(departure))
                .foregroundStyle(JourneyItineraryBuilder.isCancelled(departure) ? Color.secondary : Color.primary)

            if displayTime != departure.departureTime.scheduled {
                Text("Scheduled \(departure.departureTime.scheduled)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("Departs \(leg.journey.fromStation.name)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let arrivalTime = leg.arrivalTime {
                Text("Arr \(JourneyCardPresentation.arrivalTimeLabel(arrivalTime)) at \(leg.journey.toStation.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !JourneyItineraryBuilder.isCancelled(departure) {
                Text("Arrival time unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func platform(for departure: DepartureV2) -> some View {
        if !JourneyItineraryBuilder.isCancelled(departure) {
            PlatformBadge(
                platform: departure.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (departure.platform ?? "TBC")
                    : "TBC",
                isBus: isBus(departure)
            )
        }
    }

    private func compactStatus(_ status: StatusPresentation) -> some View {
        Text(status.compactText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(status.color)
    }

    private func unavailableServiceRow(_ leg: JourneyItineraryLeg, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Leg \(index + 1)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text("\(leg.journey.fromStation.name) → \(leg.journey.toStation.name)")
                .font(.headline)
            Label("Connecting service information unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func changeRow(
        after currentLeg: JourneyItineraryLeg,
        before nextLeg: JourneyItineraryLeg
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Change at \(currentLeg.journey.toStation.name)", systemImage: "arrow.triangle.branch")
                .font(.subheadline.weight(.semibold))

            if let minutes = JourneyItineraryBuilder.connectionMinutes(
                arrivingAt: currentLeg.arrivalDate,
                departingAt: nextLeg.departureDate
            ) {
                Text(minutes == 1 ? "1 minute to change" : "\(minutes) minutes to change")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Connection time unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.08))
    }

    private func statusPresentation(
        for departure: DepartureV2,
        journey: Journey
    ) -> StatusPresentation {
        if JourneyItineraryBuilder.isCancelled(departure) {
            return StatusPresentation(compactText: "Cancelled", detailedText: "Service cancelled", color: .red)
        }

        if let minutes = departureDelayMinutes(
            estimated: departure.departureTime.estimated,
            scheduled: departure.departureTime.scheduled
        ), minutes > 0 {
            let color: Color = minutes >= 5 ? .red : .yellow
            return StatusPresentation(
                compactText: "Delayed",
                detailedText: "Departure delayed by \(minutes) minute\(minutes == 1 ? "" : "s")",
                color: color
            )
        }

        if departure.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delayed" {
            return StatusPresentation(
                compactText: "Delayed",
                detailedText: "Departure status unknown at present",
                color: .yellow
            )
        }

        if let details = depStore.serviceDetailsById[departure.serviceID],
           let live = computeLiveStatus(
               from: details,
               within: journey.fromStation.crs,
               toCRS: journey.toStation.crs
           ) {
            let color: Color = live.delayMinutes >= 5 ? .red : (live.delayMinutes > 0 ? .yellow : .green)
            return StatusPresentation(
                compactText: live.delayMinutes > 0 ? "Delayed" : "On time",
                detailedText: live.text,
                color: color
            )
        }

        return StatusPresentation(
            compactText: "On time",
            detailedText: "Scheduled to depart \(journey.fromStation.name) on time",
            color: .green
        )
    }

    private func isBus(_ departure: DepartureV2) -> Bool {
        departure.serviceType.lowercased() == "bus" || departure.platform?.uppercased() == "BUS"
    }

    private var selectedServiceIDs: [String] {
        itinerary.legs.compactMap { $0.departure?.serviceID }
    }

    private var serviceDetailsTaskID: String {
        selectedServiceIDs.joined(separator: ",")
    }
}
