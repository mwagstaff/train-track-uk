import Foundation
import Observation
import SwiftUI

struct FutureDisruptionPeriod: Decodable, Equatable {
    let startAt: Date
    let endAt: Date?

    func isCurrentOrFuture(at now: Date) -> Bool {
        guard let endAt else { return true }
        return endAt > startAt && endAt > now
    }
}

struct FutureDisruptionNotice: Decodable, Identifiable {
    let id: String
    let title: String
    let body: String
    let sourceURL: URL?
    let kind: String
    let startAt: Date
    let endAt: Date?
    let affectedWindows: [FutureDisruptionPeriod]?

    func periods(at now: Date) -> [FutureDisruptionPeriod] {
        let windows = affectedWindows.flatMap { $0.isEmpty ? nil : $0 }
            ?? [FutureDisruptionPeriod(startAt: startAt, endAt: endAt)]
        return windows.filter { $0.isCurrentOrFuture(at: now) }.sorted { $0.startAt < $1.startAt }
    }

    var safeSourceURL: URL? {
        guard let sourceURL, sourceURL.scheme?.lowercased() == "https",
              sourceURL.user == nil, sourceURL.password == nil,
              let host = sourceURL.host?.lowercased(),
              host == "nationalrail.co.uk" || host.hasSuffix(".nationalrail.co.uk") else { return nil }
        return sourceURL
    }
}

struct FutureDisruptionsResponse: Decodable {
    let stations: [String]
    let status: String
    let checkedAt: Date?
    let reason: String?
    let notices: [FutureDisruptionNotice]

    func chronologicalNotices(at now: Date = Date()) -> [FutureDisruptionNotice] {
        notices.filter { !$0.periods(at: now).isEmpty }.sorted {
            let lhs = $0.periods(at: now)[0].startAt
            let rhs = $1.periods(at: now)[0].startAt
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }
}

enum FutureDisruptionsClient {
    static func request(stations: [String], baseURL: String) throws -> URLRequest {
        guard var components = URLComponents(string: "\(baseURL)/disruptions/future") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "stations", value: stations.map { $0.uppercased() }.joined(separator: ","))]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func fetch(stations: [String]) async throws -> FutureDisruptionsResponse {
        let request = try request(stations: stations, baseURL: ApiHostPreference.currentBaseURL)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try DisruptionDate.decoder().decode(FutureDisruptionsResponse.self, from: data)
    }
}

@MainActor
@Observable
final class FutureDisruptionsStore {
    private(set) var response: FutureDisruptionsResponse?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let stations: [String]
    @ObservationIgnored private let fetch: ([String]) async throws -> FutureDisruptionsResponse

    init(stations: [String], fetch: @escaping ([String]) async throws -> FutureDisruptionsResponse = FutureDisruptionsClient.fetch) {
        self.stations = stations.map { $0.uppercased() }
        self.fetch = fetch
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await fetch(stations)
            try Task.checkCancellation()
            // An old or mismatched cache entry must never show another route's notices.
            guard result.stations == stations else { throw URLError(.badServerResponse) }
            if result.status == "unavailable", let previous = response, !previous.notices.isEmpty {
                response = FutureDisruptionsResponse(stations: stations, status: result.status,
                    checkedAt: previous.checkedAt, reason: result.reason, notices: previous.notices)
                errorMessage = "The notices below are from the last successful check. They could not be refreshed."
                return
            }
            response = result
            errorMessage = nil
        } catch is CancellationError {
            // Dismissing this screen cancels its read without changing cached results.
        } catch {
            guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
            errorMessage = response == nil
                ? "Future disruptions could not be loaded. Check your connection and try again."
                : "Could not refresh. The notices below are from the last successful check."
        }
    }
}

@MainActor
struct FutureDisruptionsView: View {
    let group: JourneyGroup
    @State private var store: FutureDisruptionsStore
    @State private var refreshGeneration = 0
    @Environment(\.dismiss) private var dismiss

