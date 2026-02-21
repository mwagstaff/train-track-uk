import Foundation

struct LiveStatusInfo {
    let text: String
    let delayMinutes: Int
}

// Compute live status using the same time-window interpolation used by the Service Map
// Optional fromCRS/toCRS constrain evaluation to a sub-segment of the service
func computeLiveStatus(from serviceDetails: ServiceDetails, within fromCRS: String? = nil, toCRS: String? = nil) -> LiveStatusInfo? {
    if serviceDetails.serviceType.lowercased() != "train" { return nil }

    let stations = serviceDetails.allStations
    if stations.isEmpty { return nil }
    if stations.allSatisfy({ $0.isCancelledAtStation }) { return nil }

    // If a sub-window is requested, constrain the list to that window plus one station before
    // the window start (to allow "between prev and from" phrasing when approaching origin).
    var window: [CallingPoint] = stations
    if fromCRS != nil || toCRS != nil {
        let fromIdxFull = fromCRS.flatMap { code in stations.firstIndex { $0.crs == code } } ?? 0
        let toIdxFull = toCRS.flatMap { code in stations.firstIndex { $0.crs == code } } ?? (stations.count - 1)
        let start = max(0, min(fromIdxFull, toIdxFull) - 1)
        let end = min(stations.count - 1, max(fromIdxFull, toIdxFull))
        if start <= end { window = Array(stations[start...end]) }
    }

    func parseTime(_ t: String?) -> Date? {
        guard let t = t, !t.isEmpty, t != "On time", t != "Cancelled" else { return nil }
        let parts = t.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps)
    }

    func effectiveTime(_ s: CallingPoint) -> Date? {
        if let et = s.et, et != "On time", et != "Cancelled" { return parseTime(et) }
        return parseTime(s.st)
    }

    func delayMinutes(for s: CallingPoint) -> Int {
        if let at = s.at, at != "Cancelled" {
            if at == "On time" { return 0 }
            if let a = parseTime(at), let sch = parseTime(s.st) { return max(0, Int(a.timeIntervalSince(sch) / 60)) }
        }
        if let et = s.et, et != "On time", et != "Cancelled" {
            if let e = parseTime(et), let sch = parseTime(s.st) { return max(0, Int(e.timeIntervalSince(sch) / 60)) }
        }
        return 0
    }

    let now = Date()

    // Pre-departure guard: if no station along the entire service has an actual time yet,
    // the service hasn't started from its true origin. Use the first station of the FULL route
    // (not the constrained window) so we don't incorrectly reference the "prev-of-origin"
    // station like Elmers End for a Clock House → London journey where the origin is Hayes (Kent).
    let anyActualFull = stations.contains { cp in
        if let at = cp.at { return at != "Cancelled" }
        return false
    }
    if !anyActualFull, let first = stations.first(where: { !$0.isCancelledAtStation }) {
        let d = delayMinutes(for: first)
        if let et = first.et?.lowercased(), et == "delayed" {
            // Special grammar for unknown delay from origin
            return LiveStatusInfo(text: "Departure from \(first.locationName) delayed for an unknown period of time", delayMinutes: d)
        } else {
            let phrasing = d == 0 ? "on time" : "\(d) minute\(d == 1 ? "" : "s") late"
            return LiveStatusInfo(text: "Scheduled to depart \(first.locationName) \(phrasing)", delayMinutes: d)
        }
    }

    // Walk forward using the same rules as the service map to find location window
    let approachWindow: TimeInterval = 60   // within 1 min of next station -> approaching
    let atGraceWindow: TimeInterval = 30    // remain "at <prev>" for 30s after its est depart
    for i in 0..<window.count {
        let s = window[i]
        if s.isCancelledAtStation { continue }

        // If we have actual departure from this station, continue forward
        if let at = s.at, at != "Cancelled" { continue }

        guard let stTime = effectiveTime(s) else { continue }
        // Approach threshold for next station
        let arrive = stTime.addingTimeInterval(-approachWindow)

        if now < arrive {
            // Between previous and this (or before first)
            if i == 0 {
                // Check if this station is the true origin of the full route.
                if let sIdxFull = stations.firstIndex(where: { $0.crs == s.crs }) {
                    if sIdxFull == 0 {
                        // Truly before the service origin
                        if let et = s.et?.lowercased(), et == "delayed" {
                            return LiveStatusInfo(text: "Departure from \(s.locationName) delayed for an unknown period of time", delayMinutes: 0)
                        }
                        let d = delayMinutes(for: s)
                        let lateText = d == 0 ? "on time" : "\(d) minute\(d == 1 ? "" : "s") late"
                        return LiveStatusInfo(text: "Scheduled to depart \(s.locationName) \(lateText)", delayMinutes: d)
                    } else {
                        // Before the first station in the constrained window but NOT before the
                        // true route origin. Determine the correct full-route segment (or station)
                        // using the same window rules applied below, but across the full list up to sIdxFull.
                        for k in 0...sIdxFull {
                            let f = stations[k]
                            if f.isCancelledAtStation { continue }
                            if let at = f.at, at != "Cancelled" { continue }
                            guard let fTime = effectiveTime(f) else { continue }
                            let fArrive = fTime.addingTimeInterval(-approachWindow)
                            if now < fArrive {
                                if k == 0 {
                                    let d0 = delayMinutes(for: f)
                                    let phr = d0 == 0 ? "on time" : "\(d0) minute\(d0 == 1 ? "" : "s") late"
                                    return LiveStatusInfo(text: "Scheduled to depart \(f.locationName) \(phr)", delayMinutes: d0)
                                }
                                var prevK = k - 1
                                var prev = stations[prevK]
                                while prev.isCancelledAtStation, prevK > 0 {
                                    prevK -= 1
                                    prev = stations[prevK]
                                }
                                let d = max(delayMinutes(for: prev), delayMinutes(for: f))
                                let lateText = d >= 240 ? "delayed for an unknown period of time" : (d == 0 ? "on time" : "\(d) minute\(d == 1 ? "" : "s") late")
                                return LiveStatusInfo(text: "Currently \(lateText), between \(prev.locationName) and \(f.locationName)", delayMinutes: d)
                            } else if now < fTime {
                                // Inside the approach window for the first window station.
                                // Prefer staying "at <prev>" for a short grace if we've
                                // already arrived there; otherwise say "approaching <f>".
                                let d = delayMinutes(for: f)
                                let lateText = d == 0 ? "on time" : "\(d) minute\(d == 1 ? "" : "s") late"
                                if k > 0 {
                                    var prevIdx = k - 1
                                    var prev = stations[prevIdx]
                                    while prev.isCancelledAtStation, prevIdx > 0 {
                                        prevIdx -= 1
                                        prev = stations[prevIdx]
                                    }
                                    if let prevAt = prev.at, prevAt != "Cancelled", let prevET = effectiveTime(prev) {
                                        if Date() <= prevET.addingTimeInterval(atGraceWindow) {
                                            let dPrev = delayMinutes(for: prev)
                                            let latePrev = dPrev == 0 ? "on time" : "\(dPrev) minute\(dPrev == 1 ? "" : "s") late"
                                            return LiveStatusInfo(text: "Currently \(latePrev), at \(prev.locationName)", delayMinutes: dPrev)
                                        }
                                    }
                                }
                                return LiveStatusInfo(text: "Currently \(lateText), at or near \(f.locationName)", delayMinutes: d)
                            }
                        }
                        // Fallback: if nothing matched above, assume we are between the station
                        // directly before the first window station and this first station.
                        var j = sIdxFull - 1
                        var prevFull = stations[j]
                        while prevFull.isCancelledAtStation, j > 0 {
                            j -= 1
                            prevFull = stations[j]
                        }
                        let d = max(delayMinutes(for: prevFull), delayMinutes(for: s))
                        let lateText = d >= 240 ? "delayed for an unknown period of time" : (d == 0 ? "on time" : "\(d) minute\(d == 1 ? "" : "s") late")
                        return LiveStatusInfo(text: "Currently \(lateText), between \(prevFull.locationName) and \(s.locationName)", delayMinutes: d)
                    }
                }
            }

            let prev = window[i-1]
            let d = max(delayMinutes(for: prev), delayMinutes(for: s))
            let lateText = d >= 240 ? "delayed for an unknown period of time" : (d == 0 ? "on time" : "\(d) minute\(d == 1 ? "" : "s") late")
            return LiveStatusInfo(text: "Currently \(lateText), between \(prev.locationName) and \(s.locationName)", delayMinutes: d)
        } else if now < stTime {
            // Within the approach window for this next station. Only show "at <prev>"
            // when we've actually arrived there (has `at`) and are within 30s of its
            // estimated depart; otherwise show "approaching <next>".
            let dNext = delayMinutes(for: s)
            let lateNext = dNext == 0 ? "on time" : "\(dNext) minute\(dNext == 1 ? "" : "s") late"
            if i > 0 {
                var prev = window[i-1]
                var prevIdx = i-1
                while prev.isCancelledAtStation, prevIdx > 0 {
                    prevIdx -= 1
                    prev = window[prevIdx]
                }
                if let prevAt = prev.at, prevAt != "Cancelled", let prevET = effectiveTime(prev) {
                    if now <= prevET.addingTimeInterval(atGraceWindow) {
                        let dPrev = delayMinutes(for: prev)
                        let latePrev = dPrev == 0 ? "on time" : "\(dPrev) minute\(dPrev == 1 ? "" : "s") late"
                        return LiveStatusInfo(text: "Currently \(latePrev), at \(prev.locationName)", delayMinutes: dPrev)
                    }
                }
            }
            return LiveStatusInfo(text: "Currently \(lateNext), at or near \(s.locationName)", delayMinutes: dNext)
        }
    }

    // If we didn't match anything above, check for unknown delay ahead of the last
    // station with an actual time. In this case, report as currently delayed between
    // the last actual station and the next station, instead of "Arrived at <final>".
    var lastActualIdx: Int? = nil
    for (i, s) in window.enumerated() {
        if let at = s.at, at != "Cancelled" { lastActualIdx = i }
    }
    if let li = lastActualIdx, li < window.count - 1 {
        // Find the next non-cancelled station following the last actual
        var nextIdx = li + 1
        while nextIdx < window.count && window[nextIdx].isCancelledAtStation { nextIdx += 1 }
        if nextIdx < window.count {
            let next = window[nextIdx]
            // Consider "Delayed" unknown delay as a red signal here
            if next.et?.lowercased() == "delayed" || next.at == nil {
                let prev = window[li]
                let d = max(delayMinutes(for: prev), delayMinutes(for: next))
                let txt = d >= 240 ? "delayed for an unknown period of time" : (d == 0 ? "on time" : "\(d) minute\(d == 1 ? "" : "s") late")
                return LiveStatusInfo(text: "Currently \(txt), between \(prev.locationName) and \(next.locationName)", delayMinutes: d)
            }
        }
    }

    // After final station
    if let last = window.last {
        let d = delayMinutes(for: last)
        let lateText = d == 0 ? "on time" : "\(d) minute\(d == 1 ? "" : "s") late"
        return LiveStatusInfo(text: "Arrived \(lateText) at \(last.locationName)", delayMinutes: d)
    }
    return nil
}
