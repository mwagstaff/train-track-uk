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

private extension Logger { static let customWidget = Logger(subsystem: "dev.skynolimit.traintrack", category: "CustomJourneyWidget") }

// Minimal shared models (scoped to this file)
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
        if let arr = try? c.decode([PlaceInfoV2].self, forKey: .destination) { self.destination = arr }
        else if let one = try? c.decode(PlaceInfoV2.self, forKey: .destination) { self.destination = [one] } else { self.destination = [] }
        if c.contains(.origin) {
            if let arr = try? c.decode([PlaceInfoV2].self, forKey: .origin) { self.origin = arr }
            else if let one = try? c.decode(PlaceInfoV2.self, forKey: .origin) { self.origin = [one] } else { self.origin = nil }
        } else { self.origin = nil }
        self.serviceID = (try? c.decode(String.self, forKey: .serviceID)) ?? UUID().uuidString
        self.delayReason = try? c.decode(String.self, forKey: .delayReason)
        self.cancelReason = try? c.decode(String.self, forKey: .cancelReason)
        self.timestamp = try? c.decode(Date.self, forKey: .timestamp)
    }
    init(departureTime: DepartureTimeV2, serviceType: String, platform: String?, isCancelled: Bool, length: Int?, destination: [PlaceInfoV2], origin: [PlaceInfoV2]?, serviceID: String, delayReason: String?, cancelReason: String?, timestamp: Date?) {
        self.departureTime = departureTime; self.serviceType = serviceType; self.platform = platform; self.isCancelled = isCancelled; self.length = length; self.destination = destination; self.origin = origin; self.serviceID = serviceID; self.delayReason = delayReason; self.cancelReason = cancelReason; self.timestamp = timestamp
    }
}

private struct CallingPoint: Codable, Identifiable, Equatable { let locationName: String; let crs: String; let st: String; let et: String?; let at: String?; let isCancelled: Bool?; let cancelReason: String?; let length: Int?; let detachFront: Bool?; let affectedByDiversion: Bool?; let rerouteDelay: Int?; var id: String { crs } }
private struct CallingPointList: Codable, Equatable { let callingPoint: [CallingPoint] }
private struct ServiceDetails: Codable, Equatable {
    let previousCallingPoints: [CallingPointList]?
    let subsequentCallingPoints: [CallingPointList]?
    let locationName: String
    let crs: String
    let std: String?
    let sta: String?
    let etd: String?
    let atd: String?
    let ata: String?
    var allStations: [CallingPoint] {
        var arr: [CallingPoint] = []
        if let prev = previousCallingPoints { for l in prev { arr += l.callingPoint } }
        arr.append(CallingPoint(locationName: locationName, crs: crs, st: std ?? sta ?? "Unknown", et: etd, at: atd ?? ata, isCancelled: nil, cancelReason: nil, length: nil, detachFront: nil, affectedByDiversion: nil, rerouteDelay: nil))
        if let next = subsequentCallingPoints { for l in next { arr += l.callingPoint } }
        return arr
    }
}

