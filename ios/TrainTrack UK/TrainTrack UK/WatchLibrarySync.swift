import Combine
import WatchConnectivity

@MainActor
final class WatchLibrarySync: NSObject, WCSessionDelegate {
    static let shared = WatchLibrarySync()
    private var observation: AnyCancellable?
    private var started = false

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
        let store = JourneyStore.shared
        observation = Publishers.CombineLatest3(store.$journeys, store.$favouriteManualOrder, store.$myJourneysManualOrder)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
    }

    func snapshot() -> WatchLibrary {
        let store = JourneyStore.shared
        let groups = store.sortedFavouritesByManualOrder() + store.sortedMyJourneysByManualOrder()
        return WatchLibrary(routes: groups.filter { !$0.legs.isEmpty }.map { group in
            WatchRoute(id: group.id, stations: group.stationSequence.map { WatchStation(crs: $0.crs, name: $0.name) },
                       favourite: group.favorite)
        }, apiBase: ApiHostPreference.currentBaseURL, updatedAt: Date())
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
        guard message["request"] as? String == WatchLibrary.contextKey else { replyHandler([:]); return }
        Task { @MainActor in
            do { replyHandler([WatchLibrary.contextKey: try JSONEncoder().encode(self.snapshot())]) }
            catch { replyHandler(["error": "Saved routes could not be synced."]) }
        }
    }
}
