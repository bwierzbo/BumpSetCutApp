//
//  FavoritesScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Favorites screen.
//

import XCTest

struct FavoritesScreen {
    let app: XCUIApplication

    var emptyState: XCUIElement {
        app.descendants(matching: .any)["favorites.emptyState"]
    }

    var sortMenu: XCUIElement {
        app.buttons["favorites.sortMenu"]
    }

    var createFolderButton: XCUIElement {
        app.buttons["favorites.createFolder"]
    }

    var rallyCount: XCUIElement {
        app.descendants(matching: .any)["favorites.rallyCount"]
    }

    // Feed elements
    var feedCloseButton: XCUIElement {
        app.buttons["favorites.feed.close"]
    }

    var feedCounter: XCUIElement {
        app.descendants(matching: .any)["favorites.feed.counter"]
    }

    var feedPauseIcon: XCUIElement {
        app.images["favorites.feed.pauseIcon"]
    }

    var feedVideoName: XCUIElement {
        app.descendants(matching: .any)["favorites.feed.videoName"]
    }
}
