//
//  HomeScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Home screen.
//  Note: BSCIconButton is a compound SwiftUI view. Some button IDs may have
//  multiple accessibility matches. Use .firstMatch when tapping to avoid crashes.
//

import XCTest

struct HomeScreen {
    let app: XCUIApplication

    var viewLibraryButton: XCUIElement {
        app.descendants(matching: .any)["home.viewLibrary"].firstMatch
    }

    var favoriteRalliesButton: XCUIElement {
        app.descendants(matching: .any)["home.favoriteRallies"].firstMatch
    }

    var settingsButton: XCUIElement {
        app.descendants(matching: .any)["home.settings"].firstMatch
    }

    var uploadButton: XCUIElement {
        app.descendants(matching: .any)["home.upload"].firstMatch
    }

    var processButton: XCUIElement {
        app.descendants(matching: .any)["home.process"].firstMatch
    }

    var helpButton: XCUIElement {
        app.descendants(matching: .any)["home.help"].firstMatch
    }

    var statsCard: XCUIElement {
        app.descendants(matching: .any)["home.statsCard"]
    }
}