// Simple platform badge (copied style from app, compact)
private struct PlatformBadge: View {
    let platform: String
    var isBus: Bool = false
    private func displayText() -> String { let t = platform.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? "TBC" : t }
    var body: some View {
        Group {
            if isBus || platform.uppercased() == "BUS" {
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
        }
        .lineLimit(1)
    }
}

// Network service subset
private final class NetworkServiceWidgetCJ {
    static let shared = NetworkServiceWidgetCJ(); private init() {}
    private var base: String { WidgetApiHost.currentBaseURL }
    private var deviceToken: String { WidgetDeviceIdentity.deviceToken }
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    func fetchDepartures(from: String, to: String) async throws -> [DepartureV2] {
        let path = "from/\(from)/to/\(to)"
        guard let url = URL(string: "\(base)/departures/\(path)") else { throw URLError(.badURL) }
        Logger.customWidget.info("GET \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url)
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let obj = try JSONSerialization.jsonObject(with: data)
        if let dict = obj as? [String: Any], let val = dict.values.first {
            let d = try JSONSerialization.data(withJSONObject: val)
            return try decoder.decode([DepartureV2].self, from: d)
        } else if let arr = obj as? [[String: Any]], let key = arr.first?.keys.first, let val = arr.first?[key] {
            let d = try JSONSerialization.data(withJSONObject: val)
            return try decoder.decode([DepartureV2].self, from: d)
        }
        return []
    }
    func fetchDetails(ids: [String]) async throws -> [String: ServiceDetails] {
        guard !ids.isEmpty else { return [:] }
        guard let url = URL(string: "\(base)/service_details/\(ids.joined(separator: "/"))") else { throw URLError(.badURL) }
        Logger.customWidget.info("GET \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url)
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        var res: [String: ServiceDetails] = [:]
        for it in arr {
            if let k = it.keys.first, let val = it[k] {
                let d = try JSONSerialization.data(withJSONObject: val)
                if let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any], dict.isEmpty { continue }
                res[k] = try decoder.decode(ServiceDetails.self, from: d)
            }
        }
        return res
    }
}

// Delay color helpers (same as app)
private func colorForDelay(estimated: String?, scheduled: String?) -> Color {
    guard let est = estimated?.lowercased() else { return .secondary }
    if est == "cancelled" || est == "delayed" { return .red }
    guard let sch = scheduled else { return .secondary }
    let df = DateFormatter(); df.dateFormat = "HH:mm"
    if let s = df.date(from: sch), let e = df.date(from: estimated ?? "") {
        let mins = Calendar.current.dateComponents([.minute], from: s, to: e).minute ?? 0
        if mins >= 5 { return .red }; if mins > 0 { return .yellow }; return .green
    }
    return .secondary
}

// Simple live status approximation for dot coloring
private func liveDotColor(details: ServiceDetails?, fromCRS: String, toCRS: String, fallback: Color) -> Color {
    guard let details else { return fallback }
    let stations = details.allStations
    guard let fromIdx = stations.firstIndex(where: { $0.crs == fromCRS }), let toIdx = stations.firstIndex(where: { $0.crs == toCRS }) else { return fallback }
    let window = Array(stations[min(fromIdx, toIdx)...max(fromIdx, toIdx)])
    func parse(_ t: String?) -> Date? { guard let t = t, t != "On time", t != "Cancelled" else { return nil }; let p=t.split(separator: ":"); if p.count==2, let h=Int(p[0]), let m=Int(p[1]){ var c=Calendar.current.dateComponents([.year,.month,.day], from: Date()); c.hour=h; c.minute=m; return Calendar.current.date(from:c)}; return nil }
    let now = Date()
    for s in window {
        if let at = s.at, at != "Cancelled" { continue }
        guard let st = parse(s.et ?? s.st) else { continue }
        if now <= st { break }
    }
    // Use estimated vs scheduled at from station
    let f = window.first!
    if let et = parse(f.et), let st = parse(f.st) {
        let mins = Int((et.timeIntervalSince(st))/60)
        return mins >= 5 ? .red : (mins > 0 ? .yellow : .green)
    }
    return fallback
}

// MARK: - Timeline
struct CJEntry: TimelineEntry {
    let date: Date
    let fromCRS: String
    let toCRS: String
    fileprivate let departures: [DepartureV2]
    fileprivate let details: [String: ServiceDetails]
}

struct CustomJourneyProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CJEntry { CJEntry(date: .now, fromCRS: "VIC", toCRS: "KTH", departures: sample(), details: [:]) }
    func snapshot(for configuration: CustomJourneyIntent, in context: Context) async -> CJEntry {
        if configuration.journey == nil { return placeholder(in: context) }
        return await build(config: configuration)
    }
    func timeline(for configuration: CustomJourneyIntent, in context: Context) async -> Timeline<CJEntry> {
        let entry = await build(config: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
    }
    private func build(config: CustomJourneyIntent) async -> CJEntry {
        let from = config.journey?.fromCRS ?? "VIC"
        let to = config.journey?.toCRS ?? "KTH"
        do {
            var deps = try await NetworkServiceWidgetCJ.shared.fetchDepartures(from: from, to: to)
            deps.sort { l, r in
                func parse(_ t: String?) -> Date? { guard let t=t else {return nil}; let s=t.lowercased(); if ["delayed","cancelled","on time"].contains(s) {return nil}; let p=t.split(separator:":"); guard p.count==2, let h=Int(p[0]), let m=Int(p[1]) else {return nil}; var c=Calendar.current.dateComponents([.year,.month,.day], from: Date()); c.hour=h; c.minute=m; return Calendar.current.date(from:c) }
                let ld = parse(l.departureTime.estimated) ?? parse(l.departureTime.scheduled)
                let rd = parse(r.departureTime.estimated) ?? parse(r.departureTime.scheduled)
                switch (ld, rd) { case let (a?, b?): return a < b; case (nil, nil): return false; case (nil, _): return false; case (_, nil): return true }
            }
            // Limit rows depending on size in view layer
            let det = try await NetworkServiceWidgetCJ.shared.fetchDetails(ids: Array(deps.prefix(5).map{$0.serviceID}))
            return CJEntry(date: Date(), fromCRS: from, toCRS: to, departures: deps, details: det)
        } catch {
            Logger.customWidget.error("Network error: \(error.localizedDescription, privacy: .public)")
            return CJEntry(date: Date(), fromCRS: from, toCRS: to, departures: [], details: [:])
        }
    }
    // No pair resolution helpers needed for the custom journey widget
    private func sample() -> [DepartureV2] {
        [DepartureV2(departureTime: .init(scheduled: "13:27", estimated: "13:27"), serviceType: "train", platform: "2", isCancelled: false, length: 8, destination: [PlaceInfoV2(crs: "KTH", locationName: "Kent House", via: nil)], origin: nil, serviceID: "S1", delayReason: nil, cancelReason: nil, timestamp: Date())]
    }
}

// MARK: - View
private struct CustomJourneyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CJEntry

