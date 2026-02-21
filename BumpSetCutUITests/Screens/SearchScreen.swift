//
//  SearchScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Search Community screen.
//

import XCTest

struct SearchScreen {
    let app: XCUIApplication

    var searchField: XCUIElement {
        app.searchFields.firstMatch
    }

    var trendingHeader: XCUIElement {
        app.staticTexts["search.trending"]
    }

    var emptyResult: XCUIElement {
        app.staticTexts["search.emptyResult"]
    }

    var noUsersFound: XCUIElement {
        app.staticTexts["No users found"]
    }

    var noPostsFound: XCUIElement {
        app.staticTexts["No posts found"]
    }
}
