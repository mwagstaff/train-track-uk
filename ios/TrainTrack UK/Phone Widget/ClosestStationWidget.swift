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

private extension Logger { static let closestAll = Logger(subsystem: "dev.skynolimit.traintrack", category: "ClosestStationWidget") }

// Minimal models (scoped to this file)
private struct Station: Codable, Identifiable { let crs: String; let name: String; let longitude: String; let latitude: String; var id: String { crs }; var coordinate: CLLocationCoordinate2D { .init(latitude: Double(latitude) ?? 0, longitude: Double(longitude) ?? 0) } }
private struct Journey: Codable, Identifiable { let id: UUID; let fromStation: Station; let toStation: Station; let createdAt: Date; let favorite: Bool }
private struct DepartureTime: Codable { let scheduled: String; let estimated: String }
private struct PlaceInfo: Codable { let crs: String?; let locationName: String; let via: String? }
private struct Departure: Codable, Identifiable { let departureTime: DepartureTime; let serviceType: String; let platform: String?; let isCancelled: Bool; let length: Int?; let destination: [PlaceInfo]; let origin: [PlaceInfo]?; let serviceID: String; let delayReason: String?; let cancelReason: String?; let timestamp: Date?; var id: String { serviceID }
    enum CodingKeys: String, CodingKey { case departureTime = "departure_time", serviceType, platform, isCancelled, length, destination, origin, serviceID, delayReason, cancelReason, timestamp }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); departureTime = try c.decode(DepartureTime.self, forKey: .departureTime); serviceType = (try? c.decode(String.self, forKey: .serviceType)) ?? ""; platform = try? c.decode(String.self, forKey: .platform); isCancelled = (try? c.decode(Bool.self, forKey: .isCancelled)) ?? false; length = try? c.decode(Int.self, forKey: .length); if let a = try? c.decode([PlaceInfo].self, forKey: .destination) { destination = a } else if let o = try? c.decode(PlaceInfo.self, forKey: .destination) { destination = [o] } else { destination = [] }; if c.contains(.origin) { if let a = try? c.decode([PlaceInfo].self, forKey: .origin) { origin = a } else if let o = try? c.decode(PlaceInfo.self, forKey: .origin) { origin = [o] } else { origin = nil } } else { origin = nil }; serviceID = (try? c.decode(String.self, forKey: .serviceID)) ?? UUID().uuidString; delayReason = try? c.decode(String.self, forKey: .delayReason); cancelReason = try? c.decode(String.self, forKey: .cancelReason); timestamp = try? c.decode(Date.self, forKey: .timestamp) }
}
private struct CallingPoint: Codable, Identifiable { let locationName: String; let crs: String; let st: String; let et: String?; let at: String?; var id: String { crs } }
private struct CallingList: Codable { let callingPoint: [CallingPoint] }
private struct ServiceDetails: Codable { let previousCallingPoints: [CallingList]?; let subsequentCallingPoints: [CallingList]?; let locationName: String; let crs: String; let std: String?; let sta: String?; let etd: String?; let atd: String?; let ata: String?; var allStations: [CallingPoint] { var arr:[CallingPoint]=[]; if let p=previousCallingPoints { for l in p { arr += l.callingPoint } }; arr.append(CallingPoint(locationName: locationName, crs: crs, st: std ?? sta ?? "Unknown", et: etd, at: atd ?? ata)); if let s=subsequentCallingPoints { for l in s { arr += l.callingPoint } }; return arr } }

private func delayColor(estimated: String?, scheduled: String?) -> Color { guard let e=estimated?.lowercased() else { return .secondary }; if e=="cancelled" || e=="delayed" { return .red }; guard let s=scheduled else { return .secondary }; let df=DateFormatter(); df.dateFormat="HH:mm"; if let sd=df.date(from:s), let ed=df.date(from: estimated ?? "") { let m = Calendar.current.dateComponents([.minute], from: sd, to: ed).minute ?? 0; if m >= 5 { return .red }; if m > 0 { return .yellow }; return .green } ; return .secondary }

// Simple platform badge (compact)
private struct PlatformBadge: View { let platform: String; var isBus: Bool = false; private func text() -> String { let t = platform.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? "TBC" : t }; var body: some View { Group { if isBus || platform.uppercased()=="BUS" { HStack(spacing:4){ Image(systemName:"bus"); Text("Bus") }.font(.caption).fontWeight(.semibold).padding(.horizontal,6).padding(.vertical,2).background(Color.yellow).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius:6, style:.continuous)) } else { Text(text()).font(.caption).fontWeight(.semibold).padding(.horizontal,6).padding(.vertical,2).background(Color.gray.opacity(0.18)).foregroundStyle(.secondary).clipShape(RoundedRectangle(cornerRadius:6, style:.continuous)) } } .lineLimit(1) }
}

