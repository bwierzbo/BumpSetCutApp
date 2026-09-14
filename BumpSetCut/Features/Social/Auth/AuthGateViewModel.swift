//
//  AuthGateViewModel.swift
//  BumpSetCut
//
//  Wraps AuthenticationService for the auth gate sign-in flow.
//

import SwiftUI
import Observation
import Auth
import AuthenticationServices
import CryptoKit

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
                #if DEBUG
                print("[Auth] Username check failed: \(error)")
                #endif
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
            #if DEBUG
            print("[Auth] Email sign-up error: \(error)")
            #endif
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
            #if DEBUG
            print("[Auth] Email sign-in error: \(error)")
            #endif
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
            #if DEBUG
            print("[Auth] Reset password error: \(error)")
            #endif
            errorMessage = userFriendlyMessage(for: error)
            showError = true
        }
    }

    // MARK: - Sign in with Apple

    /// Raw nonce for the in-flight Apple request; its SHA-256 goes into the
    /// authorization request and the raw value is verified by Supabase.
    private var currentNonce: String?

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                errorMessage = "Apple didn't return a valid sign-in. Please try again."
                showError = true
                return
            }
            do {
                try await authService.signInWithApple(idToken: idToken, nonce: nonce)
            } catch {
                #if DEBUG
                print("[Auth] Apple sign-in error: \(error)")
                #endif
                errorMessage = userFriendlyMessage(for: error)
                showError = true
            }
        case .failure(let error):
            // The user closing the Apple sheet is not an error.
            if let authError = error as? ASAuthorizationError, authError.code == .canceled { return }
            #if DEBUG
            print("[Auth] Apple authorization error: \(error)")
            #endif
            errorMessage = userFriendlyMessage(for: error)
            showError = true
        }
    }

    // MARK: - Sign in with Google

    func signInWithGoogle() async {
        errorMessage = nil
        do {
            try await authService.signInWithGoogle()
        } catch {
            // The user dismissing the browser sheet is not an error.
            if let webError = error as? ASWebAuthenticationSessionError, webError.code == .canceledLogin { return }
            #if DEBUG
            print("[Auth] Google sign-in error: \(error)")
            #endif
            errorMessage = userFriendlyMessage(for: error)
            showError = true
        }
    }

    // MARK: - Nonce Helpers

    private static func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Unable to generate secure nonce")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
