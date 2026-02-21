//
//  LibraryEmptyStateTests.swift
//  BumpSetCutUITests
//
//  Test Plan §4 — Library empty state, folder CRUD, filters.
//

import XCTest

final class LibraryEmptyStateTests: BSCUITestCase {

    private var library: LibraryScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Navigate to Library from Home
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.viewLibraryButton.waitForExistence(timeout: 10))
        home.viewLibraryButton.tap()

        library = LibraryScreen(app: app)
    }

    func testEmptyStateDisplayed() {
        // On a fresh test install the library should be empty
        XCTAssertTrue(library.emptyState.waitForExistence(timeout: 5))
    }

    func testSortMenuExists() {
        XCTAssertTrue(library.sortMenu.waitForExistence(timeout: 5))
    }

    func testSortMenuIsTappable() {
        XCTAssertTrue(library.sortMenu.waitForExistence(timeout: 5))
        library.sortMenu.tap()
        // Menu should appear — dismiss it
        app.tap()
    }

    func testCreateFolderFlow() {
        XCTAssertTrue(library.createFolderButton.waitForExistence(timeout: 5))
        library.createFolderButton.tap()

        // Folder creation sheet should appear with text field
        let folderNameField = app.textFields["Enter folder name"]
        XCTAssertTrue(folderNameField.waitForExistence(timeout: 5))

        folderNameField.tap()
        folderNameField.typeText("Test Folder")

        // Tap Create
        let createButton = app.buttons["Create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.tap()

        // Folder should now appear in the library
        let folderText = app.staticTexts["Test Folder"]
        XCTAssertTrue(folderText.waitForExistence(timeout: 5))
    }

    func testFilterChipsVisible() {
        XCTAssertTrue(library.filterAll.waitForExistence(timeout: 5))
        XCTAssertTrue(library.filterProcessed.exists)
        XCTAssertTrue(library.filterUnprocessed.exists)
    }
}
