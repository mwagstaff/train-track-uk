import Foundation
import WidgetKit
import Combine

@MainActor
final class JourneyStore: ObservableObject {
    static let shared = JourneyStore()

    @Published private(set) var journeys: [Journey] = []
    @Published private(set) var favouriteManualOrder: [UUID] = []
    @Published private(set) var myJourneysManualOrder: [UUID] = []

    private let journeysKey = "saved_journeys"
    private let favouriteManualOrderKey = "favourite_manual_order"
    private let myJourneysManualOrderKey = "my_journeys_manual_order"
    private let userDefaults: UserDefaults

    private init() {
        if let groupDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") {
            userDefaults = groupDefaults
        } else {
            userDefaults = .standard
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["UI_TEST_RESET_JOURNEYS"] == "1" {
            userDefaults.removeObject(forKey: journeysKey)
            userDefaults.removeObject(forKey: favouriteManualOrderKey)
            userDefaults.removeObject(forKey: myJourneysManualOrderKey)
        }
        #endif
        loadJourneys()
        loadManualOrders()
        #if DEBUG
        if ProcessInfo.processInfo.environment["APP_STORE_SCREENSHOTS"] == "1" {
            loadAppStoreScreenshotJourneys()
        }
        #endif
    }

    func loadJourneys() {
        guard let data = userDefaults.data(forKey: journeysKey) else {
            journeys = []
            return
        }
        do {
            journeys = try JSONDecoder().decode([Journey].self, from: data)
        } catch {
            journeys = []
        }
    }

    private func saveJourneys() {
        do {
            let data = try JSONEncoder().encode(journeys)
            userDefaults.set(data, forKey: journeysKey)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Ignore encoding error for now
        }
    }

    #if DEBUG
    private func loadAppStoreScreenshotJourneys() {
        let kentHouse = Station(crs: "KTH", name: "Kent House", longitude: "-0.045786", latitude: "51.412659")
        let victoria = Station(crs: "VIC", name: "London Victoria", longitude: "-0.144200", latitude: "51.495100")
        let eastCroydon = Station(crs: "ECR", name: "East Croydon", longitude: "-0.093335", latitude: "51.375679")
        let brighton = Station(crs: "BTN", name: "Brighton", longitude: "-0.141234", latitude: "50.829659")
        let paddington = Station(crs: "PAD", name: "London Paddington", longitude: "-0.176049", latitude: "51.516014")
        let oxford = Station(crs: "OXF", name: "Oxford", longitude: "-1.270037", latitude: "51.753549")
        let kingsCross = Station(crs: "KGX", name: "London Kings Cross", longitude: "-0.122907", latitude: "51.530827")
        let cambridge = Station(crs: "CBG", name: "Cambridge", longitude: "0.137584", latitude: "52.194519")
        let euston = Station(crs: "EUS", name: "London Euston", longitude: "-0.134545", latitude: "51.528313")
        let birmingham = Station(crs: "BHM", name: "Birmingham New Street", longitude: "-1.898375", latitude: "52.478153")
        let manchester = Station(crs: "MAN", name: "Manchester Piccadilly", longitude: "-2.228991", latitude: "53.476704")
        let leeds = Station(crs: "LDS", name: "Leeds", longitude: "-1.549089", latitude: "53.795158")
        let edinburgh = Station(crs: "EDB", name: "Edinburgh Waverley", longitude: "-3.188236", latitude: "55.952442")
        let glasgow = Station(crs: "GLQ", name: "Glasgow Queen Street", longitude: "-4.251385", latitude: "55.863003")

        let routes: [(String, Station, Station, Bool)] = [
            ("00000000-0000-0000-0000-000000000001", kentHouse, victoria, true),
            ("00000000-0000-0000-0000-000000000002", eastCroydon, brighton, true),
            ("00000000-0000-0000-0000-000000000003", paddington, oxford, false),
            ("00000000-0000-0000-0000-000000000004", kingsCross, cambridge, false),
            ("00000000-0000-0000-0000-000000000005", euston, birmingham, false),
            ("00000000-0000-0000-0000-000000000006", manchester, leeds, false),
            ("00000000-0000-0000-0000-000000000007", edinburgh, glasgow, false)
        ]
        let createdAt = Date(timeIntervalSince1970: 1_756_000_000)
        journeys = routes.map { rawID, from, to, favourite in
            let id = UUID(uuidString: rawID)!
            return Journey(
                id: id,
                groupId: id,
                legIndex: 0,
                fromStation: from,
                toStation: to,
                createdAt: createdAt,
                favorite: favourite
            )
        }
        favouriteManualOrder = journeys.filter(\.favorite).map(\.groupId)
        myJourneysManualOrder = journeys.filter { !$0.favorite }.map(\.groupId)
        saveJourneys()
        saveFavouriteManualOrder()
        saveMyJourneysManualOrder()
    }
    #endif

