//
//  HomeTests.swift
//  BumpSetCutUITests
//
//  Test Plan §2 — Home screen elements and navigation.
//

import XCTest

final class HomeTests: BSCUITestCase {

    func testViewLibraryButtonExists() {
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.viewLibraryButton.waitForExistence(timeout: 10))
    }

    func testViewLibraryNavigatesToLibrary() {
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.viewLibraryButton.waitForExistence(timeout: 10))
        home.viewLibraryButton.tap()

        // Should navigate to Library — look for library content
        let libraryTitle = app.staticTexts["Library"]
        XCTAssertTrue(libraryTitle.waitForExistence(timeout: 5))
    }

    func testFavoriteRalliesButtonExists() {
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.favoriteRalliesButton.waitForExistence(timeout: 10))
    }

    func testFavoriteRalliesNavigatesToFavorites() {
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.favoriteRalliesButton.waitForExistence(timeout: 10))
        home.favoriteRalliesButton.tap()

        // Should navigate to favorites — look for title
        let favoritesTitle = app.staticTexts["Favorite Rallies"]
        XCTAssertTrue(favoritesTitle.waitForExistence(timeout: 5))
    }

    func testSettingsButtonOpensSettings() {
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.settingsButton.waitForExistence(timeout: 10))
        home.settingsButton.tap()

        // Settings sheet should appear
        let settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.doneButton.waitForExistence(timeout: 5))
    }

    func testHelpButtonOpensOnboarding() {
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.helpButton.waitForExistence(timeout: 10))
        home.helpButton.tap()

        // Onboarding should appear
        let onboarding = OnboardingScreen(app: app)
        XCTAssertTrue(onboarding.skipButton.waitForExistence(timeout: 5))
    }

    func testQuickActionsAreVisible() {
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.uploadButton.waitForExistence(timeout: 10))
        XCTAssertTrue(home.processButton.exists)
        XCTAssertTrue(home.helpButton.exists)
    }

    func testStatsCardIsDisplayed() {
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.statsCard.waitForExistence(timeout: 10))
    }
}
