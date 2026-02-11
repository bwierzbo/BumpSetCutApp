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
    var username = ""
    var isSignUpMode = true

    // Username availability
    var isUsernameAvailable: Bool?
    var isCheckingUsername = false
    private var checkTask: Task<Void, Never>?
    private let apiClient: any APIClient

    init(authService: AuthenticationService, apiClient: (any APIClient)? = nil) {
        self.authService = authService
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    var isAuthenticating: Bool { authService.authState == .authenticating }
    var isAuthenticated: Bool { authService.authState == .authenticated }

    var isEmailValid: Bool { email.contains("@") && email.contains(".") }
    var hasMinLength: Bool { password.count >= 12 }
    var hasUppercase: Bool { password.range(of: "[A-Z]", options: .regularExpression) != nil }
    var hasNumber: Bool { password.range(of: "[0-9]", options: .regularExpression) != nil }
    var hasSymbol: Bool { password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil }
    var isPasswordValid: Bool { hasMinLength && hasUppercase && hasNumber && hasSymbol }

    var isUsernameValidFormat: Bool {
        let pattern = /^[A-Za-z0-9_]{3,20}$/
        return username.wholeMatch(of: pattern) != nil && !username.hasPrefix("user_")
    }

    var isEmailFormValid: Bool {
        if isSignUpMode {
            return isEmailValid && isPasswordValid && isUsernameAvailable == true
        }
        return isEmailValid && password.count >= 1
    }

    // MARK: - Username Availability

    func usernameChanged() {
        checkTask?.cancel()
        isUsernameAvailable = nil

        guard isUsernameValidFormat else {
            isCheckingUsername = false
            return
        }

        isCheckingUsername = true
        let target = username
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, username == target else { return }
            do {
                let result: UsernameAvailability = try await apiClient.request(
                    .checkUsernameAvailability(username: target)
                )
                guard !Task.isCancelled, username == target else { return }
                isUsernameAvailable = result.isAvailable
            } catch {
                guard !Task.isCancelled else { return }
                isUsernameAvailable = nil
            }
            isCheckingUsername = false
        }
    }

    // MARK: - Auth Actions

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
                username: username.trimmingCharacters(in: .whitespaces)
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
