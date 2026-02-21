//
//  SocialFeedScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Social Feed screen.
//

import XCTest

struct SocialFeedScreen {
    let app: XCUIApplication

    var forYouTab: XCUIElement {
        app.buttons["feed.forYou"]
    }

    var followingTab: XCUIElement {
        app.buttons["feed.following"]
    }

    var emptyState: XCUIElement {
        app.descendants(matching: .any)["feed.emptyState"]
    }

    var refreshButton: XCUIElement {
        app.buttons["feed.refresh"]
    }

    var noHighlightsText: XCUIElement {
        app.staticTexts["No highlights yet"]
    }

    var noFollowingText: XCUIElement {
        app.staticTexts["No highlights from followed users"]
    }
}
