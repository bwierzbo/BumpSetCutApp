//
//  RallyPlayerScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Rally Player screen.
//

import XCTest

struct RallyPlayerScreen {
    let app: XCUIApplication

    var backButton: XCUIElement {
        app.buttons["rallyPlayer.back"]
    }

    var rallyCounter: XCUIElement {
        app.buttons["rallyPlayer.counter"]
    }

    var helpButton: XCUIElement {
        app.buttons["rallyPlayer.help"]
    }

    var removeButton: XCUIElement {
        app.buttons["rallyPlayer.remove"]
    }

    var undoButton: XCUIElement {
        app.buttons["rallyPlayer.undo"]
    }

    var saveButton: XCUIElement {
        app.buttons["rallyPlayer.save"]
    }

    var favoriteButton: XCUIElement {
        app.buttons["rallyPlayer.favorite"]
    }
}
