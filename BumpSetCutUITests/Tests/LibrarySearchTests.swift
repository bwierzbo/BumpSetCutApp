//
//  LibrarySearchTests.swift
//  BumpSetCutUITests
//
//  Tests for library search and view toggle.
//  Dashboard items: 4.1.6
//

import XCTest

final class LibrarySearchTests: VideoTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToLibrary()
    }

    // MARK: - 4.1.6 — Search bar filters videos by name

    func testSearchBarExists() {
        // Search bar should be visible in the library
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 5),
            "Search bar should be visible in library"
        )
    }

    func testSearchFiltersVideos() {
        let searchField = app.searchFields.firstMatch
        guard searchField.waitForExistence(timeout: 5) else {
            XCTFail("Search bar not found")
            return
        }

        // Type the video name — should still show the test video
        searchField.tap()
        searchField.typeText("Test Rally")

        // Video should still be visible (matches search)
        let videoName = app.staticTexts["Test Rally Video"]
        XCTAssertTrue(
            videoName.waitForExistence(timeout: 5),
            "Video matching search should remain visible"
        )
    }

    func testSearchNoResults() {
        let searchField = app.searchFields.firstMatch
        guard searchField.waitForExistence(timeout: 5) else {
            XCTFail("Search bar not found")
            return
        }

        // Search for something that doesn't exist
        searchField.tap()
        searchField.typeText("zzzznonexistentvideo")

        // Test video should disappear
        let videoName = app.staticTexts["Test Rally Video"]
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: videoName)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, "Non-matching videos should be hidden by search filter")
    }
}
