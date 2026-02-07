import Foundation
import Observation
import Supabase

// MARK: - Auth State

enum AuthState {
    case unauthenticated
    case authenticating
    case authenticated
    case expired
}

// MARK: - Authentication Service

@MainActor
@Observable
final class AuthenticationService {
    private(set) var currentUser: UserProfile?
    private(set) var authState: AuthState = .unauthenticated

    var isAuthenticated: Bool { authState == .authenticated }

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

            let profile = try await fetchProfile(userId: session.user.id.uuidString)
            currentUser = profile
            authState = .authenticated
            try KeychainHelper.save(profile, for: Self.userKey)
        } catch {
            // No valid session — fall back to cached user or stay unauthenticated
            if let cachedUser: UserProfile = KeychainHelper.load(for: Self.userKey) {
                currentUser = cachedUser
                authState = .authenticated
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
                userId: session.user.id.uuidString,
                fullName: result.fullName,
                email: result.email
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
        } catch let error as AppleSignInError where error == .cancelled {
            authState = .unauthenticated
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

    private func fetchOrCreateProfile(userId: String, fullName: PersonNameComponents?, email: String?) async throws -> UserProfile {
        // Try to fetch existing profile
        if let existing: UserProfile = try? await fetchProfile(userId: userId) {
            return existing
        }

        // Profile doesn't exist yet (first sign-in) — the DB trigger should have created it,
        // but if not, create one explicitly
        let displayName = fullName?.formatted() ?? "Volleyball Player"
        let username = "user_\(userId.prefix(8))"

        let profile: UserProfile = try await SupabaseConfig.client
            .from("profiles")
            .upsert([
                "id": userId,
                "display_name": displayName,
                "username": username,
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