    func journeyExists(from fromCRS: String, to toCRS: String) -> Bool {
        journeys.contains { $0.fromStation.crs == fromCRS && $0.toStation.crs == toCRS }
    }

    func journeyGroups() -> [JourneyGroup] {
        let grouped = Dictionary(grouping: journeys, by: { $0.groupId })
        return grouped.map { JourneyGroup(id: $0.key, legs: $0.value.sorted { $0.legIndex < $1.legIndex }) }
    }

    func groupExists(for stations: [Station]) -> Bool {
        guard stations.count >= 2 else { return false }
        let target = stations.map { $0.crs.uppercased() }
        return journeyGroups().contains { group in
            group.stationSequence.map { $0.crs.uppercased() } == target
        }
    }

    func addJourneyGroup(stations: [Station], favorite: Bool, saveReturn: Bool) {
        guard stations.count >= 2 else { return }
        guard stations.count <= 6 else { return }
        guard !groupExists(for: stations) else { return }
        let createdAt = Date()
        let groupId = UUID()
        for i in 0..<(stations.count - 1) {
            let leg = Journey(
                id: UUID(),
                groupId: groupId,
                legIndex: i,
                fromStation: stations[i],
                toStation: stations[i + 1],
                createdAt: createdAt,
                favorite: favorite
            )
            journeys.append(leg)
        }
        if saveReturn {
            let reversedStations = Array(stations.reversed())
            if !groupExists(for: reversedStations) {
                let returnGroupId = UUID()
                for i in 0..<(reversedStations.count - 1) {
                    let from = reversedStations[i]
                    let to = reversedStations[i + 1]
                    let leg = Journey(
                        id: UUID(),
                        groupId: returnGroupId,
                        legIndex: i,
                        fromStation: from,
                        toStation: to,
                        createdAt: createdAt,
                        favorite: favorite
                    )
                    journeys.append(leg)
                }
            }
        }
        saveJourneys()
    }

    func addJourney(from: Station, to: Station, favorite: Bool) {
        addJourneyGroup(stations: [from, to], favorite: favorite, saveReturn: false)
    }

    func addJourneyAndReturn(from: Station, to: Station, favorite: Bool) {
        addJourneyGroup(stations: [from, to], favorite: favorite, saveReturn: true)
    }

    // MARK: - Removal helpers
    func remove(group: JourneyGroup, includeReturn: Bool = false) {
        var groupIds = Set([group.id])
        if includeReturn, let reverse = reverseGroup(for: group) {
            groupIds.insert(reverse.id)
        }
        journeys.removeAll { groupIds.contains($0.groupId) }
        saveJourneys()
    }

    func remove(journey: Journey, includeReturn: Bool = false) {
        if let group = journeyGroups().first(where: { $0.id == journey.groupId }) {
            remove(group: group, includeReturn: includeReturn)
        } else {
            removePair(fromCrs: journey.fromStation.crs, toCrs: journey.toStation.crs, includeReturn: includeReturn)
        }
    }

    func removePair(fromCrs: String, toCrs: String, includeReturn: Bool) {
        if includeReturn {
            journeys.removeAll { ($0.fromStation.crs == fromCrs && $0.toStation.crs == toCrs) || ($0.fromStation.crs == toCrs && $0.toStation.crs == fromCrs) }
        } else {
            journeys.removeAll { $0.fromStation.crs == fromCrs && $0.toStation.crs == toCrs }
        }
        saveJourneys()
    }

