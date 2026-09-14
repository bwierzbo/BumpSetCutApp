//
//  TimelineEditorTests.swift
//  BumpSetCutUITests
//
//  Smoke test for the rally timeline editor: open from the overview sheet,
//  add a rally in a detection gap, save, and confirm the player reloads
//  with the new rally count. Uses the norallies.mov fixture (5.6s) with
//  timeline_metadata.json (two rallies at 0.8-2.2s and 3.4-4.6s).
//

import XCTest

final class TimelineEditorTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAddRallyOnTimeline() throws {
        let bundle = Bundle(for: type(of: self))
        guard let videoURL = bundle.url(forResource: "norallies", withExtension: "mov"),
              let metadataURL = bundle.url(forResource: "timeline_metadata", withExtension: "json") else {
            throw XCTSkip("timeline fixture not in test bundle")
        }

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--skip-onboarding", "--clear-library"]
        app.launchEnvironment["TEST_VIDEO_PATH"] = videoURL.path
        app.launchEnvironment["TEST_METADATA_PATH"] = metadataURL.path
        app.launch()

        // Home → Library → rally player
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.viewLibraryButton.waitForExistence(timeout: 10))
        home.viewLibraryButton.tap()

        let viewRallies = app.buttons["View Processed Rallies"]
        XCTAssertTrue(viewRallies.waitForExistence(timeout: 5))
        viewRallies.tap()

        let player = RallyPlayerScreen(app: app)
        XCTAssertTrue(player.rallyCounter.waitForExistence(timeout: 10))

        // Overview sheet → timeline editor
        player.rallyCounter.tap()
        let editTimeline = app.buttons["Add or Fix Rallies"]
        XCTAssertTrue(editTimeline.waitForExistence(timeout: 5))
        editTimeline.tap()

        let addRally = app.buttons["Add Rally"]
        XCTAssertTrue(addRally.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 rallies"].waitForExistence(timeout: 5))
        sleep(2)
        shoot(app, "timeline_initial")

        // Playhead starts on the first rally — Add is disabled there.
        XCTAssertFalse(addRally.isEnabled)

        // Tap the middle of the track (the 2.2-3.4s gap) and add a rally.
        let track = app.descendants(matching: .any)["timeline.track"].firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(addRally.isEnabled)
        addRally.tap()

        XCTAssertTrue(app.staticTexts["3 rallies"].waitForExistence(timeout: 5))
        shoot(app, "timeline_added")

        // Save → back to the player, reloaded with 3 rallies.
        app.buttons["Save"].tap()
        XCTAssertTrue(player.rallyCounter.waitForExistence(timeout: 10))
        sleep(2)
        shoot(app, "player_after_save")

        // Reopen the editor: the saved manual rally must round-trip.
        player.rallyCounter.tap()
        XCTAssertTrue(editTimeline.waitForExistence(timeout: 5))
        editTimeline.tap()
        XCTAssertTrue(app.staticTexts["3 rallies"].waitForExistence(timeout: 10))
        shoot(app, "timeline_reopened")
    }
}
