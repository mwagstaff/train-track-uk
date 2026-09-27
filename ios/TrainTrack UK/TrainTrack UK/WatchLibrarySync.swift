import Combine
import WatchConnectivity

@MainActor
final class WatchLibrarySync: NSObject, WCSessionDelegate {
    static let shared = WatchLibrarySync()
    private var observation: AnyCancellable?
    private var started = false
    private var journeyObservations = Set<AnyCancellable>()
    private var completedCommands: [UUID: String] = [:]
    private var commandOrder: [UUID] = []
    private var isHandlingCommand = false

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
        let store = JourneyStore.shared
        observation = Publishers.CombineLatest3(store.$journeys, store.$favouriteManualOrder, store.$myJourneysManualOrder)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
        let coordinator = JourneyTrackingCoordinator.shared
        Publishers.MergeMany([
            coordinator.$activeJourney.map { _ in () }.eraseToAnyPublisher(),
            coordinator.$armedCandidates.map { _ in () }.eraseToAnyPublisher(),
            coordinator.$recentlyCompleted.map { _ in () }.eraseToAnyPublisher(),
            DeparturesStore.shared.$serviceDetailsById.map { _ in () }.eraseToAnyPublisher(),
            RecentServiceStore.shared.$departuresByPair.map { _ in () }.eraseToAnyPublisher()
        ])
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self] _ in self?.publish() }
        .store(in: &journeyObservations)
    }

    func snapshot() -> WatchLibrary {
        let store = JourneyStore.shared
        let groups = store.sortedFavouritesByManualOrder() + store.sortedMyJourneysByManualOrder()
        return WatchLibrary(routes: groups.filter { !$0.legs.isEmpty }.map { group in
            WatchRoute(id: group.id, stations: group.stationSequence.map { WatchStation(crs: $0.crs, name: $0.name) },
                       favourite: group.favorite)
        }, apiBase: ApiHostPreference.currentBaseURL, updatedAt: Date(), journeys: WatchJourneyBridge.snapshots())
    }

    func publish() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext([WatchLibrary.contextKey: JSONEncoder().encode(snapshot())])
        } catch {
            // Retry on activation, foreground, saved-route edits or a watch request.
            debugLog("Watch library sync failed: \(error.localizedDescription)")
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publish() }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publish() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let commandData = message[WatchJourneyCommand.messageKey] as? Data
        let refresh = message["refreshJourney"] as? Bool == true
        guard commandData != nil || message["request"] as? String == WatchLibrary.contextKey else { replyHandler([:]); return }
        Task { @MainActor in
            var errorMessage: String?
            if let commandData {
                do {
                    let command = try JSONDecoder().decode(WatchJourneyCommand.self, from: commandData)
                    if let prior = self.completedCommands[command.requestID] {
                        errorMessage = prior.isEmpty ? nil : prior
                    } else if self.isHandlingCommand {
                        errorMessage = "A journey update is still in progress. Please try again."
                    } else {
                        self.isHandlingCommand = true
                        do { try await WatchJourneyBridge.perform(command) }
                        catch { errorMessage = error.localizedDescription }
                        self.isHandlingCommand = false
                        self.completedCommands[command.requestID] = errorMessage ?? ""
                        self.commandOrder.append(command.requestID)
                        if self.commandOrder.count > 30 {
                            self.completedCommands.removeValue(forKey: self.commandOrder.removeFirst())
                        }
                        self.publish()
                    }
                } catch { errorMessage = "This watch update couldn't be read. Update both apps and try again." }
            } else if refresh {
                await WatchJourneyBridge.refresh()
            }
            do {
                var response: [String: Any] = [WatchLibrary.contextKey: try JSONEncoder().encode(self.snapshot())]
                if let errorMessage { response["error"] = errorMessage }
                replyHandler(response)
            } catch { replyHandler(["error": "Journey data could not be synced."]) }
        }
    }
}
