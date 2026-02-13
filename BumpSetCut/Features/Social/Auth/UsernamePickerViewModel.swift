//
//  UsernamePickerViewModel.swift
//  BumpSetCut
//
//  ViewModel for the username picker shown after social sign-in.
//

import Foundation
import Observation

@MainActor @Observable
final class UsernamePickerViewModel {
    let authService: AuthenticationService
    var username = ""
    var isAvailable: Bool?
    var isChecking = false
    var errorMessage: String?
    var isSubmitting = false

    private var checkTask: Task<Void, Never>?
    private let apiClient: any APIClient

    init(authService: AuthenticationService, apiClient: (any APIClient)? = nil) {
        self.authService = authService
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    // MARK: - Validation

    var isValidFormat: Bool {
        let pattern = /^[A-Za-z0-9_]{3,20}$/
        return username.wholeMatch(of: pattern) != nil && !username.hasPrefix("user_")
    }

    var canSubmit: Bool {
        isValidFormat && !isChecking && isAvailable != false && !isSubmitting
    }

    // MARK: - Availability Check

    func usernameChanged() {
        checkTask?.cancel()
        isAvailable = nil

        guard isValidFormat else {
            isChecking = false
            return
        }

        isChecking = true
        let target = username
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, username == target else { return }
            do {
                let result: UsernameAvailability = try await apiClient.request(
                    .checkUsernameAvailability(username: target)
                )
                guard !Task.isCancelled, username == target else { return }
                isAvailable = result.isAvailable
            } catch {
                guard !Task.isCancelled else { return }
                isAvailable = nil
            }
            isChecking = false
        }
    }

    // MARK: - Submit

    func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        do {
            try await authService.completeUsernameSetup(username: username)
        } catch {
            errorMessage = error.localizedDescription
            isSubmitting = false
        }
    }
}
