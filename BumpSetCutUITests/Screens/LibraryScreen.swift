//
//  LibraryScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Library screen.
//

import XCTest

struct LibraryScreen {
    let app: XCUIApplication

    var emptyState: XCUIElement {
        app.descendants(matching: .any)["library.emptyState"]
    }

    var sortMenu: XCUIElement {
        app.buttons["library.sortMenu"]
    }

    var createFolderButton: XCUIElement {
        app.buttons["library.createFolder"]
    }

    var folderNameField: XCUIElement {
        app.descendants(matching: .any)["library.folderNameField"]
    }

    var filterAll: XCUIElement {
        app.descendants(matching: .any)["library.filter.all"]
    }

    var filterProcessed: XCUIElement {
        app.descendants(matching: .any)["library.filter.processed"]
    }

    var filterUnprocessed: XCUIElement {
        app.descendants(matching: .any)["library.filter.unprocessed"]
    }
}
