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

    var saveToLibraryButton: XCUIElement {
        app.buttons["process.saveToLibrary"]
    }

    var viewRalliesButton: XCUIElement {
        app.buttons["process.viewRallies"]
    }

    var doneButton: XCUIElement {
        app.buttons["process.doneButton"]
    }
}
