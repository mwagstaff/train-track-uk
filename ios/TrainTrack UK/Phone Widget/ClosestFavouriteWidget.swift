//
//  ClosestFavouriteWidget.swift
//  Phone Widget
//
//  Creates a resizable Home Screen widget called
//  "Closest Favourite Journey" that shows a compact list of
//  departures styled like the app's Next Departures screen.
//

import WidgetKit
import SwiftUI
import CoreLocation
import OSLog

private enum WidgetApiHost: String {
    case prod
    case dev

    static let storageKey = "api_host_preference"
    static let store: UserDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard

    var baseURL: String {
        switch self {
        case .prod: return "https://api.skynolimit.dev/train-track/api/v2"
        case .dev: return "http://Mikes-MacBook-Air.local:3000/api/v2"
        }
    }

    static var currentBaseURL: String {
        WidgetApiHost(rawValue: store.string(forKey: storageKey) ?? "")?.baseURL ?? WidgetApiHost.prod.baseURL
    }
}

private enum WidgetDeviceIdentity {
    private static let storageKey = "device_token"
    private static let store: UserDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard

    static var deviceToken: String {
        if let existing = store.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let token = UUID().uuidString
        store.set(token, forKey: storageKey)
        return token
    }
}

private extension Logger {
    static let widget = Logger(subsystem: "dev.skynolimit.traintrack", category: "ClosestFavouriteWidget")
}

// MARK: - Backwards compatible background for iOS 16+

// MARK: - Minimal shared models (duplicated for the extension)
private struct Station: Codable, Identifiable, Hashable {
    let crs: String
    let name: String
    let longitude: String
    let latitude: String
    var id: String { crs }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: Double(latitude) ?? 0,
            longitude: Double(longitude) ?? 0
        )
    }
}

private struct Journey: Codable, Identifiable, Hashable {
    let id: UUID
    let fromStation: Station
    let toStation: Station
    let createdAt: Date
    let favorite: Bool
}

private struct DepartureTimeV2: Codable, Hashable { let scheduled: String; let estimated: String }
private struct PlaceInfoV2: Codable, Hashable { let crs: String?; let locationName: String; let via: String? }

private struct DepartureV2: Codable, Identifiable, Hashable {
    let departureTime: DepartureTimeV2
    let serviceType: String
    let platform: String?
    let isCancelled: Bool
    let length: Int?
    let destination: [PlaceInfoV2]
    let origin: [PlaceInfoV2]?
    let serviceID: String
    let delayReason: String?
    let cancelReason: String?
    let timestamp: Date?
    var id: String { serviceID }

    private enum CodingKeys: String, CodingKey {
        case departureTime = "departure_time"
        case serviceType, platform, isCancelled, length
        case destination, origin
        case serviceID, delayReason, cancelReason, timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.departureTime = try c.decode(DepartureTimeV2.self, forKey: .departureTime)
        self.serviceType = (try? c.decode(String.self, forKey: .serviceType)) ?? ""
        self.platform = try? c.decode(String.self, forKey: .platform)
        self.isCancelled = (try? c.decode(Bool.self, forKey: .isCancelled)) ?? false
        self.length = try? c.decode(Int.self, forKey: .length)

        if let destArr = try? c.decode([PlaceInfoV2].self, forKey: .destination) {
            self.destination = destArr
        } else if let destOne = try? c.decode(PlaceInfoV2.self, forKey: .destination) {
            self.destination = [destOne]
        } else {
            self.destination = []
        }

        if c.contains(.origin) {
            if let orgArr = try? c.decode([PlaceInfoV2].self, forKey: .origin) {
                self.origin = orgArr
            } else if let orgOne = try? c.decode(PlaceInfoV2.self, forKey: .origin) {
                self.origin = [orgOne]
            } else {
                self.origin = nil
            }
        } else {
            self.origin = nil
        }

        self.serviceID = (try? c.decode(String.self, forKey: .serviceID)) ?? UUID().uuidString
        self.delayReason = try? c.decode(String.self, forKey: .delayReason)
        self.cancelReason = try? c.decode(String.self, forKey: .cancelReason)
        self.timestamp = try? c.decode(Date.self, forKey: .timestamp)
    }