    // MARK: - Favourite toggling
    func setFavorite(group: JourneyGroup, includeReturn: Bool, value: Bool) {
        var groupIds = Set([group.id])
        if includeReturn, let reverse = reverseGroup(for: group) {
            groupIds.insert(reverse.id)
        }
        var changed = false
        for i in journeys.indices {
            let j = journeys[i]
            if groupIds.contains(j.groupId) {
                journeys[i] = Journey(id: j.id, groupId: j.groupId, legIndex: j.legIndex, fromStation: j.fromStation, toStation: j.toStation, createdAt: j.createdAt, favorite: value)
                changed = true
            }
        }
        if changed { saveJourneys() }
    }

    func setFavorite(fromCrs: String, toCrs: String, includeReturn: Bool, value: Bool) {
        var changed = false
        for i in journeys.indices {
            let j = journeys[i]
            if j.fromStation.crs == fromCrs && j.toStation.crs == toCrs {
                journeys[i] = Journey(id: j.id, groupId: j.groupId, legIndex: j.legIndex, fromStation: j.fromStation, toStation: j.toStation, createdAt: j.createdAt, favorite: value)
                changed = true
            } else if includeReturn && j.fromStation.crs == toCrs && j.toStation.crs == fromCrs {
                journeys[i] = Journey(id: j.id, groupId: j.groupId, legIndex: j.legIndex, fromStation: j.fromStation, toStation: j.toStation, createdAt: j.createdAt, favorite: value)
                changed = true
            }
        }
        if changed { saveJourneys() }
    }

    // MARK: - Manual order persistence
    private func loadManualOrders() {
        if let data = userDefaults.data(forKey: favouriteManualOrderKey),
           let order = try? JSONDecoder().decode([UUID].self, from: data) {
            favouriteManualOrder = order
        }
        if let data = userDefaults.data(forKey: myJourneysManualOrderKey),
           let order = try? JSONDecoder().decode([UUID].self, from: data) {
            myJourneysManualOrder = order
        }
    }

    private func saveFavouriteManualOrder() {
        if let data = try? JSONEncoder().encode(favouriteManualOrder) {
            userDefaults.set(data, forKey: favouriteManualOrderKey)
        }
    }

    private func saveMyJourneysManualOrder() {
        if let data = try? JSONEncoder().encode(myJourneysManualOrder) {
            userDefaults.set(data, forKey: myJourneysManualOrderKey)
        }
    }

    func updateFavouriteManualOrder(_ order: [UUID]) {
        favouriteManualOrder = order
        saveFavouriteManualOrder()
    }

    func updateMyJourneysManualOrder(_ order: [UUID]) {
        myJourneysManualOrder = order
        saveMyJourneysManualOrder()
    }

    func sortedFavouritesByManualOrder() -> [JourneyGroup] {
        let favGroups = journeyGroups().filter { $0.favorite }
        let orderSet = Set(favouriteManualOrder)
        let ordered = favouriteManualOrder.compactMap { id in favGroups.first { $0.id == id } }
        let unordered = favGroups.filter { !orderSet.contains($0.id) }.sorted { $0.startStation.name < $1.startStation.name }
        return ordered + unordered
    }

    func sortedMyJourneysByManualOrder() -> [JourneyGroup] {
        let nonFavGroups = journeyGroups().filter { !$0.favorite }
        let orderSet = Set(myJourneysManualOrder)
        let ordered = myJourneysManualOrder.compactMap { id in nonFavGroups.first { $0.id == id } }
        let unordered = nonFavGroups.filter { !orderSet.contains($0.id) }.sorted { $0.startStation.name < $1.startStation.name }
        return ordered + unordered
    }

    func reverseGroup(for group: JourneyGroup) -> JourneyGroup? {
        let sequence = group.stationSequence.map { $0.crs.uppercased() }
        let reversed = sequence.reversed()
        return journeyGroups().first { candidate in
            candidate.stationSequence.map { $0.crs.uppercased() } == Array(reversed)
        }
    }
}
