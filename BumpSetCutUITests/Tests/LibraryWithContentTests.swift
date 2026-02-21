//
//  LibraryWithContentTests.swift
//  BumpSetCutUITests
//
//  Test Plan §4 — Library interactions with a video present.
//

import XCTest

final class LibraryWithContentTests: VideoTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToLibrary()
    }

    func testLibraryNotEmpty() {
        // Empty state should NOT be visible
        let emptyState = app.descendants(matching: .any)["library.emptyState"]
        XCTAssertFalse(emptyState.waitForExistence(timeout: 3), "Library should not show empty state")

        // Video card should be visible
        let videoName = app.staticTexts["Test Rally Video"]
        XCTAssertTrue(videoName.waitForExistence(timeout: 3), "Video card should be visible")
    }

    func testFilterUnprocessed() {
        let libraryScreen = LibraryScreen(app: app)

        // Tap "Unprocessed" filter
        if libraryScreen.filterUnprocessed.waitForExistence(timeout: 3) {
            libraryScreen.filterUnprocessed.tap()

            // Test video is unprocessed, should still be visible
            let videoName = app.staticTexts["Test Rally Video"]
            XCTAssertTrue(videoName.waitForExistence(timeout: 3), "Unprocessed video should appear under Unprocessed filter")
        }

        // Tap "Processed" filter
        if libraryScreen.filterProcessed.waitForExistence(timeout: 3) {
            libraryScreen.filterProcessed.tap()

            // Test video is NOT processed, should not be visible
            let videoName = app.staticTexts["Test Rally Video"]
            let predicate = NSPredicate(format: "exists == false")
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: videoName)
            let result = XCTWaiter.wait(for: [expectation], timeout: 5)
            XCTAssertEqual(result, .completed, "Unprocessed video should be hidden under Processed filter")
        }
    }

    func testSortMenuOpens() {
        let libraryScreen = LibraryScreen(app: app)

        if libraryScreen.sortMenu.waitForExistence(timeout: 3) {
            libraryScreen.sortMenu.tap()

            // Sort options should appear (e.g., Date, Name, Size)
            let dateOption = app.buttons["Date"]
            let nameOption = app.buttons["Name"]
            let anyOption = dateOption.exists || nameOption.exists
            XCTAssertTrue(anyOption, "Sort menu should show sorting options")
        }
    }

    // MARK: - Additional Tests

    func testProcessWithAIButton() {
        // Tap the brain icon (quick process button) on the video card
        let processButton = app.buttons["Process with AI"]
        XCTAssertTrue(processButton.waitForExistence(timeout: 5), "Process with AI button should exist on unprocessed video")
        processButton.tap()

        let title = app.staticTexts["Rally Detection"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Tapping Process with AI should open Rally Detection screen")
    }

    func testFilterAllShowsVideo() {
        let libraryScreen = LibraryScreen(app: app)

        if libraryScreen.filterAll.waitForExistence(timeout: 3) {
            libraryScreen.filterAll.tap()

            let videoName = app.staticTexts["Test Rally Video"]
            XCTAssertTrue(videoName.waitForExistence(timeout: 3), "Video should be visible under All filter")
        }
    }

    func testCreateFolderButton() {
        let libraryScreen = LibraryScreen(app: app)

        if libraryScreen.createFolderButton.waitForExistence(timeout: 3) {
            libraryScreen.createFolderButton.tap()

            // Folder name field should appear
            XCTAssertTrue(
                libraryScreen.folderNameField.waitForExistence(timeout: 3),
                "Folder name field should appear after tapping Create Folder"
            )
        }
    }

    func testVideoCountDisplayed() {
        // At least one video exists, verify the library shows content
        let videoName = app.staticTexts["Test Rally Video"]
        XCTAssertTrue(videoName.waitForExistence(timeout: 3), "Library should display the test video")
    }
}