    private func rowsForFamily() -> Int { switch family { case .systemSmall: return 3; case .systemMedium: return 2; case .systemLarge: return 5; default: return 2 } }

    private func timeColor(_ d: DepartureV2) -> Color { colorForDelay(estimated: d.departureTime.estimated, scheduled: d.departureTime.scheduled) }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            // Header
            if family == .systemSmall {
                HStack { Text("\(entry.fromCRS) → \(entry.toCRS)").font(.caption2).foregroundStyle(.secondary); Spacer(minLength: 0) }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Custom Journey").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(entry.fromCRS) → \(entry.toCRS)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            // Rows
            let rows = Array(entry.departures.prefix(rowsForFamily()))
            if rows.isEmpty {
                Text("No upcoming departures found").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(rows.indices, id: \.self) { i in
                    if i > 0 { Divider().opacity(0.25) }
                    let dep = rows[i]
                    HStack(spacing: 6) {
                        if family == .systemSmall {
                            let dot = liveDotColor(details: entry.details[dep.serviceID], fromCRS: entry.fromCRS, toCRS: entry.toCRS, fallback: timeColor(dep))
                            Circle().fill(dot).frame(width: 6, height: 6)
                            PlatformBadge(platform: dep.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (dep.platform ?? "TBC") : "TBC", isBus: false)
                                .scaleEffect(0.9)
                            Text(dep.departureTime.estimated)
                                .font(.headline).fontWeight(.semibold)
                                .foregroundStyle(timeColor(dep)).monospacedDigit()
                                .lineLimit(1)
                        } else {
                            // Title + meta on left
                            VStack(alignment: .leading, spacing: 2) {
                                let title = dep.destination.first?.locationName ?? ""
                                Text(title).font(.subheadline).lineLimit(1)
                                HStack(spacing: 8) {
                                    if let l = dep.length, l > 0 { Text("\(l) cars").font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                            Spacer(minLength: 6)
                            HStack(spacing: 6) {
                                PlatformBadge(platform: dep.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (dep.platform ?? "TBC") : "TBC", isBus: false)
                                Text(dep.departureTime.estimated).font(.headline).fontWeight(.semibold).foregroundStyle(timeColor(dep)).monospacedDigit()
                            }
                        }
                    }
                }
            }
            // Footer: last updated
            HStack { Spacer(); Text(updatedTimeLabel(entry.date)).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(family == .systemSmall ? 8 : 10)
        .widgetContainerBackground()
        .widgetURL({ var c=URLComponents(); c.scheme="traintrack"; c.host="journey"; c.queryItems=[.init(name:"from", value: entry.fromCRS), .init(name:"to", value: entry.toCRS)]; return c.url }())
    }
    private func updatedTimeLabel(_ d: Date) -> String { let f=DateFormatter(); f.dateFormat="HH:mm"; return "Updated " + f.string(from: d) }
}

// MARK: - Widget
@available(iOS 17.0, *)
struct CustomJourneyWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "CustomJourneyWidget", intent: CustomJourneyIntent.self, provider: CustomJourneyProvider()) { entry in
            CustomJourneyWidgetView(entry: entry)
        }
        .configurationDisplayName("Custom Journey")
        .description("Pick a journey to show its next departures.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