    init(group: JourneyGroup, store: FutureDisruptionsStore? = nil) {
        self.group = group
        _store = State(initialValue: store ?? FutureDisruptionsStore(stations: group.stationSequence.map(\.crs)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(group.displayTitle).font(.headline)
                        .accessibilityIdentifier("futureDisruptions.route")
                    Text("Published works that may affect this journey’s services, including closures of stations you use. All published dates are included, regardless of your monitoring days and hours.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let checkedAt = store.response?.checkedAt {
                        Text("Source checked \(FutureDisruptionDate.label(checkedAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let error = store.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                        if store.response?.status != "unavailable" { retryButton }
                    }
                }

                if let response = store.response {
                    responseSections(response)
                } else if store.isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading published disruptions…").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("futureDisruptions.loading")
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.timeZone, PlannerTime.displayZone)
            .navigationTitle("Future disruptions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await store.refresh() }
            .task(id: refreshGeneration) { await store.refresh() }
        }
    }

    @ViewBuilder
    private func responseSections(_ response: FutureDisruptionsResponse) -> some View {
        let notices = response.chronologicalNotices()
        if response.status != "available" {
            Section {
                Label(response.status == "partial" ? "Some published notices may be missing" : "Published notices are unavailable",
                      systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(response.reason ?? "The source could not be checked. Try again later.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if response.status == "unavailable" { retryButton }
            }
        }
        if notices.isEmpty && response.status == "available" {
            Section {
                Label("No published disruptions found", systemImage: "calendar")
                    .font(.headline)
                Text("No matching planned notices were found for this journey. This does not guarantee every service will run; check your journey again before travelling.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("futureDisruptions.empty")
        }
        ForEach(notices) { notice in
            Section {
                FutureDisruptionNoticeRow(notice: notice)
            }
        }
        if !notices.isEmpty {
            Section {
                Text("Notices are matched to published descriptions of affected routes and services, or an explicit closure of a station on this journey. This list may not include every disruption. Read each notice to confirm how your train is affected. Times are shown in UK local time.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var retryButton: some View {
        Button("Try again") { refreshGeneration += 1 }
            .disabled(store.isLoading)
    }
}

private struct FutureDisruptionNoticeRow: View {
    let notice: FutureDisruptionNotice

    var body: some View {
        let periods = notice.periods(at: Date())
        VStack(alignment: .leading, spacing: 12) {
            Label("May affect this journey", systemImage: "calendar.badge.exclamationmark")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(notice.title).font(.headline)
                .accessibilityIdentifier("futureDisruptions.notice.\(notice.id)")
            ForEach(Array(periods.prefix(3).enumerated()), id: \.offset) { _, period in
                periodView(period)
            }
            if periods.count > 3 {
                DisclosureGroup("Show \(periods.count - 3) more affected periods") {
                    ForEach(Array(periods.dropFirst(3).enumerated()), id: \.offset) { _, period in
                        periodView(period).padding(.vertical, 4)
                    }
                }
            }
            if !notice.body.isEmpty {
                if notice.body.count > 400 {
                    DisclosureGroup("Disruption details") { Text(notice.body).padding(.top, 6) }
                } else {
                    Text(notice.body).font(.subheadline)
                }
            }
            if let url = notice.safeSourceURL {
                Link("Read the National Rail notice", destination: url)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

    private func periodView(_ period: FutureDisruptionPeriod) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if period.startAt <= Date() { Text("Ongoing").font(.subheadline.weight(.semibold)) }
            Text("From \(FutureDisruptionDate.label(period.startAt))")
            if let end = period.endAt {
                Text("Until \(FutureDisruptionDate.label(end))")
            } else {
                Text("End date not yet published")
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

enum FutureDisruptionDate {
    static func label(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: PlannerTime.displayZone)
            .weekday(.abbreviated).day().month(.abbreviated).year().hour().minute()
            .timeZone(.specificName(.short)))
    }
}
