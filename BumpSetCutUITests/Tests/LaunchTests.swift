//
//  LaunchTests.swift
//  BumpSetCutUITests
//
//  Test Plan §1.1 — App launches without crash, tab bar visible.
//

import XCTest

final class LaunchTests: BSCUITestCase {

    func testAppLaunchesSuccessfully() {
        // App should launch and show the tab bar
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
    }

    func testTabBarShowsFourTabs() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        XCTAssertTrue(tabBar.buttons["Home"].exists)
        XCTAssertTrue(tabBar.buttons["Feed"].exists)
        XCTAssertTrue(tabBar.buttons["Search"].exists)
        XCTAssertTrue(tabBar.buttons["Profile"].exists)
    }

    func testHomeTabIsSelectedByDefault() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        let homeTab = tabBar.buttons["Home"]
        XCTAssertTrue(homeTab.isSelected)
    }
}
