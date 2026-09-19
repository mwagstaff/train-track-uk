import Foundation
import Observation

enum PlannerAutomaticSearchState: Equatable {
    case searchingLater
    case foundLater
    case noJourneysInNext24Hours
}

enum JourneyPlannerFeature {
    static var isEnabled: Bool {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["JOURNEY_PLANNER_ENABLED"] {
            return value == "1" || value.lowercased() == "true"
        }
        return UserDefaults.standard.object(forKey: "journeyPlannerEnabled") as? Bool ?? true
        #else
        return UserDefaults.standard.object(forKey: "journeyPlannerEnabled") as? Bool ?? false
        #endif
    }
}

@MainActor @Observable
final class PlannerRecentSearchStore {
    private(set) var searches: [PlannerRecentSearch]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "journeyPlanner.recentSearches.v1"

    private struct Saved: Codable {
        let version: Int
        let searches: [PlannerRecentSearch]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1 {
            searches = Array(saved.searches.filter {
                $0.intent.timeMode == .now || $0.intent.explicitTime != nil
            }.prefix(10))
        } else {
            searches = []
        }
    }

    func record(_ intent: PlannerSearchIntent, at date: Date) {
        searches.removeAll { $0.intent.matches(intent) }
        searches.insert(PlannerRecentSearch(id: UUID(), intent: intent, searchedAt: date), at: 0)
        searches = Array(searches.prefix(10))
        persist()
    }

    func remove(id: UUID) {
        searches.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        searches = []
        defaults.removeObject(forKey: Self.key)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Saved(version: 1, searches: searches)) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

@MainActor @Observable
final class JourneyPlannerStore {
    var origin: PlannerStation?
    var destination: PlannerStation?
    var via: PlannerStation?
    var timeMode: PlannerTimeMode = .now
    var explicitTime = Date()
    private(set) var status: PlannerStatus?
    private(set) var statusError: String?
    private(set) var isLoadingStatus = false
    private(set) var isSearching = false
    private(set) var searchProgress: PlannerSearchProgress = .queued(position: nil)
    private(set) var response: PlannerSearchResponse?
    private(set) var searchError: PlannerError?
    private(set) var automaticSearchState: PlannerAutomaticSearchState?
    let recents: PlannerRecentSearchStore
    @ObservationIgnored let client: any JourneyPlannerServing
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var automaticSearchGeneration = UUID()
    @ObservationIgnored private var lastRequest: PlannerSearchRequest?
    @ObservationIgnored private var lastIntent: PlannerSearchIntent?

    init(client: (any JourneyPlannerServing)? = nil, recents: PlannerRecentSearchStore? = nil) {
        self.client = client ?? JourneyPlannerClient()
        self.recents = recents ?? PlannerRecentSearchStore()
    }

    var intent: PlannerSearchIntent? {
        guard let origin, let destination else { return nil }
        return PlannerSearchIntent(origin: origin, destination: destination, timeMode: timeMode,
                                   explicitTime: timeMode == .now ? nil : explicitTime, via: via)
    }

    func validationMessage(now: Date = Date()) -> String? {
        guard let origin, let destination else { return "Select an origin and a destination." }
        guard origin.crs != destination.crs else { return "You are already at your destination. Select a different station." }
        if let via, via.crs == origin.crs || via.crs == destination.crs {
            return "Choose an intermediate station different from the origin and destination."
        }
        guard timeMode != .arriveBy else { return "Choose Depart now or Depart at." }
        if let status, status.capabilities.algorithms?.contains("raptor") != true {
            return "This API does not support the current journey planner."
        }
        if timeMode != .now && explicitTime < now {
            return "This time has passed. Choose a new date and time, or switch to Depart now."
        }
        let time = timeMode == .now ? now : explicitTime
        if let range = status?.dataset?.coverage.dateRange, !range.contains(time) {
            return "Choose a date within the available timetable."
        }
        if let capabilities = status?.capabilities, !capabilities.timeTypes.contains(timeMode.apiValue) {
            return "This timetable does not currently support \(timeMode.title.lowercased())."
        }
        return nil
    }

    func loadStatus() async {
        isLoadingStatus = true
        defer { isLoadingStatus = false }
        do {
            let value = try await client.status()
            try Task.checkCancellation()
            status = value
            statusError = nil
        } catch {
            guard !Task.isCancelled else { return }
            status = nil
            statusError = error.localizedDescription
        }
    }

    func restore(_ recent: PlannerRecentSearch) {
        cancelSearch()
        origin = recent.intent.origin
        destination = recent.intent.destination
        via = recent.intent.via
        timeMode = recent.intent.timeMode
        if let date = recent.intent.explicitTime { explicitTime = date }
        response = nil
        searchError = nil
    }

    func cancelSearch() {
        generation = UUID()
        automaticSearchGeneration = UUID()
        isSearching = false
        automaticSearchState = nil
    }

