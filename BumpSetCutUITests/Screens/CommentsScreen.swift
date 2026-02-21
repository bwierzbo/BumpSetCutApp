//
//  CommentsScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Comments sheet.
//

import XCTest

struct CommentsScreen {
    let app: XCUIApplication

    var title: XCUIElement {
        app.navigationBars["Comments"]
    }

    var inputField: XCUIElement {
        app.textFields["comments.input"]
    }

    var sendButton: XCUIElement {
        app.buttons["comments.send"]
    }

    var emptyState: XCUIElement {
        app.staticTexts["comments.emptyState"]
    }

    var noCommentsText: XCUIElement {
        app.staticTexts["No comments yet"]
    }

    var beFirstText: XCUIElement {
        app.staticTexts["Be the first to comment!"]
    }
}
