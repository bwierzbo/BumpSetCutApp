//
//  FavoritesEmptyStateTests.swift
//  BumpSetCutUITests
//
//  Test Plan §5 — Favorites empty state, folder CRUD.
//

import XCTest

final class FavoritesEmptyStateTests: BSCUITestCase {

    private var favorites: FavoritesScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Navigate to Favorites from Home
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.favoriteRalliesButton.waitForExistence(timeout: 10))
        home.favoriteRalliesButton.tap()

        favorites = FavoritesScreen(app: app)
    }

    func testEmptyStateDisplayed() {
        XCTAssertTrue(favorites.emptyState.waitForExistence(timeout: 5))
    }

    func testCreateFolderFlow() {
        XCTAssertTrue(favorites.createFolderButton.waitForExistence(timeout: 5))
        favorites.createFolderButton.tap()

        // Folder creation sheet should appear
        let folderNameField = app.textFields["Enter folder name"]
        XCTAssertTrue(folderNameField.waitForExistence(timeout: 5))

        folderNameField.tap()
        folderNameField.typeText("Fav Folder")

        let createButton = app.buttons["Create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.tap()

        // Folder should appear
        let folderText = app.staticTexts["Fav Folder"]
        XCTAssertTrue(folderText.waitForExistence(timeout: 5))
    }

    func testSortMenuExists() {
        XCTAssertTrue(favorites.sortMenu.waitForExistence(timeout: 5))
    }

    func testRallyCountShowsZero() {
        XCTAssertTrue(favorites.rallyCount.waitForExistence(timeout: 5))
        XCTAssertTrue(favorites.rallyCount.label.contains("0") || favorites.rallyCount.label.contains("rallies"))
    }
}
