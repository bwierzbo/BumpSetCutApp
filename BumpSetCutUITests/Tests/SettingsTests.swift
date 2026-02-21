//
//  SettingsTests.swift
//  BumpSetCutUITests
//
//  Test Plan §14 — Settings screen elements and interactions.
//

import XCTest

final class SettingsTests: BSCUITestCase {

    private var settings: SettingsScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Navigate to Settings
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.settingsButton.waitForExistence(timeout: 10))
        home.settingsButton.tap()

        settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.doneButton.waitForExistence(timeout: 5))
    }

    func testAllSectionsAreVisible() {
        // .textCase(.uppercase) only changes rendering — XCUITest sees the original text
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Processing"].exists)
        XCTAssertTrue(app.staticTexts["Privacy"].exists)

        // Legal & About — may need to scroll
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Legal"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["About"].exists)
    }

    func testThemePickerButtons() {
        XCTAssertTrue(settings.themeLightButton.waitForExistence(timeout: 3))
        XCTAssertTrue(settings.themeDarkButton.exists)
        XCTAssertTrue(settings.themeSystemButton.exists)

        // Tap light theme
        settings.themeLightButton.tap()
        sleep(1)

        // Tap dark theme
        settings.themeDarkButton.tap()
        sleep(1)

        // Tap system theme
        settings.themeSystemButton.tap()
    }

    func testThoroughAnalysisToggleIsTappable() {
        XCTAssertTrue(settings.thoroughAnalysisToggle.waitForExistence(timeout: 3))
        settings.thoroughAnalysisToggle.tap()
    }

    func testAnalyticsToggleIsTappable() {
        XCTAssertTrue(settings.analyticsToggle.waitForExistence(timeout: 3))
        settings.analyticsToggle.tap()
    }

    func testLegalLinksAreVisible() {
        app.swipeUp()
        XCTAssertTrue(settings.privacyPolicyButton.waitForExistence(timeout: 3))
        XCTAssertTrue(settings.termsOfServiceButton.exists)
        XCTAssertTrue(settings.communityGuidelinesButton.exists)
    }

    func testAboutSectionShowsAppInfo() {
        app.swipeUp()
        XCTAssertTrue(settings.appName.waitForExistence(timeout: 3))
        XCTAssertTrue(settings.appVersion.exists)
    }

    func testDoneButtonDismissesSettings() {
        settings.doneButton.tap()

        // Settings should be dismissed — Home should be visible
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.viewLibraryButton.waitForExistence(timeout: 5))
    }
}
