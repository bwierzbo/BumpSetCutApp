//
//  HomeScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Home screen.
//

import XCTest

struct HomeScreen {
    let app: XCUIApplication

    var viewLibraryButton: XCUIElement {
        app.descendants(matching: .any)["home.viewLibrary"]
    }

    var favoriteRalliesButton: XCUIElement {
        app.descendants(matching: .any)["home.favoriteRallies"]
    }

    var settingsButton: XCUIElement {
        app.buttons["home.settings"]
    }

    var uploadButton: XCUIElement {
        app.descendants(matching: .any)["home.upload"]
    }

    var processButton: XCUIElement {
        app.descendants(matching: .any)["home.process"]
    }

    var helpButton: XCUIElement {
        app.descendants(matching: .any)["home.help"]
    }

    var statsCard: XCUIElement {
        app.descendants(matching: .any)["home.statsCard"]
    }
}
