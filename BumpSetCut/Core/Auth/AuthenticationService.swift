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
            authState = .authenticated
            try KeychainHelper.save(profile, for: Self.userKey)
        } catch {
            // No valid session — stay unauthenticated
            // Don't use cached user for .needsUsername since there's no active session
            authState = .unauthenticated
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
                throw APIError.serverError(statusCode: 400, message: "Sign up failed — please check your email for a confirmation link, or try again.")
            }

            let (profile, _) = try await fetchOrCreateProfile(
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
        } catch {
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

            let (profile, _) = try await fetchOrCreateProfile(
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
            authState = .authenticated
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

    // MARK: - Password Reset

    func resetPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email)
    }

    func verifyOTP(email: String, token: String) async throws {
        try await supabase.auth.verifyOTP(email: email, token: token, type: .recovery)
    }

    func updatePassword(newPassword: String) async throws {
        try await supabase.auth.update(user: .init(password: newPassword))
    }

    // MARK: - Account Deletion

    func deleteAccount() async throws {
        let session = try await supabase.auth.session
        try await supabase.functions.invoke(
            "delete-account",
            options: .init(
                headers: ["Authorization": "Bearer \(session.accessToken)"]
            )
        )
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

    /// Returns (profile, isNewAccount)
    private func fetchOrCreateProfile(userId: String, username: String? = nil) async throws -> (UserProfile, Bool) {
        // Try to fetch existing profile first — .single() throws when no rows match
        do {
            let existing: UserProfile = try await fetchProfile(userId: userId)

            // If caller provided a username and the profile has an auto-generated one, update it
            if let username, existing.username.hasPrefix("user_"), existing.username != username {
                let updated: UserProfile = try await SupabaseConfig.client
                    .from("profiles")
                    .update(["username": username])
                    .eq("id", value: userId)
                    .select()
                    .single()
                    .execute()
                    .value
                return (updated, true)
            }

            return (existing, false)
        } catch {
            // Profile doesn't exist or fetch failed — attempt upsert (PK constraint prevents duplicates)
            print("[Auth] fetchProfile failed for \(userId.prefix(8))..., will create: \(error)")
        }

        let finalUsername = username ?? "user_\(userId.prefix(8))"

        // Use upsert to handle race conditions; DB defaults handle counts and privacy_level
        let profile: UserProfile = try await SupabaseConfig.client
            .from("profiles")
            .upsert([
                "id": userId,
                "username": finalUsername,
            ])
            .select()
            .single()
            .execute()
            .value

        return (profile, true)
    }
}
