import Foundation
import Observation
import WatchConnectivity

@MainActor @Observable
final class WatchLibraryStore: NSObject, WCSessionDelegate {
    private(set) var library: WatchLibrary?
    private(set) var syncMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        library = defaults.data(forKey: WatchLibrary.contextKey).flatMap { try? WatchLibrary.decode($0) }
        super.init()
        #if DEBUG && targetEnvironment(simulator)
        if WatchAppFixture.enabled { library = WatchAppFixture.library }
        #endif
    }

    func start() {
        #if DEBUG && targetEnvironment(simulator)
        if WatchAppFixture.enabled { return }
        #endif
        guard !started, WCSession.isSupported() else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func requestSync() {
        #if DEBUG && targetEnvironment(simulator)
        if WatchAppFixture.enabled { return }
        #endif
        start()
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if let data = session.receivedApplicationContext[WatchLibrary.contextKey] as? Data { receive(data) }
        guard session.isReachable else {
            syncMessage = "Open TrainTrack UK on your iPhone to sync saved routes."
            return
        }
        syncMessage = "Syncing with iPhone…"
        session.sendMessage(["request": WatchLibrary.contextKey], replyHandler: { reply in
            let data = reply[WatchLibrary.contextKey] as? Data
            Task { @MainActor in
                if let data { self.receive(data) }
                else { self.syncMessage = "Couldn't sync routes. Try again with the iPhone app open." }
            }
        }, errorHandler: { _ in
            Task { @MainActor in self.syncMessage = "Open TrainTrack UK on your iPhone to sync saved routes." }
        })
    }

    func receive(_ data: Data) {
        do {
            let incoming = try WatchLibrary.decode(data)
            guard incoming.updatedAt >= (library?.updatedAt ?? .distantPast) else { return }
            library = incoming
            defaults.set(data, forKey: WatchLibrary.contextKey)
            syncMessage = nil
        } catch {
            syncMessage = "Couldn't read saved routes. Update TrainTrack UK on your iPhone and try syncing again."
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.requestSync() }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchLibrary.contextKey] as? Data else { return }
        Task { @MainActor in self.receive(data) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.requestSync() }
    }
}
