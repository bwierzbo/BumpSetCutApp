//
//  ProfileScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Profile screen.
//

import XCTest

struct ProfileScreen {
    let app: XCUIApplication

    var username: XCUIElement {
        app.staticTexts["profile.username"]
    }

    var bio: XCUIElement {
        app.staticTexts["profile.bio"]
    }

    var editProfileButton: XCUIElement {
        app.buttons["profile.editProfile"]
    }

    var signOutButton: XCUIElement {
        app.buttons["profile.signOut"]
    }

    var followButton: XCUIElement {
        app.buttons["profile.follow"]
    }

    var highlightsCount: XCUIElement {
        app.descendants(matching: .any)["profile.highlightsCount"]
    }

    var followersCount: XCUIElement {
        app.descendants(matching: .any)["profile.followersCount"]
    }

    var followingCount: XCUIElement {
        app.descendants(matching: .any)["profile.followingCount"]
    }
}
