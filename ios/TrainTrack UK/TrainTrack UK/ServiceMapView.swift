import SwiftUI
import Combine

struct ServiceMapView: View {
    let serviceID: String
    let fromCRS: String
    let toCRS: String

    @EnvironmentObject var depStore: DeparturesStore
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4

    @State private var timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var currentIndex: Double = -1

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Static header pinned at top
                headerView
                    .background(.ultraThinMaterial)
                Divider()
                ScrollView {
                    stationsList
                        .padding(.vertical, 12)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                if let anchor = anchorIDForScroll() { withAnimation { proxy.scrollTo(anchor, anchor: .center) } }
                            }
                        }
                }
            }
            .navigationTitle(routeTitle())
            .onReceive(timer) { _ in
                Task { await depStore.ensureServiceDetails(for: [serviceID], force: true) }
                recalcCurrentIndex()
            }
            .onAppear {
                Task { await depStore.ensureServiceDetails(for: [serviceID], force: true) }
                recalcCurrentIndex()
            }
        }
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title is also used in the nav bar, but include here for context on scroll
            Text(routeTitle())
                .font(.title2).bold()
            if let op = serviceOperator() {
                Text("Operator: \(op)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Length header: show unknown + warning when nil or 0
            let isBus = (depStore.serviceDetailsById[serviceID]?.serviceType.lowercased() == "bus")
            if isBus {
                HStack(spacing: 6) {
                    Image(systemName: "bus")
                    Text("Bus service")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            } else if let len = serviceLength(), len > 0 {
                HStack(spacing: 6) {
                    Text("Length: \(len) coach\(len == 1 ? "" : "es")")
                    if len <= minShortTrainCars {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text("Length: unknown")
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let info = delayOrCancelInfo() {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(info)
                        .font(.caption)
                }
                .padding(8)
                .background(Color(.systemYellow).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Divider().padding(.top, 4)
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var stationsList: some View {
        let list = stations()
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<max(0, list.count), id: \.self) { index in
                let s = list[index]
                let frac = currentIndex - floor(currentIndex)
                // Use a small window around each station to render the dot on the station itself
                let epsilon = 0.02
                let atPrev = (index == Int(floor(currentIndex)) && frac >= 0 && frac <= epsilon)
                let atNext = (index == Int(ceil(currentIndex)) && frac >= (1 - epsilon) && frac <= 1)
                let isAtThisStation = atPrev || atNext || abs(currentIndex - Double(index)) < 0.0001
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.gray.opacity(0.6), lineWidth: 2))
                        if isAtThisStation {
                            PulsingDot().transition(.opacity)
                        }
                    }
                    .id("station-\(index)")

                    VStack(alignment: .leading, spacing: 2) {
                        let delayMins = delayMinutes(for: s)
                        let futureColor: Color = {
                            if let et = s.et?.lowercased(), et == "delayed" { return .red }
                            return colorForDelayMinutes(delayMins)
                        }()
                        let floorIdx = Int(floor(currentIndex))
                        // A station is future only if it is strictly after the current
                        // segment's starting station. When traveling between A (floorIdx)
                        // and B (ceilIdx), A should not be highlighted as future.
                        let isFuture = index > floorIdx
                        let nameColor: Color = {
                            if s.isCancelledAtStation { return .red }
                            if isAtThisStation { return .primary }
                            if isFuture { return futureColor }
                            return .secondary
                        }()
                        let timeColor: Color = {
                            if s.isCancelledAtStation { return .red }
                            if isAtThisStation { return .secondary }
                            if isFuture { return futureColor }
                            return .secondary
                        }()
                        Text(s.locationName)
                            .font(.body)
                            .foregroundStyle(nameColor)
                        Text(timeLabel(for: s, isFinal: index == list.count - 1))
                            .font(.caption)
                            .foregroundStyle(timeColor)
                    }
                }
                .padding(.vertical, 9)
                .padding(.leading, 6)

                // Connector segment (except after last)
                if index < list.count - 1 {
                    let progress = CGFloat(max(0, min(1, currentIndex - floor(currentIndex))))
                    let showDot = floor(currentIndex) == Double(index) &&
                                  progress > CGFloat(epsilon) && progress < CGFloat(1 - epsilon)
                    ConnectorSegment(height: 36, showDot: showDot, progress: progress)
                        .id("seg-\(index)")
                }
            }
        }
        .background(
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 2)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
    }

    // Build stations list using the combined previous/current/subsequent points
    private func stations() -> [CallingPoint] {
        guard let details = depStore.serviceDetailsById[serviceID] else { return [] }
        return details.allStations
    }

    // Determine the current floating index using the same rules as the web impl
    private func recalcCurrentIndex() {
        let list = stations()
        guard !list.isEmpty else { currentIndex = -1; return }
        let now = Date()
        // Track last station with an actual time (has departed/arrived)
        let lastActualIdx: Int = {
            var idx = -1
            for (i, s) in list.enumerated() {
                if let at = s.at, at != "Cancelled" { idx = i }
            }
            return idx
        }()

        func parse(_ t: String?) -> Date? {
            guard let t = t, !t.isEmpty, t != "On time", t != "Cancelled" else { return nil }
            let comps = t.split(separator: ":")
            guard comps.count == 2, let h = Int(comps[0]), let m = Int(comps[1]) else { return nil }
            var dc = Calendar.current.dateComponents([.year, .month, .day], from: now)
            dc.hour = h; dc.minute = m
            return Calendar.current.date(from: dc)
        }

        func effectiveTime(_ s: CallingPoint) -> Date? {
            if let et = s.et, et != "On time", et != "Cancelled" { return parse(et) }
            return parse(s.st)
        }

        func arrivalCutoff(_ s: CallingPoint) -> Date? {
            guard let t = effectiveTime(s) else { return nil }
            return t.addingTimeInterval(-30) // arrive 30s before depart time
        }

        // Walk forward to find where the train is
        for i in 0..<list.count {
            let s = list[i]
            if s.isCancelledAtStation { continue }

            // If actually departed, move on
            if let at = s.at, at != "Cancelled" { continue }

            guard let stTime = effectiveTime(s) else { continue }
            let arrive = stTime.addingTimeInterval(-30)
            if now < arrive {
                // Between previous and this
                if i == 0 { currentIndex = 0; return }

                let prev = list[i-1]
                // Departure from prev
                var depFromPrev: Date? = nil
                if let at = prev.at, at != "Cancelled" {
                    depFromPrev = (at == "On time") ? parse(prev.st) : parse(at)
                } else {
                    depFromPrev = prev.et != nil && prev.et != "On time" && prev.et != "Cancelled" ? parse(prev.et) : parse(prev.st)
                }
                let nextArrive = arrivalCutoff(s)
                guard let dep = depFromPrev, let arr = nextArrive else { currentIndex = Double(i-1); return }
                if now <= dep { currentIndex = Double(i-1); return }
                if now >= arr { currentIndex = Double(i); return }
                let total = arr.timeIntervalSince(dep)
                let elapsed = now.timeIntervalSince(dep)
                if total <= 0 { currentIndex = Double(i-1); return }
                let prog = max(0, min(1, elapsed / total))
                currentIndex = Double(i-1) + prog
                return
            } else if now < stTime {
                // At this station
                currentIndex = Double(i)
                return
            }
        }

        // If we reached here it means all effective times are in the past.
        // When subsequent stations are marked as "Delayed" (unknown delay),
        // do NOT snap the position to the final station; instead keep the dot
        // at the last station with an actual time.
        if lastActualIdx >= 0 && lastActualIdx < list.count - 1 {
            let hasUnknownAhead = list[(lastActualIdx+1)...].contains { cp in
                (cp.et?.lowercased() == "delayed") && !cp.isCancelledAtStation
            }
            if hasUnknownAhead { currentIndex = Double(lastActualIdx); return }
        }
        currentIndex = Double(max(0, list.count - 1))
    }

    // MARK: - Helpers for header
    private func routeTitle() -> String {
        let list = stations()
        guard let first = list.first?.locationName, let last = list.last?.locationName else { return "Service map" }
        return "\(first) → \(last)"
    }

    private func serviceOperator() -> String? {
        guard let d = depStore.serviceDetailsById[serviceID] else { return nil }
        return d.operator
    }

    private func serviceLength() -> Int? {
        guard let d = depStore.serviceDetailsById[serviceID] else { return nil }
        return d.length
    }

    private func delayOrCancelInfo() -> String? {
        guard let d = depStore.serviceDetailsById[serviceID] else { return nil }
        if let reason = d.delayReason, !reason.isEmpty { return reason }
        if let reason = d.cancelReason, !reason.isEmpty { return reason }
        return nil
    }

    private func anchorIDForScroll() -> String? {
        guard currentIndex >= 0 else { return nil }
        let frac = currentIndex - floor(currentIndex)
        if frac < 0.5 { return "station-\(Int(floor(currentIndex)))" }
        return "seg-\(Int(floor(currentIndex)))"
    }

    private func timeLabel(for s: CallingPoint, isFinal: Bool) -> String {
        // Prefer at (actual) then et, else st; then append delay minutes if any
        let base: String
        if let at = s.at, at != "Cancelled" { base = (at == "On time" ? s.st : at) }
        else if let et = s.et, et != "Cancelled" { base = (et == "On time" ? s.st : et) }
        else { base = s.st }

        let mins = delayMinutes(for: s)
        if mins > 0 { return "\(base) (\(mins) minute\(mins == 1 ? "" : "s") late)" }
        return base
    }

    private func delayMinutes(for s: CallingPoint) -> Int {
        // Same logic used elsewhere (LiveStatus/StatusColoring)
        if let at = s.at, at != "Cancelled" {
            if at == "On time" { return 0 }
            if let a = parseHHmm(at), let sch = parseHHmm(s.st) { return max(0, Int(a.timeIntervalSince(sch) / 60)) }
        }
        if let et = s.et, et != "On time", et != "Cancelled" {
            if let e = parseHHmm(et), let sch = parseHHmm(s.st) { return max(0, Int(e.timeIntervalSince(sch) / 60)) }
        }
        return 0
    }

    private func parseHHmm(_ t: String?) -> Date? {
        guard let t = t else { return nil }
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        var dc = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        dc.hour = h; dc.minute = m
        return Calendar.current.date(from: dc)
    }
}

private struct ConnectorSegment: View {
    let height: CGFloat
    let showDot: Bool
    let progress: CGFloat // 0..1 from previous to next

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 2)
                .padding(.leading, 10)
            if showDot {
                PulsingDot()
                    .offset(x: 5, y: height * progress - height / 2)
                    .animation(.easeInOut(duration: 1.8), value: progress)
            }
        }
        .frame(height: height)
    }
}

private struct PulsingDot: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
            Circle()
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
                .frame(width: 12, height: 12)
                .scaleEffect(pulse ? 1.8 : 1.0)
                .opacity(pulse ? 0.0 : 0.7)
                .onAppear {
                    withAnimation(Animation.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }
        }
    }
}
