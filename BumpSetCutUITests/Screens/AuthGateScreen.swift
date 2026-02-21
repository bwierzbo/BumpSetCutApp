//
//  AuthGateScreen.swift
//  BumpSetCutUITests
//
//  Page object for the AuthGate sign-in/sign-up screen.
//

import XCTest

struct AuthGateScreen {
    let app: XCUIApplication

    var signInButton: XCUIElement {
        app.buttons["authGate.emailSignIn"]
    }

    var skipButton: XCUIElement {
        app.buttons["authGate.skip"]
    }

    var toggleModeButton: XCUIElement {
        app.buttons["authGate.toggleMode"]
    }

    var emailField: XCUIElement {
        app.textFields["authGate.email"]
    }

    var passwordField: XCUIElement {
        app.secureTextFields["authGate.password"]
    }

    var usernameField: XCUIElement {
        app.textFields["authGate.username"]
    }

    var confirmPasswordField: XCUIElement {
        app.secureTextFields["authGate.confirmPassword"]
    }

    var forgotPasswordButton: XCUIElement {
        app.buttons["authGate.forgotPassword"]
    }

    var joinTitle: XCUIElement {
        app.staticTexts["Join the Community"]
    }
}
