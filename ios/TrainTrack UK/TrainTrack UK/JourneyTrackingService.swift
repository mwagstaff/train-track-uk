import Foundation

private struct JourneyTrackingSessionEnvelope: Decodable {
    let session: JourneyTrackingSessionResponse
}

private struct JourneyTrackingSessionResponse: Decodable {
    let id: String
}

private struct JourneyTrackingRegistrationRequest: Encodable {
    let journeyId: String
    let subscriptionId: String
    let deviceId: String
    let pushToken: String
    let serviceId: String
    let from: String
    let to: String
    let destinationCRS: String
    let useSandbox: Bool

    enum CodingKeys: String, CodingKey {
        case journeyId = "journey_id"
        case subscriptionId = "subscription_id"
        case deviceId = "device_id"
        case pushToken = "push_token"
        case serviceId = "service_id"
        case from
        case to
        case destinationCRS = "destination_crs"
        case useSandbox = "use_sandbox"
    }
}

@MainActor
final class JourneyTrackingService {
    static let shared = JourneyTrackingService()

    private var base: String { ApiHostPreference.currentBaseURL }

    private init() {}

    func register(checkpoint: ActiveJourneyHistoryCheckpoint) async throws -> String? {
        guard let leg = checkpoint.currentLeg else {
            log("backend_registration_skipped", "Backend registration skipped: no current leg", checkpoint: checkpoint)
            return nil
        }
        guard let serviceID = leg.serviceID else {
            log("backend_registration_skipped", "Backend registration skipped: no matched service", checkpoint: checkpoint)
            return nil
        }
        guard let pushToken = NotificationPushTokenStore.token, !pushToken.isEmpty else {
            log("backend_registration_skipped", "Backend registration skipped: notification push token unavailable", checkpoint: checkpoint, metadata: [
                "service_id": serviceID
            ])
            return nil
        }

        guard let url = URL(string: "\(base)/journey_tracking/sessions") else {
            log("backend_registration_failed", "Backend registration failed: invalid URL", checkpoint: checkpoint, metadata: [
                "service_id": serviceID,
                "api_base": base
            ])
            throw PhoneNetworkError.invalidURL
        }
        log("backend_registration_started", "Registering journey backend session for \(leg.fromStation.crs)→\(leg.toStation.crs), service \(serviceID)", checkpoint: checkpoint, metadata: [
            "service_id": serviceID,
            "from": leg.fromStation.crs,
            "to": leg.toStation.crs,
            "destination_crs": checkpoint.plannedDestination.crs,
            "use_sandbox": Self.usesSandbox
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.httpBody = try JSONEncoder().encode(JourneyTrackingRegistrationRequest(
            journeyId: checkpoint.id.uuidString,
            subscriptionId: checkpoint.subscriptionId,
            deviceId: DeviceIdentity.deviceToken,
            pushToken: pushToken,
            serviceId: serviceID,
            from: leg.fromStation.crs.uppercased(),
            to: leg.toStation.crs.uppercased(),
            destinationCRS: checkpoint.plannedDestination.crs.uppercased(),
            useSandbox: Self.usesSandbox
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            log("backend_registration_failed", "Backend registration network failure: \(error.localizedDescription)", checkpoint: checkpoint, metadata: [
                "service_id": serviceID,
                "error": error.localizedDescription
            ])
            throw error
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            log("backend_registration_failed", "Backend registration failed with HTTP \(status.map(String.init) ?? "unknown")", checkpoint: checkpoint, metadata: [
                "service_id": serviceID,
                "http_status": status,
                "response": String(String(data: data, encoding: .utf8)?.prefix(300) ?? "")
            ])
            throw PhoneNetworkError.noData
        }
        do {
            let sessionID = try JSONDecoder().decode(JourneyTrackingSessionEnvelope.self, from: data).session.id
            log("backend_registration_succeeded", "Journey backend session registered: \(sessionID)", checkpoint: checkpoint, metadata: [
                "service_id": serviceID,
                "session_id": sessionID,
                "http_status": http.statusCode
            ])
            return sessionID
        } catch {
            log("backend_registration_failed", "Backend registration response could not be decoded: \(error.localizedDescription)", checkpoint: checkpoint, metadata: [
                "service_id": serviceID,
                "http_status": http.statusCode,
                "error": error.localizedDescription
            ])
            throw error
        }
    }

    func stop(sessionID: String) async {
        guard var components = URLComponents(string: "\(base)/journey_tracking/sessions/\(sessionID)") else {
            log("backend_stop_failed", "Journey backend stop failed: invalid URL", metadata: ["session_id": sessionID])
            return
        }
        components.queryItems = [URLQueryItem(name: "device_id", value: DeviceIdentity.deviceToken)]
        guard let url = components.url else {
            log("backend_stop_failed", "Journey backend stop failed: URL components invalid", metadata: ["session_id": sessionID])
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let succeeded = status.map { (200..<300).contains($0) } ?? false
            log(
                succeeded ? "backend_stop_succeeded" : "backend_stop_failed",
                "Journey backend stop \(succeeded ? "succeeded" : "failed") for \(sessionID), HTTP \(status.map(String.init) ?? "unknown")",
                metadata: [
                    "session_id": sessionID,
                    "http_status": status,
                    "response": succeeded ? nil : String(String(data: data, encoding: .utf8)?.prefix(300) ?? "")
                ]
            )
        } catch {
            log("backend_stop_failed", "Journey backend stop network failure: \(error.localizedDescription)", metadata: [
                "session_id": sessionID,
                "error": error.localizedDescription
            ])
        }
    }

    private func log(
        _ event: String,
        _ message: String,
        checkpoint: ActiveJourneyHistoryCheckpoint? = nil,
        metadata: [String: Any?] = [:]
    ) {
        var enriched = metadata
        enriched["journey_id"] = checkpoint?.id.uuidString
        enriched["subscription_id"] = checkpoint?.subscriptionId
        DebugLogStore.shared.log(message, category: "JourneyHistory")
        ClientDiagnosticsLogger.log("journey_history", event, metadata: enriched)
    }

    private static var usesSandbox: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
