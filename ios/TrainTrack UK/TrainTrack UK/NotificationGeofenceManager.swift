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

    // iOS 18+ requires an active CLServiceSession to guarantee reliable delivery
    // of region monitoring events to the app, including cold-launch from terminated state.
    // Stored as Any? to avoid @available spreading everywhere — we simply cast when needed.
    // The session must be kept alive for the lifetime of the manager (hence a stored property,
    // not a local variable). Creating it with .always tells the system this app needs
    // "Always" location authorization and keeps region monitoring events flowing.
    //
    // On iOS 17 and below, requestAlwaysAuthorization() handles auth instead.
    //
    // Requirements for region monitoring to cold-launch a terminated app:
    //   1. CLServiceSession (iOS 18+) or requestAlwaysAuthorization (iOS <18) ✓
    //   2. authorizedAlways granted by user ✓
    //   3. UIBackgroundModes includes "location" in Info.plist ✓
    //   4. Background App Refresh enabled on device (Settings > General > Background App Refresh)
    //      — this is a user-facing setting; the app cannot enable it programmatically.
    //   5. App was NOT force-quit by the user — user swipe-close prevents re-launch.
    private var locationServiceSession: Any?

    private override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = true
        if #available(iOS 18.0, *) {
            // Create session immediately — this registers our intent with the system
            // and ensures events are delivered even after the app is OS-terminated.
            locationServiceSession = CLServiceSession(authorization: .always)
        }
    }

    func requestAlwaysAuthorizationIfNeeded() {
        if #available(iOS 18.0, *) {
            // On iOS 18+, CLServiceSession (created in init) handles authorization
            // requests automatically — no need to call requestAlwaysAuthorization().
            return
        }
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

        // Guard: if stations failed to load, stationsByCrs is empty which would make
        // `desired` empty and cause ALL existing geofences to be silently removed.
        // Bail out early to preserve the existing geofences.
        guard !stationsByCrs.isEmpty else {
            print("⚠️ [GeofenceManager] Stations not loaded — skipping geofence sync to preserve existing regions")
            Task { @MainActor in
                DebugLogStore.shared.log("Stations not loaded — skipping geofence sync to preserve existing regions", category: "Geofence")
            }
            return
        }

        let desired = desiredRegions(subscriptions: subscriptions, stationsByCrs: stationsByCrs)
        let existing = manager.monitoredRegions.filter { $0.identifier.hasPrefix(regionPrefix) }

        var removedCount = 0
        for region in existing where desired[region.identifier] == nil {
            manager.stopMonitoring(for: region)
            removedCount += 1
        }

        var addedCount = 0
        for (identifier, region) in desired {
            if !existing.contains(where: { $0.identifier == identifier }) {
                manager.startMonitoring(for: region)
                addedCount += 1
            }
        }

        // Request current state for ALL desired regions.
        // This fires didDetermineState — critical for the "already inside" case:
        // if the user is already within the geofence when sync runs (e.g. app opened
        // while standing at the station), didEnterRegion will never fire, but
        // didDetermineState(.inside) will, and we trigger the mute from there.
        for (_, region) in desired {
            manager.requestState(for: region)
        }

        let syncMsg = "Geofence sync: \(desired.count) desired, +\(addedCount) added, -\(removedCount) removed"
        Task { @MainActor in
            DebugLogStore.shared.log(syncMsg, category: "Geofence")
        }
        print("📍 \(syncMsg)")
    }

    private func desiredRegions(
        subscriptions: [NotificationSubscription],
        stationsByCrs: [String: Station]
    ) -> [String: CLCircularRegion] {
        var regions: [String: CLCircularRegion] = [:]
        for subscription in subscriptions {
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
                region.notifyOnExit = true
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

    // Returns true if the current day and time fall within the scheduled window for
    // this leg, meaning a geofence entry should actually trigger a mute.
    //
    // This prevents spurious mutes when the user passes through a starting station
    // at a time outside their scheduled window — e.g. arriving at London Victoria
    // at 09:34 when the Victoria→Kent House leg is only scheduled for 16:00–18:00.
    //
    // If the subscription/leg can't be found in the local store (e.g. subscriptions
    // haven't loaded yet, common on a cold background launch), returns true so that
    // a genuine geofence crossing is still honoured; the server validates anyway.
    private func shouldMuteNow(subscriptionId: String, from: String, to: String) -> Bool {
        guard let subscription = NotificationSubscriptionStore.shared.combinedSubscriptions
                .first(where: { $0.id == subscriptionId }),
              let leg = subscription.legs.first(where: {
                  $0.from.uppercased() == from.uppercased() &&
                  $0.to.uppercased() == to.uppercased()
              }) else {
            return true // Subscription/leg not in local store — allow; server validates.
        }

        let now = Date()
        let calendar = Calendar.current

        // Check day of week. iOS weekday: 1 = Sunday, 2 = Monday … 7 = Saturday.
        let weekday = calendar.component(.weekday, from: now)
        let dayMap: [Int: DayOfWeek] = [
            1: .sun, 2: .mon, 3: .tue, 4: .wed, 5: .thu, 6: .fri, 7: .sat
        ]
        guard let today = dayMap[weekday], subscription.daysOfWeek.contains(today) else {
            return false
        }

        // Check time window. windowStart/windowEnd are "HH:mm" strings.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let winStart = formatter.date(from: leg.windowStart),
              let winEnd   = formatter.date(from: leg.windowEnd) else {
            return true // Can't parse window — allow mute.
        }

        let nowMins   = calendar.component(.hour, from: now)    * 60 + calendar.component(.minute, from: now)
        let startMins = calendar.component(.hour, from: winStart) * 60 + calendar.component(.minute, from: winStart)
        let endMins   = calendar.component(.hour, from: winEnd)   * 60 + calendar.component(.minute, from: winEnd)

        let inWindow = nowMins >= startMins && nowMins <= endMins
        if !inWindow {
            let msg = "shouldMuteNow: \(from)→\(to) window \(leg.windowStart)–\(leg.windowEnd), current \(nowMins/60):\(String(format:"%02d",nowMins%60)) — outside window"
            DebugLogStore.shared.log(msg, category: "Geofence")
        }
        return inWindow
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circular = region as? CLCircularRegion else { return }
        guard let parsed = parseRegionIdentifier(circular.identifier) else { return }

        // Always log boundary crossings to the server regardless of mute window,
        // so geofence health is visible in the admin even when the app is force-closed.
        GeofenceEventSender.shared.sendEvent(
            regionId: circular.identifier,
            from: parsed.from,
            to: parsed.to,
            eventType: "enter"
        )

        let message = "Entered region: \(circular.identifier)\nSub: \(parsed.subscriptionId)\nFrom: \(parsed.from.uppercased()) To: \(parsed.to.uppercased())"
        Task { @MainActor in
            DebugLogStore.shared.log(message, category: "Geofence")
            print("📍 \(message)")

            // Check global mute-on-arrival preference
            let autoMuteEnabled = (UserDefaults.standard.object(forKey: "autoMuteOnArrival") as? Bool) ?? true
            guard autoMuteEnabled else {
                let skipMsg = "Geofence entry for \(parsed.from)→\(parsed.to) — mute on arrival disabled in preferences"
                DebugLogStore.shared.log(skipMsg, category: "Geofence")
                print("📍 \(skipMsg)")
                return
            }

            // Mute if within scheduled window, or if a live activity is active for this route.
            // This allows muting to work for manually-started live activities outside the usual window.
            let hasActiveLiveActivity = LiveActivityManager.shared.activeJourneys.contains(where: {
                $0.0.uppercased() == parsed.from.uppercased() && $0.1.uppercased() == parsed.to.uppercased()
            })
            guard hasActiveLiveActivity || self.shouldMuteNow(subscriptionId: parsed.subscriptionId, from: parsed.from, to: parsed.to) else {
                let skipMsg = "Geofence entry for \(parsed.from)→\(parsed.to) is outside scheduled window and no active live activity — not muting"
                DebugLogStore.shared.log(skipMsg, category: "Geofence")
                print("📍 \(skipMsg)")
                return
            }

            // Apply delay then mute (and optionally end Live Activity)
            self.triggerMuteFlow(
                subscriptionId: parsed.subscriptionId,
                from: parsed.from,
                to: parsed.to
            )
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let circular = region as? CLCircularRegion else { return }
        guard let parsed = parseRegionIdentifier(circular.identifier) else { return }

        GeofenceEventSender.shared.sendEvent(
            regionId: circular.identifier,
            from: parsed.from,
            to: parsed.to,
            eventType: "exit"
        )

        let message = "Exited region: \(circular.identifier)\nFrom: \(parsed.from.uppercased()) To: \(parsed.to.uppercased())"
        Task { @MainActor in
            DebugLogStore.shared.log(message, category: "Geofence")
        }
        print("📍 \(message)")
    }

    // Exposed for the debug UI — shows which regions CLLocationManager is actually monitoring.
    var monitoredRegionIdentifiers: [String] {
        manager.monitoredRegions
            .filter { $0.identifier.hasPrefix(regionPrefix) }
            .map { $0.identifier }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        guard region.identifier.hasPrefix(regionPrefix) else { return }
        let msg = "Started monitoring: \(region.identifier)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
        }
        print("📍 \(msg)")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let regionId = region?.identifier ?? "unknown"
        let msg = "Monitoring FAILED for \(regionId): \(error.localizedDescription)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Error")
        }
        print("❌ \(msg)")
    }

    // Called in response to requestState(for:) after sync, and also after startMonitoring.
    // Handles the critical "already inside" case: if the user is already within the geofence
    // boundary when monitoring starts (e.g. app opened while standing at the station),
    // didEnterRegion will never fire — only didDetermineState(.inside) will.
    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let circular = region as? CLCircularRegion,
              let parsed = parseRegionIdentifier(circular.identifier) else { return }

        let stateStr: String
        switch state {
        case .inside:  stateStr = "inside"
        case .outside: stateStr = "outside"
        case .unknown: stateStr = "unknown"
        @unknown default: stateStr = "unknown"
        }

        let msg = "Region state [\(stateStr)]: \(circular.identifier)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
        }
        print("📍 \(msg)")

        guard state == .inside else { return }

        // Treat being inside as an entry — trigger the mute flow.
        Task { @MainActor in
            guard !NotificationMuteStorage.isMutedToday(from: parsed.from, to: parsed.to) else {
                let skipMsg = "Already muted today for \(parsed.from)→\(parsed.to) — skipping duplicate"
                DebugLogStore.shared.log(skipMsg, category: "Mute")
                return
            }

            // Check global mute-on-arrival preference
            let autoMuteEnabled = (UserDefaults.standard.object(forKey: "autoMuteOnArrival") as? Bool) ?? true
            guard autoMuteEnabled else {
                let skipMsg = "Inside geofence for \(parsed.from)→\(parsed.to) — mute on arrival disabled in preferences"
                DebugLogStore.shared.log(skipMsg, category: "Geofence")
                print("📍 \(skipMsg)")
                return
            }

            // Mute if within scheduled window, or if a live activity is active for this route.
            let hasActiveLiveActivity = LiveActivityManager.shared.activeJourneys.contains(where: {
                $0.0.uppercased() == parsed.from.uppercased() && $0.1.uppercased() == parsed.to.uppercased()
            })
            guard hasActiveLiveActivity || self.shouldMuteNow(subscriptionId: parsed.subscriptionId, from: parsed.from, to: parsed.to) else {
                let skipMsg = "Inside geofence for \(parsed.from)→\(parsed.to) but outside scheduled window and no active live activity — not muting"
                DebugLogStore.shared.log(skipMsg, category: "Geofence")
                print("📍 \(skipMsg)")
                return
            }

            let entryMsg = "Already inside geofence — triggering mute: \(parsed.from) → \(parsed.to)"
            DebugLogStore.shared.log(entryMsg, category: "Geofence")
            self.triggerMuteFlow(
                subscriptionId: parsed.subscriptionId,
                from: parsed.from,
                to: parsed.to
            )
        }
    }

    /// Triggers the mute flow immediately — delay is applied server-side.
    /// Called from both `didEnterRegion` and `didDetermineState(.inside)`.
    ///
    /// **Why no client-side sleep**: iOS only grants ~30 s of background execution after a
    /// geofence wake, so `Task.sleep` is unreliable for delays > a few seconds. Instead,
    /// we pass `delay_minutes` to the server which applies the wait via `setTimeout`
    /// (always-on, never suspended). The server also sends the "muted" confirmation push
    /// after the delay, so no local notification is needed here.
    ///
    /// - Parameter simulate: When true the delay is zero (used by the debug simulate-arrival action).
    func triggerMuteFlow(subscriptionId: String, from: String, to: String,
                         sendNotification: Bool = true, simulate: Bool = false) {
        Task { @MainActor in
            // Guard against duplicate calls — both didEnterRegion and didDetermineState can fire
            // for the same region event. Since both outer tasks are @MainActor and this inner
            // task is also @MainActor (serial), the first call marks locally then the second
            // hits this guard and returns cleanly.
            guard !NotificationMuteStorage.isMutedToday(from: from, to: to) else {
                let skipMsg = "triggerMuteFlow: already muted today for \(from)→\(to) — skipping duplicate"
                DebugLogStore.shared.log(skipMsg, category: "Mute")
                print("⏭ \(skipMsg)")
                return
            }

            // Mark locally immediately — prevents the second triggerMuteFlow call (above guard)
            // from also sending a terminate request during the server-side delay window.
            self.markLegMutedLocally(from: from, to: to)

            let delayMinutes = simulate ? 0 : ((UserDefaults.standard.object(forKey: "muteDelayMinutes") as? Int) ?? 5)
            let msg = delayMinutes > 0
                ? "Sending mute request with \(delayMinutes)-min server-side delay for \(from)→\(to)"
                : "Sending immediate mute request for \(from)→\(to)"
            DebugLogStore.shared.log(msg, category: "Mute")
            print("⏳ \(msg)")

            // The terminate request is sent immediately via background URLSession (reliable
            // even after iOS suspends the app). The server delays the actual mute + push.
            NotificationMuteRequestSender.shared.enqueueMute(
                subscriptionId: subscriptionId,
                from: from,
                to: to,
                delayMinutes: delayMinutes
            )

            // If the user has opted in, also ask the server to end the Live Activity
            let autoEnd = (UserDefaults.standard.object(forKey: "autoEndLiveActivity") as? Bool) ?? false
            if autoEnd {
                let endMsg = "autoEndLiveActivity enabled — sending arrive event to server for \(from)→\(to)"
                DebugLogStore.shared.log(endMsg, category: "Mute")
                print("🏁 \(endMsg)")
                LiveActivityArrivalSender.shared.sendArrival(from: from, to: to)
            }
        }
    }

    func simulateArrival(subscriptionId: String, from: String, to: String, sendNotification: Bool = true) {
        let msg = "Simulated arrival for \(from.uppercased()) → \(to.uppercased())"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
        }
        print("🧪 \(msg)")
        triggerMuteFlow(subscriptionId: subscriptionId, from: from, to: to,
                        sendNotification: sendNotification, simulate: true)
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

    func enqueueMute(subscriptionId: String, from: String, to: String, delayMinutes: Int = 0) {
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
            date: currentDateKey(),
            delayMinutes: delayMinutes
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

// MARK: - Geofence Event Sender
// Sends a diagnostic event to the server whenever a CLRegion boundary is crossed.
// Uses a background URLSession so requests complete even when the app is woken
// from a force-closed state to handle a geofence event.

final class GeofenceEventSender: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = GeofenceEventSender()
    static let sessionIdentifier = "dev.skynolimit.traintrack.notifications.geofence"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let syncQueue = DispatchQueue(label: "dev.skynolimit.traintrack.geofence.sync")
    private var uploadFiles: [Int: URL] = [:]

    private override init() { super.init() }

    func sendEvent(regionId: String, from: String, to: String, eventType: String) {
        let baseURL = ApiHostPreference.currentBaseURL
        guard let url = URL(string: "\(baseURL)/notifications/geofence-event") else {
            print("❌ [GeofenceEvent] Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")

        let payload = GeofenceEventPayload(
            deviceId: DeviceIdentity.deviceToken,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            event: eventType,
            regionId: regionId,
            from: from,
            to: to
        )
        guard let body = try? JSONEncoder().encode(payload) else { return }

        let msg = "Sending geofence event: \(eventType) \(from)→\(to)"
        Task { @MainActor in DebugLogStore.shared.log(msg, category: "Geofence") }
        print("📡 [GeofenceEvent] \(msg)")

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("geofence_event_\(UUID().uuidString).json")
        if (try? body.write(to: fileURL, options: .atomic)) != nil {
            let task = session.uploadTask(with: request, fromFile: fileURL)
            syncQueue.async { self.uploadFiles[task.taskIdentifier] = fileURL }
            task.resume()
        } else {
            URLSession.shared.uploadTask(with: request, from: body).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        syncQueue.async {
            if let temp = self.uploadFiles.removeValue(forKey: taskId) {
                try? FileManager.default.removeItem(at: temp)
            }
        }
        if let error = error {
            print("❌ [GeofenceEvent] Request failed: \(error.localizedDescription)")
        } else if let response = task.response as? HTTPURLResponse {
            print("📡 [GeofenceEvent] Response: \(response.statusCode)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        BackgroundSessionCoordinator.shared.complete(identifier: session.configuration.identifier)
    }
}

// MARK: - Live Activity Arrival Sender
// Notifies the server when the user has arrived at a departure station so the server
// can end the Live Activity push (if autoEndOnArrival is enabled for that subscription).
// Uses a background URLSession so the request completes even from a background geofence wake.

final class LiveActivityArrivalSender: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = LiveActivityArrivalSender()
    static let sessionIdentifier = "dev.skynolimit.traintrack.liveactivity.arrive"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let syncQueue = DispatchQueue(label: "dev.skynolimit.traintrack.liveactivity.arrive.sync")
    private var uploadFiles: [Int: URL] = [:]

    private override init() { super.init() }

    func sendArrival(from: String, to: String) {
        let baseURL = ApiHostPreference.currentBaseURL
        guard let url = URL(string: "\(baseURL)/live_activities/arrive") else {
            print("❌ [LiveActivityArrival] Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")

        let payload: [String: String] = [
            "device_id": DeviceIdentity.deviceToken,
            "from": from.uppercased(),
            "to": to.uppercased()
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            print("❌ [LiveActivityArrival] Failed to encode payload")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("la_arrive_\(UUID().uuidString).json")
        if (try? body.write(to: fileURL, options: .atomic)) != nil {
            let task = session.uploadTask(with: request, fromFile: fileURL)
            syncQueue.async { self.uploadFiles[task.taskIdentifier] = fileURL }
            task.resume()
        } else {
            URLSession.shared.uploadTask(with: request, from: body).resume()
        }

        print("📡 [LiveActivityArrival] Sent arrive event \(from.uppercased())→\(to.uppercased())")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        syncQueue.async {
            if let temp = self.uploadFiles.removeValue(forKey: taskId) {
                try? FileManager.default.removeItem(at: temp)
            }
        }
        if let error = error {
            print("❌ [LiveActivityArrival] Request failed: \(error.localizedDescription)")
        } else if let response = task.response as? HTTPURLResponse {
            print("📡 [LiveActivityArrival] Response: \(response.statusCode)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        BackgroundSessionCoordinator.shared.complete(identifier: session.configuration.identifier)
    }
}

private struct GeofenceEventPayload: Codable {
    let deviceId: String
    let timestamp: String
    let event: String
    let regionId: String
    let from: String
    let to: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case timestamp
        case event
        case regionId = "region_id"
        case from
        case to
    }
}

private struct NotificationMuteRequest: Codable {
    let deviceId: String
    let subscriptionId: String
    let from: String
    let to: String
    let date: String
    let delayMinutes: Int

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case subscriptionId = "subscription_id"
        case from
        case to
        case date
        case delayMinutes = "delay_minutes"
    }
}
