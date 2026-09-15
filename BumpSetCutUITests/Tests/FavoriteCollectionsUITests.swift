//
//  FavoriteCollectionsUITests.swift
//  BumpSetCutUITests
//
//  Favorite collections: the favorite toast's "Choose Folder" affordance opens
//  the collection picker, where a collection can be created inline.
//

import XCTest

final class FavoriteCollectionsUITests: PreProcessedVideoTestCase {

    // Multi-rally fixture: favoriting the FIRST rally auto-advances to the
    // next one, leaving the toast (and its Choose Folder button) on top.
    // With a single-rally fixture the overview sheet would cover the toast.
    override var testVideoName: String { "5plusrallies" }
    override var testMetadataName: String { "5plusrallies_metadata" }

    /// Swipe-favorite → "Choose Folder" on the toast → picker → create a
    /// collection inline → confirm files the rally into it.
    func testChooseFolderFromFavoriteToast() {
        openRallyPlayer()

        let rallyPlayer = RallyPlayerScreen(app: app)
        rallyPlayer.favoriteButton.tap()

        // Favorite toast appears with the Choose Folder affordance (3.5s window).
        let chooseFolder = app.buttons["rallyPlayer.chooseFolder"]
        XCTAssertTrue(chooseFolder.waitForExistence(timeout: 3),
                      "Favorite toast should offer Choose Folder")
        chooseFolder.tap()

        // Collection picker sheet opens.
        let confirmButton = app.buttons["collectionPicker.confirm"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5),
                      "Collection picker should open from the toast")

        // Create a collection inline.
        let createButton = app.buttons["collectionPicker.createFolder"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.tap()

        let nameField = app.textFields["collectionPicker.newFolderField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Weekend Reel")

        app.buttons["Create"].tap()

        // Back on the picker with the new collection selected; confirm.
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmButton.label.contains("Weekend Reel"),
                      "New collection should be selected after inline create")
        confirmButton.tap()

        // Picker dismisses back to the player.
        let counterBack = rallyPlayer.rallyCounter.waitForExistence(timeout: 5)
        XCTAssertTrue(counterBack, "Player should be visible after choosing a collection")
    }
}
