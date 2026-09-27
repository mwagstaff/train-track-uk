import XCTest

final class WatchRoutesUITests: XCTestCase {
    @MainActor
    func testFavouritesDeparturesAndServiceDetails() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-watch-preview-data"]
        app.launch()
        XCTAssertTrue(app.buttons["Favourites"].waitForExistence(timeout: 10))
        capture("Watch home")
        app.buttons["Favourites"].tap()
        let route = app.buttons.containing(.staticText, identifier: "Kent House").firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        capture("Favourites")
        route.tap()
        XCTAssertTrue(app.staticTexts["On time"].waitForExistence(timeout: 10))
        capture("Departures")
        app.buttons.containing(.staticText, identifier: "On time").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["8 cars"].waitForExistence(timeout: 5))
        capture("Service details")
    }

    @MainActor
    func testMyJourneysAndEmptyState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-watch-preview-data"]
        app.launch()
        app.buttons["My Journeys"].tap()
        XCTAssertTrue(app.staticTexts["Via London Victoria"].waitForExistence(timeout: 5))
        capture("My Journeys")
        app.buttons.containing(.staticText, identifier: "Kent House").firstMatch.tap()
        let connection = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 change")).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10))
        capture("Journey with a change")
        app.terminate()
        app.launchArguments = ["-watch-preview-data", "-watch-empty-routes"]
        app.launch()
        app.buttons["Favourites"].tap()
        XCTAssertTrue(app.staticTexts["No favourites yet"].waitForExistence(timeout: 5))
        capture("No favourites")
    }

    @MainActor
    func testLargeTextRoutesRemainAccessible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-watch-preview-data", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        app.launch()
        app.buttons["Favourites"].tap()
        let route = app.buttons.containing(.staticText, identifier: "Kent House").firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        capture("Large text routes")
        route.tap()
        XCTAssertTrue(app.staticTexts["On time"].waitForExistence(timeout: 10))
        capture("Large text departures")
    }

    @MainActor
    func testWidgetDepartureLinkOpensBoard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-watch-preview-data"]
        app.launchEnvironment["WATCH_LAUNCH_URL"] = "traintrack://in-progress?from=KTH&to=VIC&watch=departures"
        app.launch()
        XCTAssertTrue(app.staticTexts["On time"].waitForExistence(timeout: 10))
        capture("Widget departure link")
    }

    @MainActor
    func testWidgetProgressLinkAndJourneyControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-watch-preview-data", "-watch-in-progress"]
        app.launchEnvironment["WATCH_LAUNCH_URL"] = "traintrack://in-progress?from=ECR&to=BTN&watch=progress"
        app.launch()
        XCTAssertTrue(app.staticTexts["Journey underway"].waitForExistence(timeout: 10))
        capture("In progress header")
        for _ in 0..<12 where !app.staticTexts["ETA TBC (delayed)"].isHittable { scrollALittle(app) }
        XCTAssertTrue(app.staticTexts["ETA TBC (delayed)"].exists)
        scrollALittle(app)
        capture("In progress status")
        for _ in 0..<12 where !app.buttons["I’ve arrived at Brighton"].isHittable { scrollALittle(app) }
        app.buttons["I’ve arrived at Brighton"].tap()
        XCTAssertTrue(app.buttons["Yes, I’m here"].waitForExistence(timeout: 5))
        app.buttons["AX_ActionContentControllerCancelButton"].firstMatch.tap()
        for _ in 0..<12 where !app.buttons["Change the train I’m on"].isHittable { scrollALittle(app) }
        app.buttons["Change the train I’m on"].tap()
        XCTAssertTrue(app.staticTexts["23:52"].waitForExistence(timeout: 5))
        capture("Change train")
        app.buttons["BackButton"].tap()
        for _ in 0..<12 where !app.buttons["End journey"].isHittable { scrollALittle(app) }
        app.buttons["End journey"].tap()
        XCTAssertTrue(app.staticTexts["End journey?"].waitForExistence(timeout: 5))
        capture("End journey confirmation")
        app.buttons["AX_ActionContentControllerCancelButton"].firstMatch.tap()
    }

    @MainActor
    private func scrollALittle(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)), withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