    // Convenience initializer for previews/placeholders
    init(
        departureTime: DepartureTimeV2,
        serviceType: String,
        platform: String?,
        isCancelled: Bool,
        length: Int?,
        destination: [PlaceInfoV2],
        origin: [PlaceInfoV2]?,
        serviceID: String,
        delayReason: String?,
        cancelReason: String?,
        timestamp: Date?
    ) {
        self.departureTime = departureTime
        self.serviceType = serviceType
        self.platform = platform
        self.isCancelled = isCancelled
        self.length = length
        self.destination = destination
        self.origin = origin
        self.serviceID = serviceID
        self.delayReason = delayReason
        self.cancelReason = cancelReason
        self.timestamp = timestamp
    }
}

// Service Details (subset used for live status)
private struct CallingPoint: Codable, Identifiable, Equatable { let locationName: String; let crs: String; let st: String; let et: String?; let at: String?; let isCancelled: Bool?; let cancelReason: String?; let length: Int?; let detachFront: Bool?; let affectedByDiversion: Bool?; let rerouteDelay: Int?; var id: String { crs } }
private struct CallingPointList: Codable, Equatable { let callingPoint: [CallingPoint]; let serviceType: String?; let serviceChangeRequired: Bool?; let assocIsCancelled: Bool? }
private struct ServiceDetails: Codable, Equatable {
    let previousCallingPoints: [CallingPointList]?
    let subsequentCallingPoints: [CallingPointList]?
    let generatedAt: String
    let serviceType: String
    let locationName: String
    let crs: String
    let operatorName: String?
    let operatorCode: String?
    let isCancelled: Bool?
    let length: Int?
    let detachFront: Bool?
    let isReverseFormation: Bool?
    let platform: String?
    let sta: String?
    let ata: String?
    let std: String?
    let etd: String?
    let atd: String?
    let delayReason: String?
    let cancelReason: String?

    private enum CodingKeys: String, CodingKey {
        case previousCallingPoints, subsequentCallingPoints, generatedAt, serviceType, locationName, crs
        case operatorName = "operator", operatorCode, isCancelled, length, detachFront, isReverseFormation, platform, sta, ata, std, etd, atd, delayReason, cancelReason
    }

    var allStations: [CallingPoint] {
        var stations: [CallingPoint] = []
        if let previous = previousCallingPoints { for list in previous { stations.append(contentsOf: list.callingPoint) } }
        let currentStation = CallingPoint(
            locationName: locationName, crs: crs, st: std ?? sta ?? "Unknown",
            et: etd, at: atd ?? ata, isCancelled: isCancelled, cancelReason: cancelReason,
            length: length, detachFront: detachFront, affectedByDiversion: false, rerouteDelay: 0
        )
        stations.append(currentStation)
        if let subsequent = subsequentCallingPoints { for list in subsequent { stations.append(contentsOf: list.callingPoint) } }
        return stations
    }
}

// MARK: - Shared helpers used by the widget UI
private func colorForDelay(estimated: String?, scheduled: String?) -> Color {
    guard let estRaw = estimated?.lowercased() else { return .secondary }
    if estRaw == "cancelled" || estRaw == "delayed" { return .red }
    guard let sch = scheduled else { return .secondary }
    let df = DateFormatter(); df.dateFormat = "HH:mm"
    if let s = df.date(from: sch), let e = df.date(from: estimated ?? "") {
        let mins = Calendar.current.dateComponents([.minute], from: s, to: e).minute ?? 0
        if mins >= 5 { return .red }; if mins > 0 { return .yellow }; return .green
    }
    return .secondary
}

private struct LiveStatusInfo { let text: String; let delayMinutes: Int }