    /// Searches each following timetable window after an empty initial result, stopping once
    /// the first journey is found or the first 24 hours have been searched.
    func searchForLaterTrainsWhenInitialWindowIsEmpty() async {
        guard let initial = response,
              initial.journeys.isEmpty,
              searchError == nil,
              lastRequest?.cursor == nil else { return }

        let token = UUID()
        automaticSearchGeneration = token
        let searchUntil = initial.search.window.from.addingTimeInterval(24 * 60 * 60)
        automaticSearchState = .searchingLater
        var current = initial

        while current.journeys.isEmpty,
              current.search.window.to < searchUntil,
              let later = current.pagination.later,
              !Task.isCancelled,
              automaticSearchGeneration == token {
            let previousWindowEnd = current.search.window.to
            await search(cursor: later, isAutomaticSearch: true, now: Date())

            guard !Task.isCancelled,
                  automaticSearchGeneration == token,
                  searchError == nil,
                  let next = response else {
                automaticSearchState = nil
                return
            }
            guard next.search.window.to > previousWindowEnd else {
                automaticSearchState = nil
                return
            }
            current = next
        }

        guard automaticSearchGeneration == token, !Task.isCancelled else { return }
        automaticSearchState = current.journeys.isEmpty ? .noJourneysInNext24Hours : .foundLater
    }

    func search(cursor: String? = nil, repeatingLastSearch: Bool = false, isAutomaticSearch: Bool = false, now: Date = Date()) async {
        if !isAutomaticSearch {
            automaticSearchGeneration = UUID()
            automaticSearchState = nil
        }
        let appendResults = cursor != nil && cursor == response?.pagination.more
        let token = UUID()
        generation = token
        isSearching = false
        searchError = nil
        if cursor == nil && !repeatingLastSearch { response = nil }
        let request: PlannerSearchRequest
        let submittedIntent = repeatingLastSearch ? lastIntent : intent
        do {
            if repeatingLastSearch, var original = lastRequest {
                if original.cursor != nil, let displayed = response?.search {
                    original = PlannerSearchRequest(origin: displayed.origin, destination: displayed.destination,
                        time: PlannerTime.iso8601(displayed.time), timeType: displayed.timeType,
                        via: original.via,
                        maxChanges: original.maxChanges, extraConnectionMinutes: original.extraConnectionMinutes,
                        allowedModes: original.allowedModes, limit: original.limit)
                }
                original.cursor = nil
                request = original
            } else if let cursor {
                guard var page = lastRequest, response != nil else {
                    throw PlannerError(code: "CURSOR_EXPIRED", message: "Search again before loading more journeys.")
                }
                page.cursor = cursor
                request = page
            } else {
                guard let submittedIntent else {
                    throw PlannerError(code: "INVALID_STATION", message: "Select an origin and a destination.")
                }
                if let message = validationMessage(now: now) {
                    throw PlannerError(code: "INVALID_REQUEST", message: message)
                }
                request = try submittedIntent.request(now: now)
            }
            try request.validateAlgorithm()
        } catch {
            searchError = error as? PlannerError
            return
        }
        searchProgress = .queued(position: nil)
        isSearching = true
        defer { if token == generation { isSearching = false } }
        do {
            let returned = try await client.search(request) { [weak self] progress in
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.searchProgress = progress
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            let result = try returned.verifiedAlgorithm(for: request)
            if appendResults, let previous = response {
                guard previous.dataset.version == result.dataset.version,
                      (previous.search.algorithm ?? "original") == (result.search.algorithm ?? "original") else {
                    throw PlannerError(code: "CURSOR_EXPIRED", message: "The timetable has changed. Search again for current journeys.")
                }
                var ids = Set(previous.journeys.map(\.id))
                let added = result.journeys.filter { ids.insert($0.id).inserted }
                let previousDisrupted = previous.disruptedJourneys ?? []
                var disruptedIDs = Set(previousDisrupted.map(\.id))
                let addedDisrupted = (result.disruptedJourneys ?? []).filter { disruptedIDs.insert($0.id).inserted }
                response = PlannerSearchResponse(journeys: previous.journeys + added, dataset: result.dataset,
                    search: result.search, warnings: result.warnings, pagination: result.pagination,
                    live: result.live, disruptedJourneys: previousDisrupted + addedDisrupted)
            } else {
                response = result
            }
            lastRequest = request
            if cursor == nil, let submittedIntent {
                lastIntent = submittedIntent
                recents.record(submittedIntent, at: now)
            }
        } catch {
            guard generation == token, !Task.isCancelled, !(error is CancellationError) else { return }
            let failure = (error as? PlannerError) ?? PlannerError(code: "NETWORK", message: error.localizedDescription)
            searchError = failure
            if failure.code == "INVALID_STATION" {
                await revalidateStations(token: token)
            }
        }
    }

    private func revalidateStations(token: UUID) async {
        enum Selection { case origin, via, destination }
        for selection in [Selection.origin, .via, .destination] {
            let selected = switch selection {
            case .origin: origin
            case .via: via
            case .destination: destination
            }
            guard let selected else { continue }
            guard let values = try? await client.stations(query: selected.crs),
                  generation == token, !Task.isCancelled else { continue }
            if !values.contains(where: { $0.crs == selected.crs }) {
                switch selection {
                case .origin: origin = nil
                case .via: via = nil
                case .destination: destination = nil
                }
            }
        }
    }
}
