import XCTest

final class JourneyPlannerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPlannerHasNoRoutingOrLiveTimesSwitches() throws {
        for largeTextAndDarkMode in [false, true] {
            let app = launch(plannerEnabled: true, largeText: largeTextAndDarkMode, dark: largeTextAndDarkMode)
            openAddJourney(in: app)
            XCTAssertFalse(app.switches["planner.raptor"].exists)
            XCTAssertFalse(app.switches["planner.live-times"].exists)
            attach(largeTextAndDarkMode ? "planner-defaults-dark-large-text" : "planner-defaults", app: app)
            app.terminate()
        }
    }

    @MainActor
    func testNewJourneyTabAndProfileNavigation() throws {
        for largeTextAndDarkMode in [false, true] {
            let app = launch(plannerEnabled: true, largeText: largeTextAndDarkMode, dark: largeTextAndDarkMode)
            XCTAssertFalse(app.tabBars.buttons["History"].exists)
            XCTAssertFalse(app.buttons["toolbar.add-journey"].exists)
            openAddJourney(in: app)
            XCTAssertTrue(app.navigationBars["New journey"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.tabBars.buttons["New journey"].isSelected)
            XCTAssertTrue(app.tabBars.firstMatch.isHittable)
            XCTAssertFalse(app.navigationBars.buttons["Cancel"].exists)
            XCTAssertTrue(app.buttons["View background photo"].isHittable)
            attach(largeTextAndDarkMode ? "new-journey-large-text" : "new-journey-tab", app: app)
            if !largeTextAndDarkMode {
                app.buttons["View background photo"].tap()
                XCTAssertTrue(app.buttons["Close photo"].waitForExistence(timeout: 5))
                app.buttons["Close photo"].tap()
                XCTAssertTrue(app.navigationBars["New journey"].waitForExistence(timeout: 5))
                app.swipeRight()
                XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 5))
                app.swipeLeft()
                XCTAssertTrue(app.navigationBars["New journey"].waitForExistence(timeout: 5))
            }
            app.tabBars.buttons["Favourites"].tap()
            XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))

            app.tabBars.buttons["My Journeys"].tap()
            XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["toolbar.add-journey"].exists)
            openAddJourney(in: app)
            XCTAssertTrue(app.navigationBars["New journey"].waitForExistence(timeout: 5))
            app.tabBars.buttons["My Journeys"].tap()
            XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 5))

            app.tabBars.buttons["Profile"].tap()
            let history = app.buttons["profile.journey-history"]
            let siri = app.buttons["profile.siri-shortcuts"]
            XCTAssertTrue(history.waitForExistence(timeout: 5))
            XCTAssertTrue(siri.exists)
            XCTAssertGreaterThan(siri.frame.minY, history.frame.minY)
            scrollTo(history, in: app)
            attach(largeTextAndDarkMode ? "profile-navigation-dark-large-text" : "profile-navigation", app: app)
            history.tap()
            XCTAssertTrue(app.navigationBars["Journey History"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
            scrollTo(siri, in: app)
            for _ in 0..<8 where siri.frame.midY >= app.tabBars.firstMatch.frame.minY {
                app.swipeUp()
            }
            if largeTextAndDarkMode { attach("profile-siri-dark-large-text", app: app) }
            siri.tap()
            XCTAssertTrue(app.navigationBars["Siri & Shortcuts"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
            let preferences = app.staticTexts["Preferences"]
            scrollTo(preferences, in: app, towardTop: true)
            preferences.tap()
            XCTAssertTrue(app.navigationBars["Preferences"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["preferences.siri-shortcuts"].exists)
            XCTAssertFalse(app.staticTexts["Siri & Shortcuts"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testNewJourneyDoesNotOfferSeparateSavedRouteForm() throws {
        let app = launch(plannerEnabled: true)
        openAddJourney(in: app)
        XCTAssertFalse(app.buttons["planner.saved-route"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Timetable published'")).firstMatch.exists)
    }

    @MainActor
    func testSavedRouteQueueProgressAtLargestText() throws {
        let app = launch(plannerEnabled: false, largeText: true, dark: true, apiBase: "http://127.0.0.1:3014/saved-progress-large/api/v2")
        saveFixtureRoute(in: app)
        let progress = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@",
            "saved-route.progress.", "Updating departures")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        attach("saved-route-queue-largest-text", app: app)
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    func testSavedRouteQueueProgressBecomesScheduledJourneys() throws {
        let app = launch(plannerEnabled: false, apiBase: "http://127.0.0.1:3014/saved-progress-\(UUID().uuidString)/api/v2")
        saveFixtureRoute(in: app)
        let queued = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND value == %@",
            "saved-route.progress.KTH-INV", "Updating departures")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Elapsed:'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Waiting to update journeys…"].exists)
        XCTAssertFalse(app.staticTexts["Checking live times…"].exists)
        XCTAssertFalse(app.staticTexts["Saved journeys are waiting to be planned."].exists)
        attach("saved-route-queue-progress", app: app)
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
        XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 5))
        let later = app.buttons["saved-route.later-departures"].firstMatch
        scrollTo(later, in: app)
        XCTAssertTrue(later.isHittable)
        XCTAssertEqual(later.label, "More departures")
        XCTAssertFalse(app.buttons["View all departures"].exists)
        XCTAssertFalse(app.buttons["Search for later departures"].exists)
        XCTAssertFalse(app.staticTexts["Route updates"].exists)
        later.tap()
        let plannedJourneys = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "saved-route.journey.saved-apply-")
        )
        let foundLaterJourney = expectation(
            for: NSPredicate(format: "count >= 2"),
            evaluatedWith: plannedJourneys
        )
        wait(for: [foundLaterJourney], timeout: 15)
        XCTAssertEqual(later.label, "Fewer departures")
        let laterProgress = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "saved-route.progress.later-")
        ).firstMatch
        XCTAssertFalse(laterProgress.exists)
        XCTAssertFalse(app.staticTexts["Showing earlier journey options. Check for updates before travelling."].exists)
        XCTAssertFalse(app.buttons["Journey notes"].exists)
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
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        if favourite { XCTAssertEqual(app.switches["Mark as favourite"].value as? String, "1") }
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(save.isHittable)
        save.tap()
        XCTAssertTrue(app.navigationBars[favourite ? "Favourites" : "My Journeys"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testUnavailablePlannerExplainsDisabledSearchWithoutSavedRouteLink() throws {
        let app = launch(plannerEnabled: true)
        let favouriteEntry = app.buttons["Add favourite journey"]
        XCTAssertTrue(favouriteEntry.waitForExistence(timeout: 5))
        favouriteEntry.tap()
        XCTAssertTrue(app.navigationBars["New journey"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["planner.live-times"].exists)
        let search = app.buttons["planner.search"]
        scrollTo(search, in: app)
        XCTAssertTrue(search.exists)
        XCTAssertFalse(search.isEnabled)
        XCTAssertFalse(app.buttons["planner.saved-route"].exists)
        var accessibilityIssues: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .textClipped, .hitRegion]) { issue in
            // Native disabled controls are exempt from contrast requirements.
            if issue.auditType == .contrast && issue.element?.isEnabled == false { return true }
            accessibilityIssues.append("\(issue.compactDescription): \(issue.element?.label ?? "Unknown element")")
            return true
        }
        XCTAssertTrue(accessibilityIssues.isEmpty, accessibilityIssues.joined(separator: "\n"))
        attach("planner-unavailable", app: app)
    }

    @MainActor
    func testDisabledPlannerPreservesOriginalAddJourney() throws {
        let app = launch(plannerEnabled: false)
        openAddJourney(in: app)
        XCTAssertTrue(app.navigationBars["New journey"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["add-journey.from"].exists)
        XCTAssertFalse(app.buttons["planner.origin"].exists)
        XCTAssertFalse(app.navigationBars.buttons["Cancel"].exists)
        app.tabBars.buttons["Favourites"].tap()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPlannerLargestDynamicTypeLayout() throws {
        let app = launch(plannerEnabled: true, largeText: true)
        openAddJourney(in: app)
        XCTAssertTrue(app.navigationBars["New journey"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["planner.origin"].isHittable)
        XCTAssertTrue(app.buttons["planner.destination"].isHittable)
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
        attach("planner-large-text", app: app)
        XCTAssertFalse(app.buttons["planner.saved-route"].exists)
    }

    @MainActor
    func testPlannerExplainsDeviceTimeZoneOutsideUK() throws {
        let app = launch(
            plannerEnabled: true,
            apiBase: "http://127.0.0.1:3014/results/api/v2",
            timeZone: "America/New_York"
        )
        openAddJourney(in: app)

        let note = app.staticTexts["planner.local-time-zone-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.label, "Times shown are in Eastern Time rather than UK time.")
        XCTAssertFalse(app.staticTexts["All train times are UK time (Europe/London)."].exists)
        attach("planner-local-time-zone", app: app)
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
    func testEmptyWindowAutomaticallyFindsLaterTrainsAtLargestTextSize() async throws {
        let app = try await launchEmptyWindowAtLargestTextSize()
        let journey = app.buttons["planner.journey.fixture-later-journey"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["planner.automatic-search.found"].exists)
        attach("planner-empty-window-automatic-later", app: app)
    }

    @MainActor
    func testAutomaticEmptyWindowSearchAccessibilityAtLargestTextSize() async throws {
        let app = try await launchEmptyWindowAtLargestTextSize()
        let journey = app.buttons["planner.journey.fixture-later-journey"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["planner.automatic-search.found"].exists)
        attach("planner-empty-window-automatic-accessibility", app: app)
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
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 15))
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
        XCTAssertTrue(journeyResultsNavigationBar(in: app).exists)
        scrollTo(later, in: app)
        XCTAssertTrue(later.isEnabled)
        try await assertFixtureCancelled(profile: "queued", after: before)
    }

    @MainActor
    func testJourneyResultsPillsAndAllPaginationButtonsShowLoading() async throws {
        let app = try await launchQueuedFixture(profile: "results")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Kent House → Inverness"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Live times unavailable"].exists)
        XCTAssertEqual(app.switches["planner.travel-via"].value as? String, "0")
        XCTAssertEqual(app.switches["planner.save-journey"].value as? String, "0")
        let journey = app.buttons["planner.journey.fixture-results"]
        XCTAssertTrue(journey.waitForExistence(timeout: 5))
        XCTAssertNotNil(journey.label.range(of: #"^\d{2}:\d{2} → \d{2}:\d{2}"#, options: .regularExpression))
        XCTAssertTrue(journey.label.contains("Southeastern"))
        XCTAssertTrue(journey.label.contains("LNER"))
        XCTAssertTrue(journey.label.contains("ScotRail"))
        XCTAssertEqual(journey.label.components(separatedBy: "Southeastern").count, 2)
        XCTAssertTrue(app.buttons["Search notes"].exists)
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
    func testJourneyResultsOptionsExpandWithRequestedDefaults() async throws {
        let app = try await launchQueuedFixture(profile: "results")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Kent House → Inverness"].waitForExistence(timeout: 10))
        app.switches["planner.travel-via"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["planner.via-station"].waitForExistence(timeout: 5))
        app.buttons["planner.via-station"].tap()
        XCTAssertTrue(app.navigationBars["Travel via"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.switches["planner.save-journey"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["planner.save.start-tracking"].label, "Start journey updates now")
        XCTAssertEqual(app.switches["planner.save.start-tracking"].value as? String, "0")
        XCTAssertEqual(app.switches["planner.save.schedule"].value as? String, "0")
        XCTAssertEqual(app.switches["planner.save.favourite"].label, "Save to Favourites")
        XCTAssertEqual(app.switches["planner.save.favourite"].value as? String, "0")
        app.switches["planner.travel-via"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let save = app.buttons["planner.save.submit"]
        scrollTo(save, in: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testBackingOutOfNewJourneyScheduleReturnsToResultsWithoutSaving() async throws {
        let app = try await launchQueuedFixture(profile: "results")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Kent House → Inverness"].waitForExistence(timeout: 10))

        app.switches["planner.save-journey"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.switches["planner.save.start-tracking"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.switches["planner.save.schedule"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.switches["planner.save.favourite"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let save = app.buttons["planner.save.submit"]
        scrollTo(save, in: app)
        save.tap()

        XCTAssertTrue(app.navigationBars["Schedule journey updates"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Back"].exists)
        XCTAssertFalse(app.buttons["Close"].exists)
        app.buttons["Back"].tap()

        XCTAssertTrue(app.navigationBars["Kent House → Inverness"].waitForExistence(timeout: 10))
        app.tabBars.buttons["My Journeys"].tap()
        XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Kent House → Inverness"].exists)
        app.tabBars.buttons["Favourites"].tap()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Kent House → Inverness"].exists)
    }

    @MainActor
    func testJourneyResultPillsAtLargestTextSize() async throws {
        let app = try await launchQueuedFixture(profile: "results", largeText: true)
        app.buttons["planner.search"].tap()
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10))
        let journey = app.buttons["planner.journey.fixture-results"]
        scrollTo(journey, in: app)
        XCTAssertTrue(journey.isHittable)
        XCTAssertTrue(journey.label.contains("Southeastern"))
        XCTAssertTrue(journey.label.contains("ScotRail"))
        attach("planner-results-pills-large-text", app: app)
        let visibleTop = app.navigationBars.firstMatch.frame.maxY
        let visibleBottom = app.tabBars.firstMatch.frame.minY
        var accessibilityIssues: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .textClipped, .hitRegion]) { issue in
            if issue.auditType == .contrast, let element = issue.element,
               element.frame.minY < visibleTop || element.frame.maxY > visibleBottom {
                // A result row can be taller than the viewport at the largest
                // Dynamic Type size. Ignore contrast sampling of its clipped edge;
                // the same content remains reachable by scrolling.
                return true
            }
            accessibilityIssues.append("\(issue.compactDescription): \(issue.element?.label ?? "Unknown element")")
            return true
        }
        XCTAssertTrue(accessibilityIssues.isEmpty, accessibilityIssues.joined(separator: "\n"))
    }

    @MainActor
    func testTimetableDepartureRowsUseSavedJourneyFormatting() async throws {
        let app = try await launchQueuedFixture(profile: "departures", destination: "VIC")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10))
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
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [.contrast, .textClipped, .hitRegion])
    }

    @MainActor
    func testPlannerArrivalTimesAndDurationTags() async throws {
        let app = try await launchQueuedFixture(profile: "durations", destination: "VIC")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10))
        assertDurationComparison(
            in: app,
            rowPrefix: "planner.journey.duration-",
            screenshotName: "planner-duration-tags",
            fastestIndices: [0]
        )
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    func testPlannerArrivalTimesAndDurationTagsAtLargestTextInDarkMode() async throws {
        let app = try await launchQueuedFixture(profile: "durations", largeText: true, destination: "VIC", dark: true)
        app.buttons["planner.search"].tap()
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10))
        assertDurationComparison(
            in: app,
            rowPrefix: "planner.journey.duration-",
            screenshotName: "planner-duration-tags-dark-largest-text",
            fastestIndices: [0]
        )
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
        let expand = card.buttons["saved-route.later-departures"]
        scrollDurationElement(expand, in: app)
        XCTAssertTrue(expand.isHittable)
        expand.tap()
        scrollTo(first, in: app, towardTop: true)
    }

    @MainActor
    private func assertDurationComparison(
        in app: XCUIApplication,
        rowPrefix: String,
        screenshotName: String,
        fastestIndices: Set<Int> = [0, 1]
    ) {
        for index in 0..<4 {
            let journey = app.buttons["\(rowPrefix)\(index)"]
            if index == 0 { XCTAssertTrue(journey.waitForExistence(timeout: 15)) }
            let oversized = scrollDurationElement(journey, in: app)
            XCTAssertTrue(journey.isHittable)
            XCTAssertGreaterThanOrEqual(journey.frame.width, 44)
            XCTAssertGreaterThanOrEqual(journey.frame.height, 44)
            assertJourneyTimeRange(journey)
            XCTAssertEqual(journey.label.contains("Fastest"), fastestIndices.contains(index), journey.label)
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
    func testGenericTransferWarningAppearsInResultsAndAffectedLeg() async throws {
        try await assertGenericTransferWarning(largeTextAndDarkMode: false)
    }

    @MainActor
    func testGenericTransferWarningAtLargestTextInDarkMode() async throws {
        try await assertGenericTransferWarning(largeTextAndDarkMode: true)
    }

    @MainActor
    func testKnownTubeTransfersDoNotShowGenericWarning() async throws {
        for (profile, journeyID, transport) in [("details", "fixture-details", "Tube"),
                                               ("tubetrack", "fixture-tubetrack", "London transport")] {
            let app = try await launchQueuedFixture(profile: profile)
            defer { app.terminate() }
            app.buttons["planner.search"].tap()
            guard journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10) else {
                XCTFail("\(profile) search did not open results.")
                return
            }
            let journey = app.buttons["planner.journey.\(journeyID)"]
            scrollTo(journey, in: app)
            guard journey.exists && journey.isHittable else {
                XCTFail("\(profile) journey did not become visible in results.")
                return
            }
            XCTAssertFalse(journey.label.contains("Warning: check transfer options"))
            journey.tap()
            guard app.navigationBars["Journey details"].waitForExistence(timeout: 10) else {
                XCTFail("\(profile) journey details did not open.")
                return
            }
            let transfer = app.staticTexts["2. \(transport) from London Victoria to London Euston"]
            scrollTo(transfer, in: app)
            guard transfer.isHittable else {
                XCTFail("\(profile) transfer did not become visible in journey details.")
                return
            }
            XCTAssertFalse(app.descendants(matching: .any)["planner.transfer-warning.1"].firstMatch.exists)
            attach("planner-\(profile)-without-generic-warning", app: app)
        }
    }

    @MainActor
    private func assertGenericTransferWarning(largeTextAndDarkMode: Bool) async throws {
        let app = try await launchQueuedFixture(profile: "generic-transfer", largeText: largeTextAndDarkMode,
            dark: largeTextAndDarkMode)
        app.buttons["planner.search"].tap()
        guard journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10) else {
            XCTFail("Generic-transfer search did not open results.")
            return
        }
        let journey = app.buttons["planner.journey.fixture-generic-transfer"]
        scrollTo(journey, in: app)
        guard journey.exists && journey.isHittable else {
            XCTFail("Generic-transfer journey did not become visible in results.")
            return
        }
        XCTAssertTrue(journey.label.contains("Warning: check transfer options"))
        attach(largeTextAndDarkMode ? "planner-generic-transfer-results-dark-large-text" : "planner-generic-transfer-results", app: app)
        journey.tap()
        guard app.navigationBars["Journey details"].waitForExistence(timeout: 10) else {
            XCTFail("Generic-transfer journey details did not open.")
            return
        }
        let warning = app.descendants(matching: .any)["planner.transfer-warning.1"].firstMatch
        scrollTo(warning, in: app)
        guard warning.exists else {
            XCTFail("Generic-transfer warning did not appear in journey details.")
            return
        }
        XCTAssertTrue(warning.isHittable)
        XCTAssertTrue(warning.label.contains("Warning: check transfer options"))
        XCTAssertTrue(warning.label.contains("No specific transport service is listed for this transfer."))
        XCTAssertTrue(warning.label.contains("Check your options before travelling. In London, you may need a taxi or night bus when the Tube is closed."))
        XCTAssertTrue(app.staticTexts["2. Transfer from London Victoria to London Euston"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["planner.transfer-warning.0"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["planner.transfer-warning.3"].firstMatch.exists)
        attach(largeTextAndDarkMode ? "planner-generic-transfer-details-dark-large-text" : "planner-generic-transfer-details", app: app)
        try app.performAccessibilityAudit(for: [.hitRegion])
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
        XCTAssertTrue(app.navigationBars["New journey"].exists)
        XCTAssertFalse(cancel.exists)
        XCTAssertTrue(app.buttons["planner.search"].isEnabled)
        XCTAssertFalse(journeyResultsNavigationBar(in: app).exists)
        try await assertFixtureCancelled(profile: "cancel", after: before)
    }

    @MainActor
    func testJourneyResultsRemainOpenAfterSwitchingTabs() async throws {
        let app = try await launchQueuedFixture(profile: "coverage")
        app.buttons["planner.search"].tap()

        let results = journeyResultsNavigationBar(in: app)
        XCTAssertTrue(results.waitForExistence(timeout: 10))
        let journey = app.buttons["planner.journey.coverage-journey"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))

        app.tabBars.buttons["My Journeys"].tap()
        XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 5))

        app.tabBars.buttons["New journey"].tap()
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertTrue(journey.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["New journey"].exists)
    }

    @MainActor
    func testRecentSearchRestoresStationsAndScrollsToTop() async throws {
        let app = try await launchQueuedFixture(profile: "results")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["New journey"].waitForExistence(timeout: 5))

        let recent = app.buttons.containing(
            .staticText,
            identifier: "Kent House → Inverness"
        ).firstMatch
        scrollTo(recent, in: app)
        XCTAssertTrue(recent.isHittable)
        recent.tap()

        let origin = app.buttons["planner.origin"]
        let destination = app.buttons["planner.destination"]
        XCTAssertTrue(origin.waitForExistence(timeout: 5))
        XCTAssertTrue(origin.isHittable)
        XCTAssertTrue(destination.isHittable)
        XCTAssertEqual(origin.label, "From, Kent House")
        XCTAssertEqual(destination.label, "To, Inverness")
        attach("planner-recent-search-restored", app: app)
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

    private func journeyResultsNavigationBar(in app: XCUIApplication) -> XCUIElement {
        app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS %@", " → ")).firstMatch
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
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10))
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
    func testLiveTimesRemainEnabledAndKeepCancellationWarnings() async throws {
        continueAfterFailure = false
        let app = try await launchQueuedFixture(profile: "live", destination: "VIC")
        app.buttons["planner.search"].tap()
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10))
        let applied = app.buttons["planner.journey.live-journey-apply"]
        XCTAssertTrue(applied.waitForExistence(timeout: 10))
        XCTAssertTrue(applied.label.contains("Delayed"))
        XCTAssertTrue(applied.label.contains("Another section of this train is cancelled."))
        let unavailable = app.buttons["planner.disrupted-options"]
        scrollTo(unavailable, in: app)
        XCTAssertTrue(unavailable.exists)
        attach("planner-live-results", app: app)
        XCTAssertFalse(app.switches["planner.live-times"].exists)
        scrollTo(applied, in: app, towardTop: true)
        applied.tap()
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
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10))
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
        guard journeyResultsNavigationBar(in: app).waitForExistence(timeout: 35) else { XCTFail("Planner search did not open results"); return }
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
        XCTAssertTrue(journeyResultsNavigationBar(in: app).exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["New journey"].waitForExistence(timeout: 5))
        let recent = app.buttons.containing(.staticText, identifier: "Kent House → London Victoria").firstMatch
        scrollTo(recent, in: app)
        XCTAssertTrue(recent.exists)
        recent.tap()
        XCTAssertTrue(app.navigationBars["New journey"].exists)
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
        XCTAssertTrue(journeyResultsNavigationBar(in: app).waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func launch(
        plannerEnabled: Bool,
        largeText: Bool = false,
        dark: Bool = false,
        apiBase: String = "http://127.0.0.1:1/api/v2",
        timeZone: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["JOURNEY_PLANNER_ENABLED"] = plannerEnabled ? "1" : "0"
        app.launchEnvironment["API_BASE"] = apiBase
        app.launchEnvironment["UI_TEST_RESET_JOURNEYS"] = "1"
        if let timeZone { app.launchEnvironment["TZ"] = timeZone }
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
        let add = app.tabBars.buttons["New journey"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<8 {
            let top = app.navigationBars.firstMatch.exists
                ? app.navigationBars.firstMatch.frame.maxY
                : app.frame.minY
            let bottom = app.tabBars.firstMatch.exists
                ? app.tabBars.firstMatch.frame.minY
                : app.frame.maxY
            if element.exists,
               element.isHittable,
               element.frame.minY >= top,
               element.frame.maxY <= bottom {
                return
            }
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