// A trimmed version of the app's live status logic suitable for the widget
private func computeLiveStatus(from serviceDetails: ServiceDetails, within fromCRS: String? = nil, toCRS: String? = nil) -> LiveStatusInfo? {
    if serviceDetails.serviceType.lowercased() != "train" { return nil }
    let stations = serviceDetails.allStations
    if stations.isEmpty { return nil }

    func parseTime(_ t: String?) -> Date? {
        guard let t = t, !t.isEmpty, t != "On time", t != "Cancelled" else { return nil }
        let parts = t.split(separator: ":"); guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date()); c.hour = h; c.minute = m
        return Calendar.current.date(from: c)
    }
    func effectiveTime(_ s: CallingPoint) -> Date? { if let et = s.et, et != "On time", et != "Cancelled" { return parseTime(et) }; return parseTime(s.st) }
    func delayMinutes(for s: CallingPoint) -> Int {
        if let at = s.at, at != "Cancelled" {
            if at == "On time" { return 0 }
            if let a = parseTime(at), let sch = parseTime(s.st) { return max(0, Int(a.timeIntervalSince(sch)/60)) }
        }
        if let et = s.et, et != "On time", et != "Cancelled" {
            if let e = parseTime(et), let sch = parseTime(s.st) { return max(0, Int(e.timeIntervalSince(sch)/60)) }
        }
        return 0
    }

    var window = stations
    if fromCRS != nil || toCRS != nil {
        let fromIdx = fromCRS.flatMap { code in stations.firstIndex { $0.crs == code } } ?? 0
        let toIdx = toCRS.flatMap { code in stations.firstIndex { $0.crs == code } } ?? (stations.count - 1)
        let start = max(0, min(fromIdx, toIdx) - 1), end = min(stations.count - 1, max(fromIdx, toIdx))
        if start <= end { window = Array(stations[start...end]) }
    }

    let now = Date(); let approach: TimeInterval = 60; let atGrace: TimeInterval = 30
    for i in 0..<window.count {
        let s = window[i]; if s.isCancelled == true || s.at == "Cancelled" || s.et == "Cancelled" { continue }
        if let at = s.at, at != "Cancelled" { continue }
        guard let stTime = effectiveTime(s) else { continue }
        let arrive = stTime.addingTimeInterval(-approach)
        if now < arrive {
            if i == 0 { return LiveStatusInfo(text: "Scheduled to depart \(s.locationName) \(delayMinutes(for: s) == 0 ? "on time" : "\(delayMinutes(for: s)) min late")", delayMinutes: delayMinutes(for: s)) }
            let prev = window[i-1]
            let d = max(delayMinutes(for: prev), delayMinutes(for: s))
            let t = d >= 240 ? "delayed for an unknown period of time" : (d == 0 ? "on time" : "\(d) min late")
            return LiveStatusInfo(text: "Currently \(t), between \(prev.locationName) and \(s.locationName)", delayMinutes: d)
        } else if now < stTime {
            let dNext = delayMinutes(for: s); let t = dNext == 0 ? "on time" : "\(dNext) min late"
            if i > 0 {
                let prev = window[i-1]
                if let prevAt = prev.at, prevAt != "Cancelled", let prevET = effectiveTime(prev), now <= prevET.addingTimeInterval(atGrace) {
                    let dPrev = delayMinutes(for: prev); let tp = dPrev == 0 ? "on time" : "\(dPrev) min late"
                    return LiveStatusInfo(text: "Currently \(tp), at \(prev.locationName)", delayMinutes: dPrev)
                }
            }
            return LiveStatusInfo(text: "Currently \(t), at or near \(s.locationName)", delayMinutes: dNext)
        }
    }
    if let last = window.last { let d = delayMinutes(for: last); return LiveStatusInfo(text: "Arrived \(d == 0 ? "on time" : "\(d) min late") at \(last.locationName)", delayMinutes: d) }
    return nil
}

// Compact platform badge mirroring the app's style.
private struct PlatformBadge: View {
    let platform: String
    var isBus: Bool = false
    private func displayText() -> String { let t = platform.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? "TBC" : t }
    var body: some View {
        Group {
            if isBus || platform.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "BUS" {
                HStack(spacing: 4) { Image(systemName: "bus"); Text("Bus") }
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.yellow).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text(displayText())
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.gray.opacity(0.18))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }.lineLimit(1)
    }
}

// MARK: - Network client (subset for the widget)
private enum WidgetNetErr: Error { case invalidURL, badData }

