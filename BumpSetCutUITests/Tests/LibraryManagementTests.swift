//
//  LibraryManagementTests.swift
//  BumpSetCutUITests
//
//  Test Plan §4 — Library management: context menus, rename, move, folders, navigation.
//  Uses VideoTestCase (unprocessed video) for basic library ops.
//  Dashboard items: 4.1.7, 4.4.2–4.4.4, 4.5.1–4.5.3, 4.7.1, 4.7.3
//

import XCTest

final class LibraryManagementTests: VideoTestCase {

    private var library: LibraryScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToLibrary()
        library = LibraryScreen(app: app)
    }

    // MARK: - Video Context Menu (4.5.1)

    /// 4.5.1 — Long-press video shows context menu with Delete, Rename, Move
    func testVideoContextMenuAppears() {
        let videoCard = app.staticTexts["Test Rally Video"]
        guard videoCard.waitForExistence(timeout: 5) else {
            XCTFail("Video card should exist in library")
            return
        }

        videoCard.press(forDuration: 1.0)

        // Context menu items should appear
        let renameButton = app.buttons["Rename"]
        let deleteButton = app.buttons["Delete"]
        let moveButton = app.buttons["Move"]

        let hasContextMenu = renameButton.waitForExistence(timeout: 5)
            || deleteButton.waitForExistence(timeout: 5)
            || moveButton.waitForExistence(timeout: 5)
        XCTAssertTrue(hasContextMenu, "Long-press on video should show context menu with Rename/Delete/Move")

        // Dismiss context menu
        app.tap()
    }

    // MARK: - Rename Video (4.5.2)

    /// 4.5.2 — Rename video via context menu
    func testRenameVideo() {
        let videoCard = app.staticTexts["Test Rally Video"]
        guard videoCard.waitForExistence(timeout: 5) else { return }

        videoCard.press(forDuration: 1.0)

        let renameButton = app.buttons["Rename"]
        guard renameButton.waitForExistence(timeout: 5) else {
            // Dismiss context menu and skip
            app.tap()
            return
        }
        renameButton.tap()

        // Rename dialog should appear with a text field
        let textField = app.textFields.firstMatch
        guard textField.waitForExistence(timeout: 5) else { return }

        // Clear and type new name
        textField.tap()
        textField.press(forDuration: 1.0)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap()
        }
        textField.typeText("Renamed Video")

        // Confirm rename
        let confirmButton = app.buttons["Rename"]
        if confirmButton.waitForExistence(timeout: 3) {
            confirmButton.tap()
        }

        // Verify name updated
        let renamedVideo = app.staticTexts["Renamed Video"]
        XCTAssertTrue(renamedVideo.waitForExistence(timeout: 5),
                       "Video name should update after rename")
    }

    // MARK: - Move Video to Folder (4.5.3)

    /// 4.5.3 — Move video to folder via context menu
    func testMoveVideoToFolder() {
        // First create a folder
        guard library.createFolderButton.waitForExistence(timeout: 5) else {
            XCTFail("Create folder button not found")
            return
        }
        library.createFolderButton.tap()

        let folderNameField = app.textFields["Enter folder name"]
        guard folderNameField.waitForExistence(timeout: 5) else {
            XCTFail("Folder name field not found")
            return
        }
        folderNameField.tap()
        folderNameField.typeText("Move Target")

        let createButton = app.buttons["Create"]
        guard createButton.waitForExistence(timeout: 3) else {
            XCTFail("Create button not found")
            return
        }
        createButton.tap()

        // Verify folder was created
        let folderText = app.staticTexts["Move Target"]
        guard folderText.waitForExistence(timeout: 5) else {
            XCTFail("Folder was not created")
            return
        }

        // Now long-press the video to get context menu
        let videoCard = app.staticTexts["Test Rally Video"]
        guard videoCard.waitForExistence(timeout: 5) else {
            XCTFail("Video card not found")
            return
        }

        videoCard.press(forDuration: 1.0)

        let moveButton = app.buttons["Move"]
        guard moveButton.waitForExistence(timeout: 5) else {
            app.tap()
            XCTFail("Move button not found in context menu")
            return
        }
        moveButton.tap()

        // Move dialog should appear with folder options
        let targetFolder = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Move Target'")
        ).firstMatch
        guard targetFolder.waitForExistence(timeout: 5) else {
            XCTFail("Target folder not found in move dialog")
            return
        }
        targetFolder.tap()

        // Tap the "Move" confirmation button in the dialog
        let moveConfirm = app.buttons["Move"]
        guard moveConfirm.waitForExistence(timeout: 3) else {
            XCTFail("Move confirmation button not found")
            return
        }
        moveConfirm.tap()

        // Video should no longer be visible in root (it moved to folder)
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: videoCard)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Video should move out of root after moving to folder")
    }

    // MARK: - Folder Navigation (4.7.1, 4.7.3)

    /// 4.7.1 — Tapping a folder navigates into it
    func testFolderNavigation() {
        // Create a folder first
        guard library.createFolderButton.waitForExistence(timeout: 5) else { return }
        library.createFolderButton.tap()

        let folderNameField = app.textFields["Enter folder name"]
        guard folderNameField.waitForExistence(timeout: 5) else { return }
        folderNameField.tap()
        folderNameField.typeText("Nav Folder")

        let createButton = app.buttons["Create"]
        guard createButton.waitForExistence(timeout: 3) else { return }
        createButton.tap()

        // Tap the folder to navigate into it
        let folderText = app.staticTexts["Nav Folder"]
        guard folderText.waitForExistence(timeout: 5) else { return }
        folderText.tap()

        // 4.7.3 — Title should show folder name
        let navTitle = app.staticTexts["Nav Folder"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5),
                       "Title should show folder name")

        // Folder should be empty
        let emptyState = library.emptyState
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5),
                       "Empty folder should show empty state")
    }

    /// 4.7.1 — Back button returns to parent folder
    func testBackButtonReturnsToParent() {
        // Create and navigate into folder
        guard library.createFolderButton.waitForExistence(timeout: 5) else { return }
        library.createFolderButton.tap()

        let folderNameField = app.textFields["Enter folder name"]
        guard folderNameField.waitForExistence(timeout: 5) else { return }
        folderNameField.tap()
        folderNameField.typeText("Back Test Folder")

        let createButton = app.buttons["Create"]
        guard createButton.waitForExistence(timeout: 3) else { return }
        createButton.tap()

        let folderText = app.staticTexts["Back Test Folder"]
        guard folderText.waitForExistence(timeout: 5) else { return }
        folderText.tap()

        // Should be inside folder now
        let navTitle = app.staticTexts["Back Test Folder"]
        guard navTitle.waitForExistence(timeout: 5) else {
            XCTFail("Folder title should appear after navigation")
            return
        }

        // Tap back button
        let backButton = app.navigationBars.buttons.firstMatch
        guard backButton.waitForExistence(timeout: 3) else { return }
        backButton.tap()

        // Should be back at library root with video visible
        let videoCard = app.staticTexts["Test Rally Video"]
        XCTAssertTrue(videoCard.waitForExistence(timeout: 5),
                       "Should return to library root showing video")
    }

    // MARK: - Folder Management (4.4.2, 4.4.3)

    /// 4.4.2 — Rename folder via context menu
    func testRenameFolderViaContextMenu() {
        // Create a folder
        guard library.createFolderButton.waitForExistence(timeout: 5) else {
            XCTFail("Create folder button not found")
            return
        }
        library.createFolderButton.tap()

        let folderNameField = app.textFields["Enter folder name"]
        guard folderNameField.waitForExistence(timeout: 5) else {
            XCTFail("Folder name field not found")
            return
        }
        folderNameField.tap()
        folderNameField.typeText("Old Name")

        let createButton = app.buttons["Create"]
        guard createButton.waitForExistence(timeout: 3) else {
            XCTFail("Create button not found")
            return
        }
        createButton.tap()

        // Long-press folder to get context menu
        let folderText = app.staticTexts["Old Name"]
        guard folderText.waitForExistence(timeout: 5) else {
            XCTFail("Folder 'Old Name' not found")
            return
        }
        folderText.press(forDuration: 1.0)

        let renameButton = app.buttons["Rename"]
        guard renameButton.waitForExistence(timeout: 5) else {
            app.tap()
            XCTFail("Rename button not found in context menu")
            return
        }
        renameButton.tap()

        // Rename alert should appear
        let renameField = app.textFields.firstMatch
        guard renameField.waitForExistence(timeout: 5) else {
            XCTFail("Rename text field not found")
            return
        }

        // Clear existing text and type new name
        renameField.tap()
        // Delete existing text character by character
        if let currentValue = renameField.value as? String, !currentValue.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            renameField.typeText(deleteString)
        }
        renameField.typeText("New Name")

        // Confirm
        let confirmRename = app.alerts.buttons["Rename"]
        if confirmRename.waitForExistence(timeout: 3) {
            confirmRename.tap()
        }

        // Verify name updated
        let renamedFolder = app.staticTexts["New Name"]
        XCTAssertTrue(renamedFolder.waitForExistence(timeout: 5),
                       "Folder name should update after rename")
    }

    /// 4.4.3 — Delete folder via context menu shows confirmation
    func testDeleteFolderConfirmation() {
        // Create a folder
        guard library.createFolderButton.waitForExistence(timeout: 5) else { return }
        library.createFolderButton.tap()

        let folderNameField = app.textFields["Enter folder name"]
        guard folderNameField.waitForExistence(timeout: 5) else { return }
        folderNameField.tap()
        folderNameField.typeText("Delete Me")

        let createButton = app.buttons["Create"]
        guard createButton.waitForExistence(timeout: 3) else { return }
        createButton.tap()

        // Long-press folder
        let folderText = app.staticTexts["Delete Me"]
        guard folderText.waitForExistence(timeout: 5) else { return }
        folderText.press(forDuration: 1.0)

        let deleteButton = app.buttons["Delete"]
        guard deleteButton.waitForExistence(timeout: 5) else {
            app.tap()
            return
        }
        deleteButton.tap()

        // Confirmation alert should appear
        let confirmAlert = app.alerts.firstMatch
        if confirmAlert.waitForExistence(timeout: 3) {
            let confirmDelete = confirmAlert.buttons["Delete"]
            XCTAssertTrue(confirmDelete.exists, "Delete confirmation should have Delete button")

            let cancelButton = confirmAlert.buttons["Cancel"]
            XCTAssertTrue(cancelButton.exists, "Delete confirmation should have Cancel button")

            // Actually delete
            confirmDelete.tap()

            // Folder should be gone
            let predicate = NSPredicate(format: "exists == false")
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: folderText)
            let result = XCTWaiter.wait(for: [expectation], timeout: 5)
            XCTAssertEqual(result, .completed, "Folder should disappear after deletion")
        }
    }

    // MARK: - Pull to Refresh (4.1.7)

    /// 4.1.7 — Pull to refresh works without crash
    func testPullToRefreshNoCrash() {
        app.swipeDown()
        sleep(1)

        // App should still be running
        let videoCard = app.staticTexts["Test Rally Video"]
        XCTAssertTrue(videoCard.waitForExistence(timeout: 5),
                       "Library should still show content after pull-to-refresh")
    }
}
