import Foundation
import CoreLocation
import UserNotifications

@MainActor
final class NotificationAlertHandler {
    static let shared = NotificationAlertHandler()

    private let locationProvider = NotificationLocationProvider()

    func handle(response: UNNotificationResponse) {
        let action = response.actionIdentifier
        let title = response.notification.request.content.title
        DebugLogStore.shared.log("Notification action: \(action) title=\(title)", category: "Mute")
        Task {
            await handleAsync(response: response)
        }
    }

    private func handleAsync(response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard var info = NotificationLegInfo(content: content) else { return }

        switch response.actionIdentifier {
        case NotificationActionId.muteLegForToday:
            await muteLegForToday(info: &info, requireGeofence: false)
        case UNNotificationDefaultActionIdentifier:
            let bypassGeofence = (info.alertType == "simulated_arrival")
            await muteLegForToday(info: &info, requireGeofence: !bypassGeofence)
        default:
            break
        }
    }

    private func muteLegForToday(info: inout NotificationLegInfo, requireGeofence: Bool) async {
        if info.fromCode == nil || info.toCode == nil {
            await info.resolveStationCodesIfNeeded()
        }
        guard let fromCode = info.fromCode, let toCode = info.toCode else {
            DebugLogStore.shared.log("Notification mute skipped: missing station codes", category: "Mute")
            return
        }

        let alreadyMuted = NotificationMuteStorage.isMutedToday(from: fromCode, to: toCode)

        if requireGeofence {
            guard let station = await info.resolveFromStation() else { return }
            guard let location = await locationProvider.requestLocation() else {
                DebugLogStore.shared.log("Notification tap: no location available for geofence check", category: "Mute")
                return
            }
            if !isInsideGeofence(location: location, station: station) {
                DebugLogStore.shared.log("Notification tap: outside geofence for \(station.crs)", category: "Mute")
                return
            }
        }

        if !alreadyMuted {
            NotificationMuteStorage.markMuted(from: fromCode, to: toCode)
        }

        var subscriptionId = info.subscriptionId
        if subscriptionId == nil {
            if NotificationSubscriptionStore.shared.subscriptions.isEmpty {
                await NotificationSubscriptionStore.shared.refresh()
            }
            subscriptionId = NotificationSubscriptionStore.shared.subscriptions.first(where: { sub in
                sub.legs.contains(where: { $0.from.uppercased() == fromCode && $0.to.uppercased() == toCode })
            })?.id
        }

        if let subscriptionId {
            NotificationMuteRequestSender.shared.enqueueMute(
                subscriptionId: subscriptionId,
                from: fromCode,
                to: toCode
            )
        } else {
            DebugLogStore.shared.log("Notification mute sent without subscription id for \(fromCode)-\(toCode)", category: "Mute")
        }

        showToast(message: alreadyMuted ? "Already muted \(info.displayLabel) for today" : "Muted \(info.displayLabel) for today")
        await NotificationSubscriptionStore.shared.refresh()
    }

    private func isInsideGeofence(location: CLLocation, station: Station) -> Bool {
        let coordinate = station.coordinate
        if coordinate.latitude == 0 && coordinate.longitude == 0 {
            return false
        }
        let stationLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distance = location.distance(from: stationLocation)
        return distance <= NotificationGeofenceManager.regionRadiusMeters
    }

    private func showToast(message: String) {
        ToastStore.shared.show(message, icon: "bell.slash.fill")
    }
}

private struct NotificationLegInfo {
    var subscriptionId: String?
    var fromCode: String?
    var toCode: String?
    var fromName: String?
    var toName: String?
    var alertType: String?

    var displayLabel: String {
        let from = fromName ?? fromCode ?? "Start"
        let to = toName ?? toCode ?? "End"
        return "\(from) → \(to)"
    }

    init?(content: UNNotificationContent) {
        let info = content.userInfo
        subscriptionId = NotificationLegInfo.stringValue(for: NotificationPayloadKeys.subscriptionId, in: info)
        fromCode = NotificationLegInfo.stringValue(for: NotificationPayloadKeys.from, in: info)
        toCode = NotificationLegInfo.stringValue(for: NotificationPayloadKeys.to, in: info)
        fromName = NotificationLegInfo.stringValue(for: NotificationPayloadKeys.fromName, in: info)
        toName = NotificationLegInfo.stringValue(for: NotificationPayloadKeys.toName, in: info)
        alertType = NotificationLegInfo.stringValue(for: NotificationPayloadKeys.alertType, in: info)

        if (fromName == nil || toName == nil) && !content.title.isEmpty {
            let parts = content.title.components(separatedBy: " → ")
            if parts.count >= 2 {
                if fromName == nil { fromName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines) }
                if toName == nil { toName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }

        if fromCode == nil && fromName == nil && content.title.isEmpty {
            return nil
        }
    }

    mutating func resolveStationCodesIfNeeded() async {
        if fromCode == nil, let station = await resolveFromStation() {
            fromCode = station.crs.uppercased()
        }
        if toCode == nil, let station = await resolveToStation() {
            toCode = station.crs.uppercased()
        }
    }

    func resolveFromStation() async -> Station? {
        await resolveStation(code: fromCode, name: fromName)
    }

    func resolveToStation() async -> Station? {
        await resolveStation(code: toCode, name: toName)
    }

    private func resolveStation(code: String?, name: String?) async -> Station? {
        if StationsService.shared.stations.isEmpty {
            try? await StationsService.shared.loadStations()
        }
        if let code {
            if let station = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(code) == .orderedSame }) {
                return station
            }
        }
        if let name {
            return StationsService.shared.stations.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        }
        return nil
    }

    private static func stringValue(for key: String, in info: [AnyHashable: Any]) -> String? {
        if let value = info[key] as? String { return value }
        if let value = info[key] as? NSString { return value as String }
        return nil
    }
}

private final class NotificationLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation() async -> CLLocation? {
        if let existing = manager.location, Date().timeIntervalSince(existing.timestamp) < 120 {
            return existing
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let status = manager.authorizationStatus
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                self.continuation = nil
                continuation.resume(returning: nil)
            @unknown default:
                self.continuation = nil
                continuation.resume(returning: nil)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let continuation = continuation else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            self.continuation = nil
            continuation.resume(returning: nil)
        case .notDetermined:
            break
        @unknown default:
            self.continuation = nil
            continuation.resume(returning: nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        continuation.resume(returning: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        continuation.resume(returning: nil)
    }
}
