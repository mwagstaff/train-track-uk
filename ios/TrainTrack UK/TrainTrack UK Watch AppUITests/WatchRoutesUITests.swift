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
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
