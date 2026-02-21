//
//  TabNavigationTests.swift
//  BumpSetCutUITests
//
//  Test Plan §1.1 — Tab navigation behavior.
//

import XCTest

final class TabNavigationTests: BSCUITestCase {

    func testAllTabsAreTappable() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        tabBar.buttons["Feed"].tap()
        XCTAssertTrue(tabBar.buttons["Feed"].isSelected)

        tabBar.buttons["Search"].tap()
        XCTAssertTrue(tabBar.buttons["Search"].isSelected)

        tabBar.buttons["Profile"].tap()
        XCTAssertTrue(tabBar.buttons["Profile"].isSelected)

        tabBar.buttons["Home"].tap()
        XCTAssertTrue(tabBar.buttons["Home"].isSelected)
    }

    func testSearchTabLoads() {
        tapSearchTab()

        // Search tab should show search UI — the tab should be selected
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["Search"].isSelected)
    }

    func testSwitchingTabsPreservesState() {
        // Start on Home
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.viewLibraryButton.waitForExistence(timeout: 10))

        // Switch to Search
        tapSearchTab()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["Search"].waitForExistence(timeout: 5))

        // Switch back to Home
        tapHomeTab()

        // Home content should still be there
        XCTAssertTrue(home.viewLibraryButton.waitForExistence(timeout: 5))
    }
}
