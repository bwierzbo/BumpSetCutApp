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

    /// "Skip" on the setup page that is showing (trim, camera position, court, net).
    var setupSkipButton: XCUIElement {
        app.buttons["process.setupSkip"]
    }

    /// "Step 2 of 4", on the setup page that is showing.
    var setupProgress: XCUIElement {
        app.descendants(matching: .any)["process.setupProgress"]
    }

    /// Start processing the way a user who sets nothing up does: tap Start, then Skip every setup page, so
    /// processing begins on the original video.
    func startProcessing() {
        startButton.tap()
        XCTAssertTrue(setupSkipButton.waitForExistence(timeout: 10), "The setup pages should appear after Start AI Processing")
        var pages = 0
        while setupSkipButton.waitForExistence(timeout: 5), pages < 6 {
            setupSkipButton.tap()
            pages += 1
        }
        XCTAssertEqual(pages, 4, "Start AI Processing leads through four setup pages")
    }
}
