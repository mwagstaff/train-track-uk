#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Deterministic simulator data for previews and navigation tests; never used on a device.
@MainActor
enum WatchAppFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-watch-preview-data") }
    static var library: WatchLibrary {
        let kent = WatchStation(crs: "KTH", name: "Kent House")
        let victoria = WatchStation(crs: "VIC", name: "London Victoria")
        let routes = [
            WatchRoute(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, stations: [kent, victoria], favourite: true),
            WatchRoute(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, stations: [kent, victoria, WatchStation(crs: "BTN", name: "Brighton")], favourite: false)
        ]
        return WatchLibrary(routes: ProcessInfo.processInfo.arguments.contains("-watch-empty-routes") ? [] : routes,
                            apiBase: "https://example.com/api/v2", updatedAt: Date())
    }

    static func board(for route: WatchRoute) -> WatchBoard {
        let now = Date()
        let services = (0..<3).map { index in
            let departure = now.addingTimeInterval(Double(5 + index * 30) * 60)
            let arrival = departure.addingTimeInterval(route.via.isEmpty ? 21 * 60 : 90 * 60)
            return WatchDeparture(id: "preview-\(index)", departure: departure, arrival: arrival,
                scheduled: index == 1 ? departure.addingTimeInterval(-420) : departure,
                platform: "2", length: 8,
                status: index == 0 ? "On time" : index == 1 ? "7 min late" : "Cancelled",
                cancelled: index == 2, changes: route.via.count,
                legs: route.via.isEmpty ? [] : [.init(title: "Train: Kent House → London Victoria",
                    departure: departure, arrival: departure.addingTimeInterval(21 * 60), platform: "2", status: nil),
                    .init(title: "Train: London Victoria → Brighton", departure: departure.addingTimeInterval(30 * 60),
                          arrival: arrival, platform: "12", status: nil)], notice: nil)
        }
        return WatchBoard(departures: services, checkedAt: now, observedAt: now, dataStatus: "live", pending: false, pollInterval: 20, message: nil)
    }
}
#endif
