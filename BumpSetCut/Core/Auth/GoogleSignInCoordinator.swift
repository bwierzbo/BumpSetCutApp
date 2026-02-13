import GoogleSignIn
import UIKit

struct GoogleSignInResult {
    let idToken: String
    let email: String?
    let fullName: String?
}

final class GoogleSignInCoordinator {

    @MainActor
    func signIn() async throws -> GoogleSignInResult {
        let config = GIDConfiguration(clientID: Secrets.googleClientID)
        GIDSignIn.sharedInstance.configuration = config

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = scene.windows.first?.rootViewController else {
            throw GoogleSignInError.missingRootViewController
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC, hint: nil, additionalScopes: nil)

        guard let idToken = result.user.idToken?.tokenString else {
            throw GoogleSignInError.missingIDToken
        }

        return GoogleSignInResult(
            idToken: idToken,
            email: result.user.profile?.email,
            fullName: result.user.profile?.name
        )
    }
}

enum GoogleSignInError: Error, LocalizedError {
    case missingRootViewController
    case missingIDToken

    var errorDescription: String? {
        switch self {
        case .missingRootViewController:
            return "Could not find a window to present Google Sign-In."
        case .missingIDToken:
            return "Google Sign-In did not return an ID token."
        }
    }
}
