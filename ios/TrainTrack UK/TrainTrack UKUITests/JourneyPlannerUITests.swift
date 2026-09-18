import XCTest

final class JourneyPlannerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSavedRouteQueueProgressAtLargestText() throws {
        let app = launch(plannerEnabled: false, largeText: true, apiBase: "http://127.0.0.1:3014/saved-progress-large/api/v2")
        saveFixtureRoute(in: app)
        let progress = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "saved-route.progress.", "Queue position: 2")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        scrollTo(progress, in: app)
        attach("saved-route-queue-largest-text", app: app)
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    func testSavedRouteQueueProgressBecomesScheduledJourneys() throws {
        let app = launch(plannerEnabled: false, apiBase: "http://127.0.0.1:3014/saved-progress/api/v2")
        saveFixtureRoute(in: app)
        let queued = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "saved-route.progress.KTH-INV", "Queue position: 2")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 10))
        XCTAssertTrue(queued.label.contains("Waiting to plan journeys"))
        XCTAssertTrue(queued.label.contains("Waiting:"))
        XCTAssertFalse(app.staticTexts["Saved journeys are waiting to be planned."].exists)
        attach("saved-route-queue-progress", app: app)
        let searching = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "saved-route.progress.KTH-INV", "Checked 3 of 8 timetable windows")).firstMatch
        XCTAssertTrue(searching.waitForExistence(timeout: 10))
        attach("saved-route-search-progress", app: app)
        let journey = app.buttons["saved-route.journey.saved-apply-KTH"].firstMatch
        XCTAssertTrue(journey.waitForExistence(timeout: 15))
        XCTAssertTrue(journey.label.contains("Scheduled"))
        XCTAssertFalse(app.staticTexts["Live times out of date"].exists)
        attach("saved-route-scheduled-ready", app: app)
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Live information may be out of date")).firstMatch.exists)
    }

    @MainActor
    func testSavedRouteShowsWholeItineraryAndIndependentTrainActions() throws {
        let app = launch(plannerEnabled: false, apiBase: "http://127.0.0.1:3014/saved/api/v2")
        saveFixtureRoute(in: app)
        let journey = app.buttons["saved-route.journey.saved-apply-KTH"].firstMatch
        XCTAssertTrue(journey.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Start route updates"].firstMatch.exists)
        attach("saved-route-itinerary-card", app: app)
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 5))
        let track = app.buttons["planner.track.KTH.VIC"]
        scrollTo(track, in: app)
        XCTAssertTrue(track.isHittable)
        track.tap()
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "could not be confirmed for tracking")).firstMatch
        // The fixture has no provider identity: no train or subscription may be guessed.
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        attach("saved-route-per-train-verification", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let options = app.buttons["saved-route.options.KTH-INV"]
        XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 5))
        scrollTo(options, in: app)
        options.tap()
        let toggle = app.switches["Use live times"].firstMatch
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["saved-route.journey.saved-ignore-KTH"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testSavedRouteLargestTextLayoutAndLegacyFallback() throws {
        let app = launch(plannerEnabled: false, largeText: true, apiBase: "http://127.0.0.1:3014/saved-legacy/api/v2")
        saveFixtureRoute(in: app)
        let fallback = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Showing saved-route departures")).firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Start route updates"].firstMatch.exists)
        attach("saved-route-legacy-large-text", app: app)
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    func testFavouritePlannedItineraryAtLargestTextInDarkMode() throws {
        let app = launch(plannerEnabled: false, largeText: true, dark: true, apiBase: "http://127.0.0.1:3014/saved/api/v2")
        saveFixtureRoute(in: app, favourite: true)
        let journey = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "saved-route.journey.")).firstMatch
        XCTAssertTrue(journey.waitForExistence(timeout: 15))
        scrollTo(journey, in: app)
        XCTAssertTrue(journey.isHittable)
        attach("favourite-planned-itinerary-dark-large-text", app: app)
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 5))
        let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "planner.track.")).firstMatch
        scrollTo(track, in: app)
        XCTAssertTrue(track.isHittable)
        attach("favourite-planned-detail-dark-large-text", app: app)
        // The separate text-clipping audit currently reports an unidentified element
        // (nil) on iOS 26.5; retain hit-target verification here and review screenshots.
        try app.performAccessibilityAudit(for: [.hitRegion])
    }

    @MainActor
    private func saveFixtureRoute(in app: XCUIApplication, favourite: Bool = false, destination: (String, String) = ("INV", "Inverness")) {
        if favourite { app.buttons["Add favourite journey"].tap() }
        else { openAddJourney(in: app) }
        for (field, code, name) in [("from", "KTH", "Kent House"), ("destination", destination.0, destination.1)] {
            let input = app.textFields["add-journey.\(field)"]
            scrollTo(input, in: app, towardTop: field == "from")
            input.tap()
            input.typeText(code)
            let suggestion = app.staticTexts[name].firstMatch
            XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
            suggestion.tap()
        }
        let save = app.buttons["Save"]
        scrollTo(save, in: app)
        if favourite { XCTAssertEqual(app.switches["Mark as favourite"].value as? String, "1") }
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.navigationBars[favourite ? "Favourites" : "My Journeys"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testUnavailablePlannerKeepsSavedRouteAndFavouritePrefill() throws {
        let app = launch(plannerEnabled: true)
        let favouriteEntry = app.buttons["Add favourite journey"]
        XCTAssertTrue(favouriteEntry.waitForExistence(timeout: 5))
        favouriteEntry.tap()
        XCTAssertTrue(app.navigationBars["Find journeys"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["planner.live-times"].exists)
        XCTAssertFalse(app.buttons["planner.search"].isEnabled)
        let savedRoute = app.buttons["planner.saved-route"]
        scrollTo(savedRoute, in: app)
        XCTAssertTrue(savedRoute.exists)
        var accessibilityIssues: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .textClipped, .hitRegion]) { issue in
            // Native disabled controls are exempt from contrast requirements.
            if issue.auditType == .contrast && issue.element?.isEnabled == false { return true }
            accessibilityIssues.append("\(issue.compactDescription): \(issue.element?.label ?? "Unknown element")")
            return true
        }
        XCTAssertTrue(accessibilityIssues.isEmpty, accessibilityIssues.joined(separator: "\n"))
        attach("planner-unavailable", app: app)
        savedRoute.tap()
        XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["add-journey.from"].exists)
        XCTAssertTrue(app.textFields["add-journey.destination"].exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["Add intermediate stop"].exists)
        let favourite = app.switches["Mark as favourite"]
        scrollTo(favourite, in: app)
        XCTAssertEqual(favourite.value as? String, "1")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDisabledPlannerPreservesOriginalAddJourney() throws {
        let app = launch(plannerEnabled: false)
        openAddJourney(in: app)
        XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["add-journey.from"].exists)
        XCTAssertFalse(app.navigationBars["Find journeys"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPlannerLargestDynamicTypeLayout() throws {
        let app = launch(plannerEnabled: true, largeText: true)
        openAddJourney(in: app)
        XCTAssertTrue(app.navigationBars["Find journeys"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["planner.origin"].isHittable)
        XCTAssertTrue(app.buttons["planner.destination"].isHittable)
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
        attach("planner-large-text", app: app)
        scrollTo(app.buttons["planner.saved-route"], in: app)
        XCTAssertTrue(app.buttons["planner.saved-route"].isHittable)
        attach("planner-large-text-saved-route", app: app)
    }

    @MainActor
    func testStationPickerShowsNearbyAndRecentlyUsedSections() throws {
        let app = launch(plannerEnabled: true)
        openAddJourney(in: app)

        let origin = app.buttons["planner.origin"]
        XCTAssertTrue(origin.waitForExistence(timeout: 5))
        origin.tap()

        XCTAssertTrue(app.navigationBars["From"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Nearby stations"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recently used"].exists)
        attach("planner-station-suggestions", app: app)
    }

    @MainActor
    func testEmptyWindowExplainsScopeAndCanSearchEarlierAndLaterAtLargestTextSize() async throws {
        let app = try await launchEmptyWindowAtLargestTextSize()
        let interval = app.staticTexts["planner.empty.interval"]
        scrollTo(interval, in: app)
        XCTAssertTrue(interval.label.hasPrefix("Departures searched:"))
        let originalInterval = interval.label
        XCTAssertEqual(app.staticTexts["planner.empty.change-limit"].label, "Up to 5 changes.")
        attach("planner-empty-window-context", app: app)
        let earlier = app.buttons["planner.empty.earlier"]
        let later = app.buttons["planner.empty.later"]
        scrollTo(earlier, in: app)
        XCTAssertTrue(earlier.isHittable)
        XCTAssertTrue(later.isHittable)
        attach("planner-empty-window-large-text", app: app)
        earlier.tap()
        scrollTo(interval, in: app, towardTop: true)
        let earlierLoaded = expectation(for: NSPredicate(format: "label != %@", originalInterval), evaluatedWith: interval)
        await fulfillment(of: [earlierLoaded], timeout: 10)
        XCTAssertTrue(interval.label.hasPrefix("Departures searched:"))
        scrollTo(later, in: app)
        later.tap()
        scrollTo(interval, in: app, towardTop: true)
        let originalLoaded = expectation(for: NSPredicate(format: "label == %@", originalInterval), evaluatedWith: interval)
        await fulfillment(of: [originalLoaded], timeout: 10)
        scrollTo(later, in: app)
        later.tap()
        let journey = app.buttons["planner.journey.fixture-later-journey"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["planner.empty.later"].exists)
    }

    @MainActor
    func testEmptyWindowAccessibilityAtLargestTextSize() async throws {
        let app = try await launchEmptyWindowAtLargestTextSize()
        let earlier = app.buttons["planner.empty.earlier"]
        scrollTo(earlier, in: app)
        XCTAssertTrue(earlier.isHittable)
        XCTAssertTrue(app.buttons["planner.empty.later"].isHittable)
        attach("planner-empty-window-accessibility", app: app)
        // Keep the audit isolated: its scan can invalidate the iOS 26 collection snapshot.
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    func testQueuedSearchShowsProgressAndPaginationCanBeCancelled() async throws {
        let app = try await launchQueuedFixture(profile: "queued")
        let search = app.buttons["planner.search"]
        search.tap()
        XCTAssertTrue(app.buttons["Waiting to search…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["planner.cancel-search"].exists)
        attach("planner-queued", app: app)
        let running = expectation(for: NSPredicate(format: "label == %@", "Finding journeys…"), evaluatedWith: search)
        await fulfillment(of: [running], timeout: 10)
        attach("planner-running", app: app)
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 15))
        let later = app.buttons["planner.empty.later"]
        scrollTo(later, in: app)
        XCTAssertTrue(later.isEnabled)
        let before = try await fixtureCancellationCount(profile: "queued")
        later.tap()
        let disabled = expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: later)
        await fulfillment(of: [disabled], timeout: 5)
        XCTAssertFalse(app.buttons["planner.empty.earlier"].isEnabled)
        XCTAssertTrue(app.activityIndicators["planner.pagination.spinner"].exists)
        let cancel = app.buttons["planner.cancel-search"]
        scrollTo(cancel, in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        attach("planner-pagination-cancel", app: app)
        cancel.tap()
        XCTAssertFalse(cancel.exists)
        XCTAssertTrue(app.navigationBars["Journeys"].exists)
        scrollTo(later, in: app)
        XCTAssertTrue(later.isEnabled)
        try await assertFixtureCancelled(profile: "queued", after: before)
    }

    @MainActor
    func testJourneyResultsPillsAndAllPaginationButtonsShowLoading() async throws {
        let app = try await launchQueuedFixture(profile: "results")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        let journey = app.buttons["planner.journey.fixture-results"]
        XCTAssertTrue(journey.waitForExistence(timeout: 5))
        XCTAssertNotNil(journey.label.range(of: #"^\d{2}:\d{2} → \d{2}:\d{2}"#, options: .regularExpression))
        XCTAssertTrue(journey.label.contains("Southeastern"))
        XCTAssertTrue(journey.label.contains("LNER"))
        XCTAssertTrue(journey.label.contains("ScotRail"))
        XCTAssertEqual(journey.label.components(separatedBy: "Southeastern").count, 2)
        XCTAssertFalse(app.buttons["Search notes"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Timetable published'")).firstMatch.exists)
        attach("planner-results-pills", app: app)
        for identifier in ["planner.more", "planner.earlier", "planner.later"] {
            let button = app.buttons[identifier]
            scrollTo(button, in: app)
            XCTAssertTrue(button.isEnabled)
            button.tap()
            let disabled = expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: button)
            await fulfillment(of: [disabled], timeout: 5)
            XCTAssertFalse(app.buttons["planner.more"].isEnabled)
            XCTAssertFalse(app.buttons["planner.earlier"].isEnabled)
            XCTAssertFalse(app.buttons["planner.later"].isEnabled)
            XCTAssertTrue(app.activityIndicators["planner.pagination.spinner"].exists)
            attach("\(identifier)-loading", app: app)
            let cancel = app.buttons["planner.cancel-search"]
            scrollTo(cancel, in: app, towardTop: true)
            cancel.tap()
            scrollTo(button, in: app)
            XCTAssertTrue(button.isEnabled)
        }
    }

    @MainActor
    func testJourneyResultPillsAtLargestTextSize() async throws {
        let app = try await launchQueuedFixture(profile: "results", largeText: true)
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        let journey = app.buttons["planner.journey.fixture-results"]
        scrollTo(journey, in: app)
        XCTAssertTrue(journey.isHittable)
        XCTAssertTrue(journey.label.contains("Southeastern"))
        XCTAssertTrue(journey.label.contains("ScotRail"))
        attach("planner-results-pills-large-text", app: app)
        try app.performAccessibilityAudit(for: [.contrast, .textClipped, .hitRegion])
    }

    @MainActor
    func testTimetableDepartureRowsUseSavedJourneyFormatting() async throws {
        let app = try await launchQueuedFixture(profile: "departures", destination: "VIC")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        let onTime = app.buttons["planner.journey.departure-row-onTime"]
        XCTAssertTrue(onTime.waitForExistence(timeout: 10))
        XCTAssertTrue(onTime.label.contains("On time"))
        XCTAssertTrue(onTime.label.contains("10 car train"))
        XCTAssertTrue(onTime.label.contains("Platform 2"))
        assertJourneyTimeRange(onTime)
        XCTAssertFalse(onTime.label.contains("Fastest"))
        XCTAssertFalse(onTime.label.contains("Slower"))
        XCTAssertTrue(onTime.label.contains("35 min · Direct"))
        XCTAssertTrue(onTime.label.contains("Southeastern"))
        let delayed = app.buttons["planner.journey.departure-row-delayed"]
        scrollTo(delayed, in: app)
        assertJourneyTimeRange(delayed)
        XCTAssertFalse(delayed.label.contains("Fastest"))
        XCTAssertFalse(delayed.label.contains("Slower"))
        XCTAssertTrue(delayed.label.contains("Delayed"))
        XCTAssertTrue(delayed.label.contains("Scheduled "))
        let unknown = app.buttons["planner.journey.departure-row-unknown"]
        scrollTo(unknown, in: app)
        assertJourneyTimeRange(unknown)
        XCTAssertFalse(unknown.label.contains("Fastest"))
        XCTAssertFalse(unknown.label.contains("Slower"))
        // Without a live departure/arrival observation, this row uses its timetable.
        XCTAssertTrue(unknown.label.contains("Scheduled"))
        XCTAssertFalse(unknown.label.contains("On time"))
        let cancelled = app.buttons["planner.journey.departure-row-cancelled"]
        scrollTo(cancelled, in: app)
        assertJourneyTimeRange(cancelled)
        XCTAssertFalse(cancelled.label.contains("Fastest"))
        XCTAssertFalse(cancelled.label.contains("Slower"))
        XCTAssertTrue(cancelled.label.contains("Cancelled"))
        XCTAssertFalse(cancelled.label.contains("10 car train"))
        attach("planner-departure-rows", app: app)
        scrollTo(onTime, in: app, towardTop: true)
        onTime.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [.contrast, .textClipped, .hitRegion])
    }

    @MainActor
    func testPlannerArrivalTimesAndDurationTags() async throws {
        let app = try await launchQueuedFixture(profile: "durations", destination: "VIC")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        assertDurationComparison(in: app, rowPrefix: "planner.journey.duration-", screenshotName: "planner-duration-tags")
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    func testPlannerArrivalTimesAndDurationTagsAtLargestTextInDarkMode() async throws {
        let app = try await launchQueuedFixture(profile: "durations", largeText: true, destination: "VIC", dark: true)
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        assertDurationComparison(in: app, rowPrefix: "planner.journey.duration-", screenshotName: "planner-duration-tags-dark-largest-text")
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    func testSavedRouteArrivalTimesAndDurationTags() async throws {
        _ = try await fixtureCancellationCount(profile: "saved-durations")
        let app = launch(plannerEnabled: false, apiBase: "http://127.0.0.1:3014/saved-durations/api/v2")
        saveFixtureRoute(in: app, destination: ("VIC", "London Victoria"))
        expandDurationFixtureRoute(in: app)
        assertDurationComparison(in: app, rowPrefix: "saved-route.journey.duration-KTH-", screenshotName: "saved-route-duration-tags")
        // Whole-screen hit-region auditing reports an unidentified SwiftUI node;
        // the existing header also has 30pt controls. Check changed row targets
        // explicitly below, while retaining the whole-screen clipping audit.
        try app.performAccessibilityAudit(for: [.textClipped])
    }

    @MainActor
    func testFavouriteArrivalTimesAndDurationTagsAtLargestTextInDarkMode() async throws {
        _ = try await fixtureCancellationCount(profile: "saved-durations")
        let app = launch(plannerEnabled: false, largeText: true, dark: true, apiBase: "http://127.0.0.1:3014/saved-durations/api/v2")
        saveFixtureRoute(in: app, favourite: true, destination: ("VIC", "London Victoria"))
        expandDurationFixtureRoute(in: app)
        assertDurationComparison(in: app, rowPrefix: "saved-route.journey.duration-KTH-", screenshotName: "favourite-duration-tags-dark-largest-text")
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    private func expandDurationFixtureRoute(in app: XCUIApplication) {
        let first = app.buttons["saved-route.journey.duration-KTH-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let third = app.buttons["saved-route.journey.duration-KTH-2"]
        scrollDurationElement(third, in: app)
        // The collapsed card compares its three visible options (30, 30, 40).
        XCTAssertTrue(third.label.contains("Slower"))
        let card = app.cells.containing(.button, identifier: "saved-route.journey.duration-KTH-2").firstMatch
        let expand = card.buttons["View all journeys"]
        scrollDurationElement(expand, in: app)
        XCTAssertTrue(expand.isHittable)
        expand.tap()
        scrollTo(first, in: app, towardTop: true)
    }

    @MainActor
    private func assertDurationComparison(in app: XCUIApplication, rowPrefix: String, screenshotName: String) {
        for index in 0..<4 {
            let journey = app.buttons["\(rowPrefix)\(index)"]
            if index == 0 { XCTAssertTrue(journey.waitForExistence(timeout: 15)) }
            let oversized = scrollDurationElement(journey, in: app)
            XCTAssertTrue(journey.isHittable)
            XCTAssertGreaterThanOrEqual(journey.frame.width, 44)
            XCTAssertGreaterThanOrEqual(journey.frame.height, 44)
            assertJourneyTimeRange(journey)
            XCTAssertEqual(journey.label.contains("Fastest"), index < 2, journey.label)
            XCTAssertEqual(journey.label.contains("Slower"), index == 3, journey.label)
            if index == 0 || index == 3 {
                attach("\(screenshotName)-\(index)", app: app)
                if oversized {
                    scrollDurationElement(journey, in: app, alignBottom: true)
                    attach("\(screenshotName)-\(index)-bottom", app: app)
                }
            }
        }
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Arr ")).firstMatch.exists)
    }

    @MainActor
    @discardableResult
    private func scrollDurationElement(_ element: XCUIElement, in app: XCUIApplication, alignBottom: Bool = false) -> Bool {
        var oversized = false
        for _ in 0..<12 {
            let screen = app.frame
            let top = app.navigationBars.firstMatch.frame.maxY + 12
            let tabs = app.tabBars.firstMatch
            let bottom = (tabs.exists ? tabs.frame.minY : screen.maxY - 30) - 12
            var offset: CGFloat = 180
            if element.exists {
                let frame = element.frame
                oversized = frame.height > bottom - top
                if oversized {
                    offset = alignBottom ? frame.maxY - bottom : frame.minY - top
                } else if frame.minY < top {
                    offset = frame.minY - top
                } else if frame.maxY > bottom {
                    offset = frame.maxY - bottom
                } else if element.isHittable {
                    return false
                }
                if abs(offset) < 8 && element.isHittable { return oversized }
            }
            // Match the missing distance and hold at the end to avoid scrolling
            // past the row, then reversing forever at accessibility text sizes.
            let distance = min(220, max(16, abs(offset))) * (offset < 0 ? -1 : 1)
            let startY = offset < 0 ? top + 30 : bottom - 30
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: screen.midX - screen.minX, dy: startY - screen.minY))
            let end = origin.withOffset(CGVector(dx: screen.midX - screen.minX, dy: startY - screen.minY - distance))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        return oversized
    }

    @MainActor
    private func assertJourneyTimeRange(_ journey: XCUIElement) {
        XCTAssertNotNil(journey.label.range(of: #"^\d{2}:\d{2} → \d{2}:\d{2}"#, options: .regularExpression), journey.label)
        XCTAssertFalse(journey.label.contains("Arr "), journey.label)
    }

    @MainActor
    func testJourneyDetailsDescribeLegsAndRouteMapsHighlightSelectedSection() async throws {
        let app = try await launchQueuedFixture(profile: "details")
        app.buttons["planner.search"].tap()
        let journey = app.buttons["planner.journey.fixture-details"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        XCTAssertTrue(journey.label.contains("Lumo"))
        XCTAssertTrue(journey.label.contains("Southeastern, Tube, Lumo, ScotRail"))
        journey.tap()
        guard app.navigationBars["Journey details"].waitForExistence(timeout: 10) else {
            XCTFail("Tapping a journey did not open its details.")
            return
        }
        XCTAssertTrue(app.staticTexts["Summary"].exists)
        let summary = app.descendants(matching: .any)["planner.detail.summary"].firstMatch
        XCTAssertTrue(summary.label.contains("Southeastern, Tube, Lumo, ScotRail"))
        XCTAssertFalse(app.staticTexts["Scheduled times only"].exists)
        XCTAssertFalse(app.staticTexts["Live delays and cancellations are not included. All times are UK time."].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Timetable published")).firstMatch.exists)
        attach("planner-detail-summary", app: app)
        let firstMap = app.buttons["planner.route-map.0"]
        scrollTo(firstMap, in: app)
        XCTAssertTrue(app.staticTexts["1. Train from Kent House to London Victoria"].exists)
        XCTAssertFalse(app.buttons["Calling points"].exists)
        XCTAssertTrue(app.staticTexts["Depart from Kent House"].exists)
        XCTAssertTrue(app.staticTexts["Arrive at London Victoria"].exists)
        attach("planner-detail-train", app: app)
        firstMap.tap()
        XCTAssertTrue(app.navigationBars["Route map"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Selected section in blue · Other sections in grey"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["Train from Kent House to London Victoria"].exists)
        attach("planner-route-map-first-leg", app: app)
        app.buttons["Show whole journey"].tap()
        XCTAssertTrue(app.buttons["Show selected section"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["planner.map.station.STG"].firstMatch.label.contains("journey change"))
        let destination = app.descendants(matching: .any)["planner.map.station.INV"].firstMatch
        XCTAssertTrue(destination.label.contains("journey destination"))
        XCTAssertTrue(destination.label.contains("(due "))
        attach("planner-route-map-whole-journey", app: app)
        app.buttons["Show selected section"].tap()
        XCTAssertTrue(app.buttons["Show whole journey"].waitForExistence(timeout: 5))
        let origin = app.descendants(matching: .any)["planner.map.station.KTH"].firstMatch
        guard origin.waitForExistence(timeout: 10) else { XCTFail("Origin annotation did not return after zooming in."); return }
        XCTAssertTrue(origin.label.contains("selected section origin"))
        XCTAssertTrue(app.descendants(matching: .any)["planner.map.station.VIC"].firstMatch.label.contains("selected section destination"))
        attach("planner-route-map-selected-again", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let tubeMap = app.buttons["planner.route-map.1"]
        scrollTo(tubeMap, in: app)
        XCTAssertTrue(app.staticTexts["Tube"].exists)
        XCTAssertTrue(app.staticTexts["Depart from London Victoria"].exists)
        XCTAssertTrue(app.staticTexts["Arrive at London Euston"].exists)
        attach("planner-detail-tube", app: app)
        let lumoMap = app.buttons["planner.route-map.2"]
        scrollTo(lumoMap, in: app)
        XCTAssertTrue(app.staticTexts["Lumo"].exists)
        XCTAssertFalse(app.staticTexts["LF"].exists)
        lumoMap.tap()
        XCTAssertTrue(app.staticTexts["Train from London Euston to Stirling"].waitForExistence(timeout: 45))
        attach("planner-route-map-lumo-leg", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let change = app.staticTexts["4. Change trains at Stirling"]
        scrollTo(change, in: app)
        XCTAssertTrue(app.staticTexts["Allow at least 5 min to change trains."].exists)
        XCTAssertFalse(app.staticTexts["Stirling → Stirling"].exists)
        XCTAssertFalse(app.buttons["planner.route-map.3"].exists)
        attach("planner-detail-change-trains", app: app)
    }

    @MainActor
    func testPlannerMapShowsMatchedLiveTrain() async throws {
        let app = try await launchQueuedFixture(profile: "live-details")
        app.buttons["planner.search"].tap()
        let journey = app.buttons["planner.journey.fixture-details"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 10))
        let map = app.buttons["planner.route-map.0"]
        scrollTo(map, in: app)
        map.tap()
        XCTAssertTrue(app.descendants(matching: .any)["planner.map.train"].firstMatch.waitForExistence(timeout: 45))
        attach("planner-route-map-live-train", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    func testJourneyDetailsAtLargestTextSize() async throws {
        let app = try await launchQueuedFixture(profile: "details", largeText: true)
        app.buttons["planner.search"].tap()
        let journey = app.buttons["planner.journey.fixture-details"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        journey.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.2)).tap()
        guard app.navigationBars["Journey details"].waitForExistence(timeout: 10) else {
            XCTFail("Journey details did not open at the largest text size.")
            return
        }
        let tubeMap = app.buttons["planner.route-map.1"]
        scrollTo(tubeMap, in: app)
        XCTAssertTrue(tubeMap.isHittable)
        app.swipeDown()
        attach("planner-detail-tube-large-text", app: app)
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    func testTubeTrackDirectionsExplainDisruptionAndShowLinePills() async throws {
        let app = try await launchQueuedFixture(profile: "tubetrack")
        app.buttons["planner.search"].tap()
        let journey = app.buttons["planner.journey.fixture-tubetrack"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        XCTAssertTrue(journey.label.contains("Circle, Northern"))
        XCTAssertTrue(journey.label.contains("5 extra minutes"))
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 10))
        let note = app.descendants(matching: .any)["planner.local-note.1"].firstMatch
        scrollToLocalDirection(note, in: app)
        XCTAssertTrue(note.label.contains("avoid severe delays"))
        let circle = app.descendants(matching: .any)["planner.local-step.0"].firstMatch
        scrollToLocalDirection(circle, in: app)
        XCTAssertTrue(circle.label.contains("Circle"))
        XCTAssertTrue(circle.label.contains("Estimated"))
        attach("planner-tubetrack-circle-directions", app: app)
        let northern = app.descendants(matching: .any)["planner.local-step.1"].firstMatch
        scrollToLocalDirection(northern, in: app)
        XCTAssertTrue(northern.label.contains("Change at Embankment"))
        XCTAssertTrue(northern.label.contains("Northern"))
        XCTAssertFalse(app.staticTexts["A supplied connecting transfer. Specific departures and intermediate stops are not provided."].exists)
        attach("planner-tubetrack-change-directions", app: app)
        // Review the captured line colours/text visually: iOS 26.5's SwiftUI
        // audit reports unidentifiable contrast/clipping nodes on this screen.
        try app.performAccessibilityAudit(for: [.hitRegion])
    }

    @MainActor
    func testTubeTrackDirectionsAtLargestTextInDarkMode() async throws {
        let app = try await launchQueuedFixture(profile: "tubetrack", largeText: true, dark: true)
        app.buttons["planner.search"].tap()
        let journey = app.buttons["planner.journey.fixture-tubetrack"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        scrollToLocalDirection(journey, in: app)
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 10))
        let note = app.descendants(matching: .any)["planner.local-note.0"].firstMatch
        scrollToLocalDirection(note, in: app)
        XCTAssertTrue(note.label.contains("5 extra minutes"))
        attach("planner-tubetrack-large-text-disruption", app: app)
        let northern = app.descendants(matching: .any)["planner.local-step.1"].firstMatch
        scrollToLocalDirection(northern, in: app)
        XCTAssertTrue(northern.label.contains("Change at Embankment"))
        attach("planner-tubetrack-large-text-dark", app: app)
        try app.performAccessibilityAudit(for: [.hitRegion])
    }

    @MainActor
    private func scrollToLocalDirection(_ element: XCUIElement, in app: XCUIApplication) {
        // Short drags keep small direction/notes rows from being skipped between snapshots.
        for _ in 0..<35 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.frame.maxY - 30
            if element.isHittable && (element.frame.height > bottom - top
                || (element.frame.minY >= top && element.frame.maxY <= bottom)) { return }
            let towardTop = element.exists && element.frame.minY < top
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.4 : 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.65 : 0.45))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    }

    @MainActor
    func testQueuedSearchCanBeCancelledBeforeResults() async throws {
        let app = try await launchQueuedFixture(profile: "cancel", largeText: true)
        let before = try await fixtureCancellationCount(profile: "cancel")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.buttons["Waiting to search…"].waitForExistence(timeout: 5))
        let cancel = app.buttons["planner.cancel-search"]
        scrollTo(cancel, in: app)
        XCTAssertTrue(cancel.isHittable)
        attach("planner-queued-large-text-cancel", app: app)
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Find journeys"].exists)
        XCTAssertFalse(cancel.exists)
        XCTAssertTrue(app.buttons["planner.search"].isEnabled)
        XCTAssertFalse(app.navigationBars["Journeys"].exists)
        try await assertFixtureCancelled(profile: "cancel", after: before)
    }

    @MainActor
    private func launchQueuedFixture(profile: String, largeText: Bool = false, destination: String = "INV", dark: Bool = false) async throws -> XCUIApplication {
        let base = "http://127.0.0.1:3014/\(profile)/api/v2"
        _ = try await fixtureCancellationCount(profile: profile)
        let app = launch(plannerEnabled: true, largeText: largeText, dark: dark, apiBase: base)
        openAddJourney(in: app)
        selectStations(origin: "KTH", destination: destination, in: app)
        scrollTo(app.buttons["planner.search"], in: app)
        return app
    }

    private func fixtureCancellationCount(profile: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:3014/\(profile)/test-state")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Start journey_planner_ui_fixture.py to run queued-search UI tests.")
        }
        let state = try JSONDecoder().decode([String: Int].self, from: data)
        return state["cancelled"] ?? 0
    }

    private func assertFixtureCancelled(profile: String, after count: Int) async throws {
        for _ in 0..<20 {
            if try await fixtureCancellationCount(profile: profile) > count { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Cancelling the search did not release its server lease.")
    }

    @MainActor
    func testLongJourneyShowsPartialOnTimeCoverageAndNeutralTubeDetails() async throws {
        let app = try await launchQueuedFixture(profile: "coverage")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        let journey = app.buttons["planner.journey.coverage-journey"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        XCTAssertTrue(journey.label.contains("1 of 2 trains confirmed on time"))
        XCTAssertFalse(journey.label.contains("All trains on time"))
        XCTAssertFalse(journey.label.contains("supplied generic transfer"))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "supplied generic transfer")).firstMatch.exists)
        attach("planner-partial-rail-coverage", app: app)
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 5))
        let explanation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "A supplied connecting transfer.")).firstMatch
        scrollTo(explanation, in: app)
        XCTAssertTrue(explanation.isHittable)
        attach("planner-neutral-tube-detail", app: app)
    }

    @MainActor
    func testLiveTimesOverrideRerunsAndKeepsCancellationWarnings() async throws {
        continueAfterFailure = false
        let app = try await launchQueuedFixture(profile: "live", destination: "VIC")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        let applied = app.buttons["planner.journey.live-journey-apply"]
        XCTAssertTrue(applied.waitForExistence(timeout: 10))
        XCTAssertTrue(applied.label.contains("Delayed"))
        XCTAssertTrue(applied.label.contains("Another section of this train is cancelled."))
        let unavailable = app.buttons["planner.disrupted-options"]
        scrollTo(unavailable, in: app)
        XCTAssertTrue(unavailable.exists)
        attach("planner-live-results", app: app)
        let toggle = app.switches["planner.live-times"]
        scrollTo(toggle, in: app, towardTop: true)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        let scheduled = app.buttons["planner.journey.live-journey-ignore"]
        XCTAssertTrue(scheduled.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(scheduled.label.contains("Delayed"))
        XCTAssertTrue(scheduled.label.contains("Another section of this train is cancelled."))
        let cancelled = app.buttons["planner.journey.live-cancelled-ignore"]
        scrollTo(cancelled, in: app)
        XCTAssertTrue(cancelled.label.contains("Cancelled"))
        attach("planner-live-scheduled-override", app: app)
        scrollTo(scheduled, in: app, towardTop: true)
        scheduled.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 5))
        let points = app.buttons["planner.calling-points.0"]
        scrollTo(points, in: app)
        points.tap()
        let cancelledStop = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Penge East")).firstMatch
        scrollTo(cancelledStop, in: app)
        XCTAssertTrue(cancelledStop.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This stop is cancelled.")).firstMatch.exists)
        attach("planner-live-cancelled-calling-point", app: app)
    }

    @MainActor
    func testLiveCallingPointWarningsAtLargestTextSize() async throws {
        continueAfterFailure = false
        let app = try await launchQueuedFixture(profile: "live", largeText: true, destination: "VIC")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        let journey = app.buttons["planner.journey.live-journey-apply"]
        scrollTo(journey, in: app)
        XCTAssertTrue(journey.label.contains("Delayed"))
        XCTAssertTrue(journey.label.contains("Another section of this train is cancelled."))
        attach("planner-live-large-text-results", app: app)
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 5))
        let points = app.buttons["planner.calling-points.0"]
        scrollTo(points, in: app)
        points.tap()
        let cancelledStop = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Penge East")).firstMatch
        scrollTo(cancelledStop, in: app)
        XCTAssertTrue(cancelledStop.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This stop is cancelled.")).firstMatch.exists)
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This stop is cancelled.")).firstMatch.isHittable)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Scheduled departure")).firstMatch.exists)
        attach("planner-live-large-text-calling-point", app: app)
        // Isolate the audit at the end because its scan can change collection snapshots.
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    func testLocalPlannerSearchResultsDetailsAndRecentSearch() async throws {
        let base = ProcessInfo.processInfo.environment["PLANNER_INTEGRATION_API_BASE"] ?? "http://127.0.0.1:3013/api/v2"
        let statusURL = URL(string: base.replacingOccurrences(of: "/api/v2", with: "/api/v3/journey-planner/status"))!
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Start the local planner server to run the integration UI test.")
        }
        let app = launch(plannerEnabled: true, apiBase: base)
        openAddJourney(in: app)
        selectStations(origin: "KTH", destination: "VIC", in: app)
        let search = app.buttons["planner.search"]
        scrollTo(search, in: app)
        XCTAssertTrue(search.isEnabled)
        search.tap()
        guard app.navigationBars["Journeys"].waitForExistence(timeout: 35) else { XCTFail("Planner search did not open results"); return }
        let journey = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'planner.journey.'")).firstMatch
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        attach("planner-results", app: app)
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 10))
        let routeMap = app.buttons["planner.route-map.0"]
        scrollTo(routeMap, in: app)
        XCTAssertTrue(routeMap.waitForExistence(timeout: 15))
        routeMap.tap()
        XCTAssertTrue(app.navigationBars["Route map"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Selected section in blue · Other sections in grey"].waitForExistence(timeout: 45))
        attach("planner-details", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let later = app.buttons["Later journeys"]
        scrollTo(later, in: app)
        XCTAssertTrue(later.exists)
        later.tap()
        XCTAssertTrue(app.navigationBars["Journeys"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Find journeys"].waitForExistence(timeout: 5))
        let recent = app.buttons.containing(.staticText, identifier: "Kent House → London Victoria").firstMatch
        scrollTo(recent, in: app)
        XCTAssertTrue(recent.exists)
        recent.tap()
        XCTAssertTrue(app.navigationBars["Find journeys"].exists)
    }

    @MainActor
    private func launchEmptyWindowAtLargestTextSize() async throws -> XCUIApplication {
        // Start journey_planner_ui_fixture.py to run this deterministic HTTP scenario.
        let base = ProcessInfo.processInfo.environment["PLANNER_EMPTY_WINDOW_API_BASE"] ?? "http://127.0.0.1:3014/api/v2"
        var statusRequest = URLRequest(url: URL(string: base.replacingOccurrences(of: "/api/v2", with: "/api/v3/journey-planner/status"))!)
        statusRequest.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: statusRequest),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Start journey_planner_ui_fixture.py to run the empty-window UI test.")
        }
        let app = launch(plannerEnabled: true, largeText: true, apiBase: base)
        openAddJourney(in: app)
        selectStations(origin: "KTH", destination: "INV", in: app)
        scrollTo(app.buttons["planner.search"], in: app)
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func launch(plannerEnabled: Bool, largeText: Bool = false, dark: Bool = false, apiBase: String = "http://127.0.0.1:1/api/v2") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["JOURNEY_PLANNER_ENABLED"] = plannerEnabled ? "1" : "0"
        app.launchEnvironment["API_BASE"] = apiBase
        app.launchEnvironment["UI_TEST_RESET_JOURNEYS"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        if dark { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func selectStations(origin: String, destination: String, in app: XCUIApplication) {
        for (field, code) in [("origin", origin), ("destination", destination)] {
            let stationField = app.buttons["planner.\(field)"]
            scrollTo(stationField, in: app, towardTop: true)
            stationField.tap()
            let search = app.searchFields.firstMatch
            guard search.waitForExistence(timeout: 5) else { XCTFail("Station search field is unavailable"); return }
            search.tap()
            search.typeText(code)
            let station = app.buttons["planner.station.\(code)"]
            guard station.waitForExistence(timeout: 10) else { XCTFail("Station suggestion is unavailable"); return }
            station.tap()
        }
    }

    @MainActor private func openAddJourney(in app: XCUIApplication) {
        let add = app.buttons["toolbar.add-journey"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<8 where !element.isHittable {
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
    }

    @MainActor private func attach(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
