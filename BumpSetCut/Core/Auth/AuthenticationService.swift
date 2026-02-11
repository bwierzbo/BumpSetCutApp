import Foundation
import Observation
import Supabase

// MARK: - Auth State

enum AuthState {
    case unauthenticated
    case authenticating
    case authenticated
    case needsUsername
    case expired
}

// MARK: - Authentication Service

@MainActor
@Observable
final class AuthenticationService {
    private(set) var currentUser: UserProfile?
    private(set) var authState: AuthState = .unauthenticated

    var isAuthenticated: Bool { authState == .authenticated }
    var needsUsernameSetup: Bool { currentUser?.username.hasPrefix("user_") == true }

    private let appleSignIn = AppleSignInCoordinator()
    private let supabase = SupabaseConfig.client
    private static let tokenKey = "auth_token"
    private static let userKey = "cached_user"

    // MARK: - Session Restoration

    func restoreSession() async {
        // Use a timeout to avoid hanging when no session exists
        do {
            let session = try await withThrowingTaskGroup(of: Session.self) { group in
                group.addTask {
                    try await self.supabase.auth.session
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw APIError.unauthorized
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            if session.isExpired {
                // Session expired, try to refresh
                do {
                    try await refreshToken()
                } catch {
                    authState = .unauthenticated
                    clearStoredCredentials()
                    return
                }
            }

            let profile = try await fetchProfile(userId: session.user.id.uuidString.lowercased())
            currentUser = profile
            if profile.username.hasPrefix("user_") {
                authState = .needsUsername
            } else {
                authState = .authenticated
            }
            try KeychainHelper.save(profile, for: Self.userKey)
        } catch {
            // No valid session — fall back to cached user or stay unauthenticated
            if let cachedUser: UserProfile = KeychainHelper.load(for: Self.userKey) {
                currentUser = cachedUser
                if cachedUser.username.hasPrefix("user_") {
                    authState = .needsUsername
                } else {
                    authState = .authenticated
                }
            } else {
                authState = .unauthenticated
            }
        }
    }

    // MARK: - Apple Sign In

    func signInWithApple() async throws {
        authState = .authenticating

        do {
            let result = try await appleSignIn.signIn()

            // Exchange Apple identity token with Supabase for a session
            let session = try await supabase.auth.signInWithIdToken(
                credentials: .init(
                    provider: .apple,
                    idToken: result.identityToken
                )
            )

            // Fetch or create profile from DB
            let profile = try await fetchOrCreateProfile(
                userId: session.user.id.uuidString.lowercased()
            )

            let token = AuthToken(
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                expiresAt: Date(timeIntervalSince1970: session.expiresAt)
            )

            try KeychainHelper.save(token, for: Self.tokenKey)
            try KeychainHelper.save(profile, for: Self.userKey)

            currentUser = profile
            if profile.username.hasPrefix("user_") {
                authState = .needsUsername
            } else {
                authState = .authenticated
            }
        } catch let error as AppleSignInError where error == .cancelled {
            authState = .unauthenticated
        } catch {
            authState = .unauthenticated
            throw error
        }
    }

    // MARK: - Email Sign Up

    func signUpWithEmail(email: String, password: String, username: String) async throws {
        authState = .authenticating

        do {
            let session = try await supabase.auth.signUp(
                email: email,
                password: password
            )

            guard let session = session.session else {
                authState = .unauthenticated
                throw APIError.serverError(statusCode: 400, message: "Sign up failed — no session returned.")
            }

            let profile = try await fetchOrCreateProfile(
                userId: session.user.id.uuidString.lowercased(),
                username: username
            )

            let token = AuthToken(
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                expiresAt: Date(timeIntervalSince1970: session.expiresAt)
            )

            try KeychainHelper.save(token, for: Self.tokenKey)
            try KeychainHelper.save(profile, for: Self.userKey)

            currentUser = profile
            authState = .authenticated
        } catch let error where !(error is APIError) {
            authState = .unauthenticated
            throw error
        }
    }

    // MARK: - Email Sign In

    func signInWithEmail(email: String, password: String) async throws {
        authState = .authenticating

        do {
            let session = try await supabase.auth.signIn(
                email: email,
                password: password
            )

            let profile = try await fetchOrCreateProfile(
                userId: session.user.id.uuidString.lowercased()
            )

            let token = AuthToken(
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                expiresAt: Date(timeIntervalSince1970: session.expiresAt)
            )

            try KeychainHelper.save(token, for: Self.tokenKey)
            try KeychainHelper.save(profile, for: Self.userKey)

            currentUser = profile
            if profile.username.hasPrefix("user_") {
                authState = .needsUsername
            } else {
                authState = .authenticated
            }
        } catch {
            authState = .unauthenticated
            throw error
        }
    }

    // MARK: - Google Sign In

    func signInWithGoogle() async throws {
        authState = .authenticating

        do {
            let result = try await GoogleSignInCoordinator().signIn()

            let session = try await supabase.auth.signInWithIdToken(
                credentials: .init(
                    provider: .google,
                    idToken: result.idToken
                )
            )

            let profile = try await fetchOrCreateProfile(
                userId: session.user.id.uuidString.lowercased()
            )

            let token = AuthToken(
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                expiresAt: Date(timeIntervalSince1970: session.expiresAt)
            )

            try KeychainHelper.save(token, for: Self.tokenKey)
            try KeychainHelper.save(profile, for: Self.userKey)

            currentUser = profile
            if profile.username.hasPrefix("user_") {
                authState = .needsUsername
            } else {
                authState = .authenticated
            }
        } catch {
            authState = .unauthenticated
            throw error
        }
    }

    // MARK: - Token Refresh

    func refreshToken() async throws {
        do {
            let session = try await supabase.auth.refreshSession()

            let refreshed = AuthToken(
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                expiresAt: Date(timeIntervalSince1970: session.expiresAt)
            )

            try KeychainHelper.save(refreshed, for: Self.tokenKey)
            authState = .authenticated
        } catch {
            authState = .expired
            throw APIError.unauthorized
        }
    }

    // MARK: - Sign Out

    func signOut() {
        Task {
            try? await supabase.auth.signOut()
        }
        clearStoredCredentials()
        currentUser = nil
        authState = .unauthenticated
    }

    // MARK: - Username Setup

    func completeUsernameSetup(username: String) async throws {
        let update = UserProfileUpdate(username: username)
        let updated: UserProfile = try await SupabaseAPIClient.shared.request(.updateProfile(update))
        currentUser = updated
        try? KeychainHelper.save(updated, for: Self.userKey)
        authState = .authenticated
    }

    // MARK: - Profile Update

    func updateLocalProfile(_ profile: UserProfile) {
        currentUser = profile
        try? KeychainHelper.save(profile, for: Self.userKey)
    }

    // MARK: - Account Deletion

    func deleteAccount() async throws {
        try await supabase.functions.invoke("delete-account")
        signOut()
    }

    // MARK: - Private

    private func clearStoredCredentials() {
        try? KeychainHelper.delete(for: Self.tokenKey)
        try? KeychainHelper.delete(for: Self.userKey)
    }

    private func fetchProfile(userId: String) async throws -> UserProfile {
        try await SupabaseConfig.client
            .from("profiles")
            .select()
            .eq("id", value: userId)
            .single()
            .execute()
            .value
    }

    private func fetchOrCreateProfile(userId: String, username: String? = nil) async throws -> UserProfile {
        // Try to fetch existing profile first
        do {
            let existing: UserProfile = try await fetchProfile(userId: userId)
            return existing
        } catch {
            // Profile doesn't exist — create one
        }

        let finalUsername = username ?? "user_\(userId.prefix(8))"

        let profile: UserProfile = try await SupabaseConfig.client
            .from("profiles")
            .insert([
                "id": userId,
                "username": finalUsername,
            ])
            .select()
            .single()
            .execute()
            .value

        return profile
    }
}

// MARK: - AppleSignInError Equatable

extension AppleSignInError: Equatable {
    static func == (lhs: AppleSignInError, rhs: AppleSignInError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled): return true
        case (.missingCredentials, .missingCredentials): return true
        default: return false
        }
    }
}
