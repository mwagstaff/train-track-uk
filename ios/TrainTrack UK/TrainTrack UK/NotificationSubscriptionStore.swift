import Foundation
import Combine

final class NotificationSubscriptionService {
    static let shared = NotificationSubscriptionService()
    private init() {}

    private var base: String { ApiHostPreference.currentBaseURL }
    private var deviceId: String { DeviceIdentity.deviceToken }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func fetchSubscriptions() async throws -> [NotificationSubscription] {
        try await fetchSubscriptions(path: "subscriptions")
    }

    func fetchLiveSessions() async throws -> [NotificationSubscription] {
        try await fetchSubscriptions(path: "live_sessions")
    }

    func upsertSubscription(_ requestBody: NotificationSubscriptionRequest) async throws -> NotificationSubscription {
        try await upsert(requestBody, path: "subscriptions")
    }

    func upsertLiveSession(_ requestBody: NotificationSubscriptionRequest) async throws -> NotificationSubscription {
        try await upsert(requestBody, path: "live_sessions")
    }

    func deleteSubscription(id: String) async throws {
        try await delete(id: id, path: "subscriptions")
    }

    func deleteLiveSession(id: String) async throws {
        try await delete(id: id, path: "live_sessions")
    }

    private func fetchSubscriptions(path: String) async throws -> [NotificationSubscription] {
        guard let url = URL(string: "\(base)/notifications/\(path)?device_id=\(deviceId)") else {
            throw PhoneNetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Token")
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        try validateResponse(urlResponse, data: data)
        if data.isEmpty {
            throw NotificationServiceError(message: "Empty response from server.")
        }
        let payload = try decoder.decode(NotificationSubscriptionListResponse.self, from: data)
        return payload.subscriptions
    }

    private func upsert(_ requestBody: NotificationSubscriptionRequest, path: String) async throws -> NotificationSubscription {
        guard let url = URL(string: "\(base)/notifications/\(path)") else {
            throw PhoneNetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Token")
        request.httpBody = try encoder.encode(requestBody)
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        try validateResponse(urlResponse, data: data)
        if data.isEmpty {
            throw NotificationServiceError(message: "Empty response from server.")
        }
        let payload = try decoder.decode(NotificationSubscriptionResponse.self, from: data)
        return payload.subscription
    }

    private func delete(id: String, path: String) async throws {
        guard let url = URL(string: "\(base)/notifications/\(path)") else {
            throw PhoneNetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Token")
        let body = NotificationSubscriptionDeleteRequest(deviceId: deviceId, subscriptionId: id)
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if let message = decodeErrorMessage(data) {
                throw NotificationServiceError(message: message)
            }
            throw NotificationServiceError(message: "Request failed with status \(http.statusCode).")
        }
    }

    private func decodeErrorMessage(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let errorResponse = try? decoder.decode(NotificationAPIErrorResponse.self, from: data) {
            return errorResponse.error
        }
        return nil
    }
}

@MainActor
final class NotificationSubscriptionStore: ObservableObject {
    static let shared = NotificationSubscriptionStore()

    @Published private(set) var subscriptions: [NotificationSubscription] = []
    @Published private(set) var liveSessions: [NotificationSubscription] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String? = nil

    private let service = NotificationSubscriptionService.shared

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let scheduledTask = service.fetchSubscriptions()
            async let liveSessionsTask = service.fetchLiveSessions()
            subscriptions = try await scheduledTask
            liveSessions = try await liveSessionsTask
            lastError = nil
            await syncGeofences()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func upsert(_ requestBody: NotificationSubscriptionRequest) async throws -> NotificationSubscription {
        let subscription = try await service.upsertSubscription(requestBody)
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = subscription
        } else {
            subscriptions.append(subscription)
        }
        await syncGeofences()
        return subscription
    }

    func delete(id: String) async throws {
        try await service.deleteSubscription(id: id)
        subscriptions.removeAll { $0.id == id }
        await syncGeofences()
    }

    func subscription(for routeKey: String) -> NotificationSubscription? {
        subscriptions.first { $0.routeKey == routeKey }
    }

    func upsertLiveSession(_ requestBody: NotificationSubscriptionRequest) async throws -> NotificationSubscription {
        let subscription = try await service.upsertLiveSession(requestBody)
        if let index = liveSessions.firstIndex(where: { $0.id == subscription.id }) {
            liveSessions[index] = subscription
        } else {
            liveSessions.append(subscription)
        }
        await syncGeofences()
        return subscription
    }

    func deleteLiveSession(id: String) async throws {
        try await service.deleteLiveSession(id: id)
        liveSessions.removeAll { $0.id == id }
        await syncGeofences()
    }

    func liveSession(for routeKey: String) -> NotificationSubscription? {
        liveSessions.first { $0.routeKey == routeKey }
    }

    var combinedSubscriptions: [NotificationSubscription] {
        subscriptions + liveSessions
    }

    var canCreateNew: Bool { subscriptions.count < 3 }
    var canCreateNewLiveSession: Bool { liveSessions.count < 3 }

    private func syncGeofences() async {
        await NotificationGeofenceManager.shared.sync(subscriptions: combinedSubscriptions)
    }
}

private struct NotificationSubscriptionResponse: Codable {
    let subscription: NotificationSubscription
}

private struct NotificationSubscriptionListResponse: Codable {
    let subscriptions: [NotificationSubscription]
}

private struct NotificationSubscriptionDeleteRequest: Codable {
    let deviceId: String
    let subscriptionId: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case subscriptionId = "subscription_id"
    }
}

private struct NotificationAPIErrorResponse: Codable {
    let error: String
}

private struct NotificationServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
