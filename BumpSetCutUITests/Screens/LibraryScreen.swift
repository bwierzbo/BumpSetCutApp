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

extension XCUIApplication {
    /// A library video or folder card. Cards are single button elements whose
    /// label starts with the item's name ("Name, Ready, 0:42…" /
    /// "Name folder, 3 videos"), so their text isn't a separate element.
    func libraryCard(named name: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }
}
