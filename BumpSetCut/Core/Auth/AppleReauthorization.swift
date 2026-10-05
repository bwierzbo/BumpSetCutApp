//
//  AppleReauthorization.swift
//  BumpSetCut
//
//  A fresh Sign in with Apple authorization code, for revoking the app's
//  Apple tokens when an account is deleted (Apple requires the revoke).
//  Apple's codes are single-use and expire in minutes, so one can't be
//  kept from sign-in — the user confirms with Apple at deletion instead.
//

import AuthenticationServices
import UIKit

@MainActor
final class AppleReauthorization: NSObject {

    enum ReauthorizationError: LocalizedError {
        case noCode
        var errorDescription: String? { "Apple didn't confirm your account. Try again to delete it." }
    }

    private var continuation: CheckedContinuation<String, Error>?

    /// Ask Apple to confirm the signed-in Apple ID; returns its authorization
    /// code. Throws if the user cancels.
    static func authorizationCode() async throws -> String {
        try await AppleReauthorization().request()
    }

    private func request() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(
                authorizationRequests: [ASAuthorizationAppleIDProvider().createRequest()])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension AppleReauthorization: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        let code = (authorization.credential as? ASAuthorizationAppleIDCredential)?
            .authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        MainActor.assumeIsolated {
            finish(code.map { .success($0) } ?? .failure(ReauthorizationError.noCode))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }
}

extension AppleReauthorization: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}