// Network
private final class Net {
    static let shared = Net()
    private init() {}

    private var base: String { WidgetApiHost.currentBaseURL }
    private var deviceToken: String { WidgetDeviceIdentity.deviceToken }
    private let dec: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func deps(from: String, to: String) async throws -> [Departure] {
        guard let url = URL(string: "\(base)/departures/from/\(from)/to/\(to)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let obj = try JSONSerialization.jsonObject(with: data)
        if let dict = obj as? [String: Any], let val = dict.values.first {
            let d = try JSONSerialization.data(withJSONObject: val)
            return try dec.decode([Departure].self, from: d)
        } else if let arr = obj as? [[String: Any]], let key = arr.first?.keys.first, let val = arr.first?[key] {
            let d = try JSONSerialization.data(withJSONObject: val)
            return try dec.decode([Departure].self, from: d)
        }
        return []
    }

    func details(ids: [String]) async throws -> [String: ServiceDetails] {
        guard !ids.isEmpty else { return [:] }
        guard let url = URL(string: "\(base)/service_details/\(ids.joined(separator: "/"))") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        var out: [String: ServiceDetails] = [:]
        for it in arr {
            if let k = it.keys.first, let val = it[k] {
                let d = try JSONSerialization.data(withJSONObject: val)
                if let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any], dict.isEmpty { continue }
                out[k] = try JSONDecoder().decode(ServiceDetails.self, from: d)
            }
        }
        return out
    }
}

// Timeline
struct CS_Entry: TimelineEntry {
    let date: Date
    fileprivate let journey: Journey?
    fileprivate let departures: [Departure]
    fileprivate let details: [String:ServiceDetails]
    fileprivate let distanceToStation: CLLocationDistance?
}

struct ClosestStationProvider: TimelineProvider {
    private let groupID = "group.dev.skynolimit.traintrack"; private let journeysKey = "saved_journeys"
    func placeholder(in context: Context) -> CS_Entry { CS_Entry(date:.now, journey:nil, departures:[], details:[:], distanceToStation:nil) }
    func getSnapshot(in context: Context, completion: @escaping (CS_Entry)->()) { completion(placeholder(in: context)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CS_Entry>)->()) { Task { let e = await build(context: context); completion(Timeline(entries:[e], policy:.after(Date().addingTimeInterval(60)))) } }

    private func loadJourneys() -> [Journey] { guard let ud = UserDefaults(suiteName: groupID), let data = ud.data(forKey: journeysKey) else { return [] }; return (try? JSONDecoder().decode([Journey].self, from: data)) ?? [] }
    private func loadSharedLocation(maxAgeHours: Double = 24) -> CLLocation? { guard let ud = UserDefaults(suiteName: groupID) else { return nil }; let ts = ud.double(forKey:"widget_last_loc_ts"); guard let lat = ud.object(forKey:"widget_last_lat") as? Double, let lng = ud.object(forKey:"widget_last_lng") as? Double else { return nil }; if ts>0 && Date().timeIntervalSince(Date(timeIntervalSince1970: ts)) > maxAgeHours*3600 { return nil }; return CLLocation(latitude: lat, longitude: lng) }
    private func nearest(using loc: CLLocation?, from list: [Journey]) -> Journey? { guard !list.isEmpty else { return nil }; guard let loc else { return list.first }; return list.min { a,b in CLLocation(latitude:a.fromStation.coordinate.latitude, longitude:a.fromStation.coordinate.longitude).distance(from:loc) < CLLocation(latitude:b.fromStation.coordinate.latitude, longitude:b.fromStation.coordinate.longitude).distance(from:loc) } }

