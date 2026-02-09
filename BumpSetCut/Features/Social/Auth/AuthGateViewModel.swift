//
//  AuthGateViewModel.swift
//  BumpSetCut
//
//  Wraps AuthenticationService for the auth gate sign-in flow.
//

import SwiftUI
import Observation

@MainActor @Observable
class AuthGateViewModel {
    let authService: AuthenticationService
    var errorMessage: String?
    var showError = false

    // Email form state
    var email = ""
    var password = ""
    var displayName = ""
    var isSignUpMode = true

    init(authService: AuthenticationService) {
        self.authService = authService
    }

    var isAuthenticating: Bool { authService.authState == .authenticating }
    var isAuthenticated: Bool { authService.authState == .authenticated }

    var isEmailValid: Bool { email.contains("@") && email.contains(".") }
    var hasMinLength: Bool { password.count >= 12 }
    var hasUppercase: Bool { password.range(of: "[A-Z]", options: .regularExpression) != nil }
    var hasNumber: Bool { password.range(of: "[0-9]", options: .regularExpression) != nil }
    var hasSymbol: Bool { password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil }
    var isPasswordValid: Bool { hasMinLength && hasUppercase && hasNumber && hasSymbol }

    var isEmailFormValid: Bool {
        if isSignUpMode {
            return isEmailValid && isPasswordValid && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return isEmailValid && password.count >= 1
    }

    func signInWithApple() async {
        errorMessage = nil
        do {
            try await authService.signInWithApple()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func signUpWithEmail() async {
        errorMessage = nil
        do {
            try await authService.signUpWithEmail(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password,
                displayName: displayName.trimmingCharacters(in: .whitespaces)
            )
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func signInWithEmail() async {
        errorMessage = nil
        do {
            try await authService.signInWithEmail(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func signInWithGoogle() async {
        errorMessage = nil
        do {
            try await authService.signInWithGoogle()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
