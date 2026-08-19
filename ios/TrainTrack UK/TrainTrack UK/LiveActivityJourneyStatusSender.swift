import Foundation
import JourneyActivityShared

final class LiveActivityJourneyStatusSender: NSObject, URLSessionTaskDelegate {
    static let shared = LiveActivityJourneyStatusSender()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private let syncQueue = DispatchQueue(label: "dev.skynolimit.traintrack.liveactivity.status.sync")
    private var backgroundTasks: [Int: AppBackgroundTaskToken] = [:]

    private override init() {
        super.init()
    }

    func send(
        phase: JourneyActivityAttributes.JourneyPhase,
        from: String,
        to: String
    ) {
        guard let url = URL(string: "\(ApiHostPreference.currentBaseURL)/live_activities/status") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")

        let payload = [
            "device_id": DeviceIdentity.deviceToken,
            "from": from.uppercased(),
            "to": to.uppercased(),
            "phase": phase.rawValue
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let task = session.uploadTask(with: request, from: body)
        let backgroundTask = AppBackgroundTaskToken(name: "live-activity-status")
        syncQueue.sync {
            self.backgroundTasks[task.taskIdentifier] = backgroundTask
        }
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        syncQueue.async {
            self.backgroundTasks.removeValue(forKey: task.taskIdentifier)?.end()
        }
        if let error {
            print("❌ [LiveActivityStatus] Request failed: \(error.localizedDescription)")
        } else if let response = task.response as? HTTPURLResponse {
            print("📡 [LiveActivityStatus] Response: \(response.statusCode)")
        }
    }
}
