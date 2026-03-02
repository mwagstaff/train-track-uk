import Foundation
import CoreLocation
import UserNotifications

// MARK: - Shared Utilities

private func currentDateKey() -> String {
    NotificationMuteStorage.currentDateKey()
}

// MARK: - Geofence Manager

@MainActor
final class NotificationGeofenceManager: NSObject, CLLocationManagerDelegate {
    static let shared = NotificationGeofenceManager()

    private let manager = CLLocationManager()
    private nonisolated let regionPrefix = "tt_notify_mute"
    static let regionRadiusMeters: CLLocationDistance = 250

    private override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = true
    }

    func requestAlwaysAuthorizationIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            break
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func sync(subscriptions: [NotificationSubscription]) async {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        guard manager.authorizationStatus == .authorizedAlways else { return }

        if StationsService.shared.stations.isEmpty {
            try? await StationsService.shared.loadStations()
        }
        let stationsByCrs = StationsService.shared.stations.reduce(into: [String: Station]()) { result, station in
            let key = station.crs.uppercased()
            if result[key] == nil {
                result[key] = station
            }
        }

        let desired = desiredRegions(subscriptions: subscriptions, stationsByCrs: stationsByCrs)
        let existing = manager.monitoredRegions.filter { $0.identifier.hasPrefix(regionPrefix) }

        for region in existing where desired[region.identifier] == nil {
            manager.stopMonitoring(for: region)
        }

        for (identifier, region) in desired {
            if !existing.contains(where: { $0.identifier == identifier }) {
                manager.startMonitoring(for: region)
            }
        }
    }

    private func desiredRegions(
        subscriptions: [NotificationSubscription],
        stationsByCrs: [String: Station]
    ) -> [String: CLCircularRegion] {
        var regions: [String: CLCircularRegion] = [:]
        for subscription in subscriptions {
            guard subscription.muteOnArrival ?? true else { continue }
            for leg in subscription.legs where leg.enabled {
                guard let station = stationsByCrs[leg.from.uppercased()] else { continue }
                let coordinate = station.coordinate
                if coordinate.latitude == 0 && coordinate.longitude == 0 { continue }
                let identifier = regionIdentifier(subscriptionId: subscription.id, from: leg.from, to: leg.to)
                if regions[identifier] != nil { continue }
                let region = CLCircularRegion(
                    center: coordinate,
                    radius: Self.regionRadiusMeters,
                    identifier: identifier
                )
                region.notifyOnEntry = true
                region.notifyOnExit = false
                regions[identifier] = region
            }
        }
        return regions
    }

    private func regionIdentifier(subscriptionId: String, from: String, to: String) -> String {
        "\(regionPrefix):\(subscriptionId):\(from.uppercased()):\(to.uppercased())"
    }

    private nonisolated func parseRegionIdentifier(_ identifier: String) -> (subscriptionId: String, from: String, to: String)? {
        let parts = identifier.split(separator: ":")
        guard parts.count == 4, parts[0] == regionPrefix else { return nil }
        return (String(parts[1]), String(parts[2]), String(parts[3]))
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circular = region as? CLCircularRegion else { return }
        guard let parsed = parseRegionIdentifier(circular.identifier) else { return }

        let message = "Entered region: \(circular.identifier)\nSub: \(parsed.subscriptionId)\nFrom: \(parsed.from.uppercased()) To: \(parsed.to.uppercased())"
        Task { @MainActor in
            DebugLogStore.shared.log(message, category: "Geofence")
            print("📍 \(message)")
            // Mark this leg as muted locally (for client-side filtering)
            self.markLegMutedLocally(from: parsed.from, to: parsed.to)
            // Send local notification to confirm arrival
            self.sendArrivalNotification(subscriptionId: parsed.subscriptionId, from: parsed.from, to: parsed.to)
            // Enqueue mute request to backend
            NotificationMuteRequestSender.shared.enqueueMute(
                subscriptionId: parsed.subscriptionId,
                from: parsed.from,
                to: parsed.to
            )
        }
    }

    func simulateArrival(subscriptionId: String, from: String, to: String, sendNotification: Bool = true) {
        let msg = "Simulated arrival for \(from.uppercased()) → \(to.uppercased())"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
        }
        print("🧪 \(msg)")

        markLegMutedLocally(from: from, to: to)
        if sendNotification {
            sendArrivalNotification(subscriptionId: subscriptionId, from: from, to: to)
        }
        NotificationMuteRequestSender.shared.enqueueMute(
            subscriptionId: subscriptionId,
            from: from,
            to: to
        )
    }

    private func markLegMutedLocally(from: String, to: String) {
        let todayString = NotificationMuteStorage.markMuted(from: from, to: to)
        let legKey = NotificationMuteStorage.legKey(from: from, to: to)
        let msg = "Marked leg \(legKey) as muted locally for \(todayString)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Mute")
        }
        print("✅ \(msg)")
    }

    private func sendArrivalNotification(subscriptionId: String, from: String, to: String) {
        let fromStation = StationsService.shared.stations.first { $0.crs.uppercased() == from.uppercased() }
        let toStation = StationsService.shared.stations.first { $0.crs.uppercased() == to.uppercased() }

        let fromName = fromStation?.name ?? from
        let toName = toStation?.name ?? to

        let content = UNMutableNotificationContent()
        content.title = "Arrived at \(fromName)"
        content.body = "Notifications for your journey to \(toName) have been muted for the rest of today."
        content.sound = .default
        content.badge = 0
        content.categoryIdentifier = NotificationCategoryId.stationArrival
        content.userInfo = [
            NotificationPayloadKeys.subscriptionId: subscriptionId,
            NotificationPayloadKeys.from: from.uppercased(),
            NotificationPayloadKeys.to: to.uppercased(),
            NotificationPayloadKeys.fromName: fromName,
            NotificationPayloadKeys.toName: toName,
            NotificationPayloadKeys.legKey: NotificationMuteStorage.legKey(from: from, to: to),
            NotificationPayloadKeys.alertType: "arrival"
        ]

        let request = UNNotificationRequest(
            identifier: "station_arrival_\(from)_\(to)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to send arrival notification: \(error.localizedDescription)")
            } else {
                print("✅ Sent arrival notification for \(fromName) → \(toName)")
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus == .authorizedAlways else { return }
        Task { @MainActor in
            await NotificationSubscriptionStore.shared.refresh()
        }
    }
}

