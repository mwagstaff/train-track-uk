import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct FutureDisruptionsTests {
    @Test func manualRequestPreservesDirectionAndViaWithoutMonitoringOrDeviceFields() throws {
        let request = try FutureDisruptionsClient.request(stations: ["clk", "lew", "lbg"], baseURL: "https://example.test/api/v2")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/v2/disruptions/future")
        #expect(components.queryItems == [URLQueryItem(name: "stations", value: "CLK,LEW,LBG")])
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "X-Device-Token") == nil)
    }

    @Test func decodedPeriodsSortByNextUnexpiredPeriodAndSupportAnUnknownEnd() throws {
        let json = """
        {"stations":["CLK","LBG"],"status":"available","checkedAt":"2026-09-19T12:00:00.123Z","reason":null,"notices":[
          {"id":"later","title":"Later","body":"","sourceURL":null,"kind":"engineering","startAt":"2026-09-01T12:00:00Z","endAt":"2026-09-23T12:00:00Z","affectedWindows":[{"startAt":"2026-09-01T12:00:00Z","endAt":"2026-09-02T12:00:00Z"},{"startAt":"2026-09-22T12:00:00Z","endAt":"2026-09-23T12:00:00Z"}]},
          {"id":"ended","title":"Ended","body":"","sourceURL":null,"kind":"engineering","startAt":"2026-09-18T12:00:00Z","endAt":"2026-09-19T12:00:00Z"},
          {"id":"ongoing","title":"Ongoing","body":"","sourceURL":null,"kind":"engineering","startAt":"2026-09-18T12:00:00Z","endAt":null,"affectedWindows":[{"startAt":"2026-09-18T12:00:00Z","endAt":null}]}
        ]}
        """
        let result = try DisruptionDate.decoder().decode(FutureDisruptionsResponse.self, from: Data(json.utf8))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-19T12:00:00Z"))
        #expect(result.chronologicalNotices(at: now).map(\.id) == ["ongoing", "later"])
        #expect(result.notices[0].periods(at: now).count == 1)
        #expect(result.notices[2].periods(at: now)[0].endAt == nil)
    }

    @Test func onlyOfficialSecureLinksAreExposed() {
        for (url, allowed) in [
            ("https://www.nationalrail.co.uk/engineering-works/example", true),
            ("https://nationalrail.co.uk/travel-information/", true),
            ("https://nationalrail.co.uk.evil.test/path", false),
            ("http://www.nationalrail.co.uk/path", false),
            ("https://user@www.nationalrail.co.uk/path", false),
            ("javascript:alert(1)", false)
        ] {
            let notice = notice(url: url)
            #expect((notice.safeSourceURL != nil) == allowed)
        }
    }

    @Test func failedRefreshPreservesLastKnownNoticesAndSuccessfulRetryClearsError() async {
        var calls = 0
        let response = response(status: "partial", notices: [notice()])
        let store = FutureDisruptionsStore(stations: ["CLK", "LBG"]) { _ in
            calls += 1
            if calls == 2 { throw URLError(.notConnectedToInternet) }
            return response
        }
        await store.refresh()
        #expect(store.response?.status == "partial")
        await store.refresh()
        #expect(store.response?.notices.count == 1)
        #expect(store.errorMessage?.contains("last successful check") == true)
        await store.refresh()
        #expect(store.errorMessage == nil)
        #expect(!store.isLoading)
    }

    @Test func unavailableIsNotMistakenForAnEmptySuccessfulCheck() async {
        let store = FutureDisruptionsStore(stations: ["CLK", "LBG"]) { _ in response(status: "unavailable") }
        await store.refresh()
        #expect(store.response?.status == "unavailable")
        #expect(store.response?.checkedAt == nil)
    }

    @Test func successfulUnavailableResponsePreservesNoticesUntilSourceRecovers() async {
        var calls = 0
        let store = FutureDisruptionsStore(stations: ["CLK", "LBG"]) { _ in
            calls += 1
            return response(status: calls == 2 ? "unavailable" : "available", notices: calls == 1 ? [notice()] : [])
        }
        await store.refresh()
        await store.refresh()
        #expect(store.response?.status == "unavailable")
        #expect(store.response?.notices.count == 1)
        #expect(store.errorMessage?.contains("last successful check") == true)
        await store.refresh()
        #expect(store.response?.status == "available")
        #expect(store.response?.notices.isEmpty == true)
        #expect(store.errorMessage == nil)
    }

    @Test func mismatchedRouteAndCancelledRequestsCannotPublishResults() async {
        let mismatched = FutureDisruptionsStore(stations: ["LBG", "CLK"]) { _ in response(status: "available") }
        await mismatched.refresh()
        #expect(mismatched.response == nil)
        #expect(mismatched.errorMessage != nil)
        let cancelled = FutureDisruptionsStore(stations: ["CLK", "LBG"]) { _ in throw CancellationError() }
        await cancelled.refresh()
        #expect(cancelled.response == nil)
        #expect(cancelled.errorMessage == nil)
        #expect(!cancelled.isLoading)
    }

    @Test func concurrentRefreshOnlyFetchesOnce() async {
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let store = FutureDisruptionsStore(stations: ["CLK", "LBG"]) { _ in
            calls += 1
            await withCheckedContinuation { release = $0 }
            return response(status: "available")
        }
        let first = Task { await store.refresh() }
        while release == nil { await Task.yield() }
        await store.refresh()
        #expect(calls == 1)
        first.cancel()
        release?.resume()
        await first.value
        #expect(store.response == nil)
        #expect(!store.isLoading)
    }

    private func response(status: String, notices: [FutureDisruptionNotice] = []) -> FutureDisruptionsResponse {
        FutureDisruptionsResponse(stations: ["CLK", "LBG"], status: status, checkedAt: nil,
                                 reason: status == "available" ? nil : "Some notices could not be checked.", notices: notices)
    }

    private func notice(url: String? = nil) -> FutureDisruptionNotice {
        FutureDisruptionNotice(id: "notice", title: "Engineering works", body: "Allow extra time",
            sourceURL: url.flatMap(URL.init(string:)), kind: "engineering", startAt: Date(), endAt: nil, affectedWindows: nil)
    }
}
