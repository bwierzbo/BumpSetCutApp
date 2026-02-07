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

    init(authService: AuthenticationService) {
        self.authService = authService
    }

    var isAuthenticating: Bool { authService.authState == .authenticating }
    var isAuthenticated: Bool { authService.authState == .authenticated }

    func signInWithApple() async {
        errorMessage = nil
        do {
            try await authService.signInWithApple()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