private final class NetworkServiceWidget {
    static let shared = NetworkServiceWidget()
    private init() {}
    private var base: String { WidgetApiHost.currentBaseURL }
    private var deviceToken: String { WidgetDeviceIdentity.deviceToken }
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    func fetchDepartures(from: String, to: String) async throws -> [DepartureV2] {
        let path = "from/\(from)/to/\(to)"
        guard let url = URL(string: "\(base)/departures/\(path)") else { throw WidgetNetErr.invalidURL }
        Logger.widget.info("GET \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url)
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        // Response shape could be {"ECR_VIC": [...]} or [{"ECR_VIC": [...]}]
        let json = try JSONSerialization.jsonObject(with: data)
        if let dict = json as? [String: Any], let arr = dict.values.first {
            let d = try JSONSerialization.data(withJSONObject: arr)
            return try decoder.decode([DepartureV2].self, from: d)
        } else if let arr = json as? [[String: Any]], let key = arr.first?.keys.first, let val = arr.first?[key] {
            let d = try JSONSerialization.data(withJSONObject: val)
            return try decoder.decode([DepartureV2].self, from: d)
        }
        Logger.widget.error("Unexpected departures JSON shape")
        return []
    }

    func fetchServiceDetails(ids: [String]) async throws -> [String: ServiceDetails] {
        guard !ids.isEmpty else { return [:] }
        let path = ids.joined(separator: "/")
        guard let url = URL(string: "\(base)/service_details/\(path)") else { throw WidgetNetErr.invalidURL }
        Logger.widget.info("GET \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url)
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let arrAny = try JSONSerialization.jsonObject(with: data)
        let arr = arrAny as? [[String: Any]] ?? []
        var out: [String: ServiceDetails] = [:]
        for item in arr {
            if let key = item.keys.first, let val = item[key] {
                let valData = try JSONSerialization.data(withJSONObject: val, options: [])
                if let dict = try? JSONSerialization.jsonObject(with: valData) as? [String: Any], dict.isEmpty { continue }
                out[key] = try decoder.decode(ServiceDetails.self, from: valData)
            }
        }
        if out.isEmpty { Logger.widget.info("Service details result empty for \(ids.count, privacy: .public) ids") }
        return out
    }
}

// MARK: - Location fetcher (best-effort, with short timeout)
private final class OneShotLocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutWork: DispatchWorkItem?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func fetch(timeout: TimeInterval = 1.5) async -> CLLocation? {
        // Widgets cannot prompt for location permission. Only use if already authorized.
        let status = manager.authorizationStatus
        if !(status == .authorizedAlways || status == .authorizedWhenInUse) {
            Logger.widget.debug("Location not authorized for widget; skipping")
            return nil
        }

        manager.requestLocation()
        return await withCheckedContinuation { (c: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = c
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if let cont = self.continuation {
                    Logger.widget.debug("Location timeout fired; returning nil")
                    self.continuation = nil
                    cont.resume(returning: nil)
                }
            }
            self.timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        timeoutWork?.cancel(); timeoutWork = nil
        if let cont = continuation {
            Logger.widget.debug("Location success from widget")
            continuation = nil
            cont.resume(returning: locations.last)
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        timeoutWork?.cancel(); timeoutWork = nil
        if let cont = continuation {
            Logger.widget.error("Location failed: \(error.localizedDescription, privacy: .public)")
            continuation = nil
            cont.resume(returning: nil)
        }
    }
}

// MARK: - Timeline entry
private struct ClosestFavouriteEntry: TimelineEntry {
    let date: Date
    let journey: Journey?
    let departures: [DepartureV2]
    let detailsById: [String: ServiceDetails]
    let debugInfo: String?
}

// MARK: - Provider
private struct ClosestFavouriteProvider: TimelineProvider {
    private let groupID = "group.dev.skynolimit.traintrack"
    private let journeysKey = "saved_journeys"

    func placeholder(in context: Context) -> ClosestFavouriteEntry {
        ClosestFavouriteEntry(date: Date(), journey: sampleJourney(), departures: sampleDepartures(), detailsById: [:], debugInfo: "placeholder")
    }

    func getSnapshot(in context: Context, completion: @escaping (ClosestFavouriteEntry) -> ()) {
        Logger.widget.info("getSnapshot called")
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClosestFavouriteEntry>) -> ()) {
        Logger.widget.info("getTimeline called (family=\(String(describing: context.family)))")
        Task {
            let entry = await buildEntry(context: context)
            // Aim to refresh roughly every minute to keep departures fresh.
            let next = Date().addingTimeInterval(60)
            Logger.widget.info("Timeline built: journey?=\(entry.journey != nil ? "yes" : "no", privacy: .public) deps=\(entry.departures.count, privacy: .public)")
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func loadJourneys() -> [Journey] {
        guard let ud = UserDefaults(suiteName: groupID) else {
            Logger.widget.error("Failed to open UserDefaults suite \(self.groupID, privacy: .public)")
            return []
        }
        guard let data = ud.data(forKey: journeysKey) else {
            Logger.widget.info("No journeys data found in app group store")
            return []
        }
        do {
            let journeys = try JSONDecoder().decode([Journey].self, from: data)
            Logger.widget.info("Decoded \(journeys.count, privacy: .public) stored journeys")
            return journeys
        } catch {
            Logger.widget.error("Failed to decode journeys JSON: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func closestFavourite(using loc: CLLocation?, from journeys: [Journey]) -> Journey? {
        let favs = journeys.filter { $0.favorite }
        guard !favs.isEmpty else { return nil }
        guard let loc else { return favs.first }
        return favs.min { a, b in
            let da = CLLocation(latitude: a.fromStation.coordinate.latitude, longitude: a.fromStation.coordinate.longitude).distance(from: loc)
            let db = CLLocation(latitude: b.fromStation.coordinate.latitude, longitude: b.fromStation.coordinate.longitude).distance(from: loc)
            return da < db
        }
    }

    // Read last known location saved by the app into the App Group store
    private func loadSharedLocation(maxAgeHours: Double = 24) -> CLLocation? {
        guard let ud = UserDefaults(suiteName: groupID) else { return nil }
        let ts = ud.double(forKey: "widget_last_loc_ts")
        let lat = ud.object(forKey: "widget_last_lat") as? Double
        let lng = ud.object(forKey: "widget_last_lng") as? Double
        guard let lat, let lng else { return nil }
        if lat == 0 && lng == 0 { return nil }
        if ts > 0 {
            let age = Date().timeIntervalSince(Date(timeIntervalSince1970: ts))
            if age > maxAgeHours * 3600 { return nil }
        }
        return CLLocation(latitude: lat, longitude: lng)
    }

    private func rowsForFamily(_ family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 2 // keep medium comfortable
        case .systemLarge: return 5
        default: return 2
        }
    }

    private func buildEntry(context: Context) async -> ClosestFavouriteEntry {
        var dbg: [String] = []
        let journeys = loadJourneys()
        let sharedLoc = loadSharedLocation()
        let location: CLLocation?
        if let s = sharedLoc {
            location = s
        } else {
            location = await OneShotLocationFetcher().fetch()
        }
        dbg.append("journeys=\(journeys.count)")
        dbg.append(sharedLoc != nil ? "loc=shared" : (location == nil ? "loc=nil" : "loc=ok"))
        Logger.widget.info("Journeys available: \(journeys.count, privacy: .public)")
        let j = closestFavourite(using: location, from: journeys)
        if j == nil { Logger.widget.info("No favourite journey available for widget") }
        guard var j else {
            return ClosestFavouriteEntry(date: Date(), journey: nil, departures: [], detailsById: [:], debugInfo: dbg.joined(separator: "; "))
        }
        Logger.widget.info("Chosen journey: \(j.fromStation.crs, privacy: .public) → \(j.toStation.crs, privacy: .public)")
        dbg.append("chosen=\(j.fromStation.crs)->\(j.toStation.crs)")
        do {
            Logger.widget.info("Fetching departures… from=\(j.fromStation.crs, privacy: .public) to=\(j.toStation.crs, privacy: .public)")
            var deps = try await NetworkServiceWidget.shared.fetchDepartures(from: j.fromStation.crs, to: j.toStation.crs)
            Logger.widget.info("Fetched \(deps.count, privacy: .public) departures")
            dbg.append("deps=\(deps.count)")
            if deps.isEmpty {
                // Fallback: try reverse direction if original returned none
                Logger.widget.info("Zero results; attempting reverse direction")
                let rev = try await NetworkServiceWidget.shared.fetchDepartures(from: j.toStation.crs, to: j.fromStation.crs)
                if !rev.isEmpty {
                    Logger.widget.info("Reverse direction returned \(rev.count, privacy: .public)")
                    dbg.append("rev=\(rev.count)")
                    deps = rev
                    // Swap direction for display only
                    j = Journey(id: j.id, fromStation: j.toStation, toStation: j.fromStation, createdAt: j.createdAt, favorite: j.favorite)
                } else {
                    dbg.append("rev=0")
                }
            }
            // sort by estimated time if parseable, else scheduled
            deps.sort(by: { lhs, rhs in
                func parse(_ t: String?) -> Date? {
                    guard let t = t else { return nil }
                    let s = t.lowercased(); if s == "delayed" || s == "cancelled" || s == "on time" { return nil }
                    let parts = t.split(separator: ":"); guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
                    var c = Calendar.current.dateComponents([.year,.month,.day], from: Date()); c.hour = h; c.minute = m; return Calendar.current.date(from: c)
                }
                let l = parse(lhs.departureTime.estimated) ?? parse(lhs.departureTime.scheduled)
                let r = parse(rhs.departureTime.estimated) ?? parse(rhs.departureTime.scheduled)
                switch (l, r) { case let (li?, ri?): return li < ri; case (nil, nil): return false; case (nil, _): return false; case (_, nil): return true }
            })
            let count = rowsForFamily(context.family)
            deps = Array(deps.prefix(count))
            let detailIDs = deps.prefix(5).map { $0.serviceID }
            Logger.widget.info("Fetching details for \(detailIDs.count, privacy: .public) services")
            let details = try await NetworkServiceWidget.shared.fetchServiceDetails(ids: detailIDs)
            Logger.widget.info("Fetched details: \(details.count, privacy: .public)")
            return ClosestFavouriteEntry(date: Date(), journey: j, departures: deps, detailsById: details, debugInfo: dbg.joined(separator: "; "))
        } catch {
            Logger.widget.error("Network error: \(error.localizedDescription, privacy: .public)")
            dbg.append("err=\(error.localizedDescription)")
            return ClosestFavouriteEntry(date: Date(), journey: j, departures: [], detailsById: [:], debugInfo: dbg.joined(separator: "; "))
        }
    }

    // MARK: - Samples
    private func sampleJourney() -> Journey {
        Journey(
            id: UUID(),
            fromStation: Station(crs: "ORI", name: "Orpington", longitude: "0.089", latitude: "51.373"),
            toStation: Station(crs: "VIC", name: "London Victoria", longitude: "-0.143", latitude: "51.495"),
            createdAt: Date(), favorite: true
        )
    }

    private func sampleDepartures() -> [DepartureV2] {
        return [
            DepartureV2(
                departureTime: .init(scheduled: "09:27", estimated: "09:27"), serviceType: "train", platform: "2", isCancelled: false, length: 8,
                destination: [PlaceInfoV2(crs: "VIC", locationName: "London Victoria", via: nil)], origin: nil, serviceID: "S1", delayReason: nil, cancelReason: nil, timestamp: Date()
            ),
            DepartureV2(
                departureTime: .init(scheduled: "09:42", estimated: "09:44"), serviceType: "train", platform: "TBC", isCancelled: false, length: 4,
                destination: [PlaceInfoV2(crs: "VIC", locationName: "London Victoria", via: "via Bromley South")], origin: nil, serviceID: "S2", delayReason: nil, cancelReason: nil, timestamp: Date()
            )
        ]
    }
}

// MARK: - View
private struct ClosestFavouriteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ClosestFavouriteEntry

    private func rowsForFamily() -> Int {
        switch family { case .systemSmall: return 3; case .systemMedium: return 2; case .systemLarge: return 5; default: return 2 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            if let j = entry.journey {
                // Header
                if family == .systemSmall {
                    HStack {
                        Text("\(j.fromStation.crs) → \(j.toStation.crs)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Closest Favourite Journey").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(j.fromStation.crs) → \(j.toStation.crs)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // Rows
                if entry.departures.isEmpty {
                    Spacer(minLength: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No upcoming departures found").font(.footnote).foregroundStyle(.secondary)
                        if let dbg = entry.debugInfo, !dbg.isEmpty {
                            Text(dbg).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } else {
                    let limit = rowsForFamily()
                    let rows = Array(entry.departures.prefix(limit))
                    ForEach(rows.indices, id: \.self) { idx in
                        if idx > 0 { Divider().opacity(0.25) }
                        let dep = rows[idx]
                        DepartureRowCompact(dep: dep, fromCRS: j.fromStation.crs, toCRS: j.toStation.crs, details: entry.detailsById[dep.serviceID], family: family)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if family != .systemSmall {
                        Text("Closest Favourite Journey").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Add favourite journeys in the app").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            // Footer: last updated HH:mm
            HStack {
                Spacer()
                Text(updatedTimeLabel(entry.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(family == .systemSmall ? 8 : 10)
        .widgetContainerBackground()
        .widgetURL(linkURL())
    }

    private func linkURL() -> URL? {
        guard let j = entry.journey else { return nil }
        var comps = URLComponents()
        comps.scheme = "traintrack"
        comps.host = "journey"
        comps.queryItems = [
            .init(name: "from", value: j.fromStation.crs),
            .init(name: "to", value: j.toStation.crs)
        ]
        return comps.url
    }

    private func updatedTimeLabel(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return "Updated " + df.string(from: date)
    }
}

// Compact row tailored for widget density
private struct DepartureRowCompact: View {
    let dep: DepartureV2
    let fromCRS: String
    let toCRS: String
    let details: ServiceDetails?
    let family: WidgetFamily

    private var destinationLabel: String {
        if let first = dep.destination.first {
            if let via = first.via, !via.isEmpty { return "\(first.locationName) \(via)" }
            return first.locationName
        }
        return ""
    }

    private var timeColor: Color { colorForDelay(estimated: dep.departureTime.estimated, scheduled: dep.departureTime.scheduled) }
    private var isBus: Bool { dep.serviceType.lowercased() == "bus" || dep.platform?.uppercased() == "BUS" }

    private var dotColor: Color {
        if let details, let live = computeLiveStatus(from: details, within: fromCRS, toCRS: toCRS) {
            return live.delayMinutes >= 5 ? .red : (live.delayMinutes > 0 ? .yellow : .green)
        }
        return timeColor
    }

    private func arrivalLabel() -> String? {
        guard let details else { return nil }
        if let cp = details.allStations.first(where: { $0.crs == toCRS }) {
            if let et = cp.et, !et.isEmpty, et.lowercased() != "on time" { return "Arr \(et)" }
            return "Arr \(cp.st)"
        }
        return nil
    }

    var body: some View {
        if family == .systemSmall {
            // Minimal layout: only platform + est time, aligned trailing
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Circle().fill(dotColor).frame(width: 6, height: 6)
                PlatformBadge(platform: dep.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (dep.platform ?? "TBC") : "TBC", isBus: isBus)
                    .scaleEffect(0.9)
                Text(dep.departureTime.estimated)
                    .font(.headline).fontWeight(.semibold)
                    .foregroundStyle(timeColor).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        } else {
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(destinationLabel)
                        .font(.subheadline)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let arr = arrivalLabel() { Text(arr).font(.caption2).foregroundStyle(.secondary) }
                        if !isBus {
                            if let l = dep.length, l > 0 {
                                Text("\(l) cars").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("Unknown length").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let details, let live = computeLiveStatus(from: details, within: fromCRS, toCRS: toCRS) {
                        HStack(spacing: 6) {
                            Circle().fill(live.delayMinutes >= 5 ? Color.red : (live.delayMinutes > 0 ? .yellow : .green)).frame(width: 6, height: 6)
                            Text(live.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.top, 1)
                    }
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    PlatformBadge(platform: dep.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (dep.platform ?? "TBC") : "TBC", isBus: isBus)
                    Text(dep.departureTime.estimated)
                        .font(.headline).fontWeight(.semibold)
                        .foregroundStyle(timeColor).monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                }
            }
        }
    }
}

// MARK: - Widget definition
struct ClosestFavouriteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClosestFavouriteWidget", provider: ClosestFavouriteProvider()) { entry in
            ClosestFavouriteWidgetView(entry: entry)
        }
        .configurationDisplayName("Closest Favourite Journey")
        .description("Shows upcoming departures for your nearest favourite journey.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#if DEBUG
// Preview helpers (don't rely on Provider.Context initializers)
private func previewSampleJourney() -> Journey {
    Journey(
        id: UUID(),
        fromStation: Station(crs: "ORI", name: "Orpington", longitude: "0.089", latitude: "51.373"),
        toStation: Station(crs: "VIC", name: "London Victoria", longitude: "-0.143", latitude: "51.495"),
        createdAt: Date(), favorite: true
    )
}

private func previewSampleDepartures() -> [DepartureV2] {
    [
        DepartureV2(
            departureTime: .init(scheduled: "09:27", estimated: "09:27"),
            serviceType: "train", platform: "2", isCancelled: false, length: 8,
            destination: [PlaceInfoV2(crs: "VIC", locationName: "London Victoria", via: nil)], origin: nil, serviceID: "S1", delayReason: nil, cancelReason: nil, timestamp: Date()
        ),
        DepartureV2(
            departureTime: .init(scheduled: "09:42", estimated: "09:44"),
            serviceType: "train", platform: "TBC", isCancelled: false, length: 4,
            destination: [PlaceInfoV2(crs: "VIC", locationName: "London Victoria", via: "via Bromley South")], origin: nil, serviceID: "S2", delayReason: nil, cancelReason: nil, timestamp: Date()
        )
    ]
}

// Previews removed for iOS 16.x compatibility
#endif
