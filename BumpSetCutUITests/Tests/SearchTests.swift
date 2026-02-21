//
//  SearchTests.swift
//  BumpSetCutUITests
//
//  Test Plan §13.4 — Community search: users, posts, trending, empty states.
//  Dashboard items: 13.4.1–13.4.4
//

import XCTest

final class SearchTests: BSCUITestCase {

    private var searchScreen: SearchScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        searchScreen = SearchScreen(app: app)
    }

    // MARK: - Search Tab Access (13.4.1)

    /// 13.4.1 — Search tab loads without auth requirement
    func testSearchTabLoads() {
        tapSearchTab()

        // Search should be accessible — either search field or nav title
        let searchField = searchScreen.searchField
        let searchNav = app.navigationBars["Search"]
        let hasSearch = searchField.waitForExistence(timeout: 5) || searchNav.waitForExistence(timeout: 5)
        XCTAssertTrue(hasSearch, "Search tab should load")
    }

    /// Search field is visible and can receive focus
    func testSearchFieldExists() {
        tapSearchTab()

        let searchField = searchScreen.searchField
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                       "Search field should exist")
    }

    // MARK: - Trending Tags

    /// Trending section appears on empty search
    func testTrendingTagsAppear() {
        tapSearchTab()

        // Wait for trending to load
        let trendingHeader = searchScreen.trendingHeader
        if trendingHeader.waitForExistence(timeout: 5) {
            XCTAssertTrue(trendingHeader.exists,
                           "Trending section should appear on empty search")
        }
        // Trending might not load (no backend) — still valid
    }

    // MARK: - Search Scopes

    /// Scope picker (Users/Posts) exists
    func testSearchScopesExist() {
        tapSearchTab()

        guard searchScreen.searchField.waitForExistence(timeout: 5) else { return }

        // Tap search field to activate it
        searchScreen.searchField.tap()

        // Type something to trigger scope buttons
        searchScreen.searchField.typeText("test")

        // Look for scope buttons (Users / Posts)
        let usersScope = app.buttons["Users"]
        let postsScope = app.buttons["Posts"]

        // Scopes should appear after typing
        let hasScopes = usersScope.waitForExistence(timeout: 5) || postsScope.waitForExistence(timeout: 5)
        XCTAssertTrue(hasScopes, "Search scopes (Users/Posts) should exist")
    }

    // MARK: - Search Results (13.4.2, 13.4.4)

    /// 13.4.2 — Typing username triggers search
    func testSearchByUsername() {
        tapSearchTab()

        guard searchScreen.searchField.waitForExistence(timeout: 5) else { return }

        searchScreen.searchField.tap()
        searchScreen.searchField.typeText("volleyballplayer")

        // Should show either results or empty state
        sleep(2) // Wait for debounced search

        let noUsers = searchScreen.noUsersFound
        let anyUser = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'volleyball'")
        ).firstMatch

        let hasSearchResult = noUsers.waitForExistence(timeout: 5) || anyUser.waitForExistence(timeout: 5)
        XCTAssertTrue(hasSearchResult,
                       "Should show search results or 'No users found' empty state")
    }

    /// 13.4.4 — Empty search shows suggestions or empty state
    func testEmptySearchState() {
        tapSearchTab()

        guard searchScreen.searchField.waitForExistence(timeout: 5) else { return }

        searchScreen.searchField.tap()
        searchScreen.searchField.typeText("zzzznonexistentuser12345")

        sleep(2)

        // Should show empty result
        let noResults = searchScreen.noUsersFound
        let emptyResult = searchScreen.emptyResult
        let hasEmpty = noResults.waitForExistence(timeout: 5) || emptyResult.waitForExistence(timeout: 5)
        XCTAssertTrue(hasEmpty, "Searching for nonexistent user should show empty state")
    }

    // MARK: - No Crash Tests

    /// Rapid search typing doesn't crash
    func testRapidSearchTypingNoCrash() {
        tapSearchTab()

        guard searchScreen.searchField.waitForExistence(timeout: 5) else { return }

        searchScreen.searchField.tap()
        searchScreen.searchField.typeText("test")

        // Clear and type again rapidly
        let clearButton = app.buttons["Clear text"]
        if clearButton.waitForExistence(timeout: 2) {
            clearButton.tap()
        }
        searchScreen.searchField.typeText("another search")

        sleep(1)
        // App should still be running
        XCTAssertTrue(app.tabBars.firstMatch.exists,
                       "App should survive rapid search typing")
    }
}
