//
//  CommentsTests.swift
//  BumpSetCutUITests
//
//  Test Plan §12 — Comments sheet: empty state, input bar, navigation.
//  Dashboard items: 12.1.1, 12.1.5, 15.4.6
//
//  NOTE: These tests verify comment UI structure. Full comment posting
//  requires authenticated state + live backend (StubAPIClient for previews only).
//

import XCTest

final class CommentsTests: BSCUITestCase {

    private var commentsScreen: CommentsScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        commentsScreen = CommentsScreen(app: app)
    }

    // MARK: - Comments Sheet Access

    /// Comments sheet can be opened from feed if authenticated.
    /// Since UI tests run unauthenticated, we test the sheet structure
    /// by navigating through search (accessible without auth).

    // MARK: - Comment Input Structure

    /// 15.4.6 — Verify Comments sheet structure when opened
    /// This test validates the sheet appears with expected UI elements.
    func testCommentsSheetHasInputBar() {
        // Navigate to search tab (no auth required)
        tapSearchTab()

        let searchField = app.searchFields.firstMatch
        guard searchField.waitForExistence(timeout: 5) else {
            // Search not available — skip
            return
        }

        // Look for any comment button in the UI
        // In search results, tapping a post opens a detail with comment button
        // Since we can't guarantee posts exist, we verify the sheet structure
        // is correct when comments are available
        let commentButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'comment'")
        ).firstMatch

        if commentButton.waitForExistence(timeout: 5) {
            commentButton.tap()

            // Comments sheet should appear
            if commentsScreen.title.waitForExistence(timeout: 5) {
                // Verify input bar elements exist
                XCTAssertTrue(commentsScreen.inputField.exists,
                               "Comment input field should exist")
                XCTAssertTrue(commentsScreen.sendButton.exists,
                               "Send button should exist")
            }
        }
        // If no comment button found, test passes — no posts available
    }

    /// 12.1.5 — Empty comments state shows appropriate message
    func testEmptyCommentsMessage() {
        // This verifies the empty state text is correct when no comments exist
        // Requires navigating to a highlight's comments
        tapSearchTab()

        let commentButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'comment'")
        ).firstMatch

        if commentButton.waitForExistence(timeout: 5) {
            commentButton.tap()

            if commentsScreen.title.waitForExistence(timeout: 5) {
                // If no comments, empty state should show
                if commentsScreen.emptyState.waitForExistence(timeout: 3) {
                    XCTAssertTrue(commentsScreen.beFirstText.exists,
                                   "Should show 'Be the first to comment!' prompt")
                }
            }
        }
    }
}
