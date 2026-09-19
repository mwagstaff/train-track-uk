import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct DisruptionMonitoringTests {
    @Test func unscheduledRoutesMonitorEveryDayWithoutPushAndKeepOrderedConnections() throws {
        let group = group(["KTH", "HNH", "ZFD"])
        let settings = DisruptionMonitorSettings.seeded(for: group, subscriptions: [])
        #expect(settings.enabled)
        #expect(settings.days == Array(1...7))
        #expect(settings.window.isAllDay)
        #expect(!settings.pushEnabled)
        let request = DisruptionMonitorRegistration(group: group, settings: settings, pushAuthorized: true)
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["stations"] as? [String] == ["KTH", "HNH", "ZFD"])
        #expect(json["window_start"] as? String == "00:00")
        #expect(json["window_end"] as? String == "24:00")
        #expect(json["push_enabled"] as? Bool == false)
    }

    @Test func scheduleSeedUsesCompleteDirectionAndISODaysIncludingCustomHours() {
        let route = group(["KTH", "HNH", "ZFD"])
        var first = leg("KTH", "HNH", start: "07:00", end: "09:00")
        first.dayWindows = ["sat": NotificationTimeWindow(windowStart: "10:00", windowEnd: "12:00")]
        let schedule = subscription(legs: [first, leg("HNH", "ZFD"), leg("ZFD", "HNH"), leg("HNH", "KTH")], days: [.mon, .sat])
        let settings = DisruptionMonitorSettings.seeded(for: route, subscriptions: [schedule])
        #expect(settings.days == [1, 6])
        #expect(settings.window.start == "07:00")
        #expect(settings.window(on: 6).start == "10:00")
        #expect(settings.dayWindows?["sat"] == nil)
        #expect(!settings.pushEnabled)
        let otherRoute = group(["KTH", "VIC", "ZFD"])
        #expect(DisruptionMonitorSettings.seeded(for: otherRoute, subscriptions: [schedule]).window.isAllDay)
        #expect(DisruptionMonitorSettings.seeded(for: route, subscriptions: [schedule, schedule]).window.isAllDay)
    }

    @Test func pushOptInNeverOverridesDeniedSystemPermission() {
        var settings = DisruptionMonitorSettings()
        settings.pushEnabled = true
        let route = group(["KTH", "VIC"])
        #expect(!DisruptionMonitorRegistration(group: route, settings: settings, pushAuthorized: false).pushEnabled)
        #expect(DisruptionMonitorRegistration(group: route, settings: settings, pushAuthorized: true).pushEnabled)
    }

    @Test func disabledDraftCannotInvalidateTheFullDeviceSnapshot() {
        var settings = DisruptionMonitorSettings()
        settings.enabled = false
        settings.days = []
        settings.window = DisruptionTimeWindow(start: "07:00", end: "07:00")
        let request = DisruptionMonitorRegistration(group: group(["KTH", "VIC"]), settings: settings, pushAuthorized: false)
        #expect(!request.enabled)
        #expect(!request.days.isEmpty)
        #expect(request.windowStart == "00:00")
        #expect(request.windowEnd == "24:00")
    }

    @Test func duplicateSavedRoutesShareOneMonitorButReverseDirectionStaysSeparate() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let one = group(["KTH", "VIC"]), duplicate = group(["KTH", "VIC"]), reverse = group(["VIC", "KTH"])
        var lastRequest: DisruptionMonitorSnapshot?
        let store = DisruptionMonitoringStore(defaults: defaults, replace: { snapshot in
            lastRequest = snapshot
            return emptyResponse()
        }, groups: { [one, duplicate, reverse] }, subscriptions: { [] }, schedulesLoaded: { true }, pushAuthorized: { false })
        await store.refresh()
        let request = try #require(lastRequest)
        #expect(request.monitors.count == 2)
        #expect(Set(request.monitors.map(\.stations)) == Set([["KTH", "VIC"], ["VIC", "KTH"]]))
    }

    @Test func wireDatesAcceptFractionalSecondsAndShadowOrExpiredWarningsStayHidden() throws {
        let id = UUID()
        let json = """
        {"mode":"active","horizonDays":7,"monitors":[{"id":"\(id)","status":"checked","lastCheckedAt":"2026-09-19T10:00:00.123Z","reason":null}],"advisories":[{"id":"a","monitorId":"\(id)","kind":"replacement_bus","title":"Replacement buses","body":"Allow extra time","startAt":"2026-09-20T08:00:00Z","endAt":"2026-09-20T18:00:00.000Z","sourceURL":null,"confidence":"timetable","checkedAt":"2026-09-19T10:00:00Z","extraMinutes":25}]}
        """
        let response = try DisruptionDate.decoder().decode(DisruptionMonitoringResponse.self, from: Data(json.utf8))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-19T12:00:00Z"))
        #expect(response.visibleAdvisories(for: id, now: now).count == 1)
        #expect(response.visibleAdvisories(for: UUID(), now: now).isEmpty)
        #expect(response.visibleAdvisories(for: id, now: now.addingTimeInterval(3 * 86400)).isEmpty)
        let shadow = DisruptionMonitoringResponse(mode: "shadow", horizonDays: 7, monitors: response.monitors, advisories: response.advisories)
        #expect(shadow.visibleAdvisories(for: id, now: now).isEmpty)
        #expect(!response.monitors[0].isStale(now: now))
        #expect(response.monitors[0].isStale(now: now.addingTimeInterval(86400)))
    }

    @Test func failedOfflineDeletionRetriesWithEmptySnapshotOnNextRefresh() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let routes = Routes([group(["KTH", "VIC"])])
        var requests: [DisruptionMonitorSnapshot] = []
        let store = DisruptionMonitoringStore(defaults: defaults, replace: { snapshot in
            requests.append(snapshot)
            if requests.count == 1 { throw URLError(.notConnectedToInternet) }
            return emptyResponse()
        }, groups: { routes.values }, subscriptions: { [] }, schedulesLoaded: { true }, pushAuthorized: { false })
        await store.refresh()
        #expect(requests[0].monitors.count == 1)
        #expect(store.lastError != nil)
        routes.values = []
        await store.refresh()
        #expect(requests.count == 2)
        #expect(requests[1].monitors.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test func disjointAffectedPeriodsDecodeWithoutImplyingAContinuousClosure() throws {
        let id = UUID()
        let json = """
        {"id":"a","monitorId":"\(id)","kind":"closure","title":"Planned engineering","body":"Some travel windows are affected","startAt":"2026-09-20T07:00:00Z","endAt":"2026-09-22T09:00:00Z","sourceURL":null,"confidence":"confirmed","checkedAt":"2026-09-19T10:00:00Z","extraMinutes":null,"affectedWindows":[{"startAt":"2026-09-22T07:00:00Z","endAt":"2026-09-22T09:00:00Z"},{"startAt":"2026-09-20T07:00:00Z","endAt":"2026-09-20T09:00:00Z"}]}
        """
        let advisory = try DisruptionDate.decoder().decode(DisruptionAdvisory.self, from: Data(json.utf8))
        #expect(advisory.affectedPeriods.count == 2)
        #expect(advisory.affectedPeriods[0].endAt < advisory.affectedPeriods[1].startAt)
        let betweenPeriods = try #require(ISO8601DateFormatter().date(from: "2026-09-21T12:00:00Z"))
        #expect(advisory.nextAffectedPeriod(at: betweenPeriods) == advisory.affectedPeriods[1])
        var legacy = advisory
        legacy.affectedWindows = nil
        #expect(legacy.affectedPeriods == [DisruptionAffectedWindow(startAt: advisory.startAt, endAt: advisory.endAt)])
        let cached = try JSONDecoder().decode(DisruptionAdvisory.self, from: JSONEncoder().encode(advisory))
        #expect(cached.affectedPeriods == advisory.affectedPeriods)
    }

    @Test func rejectedSnapshotExplainsTheServerLimitWithoutTruncatingJourneys() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DisruptionMonitoringStore(defaults: defaults, replace: { _ in
            throw DisruptionMonitoringError.rejected("Supply at most 100 saved journey monitors.")
        }, groups: { [group(["KTH", "VIC"])] }, subscriptions: { [] }, schedulesLoaded: { true }, pushAuthorized: { false })
        await store.refresh()
        #expect(store.lastError?.contains("at most 100") == true)
        #expect(!store.isSuspended)
    }

    @Test func deletionDuringUploadCannotBeOverwrittenByAnOlderSnapshot() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let routes = Routes([group(["KTH", "VIC"])])
        var requests: [DisruptionMonitorSnapshot] = []
        var releaseUpload: CheckedContinuation<Void, Never>?
        let store = DisruptionMonitoringStore(defaults: defaults, replace: { snapshot in
            requests.append(snapshot)
            if requests.count == 1 {
                await withCheckedContinuation { releaseUpload = $0 }
            }
            return emptyResponse()
        }, groups: { routes.values }, subscriptions: { [] }, schedulesLoaded: { true }, pushAuthorized: { false })
        let first = Task { await store.refresh() }
        while releaseUpload == nil { await Task.yield() }
        routes.values = []
        await store.refresh()
        #expect(requests.count == 1)
        releaseUpload?.resume()
        await first.value
        #expect(requests.count == 2)
        #expect(requests.last?.monitors.isEmpty == true)
    }

    @Test func deletedDeviceSuspensionSurvivesRestartAndDoesNotUploadAgain() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = group(["KTH", "VIC"])
        var attempts = 0
        let makeStore = {
            DisruptionMonitoringStore(defaults: defaults, replace: { _ in
                attempts += 1
                throw DisruptionMonitoringError.deviceDeleted
            }, groups: { [route] }, subscriptions: { [] }, schedulesLoaded: { true }, pushAuthorized: { false })
        }
        let store = makeStore()
        await store.refresh()
        #expect(store.isSuspended)
        #expect(store.response == nil)
        await store.refresh()
        let restarted = makeStore()
        await restarted.refresh()
        #expect(restarted.isSuspended)
        #expect(attempts == 1)
    }

    @Test func failedRefreshDoesNotTurnUnknownIntoClearOrLoseCachedWarnings() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = group(["KTH", "VIC"])
        let warning = DisruptionAdvisory(id: "a", monitorId: route.id.uuidString, kind: "replacement_bus",
            title: "Replacement buses", body: "Allow extra time", startAt: Date().addingTimeInterval(86400),
            endAt: Date().addingTimeInterval(2 * 86400), sourceURL: nil, confidence: "timetable", checkedAt: Date(), extraMinutes: 25)
        let store = DisruptionMonitoringStore(defaults: defaults, replace: { _ in
            DisruptionMonitoringResponse(mode: "active", horizonDays: 7, monitors: [], advisories: [warning])
        }, groups: { [route] }, subscriptions: { [] }, schedulesLoaded: { true }, pushAuthorized: { false })
        #expect(store.summary(for: route) == "Awaiting first disruption check")
        await store.refresh()
        let restarted = DisruptionMonitoringStore(defaults: defaults, replace: { _ in
            throw URLError(.notConnectedToInternet)
        }, groups: { [route] }, subscriptions: { [] }, schedulesLoaded: { true }, pushAuthorized: { false })
        await restarted.refresh()
        #expect(restarted.advisories(for: route).count == 1)
        #expect(restarted.lastError != nil)
        #expect(restarted.summary(for: route) == "Replacement buses")
    }

    private func defaults() throws -> (UserDefaults, String) {
        let suite = "DisruptionMonitoringTests.\(UUID())"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @MainActor
    private final class Routes {
        var values: [JourneyGroup]
        init(_ values: [JourneyGroup]) { self.values = values }
    }

    private func emptyResponse() -> DisruptionMonitoringResponse {
        DisruptionMonitoringResponse(mode: "active", horizonDays: 7, monitors: [], advisories: [])
    }

    private func group(_ stations: [String]) -> JourneyGroup {
        let id = UUID()
        let values = stations.map { Station(crs: $0, name: $0, longitude: "0", latitude: "0") }
        let legs = zip(values, values.dropFirst()).enumerated().map { index, pair in
            Journey(id: UUID(), groupId: id, legIndex: index, fromStation: pair.0,
                    toStation: pair.1, createdAt: Date(), favorite: false)
        }
        return JourneyGroup(id: id, legs: legs)
    }

    private func leg(_ from: String, _ to: String, start: String = "08:00", end: String = "10:00") -> NotificationLeg {
        NotificationLeg(from: from, to: to, fromName: nil, toName: nil, enabled: true, windowStart: start, windowEnd: end)
    }

    private func subscription(legs: [NotificationLeg], days: [DayOfWeek]) -> NotificationSubscription {
        NotificationSubscription(id: "test", deviceId: "test", routeKey: "KTH-ZFD", scheduleKind: .regular,
            daysOfWeek: days, notificationTypes: [.delays], legs: legs, muteOnArrival: true,
            source: .scheduled, liveSessionOrigin: nil, activeUntil: nil, mutedByLegDay: nil,
            mutedAtByLegDay: nil, createdAt: nil, updatedAt: nil)
    }
}
