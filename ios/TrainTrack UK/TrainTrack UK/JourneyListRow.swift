import SwiftUI

struct JourneyListRow: View {
    let group: JourneyGroup
    @EnvironmentObject var depStore: DeparturesStore
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4

    private var primaryLeg: Journey {
        group.legs.first!
    }

    private var nextDeparture: DepartureV2? {
        let deps = depStore.departures(for: primaryLeg)
        return deps.first(where: { !$0.isCancelled }) ?? deps.first
    }

    private var estimatedTime: String {
        nextDeparture?.departureTime.estimated ?? "—"
    }

    private var timeColor: Color {
        guard let dep = nextDeparture else { return .secondary }
        return colorForDelay(estimated: dep.departureTime.estimated, scheduled: dep.departureTime.scheduled)
    }

    private var isBusService: Bool {
        guard let dep = nextDeparture else { return false }
        if dep.serviceType.lowercased() == "bus" { return true }
        if let p = dep.platform, p.uppercased() == "BUS" { return true }
        return false
    }

    private var arrivalLabel: String? {
        if group.legs.count > 1 {
            return connectedFinalArrivalLabel()
        }
        return legArrivalLabel(for: primaryLeg, departure: nextDeparture)
    }

    private func connectedFinalArrivalLabel() -> String? {
        guard let firstDep = nextDeparture else { return nil }
        guard let finalTime = connectedFinalArrivalTime(startingWith: firstDep) else { return nil }
        return "Arr \(finalTime)"
    }

    private func connectedFinalArrivalTime(startingWith firstDeparture: DepartureV2) -> String? {
        var previousArrivalDate: Date? = nil
        var previousArrivalTime: String? = nil
        var previousDepartureDate: Date? = nil

        for (index, leg) in group.legs.enumerated() {
            let dep: DepartureV2
            if index == 0 {
                dep = firstDeparture
            } else {
                let earliest = previousArrivalDate ?? previousDepartureDate
                guard let nextDep = selectDeparture(for: leg, earliest: earliest) else { return nil }
                dep = nextDep
            }

            let arrival = arrivalInfo(for: dep, toCRS: leg.toStation.crs)
            guard let arrTime = arrival.time, let arrDate = arrival.date else { return nil }
            previousArrivalDate = arrDate
            previousArrivalTime = arrTime
            previousDepartureDate = departureDate(dep)
        }

        return previousArrivalTime
    }

    private func legArrivalLabel(for leg: Journey, departure: DepartureV2?) -> String? {
        guard let dep = departure else { return nil }
        guard let time = arrivalInfo(for: dep, toCRS: leg.toStation.crs).time else { return nil }
        return "Arr \(time)"
    }

    private func selectDeparture(for leg: Journey, earliest: Date?) -> DepartureV2? {
        let deps = depStore.departures(for: leg).filter { !$0.isCancelled }
        guard !deps.isEmpty else { return nil }
        if let earliest {
            if let match = deps.first(where: { dep in
                guard let depDate = departureDate(dep) else { return false }
                return depDate >= earliest
            }) {
                return match
            }
        }
        return deps.first
    }

    private func departureDisplayTime(_ dep: DepartureV2) -> String {
        let est = dep.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = est.lowercased()
        if est.isEmpty || lower == "delayed" || lower == "cancelled" || lower == "on time" {
            return dep.departureTime.scheduled
        }
        return est
    }

    private func arrivalInfo(for dep: DepartureV2, toCRS: String) -> (time: String?, date: Date?) {
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

    @ViewBuilder
    private var metaLine: some View {
        let deps = depStore.departures(for: primaryLeg)
        if deps.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("No upcoming departures found")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            let length = nextDeparture?.length
            let isBus: Bool = {
                guard let dep = nextDeparture else { return false }
                if dep.serviceType.lowercased() == "bus" { return true }
                if let p = dep.platform, p.uppercased() == "BUS" { return true }
                return false
            }()

            HStack(spacing: 10) {
                // Estimated arrival at destination
                if let arr = arrivalLabel {
                    Text(arr)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Length + short train warning; hide for bus services
                if isBus {
                    EmptyView()
                } else if let l = length, l > 0 {
                    HStack(spacing: 4) {
                        Text(lengthLabel("\(l) cars"))
                        if l <= minShortTrainCars {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Text(lengthLabel("Unknown length"))
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func lengthLabel(_ base: String) -> String {
        guard group.legs.count > 1 else { return base }
        return "\(base) (first leg)"
    }

    private var statusInfo: (text: String, color: Color)? {
        guard let dep = nextDeparture else { return nil }
        if dep.isCancelled { return ("Cancelled", .red) }

        if let details = depStore.serviceDetailsById[dep.serviceID], let live = computeLiveStatus(from: details, within: primaryLeg.fromStation.crs, toCRS: primaryLeg.toStation.crs) {
            let c: Color = live.delayMinutes >= 5 ? .red : (live.delayMinutes > 0 ? .yellow : .green)
            return (live.text, c)
        }

        // Fallback: compare estimated vs scheduled
        let est = dep.departureTime.estimated.lowercased()
        if est == "cancelled" { return ("Cancelled", .red) }
        if est == "delayed" { return ("Delayed", .red) }
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        if let s = df.date(from: dep.departureTime.scheduled), let e = df.date(from: dep.departureTime.estimated) {
            let mins = Calendar.current.dateComponents([.minute], from: s, to: e).minute ?? 0
            let c: Color = mins >= 5 ? .red : (mins > 0 ? .yellow : .green)
            let label = mins == 0 ? "On time" : "\(mins) min late"
            return (label, c)
        }
        return ("Loading status…", .gray)
    }

    // MARK: - Faster later service detection
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
        return parseHHmm(departureDisplayTime(d))
    }

    private func arrivalDate(_ d: DepartureV2) -> Date? {
        arrivalInfo(for: d, toCRS: primaryLeg.toStation.crs).date
    }

    private var fasterLaterLabel: String? {
        guard let current = nextDeparture, let thisArr = arrivalDate(current), let thisDep = departureDate(current) else { return nil }
        let deps = depStore.departures(for: primaryLeg)
        var bestArrival: Date? = nil
        var bestArrivalStr: String? = nil
        for other in deps {
            guard let oDep = departureDate(other), oDep > thisDep else { continue }
            guard let oArr = arrivalDate(other) else { continue }
            if oArr < thisArr {
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
                Text(group.displayTitle)
                metaLine
                if let warn = fasterLaterLabel {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(warn)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
                if let s = statusInfo {
                    HStack(spacing: 6) {
                        Circle().fill(s.color).frame(width: 8, height: 8)
                        Text(s.text)
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
            // Estimated time moved to right; platform lozenge to its right
            if let dep = nextDeparture {
                HStack(spacing: 8) {
                    PlatformBadge(platform: dep.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (dep.platform ?? "TBC") : "TBC", isBus: isBusService)
                    Text(estimatedTime)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(timeColor)
                        .monospacedDigit()
                }
            }
        }
        .onAppear {
            // Prefetch details for the top few services to populate status quickly
            let ids = group.legs.flatMap { depStore.departures(for: $0).prefix(2).map { $0.serviceID } }
            Task { await depStore.ensureServiceDetails(for: Array(Set(ids))) }
        }
    }
}