final class NotificationMuteRequestSender: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    static let shared = NotificationMuteRequestSender()
    static let sessionIdentifier = "dev.skynolimit.traintrack.notifications.mute"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var responseData: [Int: Data] = [:] // Store data by task identifier
    private var uploadFiles: [Int: URL] = [:]
    private let syncQueue = DispatchQueue(label: "dev.skynolimit.traintrack.notifications.mute.sync")

    func enqueueMute(subscriptionId: String, from: String, to: String) {
        let baseURL = ApiHostPreference.currentBaseURL
        guard let url = URL(string: "\(baseURL)/notifications/terminate") else {
            let errorMsg = "Invalid URL for terminate endpoint: \(baseURL)"
            Task { @MainActor in DebugLogStore.shared.log(errorMsg, category: "Error") }
            print("❌ \(errorMsg)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")

        let payload = NotificationMuteRequest(
            deviceId: DeviceIdentity.deviceToken,
            subscriptionId: subscriptionId,
            from: from.uppercased(),
            to: to.uppercased(),
            date: currentDateKey()
        )
        guard let body = try? JSONEncoder().encode(payload) else {
            let errorMsg = "Failed to encode mute request payload"
            Task { @MainActor in DebugLogStore.shared.log(errorMsg, category: "Error") }
            print("❌ \(errorMsg)")
            return
        }

        if let bodyString = String(data: body, encoding: .utf8) {
            let msg = "Sending mute request: \(bodyString)\nURL: \(url.absoluteString)"
            Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
            print("📤 \(msg)")
            Task { @MainActor in
                MuteRequestDebugStore.shared.record(payload: bodyString, url: url.absoluteString, status: "queued")
            }
        }

        if let tempFile = writePayloadToTempFile(body) {
            let task = session.uploadTask(with: request, fromFile: tempFile)
            syncQueue.async {
                self.uploadFiles[task.taskIdentifier] = tempFile
            }
            task.resume()
        } else {
            let task = URLSession.shared.uploadTask(with: request, from: body)
            task.resume()
        }

        let msg = "Mute request task started for \(from.uppercased()) → \(to.uppercased())"
        Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
        print("✅ \(msg)")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskId = dataTask.taskIdentifier
        syncQueue.async {
            if self.responseData[taskId] == nil {
                self.responseData[taskId] = data
            } else {
                self.responseData[taskId]?.append(data)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        let data: Data? = syncQueue.sync {
            let data = self.responseData[taskId]
            self.responseData.removeValue(forKey: taskId)
            if let temp = self.uploadFiles.removeValue(forKey: taskId) {
                try? FileManager.default.removeItem(at: temp)
            }
            return data
        }

        if let error = error {
            let msg = "Mute request failed: \(error.localizedDescription)"
            Task { @MainActor in DebugLogStore.shared.log(msg, category: "Error") }
            print("❌ \(msg)")
            Task { @MainActor in
                MuteRequestDebugStore.shared.update(status: "error", response: error.localizedDescription)
            }
        } else if let response = task.response as? HTTPURLResponse {
            var msg = "Mute request completed with status: \(response.statusCode)"

            if let data = data, !data.isEmpty, let responseString = String(data: data, encoding: .utf8) {
                msg += "\nResponse: \(responseString)"
            }

            let category: String
            if response.statusCode == 404 {
                msg += "\nBackend returned 404 - subscription or leg not found. This may indicate a mismatch in subscription ID or station codes"
                category = "Error"
            } else if response.statusCode == 400 {
                msg += "\nBackend returned 400 - invalid request parameters"
                category = "Error"
            } else if response.statusCode == 200 {
                category = "Mute"
            } else {
                msg += "\nUnexpected response code: \(response.statusCode)"
                category = "Error"
            }

            Task { @MainActor in DebugLogStore.shared.log(msg, category: category) }
            print(response.statusCode == 200 ? "✅ \(msg)" : "⚠️ \(msg)")
            Task { @MainActor in
                MuteRequestDebugStore.shared.update(status: "\(response.statusCode)", response: data.flatMap { String(data: $0, encoding: .utf8) })
            }
        } else {
            let msg = "Mute request completed (no response details)"
            Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
            print("✅ \(msg)")
            Task { @MainActor in
                MuteRequestDebugStore.shared.update(status: "ok", response: nil)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        print("✅ Background URL session finished all events")
        BackgroundSessionCoordinator.shared.complete(identifier: session.configuration.identifier)
    }

    private func writePayloadToTempFile(_ data: Data) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("mute_payload_\(UUID().uuidString).json")
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            let msg = "Failed to write mute payload to temp file: \(error.localizedDescription)"
            Task { @MainActor in DebugLogStore.shared.log(msg, category: "Error") }
            return nil
        }
    }
}

final class BackgroundSessionCoordinator {
    static let shared = BackgroundSessionCoordinator()
    private var completions: [String: () -> Void] = [:]

    private init() {}

    func register(identifier: String, completion: @escaping () -> Void) {
        completions[identifier] = completion
    }

    func complete(identifier: String?) {
        guard let identifier else { return }
        let completion = completions.removeValue(forKey: identifier)
        completion?()
    }
}

private struct NotificationMuteRequest: Codable {
    let deviceId: String
    let subscriptionId: String
    let from: String
    let to: String
    let date: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case subscriptionId = "subscription_id"
        case from
        case to
        case date
    }
}
