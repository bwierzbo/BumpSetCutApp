//
//  AuthGateViewModel.swift
//  BumpSetCut
//
//  Wraps AuthenticationService for the auth gate sign-in flow.
//

import SwiftUI
import Observation
import Auth

@MainActor @Observable
class AuthGateViewModel {
    let authService: AuthenticationService
    var errorMessage: String?
    var showError = false

    // Email form state
    var email = ""
    var password = ""
    var confirmPassword = ""
    var username = ""
    var isSignUpMode = false

    // Forgot password
    var showForgotPasswordSent = false

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
    var hasMinLength: Bool { password.count >= 8 }
    var hasUppercase: Bool { password.range(of: "[A-Z]", options: .regularExpression) != nil }
    var hasNumber: Bool { password.range(of: "[0-9]", options: .regularExpression) != nil }
    var hasSymbol: Bool { password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil }
    var isPasswordValid: Bool { hasMinLength && hasUppercase && hasNumber && hasSymbol }
    var passwordsMatch: Bool { password == confirmPassword && !confirmPassword.isEmpty }

    var isUsernameValidFormat: Bool {
        let pattern = /^[A-Za-z0-9_]{3,20}$/
        return username.wholeMatch(of: pattern) != nil && !username.hasPrefix("user_")
    }

    var isEmailFormValid: Bool {
        if isSignUpMode {
            // Allow submit if username format is valid and not actively known to be taken.
            // If the availability check failed (nil due to network), let server enforce uniqueness.
            return isEmailValid && isPasswordValid && passwordsMatch
                && isUsernameValidFormat && !isCheckingUsername && isUsernameAvailable != false
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
                print("[Auth] Username check failed: \(error)")
                isUsernameAvailable = nil
            }
            isCheckingUsername = false
        }
    }

    // MARK: - Auth Actions

    func signUpWithEmail() async {
        errorMessage = nil
        do {
            try await authService.signUpWithEmail(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password,
                username: username.trimmingCharacters(in: .whitespaces)
            )
        } catch {
            print("[Auth] Email sign-up error: \(error)")
            errorMessage = userFriendlyMessage(for: error)
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
            print("[Auth] Email sign-in error: \(error)")
            errorMessage = userFriendlyMessage(for: error)
            showError = true
        }
    }

    func forgotPassword() async {
        guard isEmailValid else {
            errorMessage = "Please enter your email address first."
            showError = true
            return
        }
        do {
            try await authService.resetPassword(email: email.trimmingCharacters(in: .whitespaces))
            showForgotPasswordSent = true
        } catch {
            print("[Auth] Reset password error: \(error)")
            errorMessage = userFriendlyMessage(for: error)
            showError = true
        }
    }

    // MARK: - Error Formatting

    private func userFriendlyMessage(for error: Error) -> String {
        if let authError = error as? AuthError,
           case .api(let message, _, _, let response) = authError {
            // Only treat infrastructure errors as "server down"
            let code = response.statusCode
            if code == 502 || code == 503 || code == 522 {
                return "Server is temporarily unavailable. Please try again in a few minutes."
            }
            // For other API errors, show the Supabase message
            return message.isEmpty ? "Sign in failed. Please try again." : message
        }
        return error.localizedDescription
    }
}