    private func build(context: Context) async -> CS_Entry {
        let js = loadJourneys()
        let location = loadSharedLocation()
        guard let j = nearest(using: location, from: js) else { return CS_Entry(date: Date(), journey: nil, departures: [], details: [:], distanceToStation: nil) }
        let distance = location.map { loc in CLLocation(latitude: j.fromStation.coordinate.latitude, longitude: j.fromStation.coordinate.longitude).distance(from: loc) }
        do {
            var deps = try await Net.shared.deps(from: j.fromStation.crs, to: j.toStation.crs)
            deps.sort { l,r in
                func parse(_ t:String?)->Date?{ guard let t=t else {return nil}; let s=t.lowercased(); if ["delayed","cancelled","on time"].contains(s){return nil}; let p=t.split(separator:":"); guard p.count==2, let h=Int(p[0]), let m=Int(p[1]) else {return nil}; var c=Calendar.current.dateComponents([.year,.month,.day], from: Date()); c.hour=h; c.minute=m; return Calendar.current.date(from:c) }
                let ld = parse(l.departureTime.estimated) ?? parse(l.departureTime.scheduled)
                let rd = parse(r.departureTime.estimated) ?? parse(r.departureTime.scheduled)
                switch (ld,rd){ case let (a?,b?): return a<b; case (nil,nil): return false; case (nil,_): return false; case (_ ,nil): return true }
            }
            let det = try await Net.shared.details(ids: Array(deps.prefix(5).map{$0.serviceID}))
            return CS_Entry(date: Date(), journey: j, departures: deps, details: det, distanceToStation: distance)
        } catch {
            return CS_Entry(date: Date(), journey: j, departures: [], details: [:], distanceToStation: distance)
        }
    }
}

// Views
private struct RowSmall: View { let dep: Departure; let fromCRS: String; let toCRS: String; let details: ServiceDetails?; var body: some View { HStack(spacing:6){ Spacer(minLength:0); Circle().fill(delayColor(estimated: dep.departureTime.estimated, scheduled: dep.departureTime.scheduled)).frame(width:6,height:6); PlatformBadge(platform: dep.platform?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false ? (dep.platform ?? "TBC") : "TBC").scaleEffect(0.9); Text(dep.departureTime.estimated).font(.headline).fontWeight(.semibold).foregroundStyle(delayColor(estimated: dep.departureTime.estimated, scheduled: dep.departureTime.scheduled)).monospacedDigit().lineLimit(1) } }
}

private struct ClosestStationWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CS_Entry

    private func rowsForFamily() -> Int { switch family { case .systemSmall: return 3; case .systemMedium: return 2; case .systemLarge: return 5; default: return 2 } }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            return String(format: "%.0fm away", meters)
        } else {
            return String(format: "%.1fkm away", meters / 1000)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            if let j = entry.journey {
                if family == .systemSmall {
                    HStack {
                        Text("\(j.fromStation.crs) → \(j.toStation.crs)").font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let dist = entry.distanceToStation {
                            Text(formatDistance(dist)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack {
                        Text("Closest Station").font(.caption2).foregroundStyle(.secondary)
                        if let dist = entry.distanceToStation {
                            Text(formatDistance(dist)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(j.fromStation.crs) → \(j.toStation.crs)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                let list = Array(entry.departures.prefix(rowsForFamily()))
                if list.isEmpty {
                    Text("No upcoming departures found").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(list.indices, id: \.self) { i in
                        if i > 0 { Divider().opacity(0.25) }
                        let d = list[i]
                        if family == .systemSmall {
                            RowSmall(dep: d, fromCRS: j.fromStation.crs, toCRS: j.toStation.crs, details: entry.details[d.serviceID])
                        } else {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.destination.first?.locationName ?? "").font(.subheadline).lineLimit(1)
                                    if let l = d.length, l > 0 { Text("\(l) cars").font(.caption2).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 6)
                                HStack(spacing: 6) {
                                    PlatformBadge(platform: d.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (d.platform ?? "TBC") : "TBC")
                                    Text(d.departureTime.estimated).font(.headline).fontWeight(.semibold).foregroundStyle(delayColor(estimated: d.departureTime.estimated, scheduled: d.departureTime.scheduled)).monospacedDigit()
                                }
                            }
                        }
                    }
                }
            } else {
                Text("No journeys saved").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Spacer()
                Text("Updated \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(family == .systemSmall ? 8 : 10)
        .widgetContainerBackground()
        .widgetURL({ var c = URLComponents(); c.scheme = "traintrack"; c.host = "journey"; if let j = entry.journey { c.queryItems = [.init(name: "from", value: j.fromStation.crs), .init(name: "to", value: j.toStation.crs)] }; return c.url }())
    }
}

struct ClosestStationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClosestStationWidget", provider: ClosestStationProvider()) { entry in
            ClosestStationWidgetView(entry: entry)
        }
        .configurationDisplayName("Closest Station")
        .description("Shows departures from your nearest saved station.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
