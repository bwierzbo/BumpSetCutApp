import AuthenticationServices
import UIKit

// MARK: - Apple Sign In Result

struct AppleSignInResult {
    let identityToken: String
    let authorizationCode: String
    let fullName: PersonNameComponents?
    let email: String?
}

// MARK: - Apple Sign In Coordinator

final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate,
                                     ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<AppleSignInResult, Error>?

    func signIn() async throws -> AppleSignInResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8),
              let authCodeData = credential.authorizationCode,
              let authCode = String(data: authCodeData, encoding: .utf8) else {
            continuation?.resume(throwing: AppleSignInError.missingCredentials)
            continuation = nil
            return
        }

        let result = AppleSignInResult(
            identityToken: identityToken,
            authorizationCode: authCode,
            fullName: credential.fullName,
            email: credential.email
        )
        continuation?.resume(returning: result)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            continuation?.resume(throwing: AppleSignInError.cancelled)
        } else {
            continuation?.resume(throwing: AppleSignInError.failed(error))
        }
        continuation = nil
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

// MARK: - Apple Sign In Error

enum AppleSignInError: Error, LocalizedError {
    case cancelled
    case missingCredentials
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Sign in was cancelled."
        case .missingCredentials:
            return "Apple Sign In returned incomplete credentials."
        case .failed(let error):
            return "Apple Sign In failed: \(error.localizedDescription)"
        }
    }
}
