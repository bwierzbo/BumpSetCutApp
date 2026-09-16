//
//  ProcessScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Process Video screen.
//

import XCTest

struct ProcessScreen {
    let app: XCUIApplication

    var startButton: XCUIElement {
        app.buttons["process.startButton"]
    }

    var cancelButton: XCUIElement {
        app.buttons["process.cancelButton"]
    }

    var viewRalliesButton: XCUIElement {
        app.buttons["process.viewRallies"]
    }

    var doneButton: XCUIElement {
        app.buttons["process.doneButton"]
    }

    /// "Skip" on the pre-trim sheet that "Start AI Processing" opens.
    var preTrimSkipButton: XCUIElement {
        app.buttons["Skip"]
    }

    /// Start processing the way a user does: tap Start, then Skip the
    /// pre-trim step so processing begins on the original video.
    func startProcessing() {
        startButton.tap()
        XCTAssertTrue(
            preTrimSkipButton.waitForExistence(timeout: 10),
            "Pre-trim sheet should appear after Start AI Processing"
        )
        preTrimSkipButton.tap()
    }
}
