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

    var settingsButton: XCUIElement {
        app.buttons["profile.settings"]
    }

    /// Sign Out is a row in the Settings sheet, opened from the gear.
    var signOutButton: XCUIElement {
        app.buttons["settings.signOut"]
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
