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
    private(set) var authState: AuthState = .unauthenticated {
        didSet {
            // Blocks must survive relaunch: load them whenever a session
            // becomes active (sign-in or restore), clear them on sign-out.
            guard authState != oldValue else { return }
            if authState == .authenticated {
                Task { await ModerationService.shared.ensureBlocksLoaded() }
                if let userId = currentUser?.id {
                    SocialNotificationService.shared.start(userId: userId)
                }
            } else if authState == .unauthenticated {
                ModerationService.shared.resetForSignOut()
                SocialNotificationService.shared.stop()
            }
        }
    }

    var isAuthenticated: Bool { authState == .authenticated }
    var needsUsernameSetup: Bool { currentUser?.username.hasPrefix("user_") == true }

    private let supabase = SupabaseConfig.client
    // The supabase-swift SDK persists the session itself; we only cache the profile.
    // "auth_token" entries written by older builds are cleared on fresh install (BumpSetCutApp).
    private static let userKey = "cached_user"

    // MARK: - Session Restoration

    func restoreSession() async {
        do {
            // No stored session → nothing to restore; bail without any network wait.
            // With a stored session, await auth.session untimed: the only wait is a
            // legitimate token refresh, and racing it with a fixed timeout signed
            // out users with valid-but-expired sessions on slow connections.
            guard supabase.auth.currentSession != nil else {
                authState = .unauthenticated
                return
            }
            let session = try await supabase.auth.session

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

            guard let profile = try await fetchProfile(userId: session.user.id.uuidString.lowercased()) else {
                throw APIError.unauthorized
            }
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

            try KeychainHelper.save(profile, for: Self.userKey)

            currentUser = profile
            authState = .authenticated
        } catch {
            authState = .unauthenticated
            throw error
        }
    }

    // MARK: - Sign in with Apple

    /// Completes native Sign in with Apple: exchanges Apple's ID token (with
    /// the raw nonce whose SHA-256 was attached to the authorization request)
    /// for a Supabase session.
    func signInWithApple(idToken: String, nonce: String) async throws {
        authState = .authenticating
        do {
            let session = try await supabase.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            )
            try await completeSocialSignIn(session: session)
        } catch {
            authState = .unauthenticated
            throw error
        }
    }

    // MARK: - Sign in with Google

    /// Runs Supabase's Google OAuth flow in an ASWebAuthenticationSession
    /// (PKCE; redirect back via bumpsetcut://auth-callback from SupabaseConfig).
    func signInWithGoogle() async throws {
        authState = .authenticating
        do {
            let session = try await supabase.auth.signInWithOAuth(provider: .google)
            try await completeSocialSignIn(session: session)
        } catch {
            authState = .unauthenticated
            throw error
        }
    }

    /// Shared post-session handling for social providers. Social sign-ins have
    /// no username step, so a freshly minted `user_*` profile routes to the
    /// username picker instead of straight into the app.
    private func completeSocialSignIn(session: Session) async throws {
        let (profile, _) = try await fetchOrCreateProfile(userId: session.user.id.uuidString.lowercased())
        try KeychainHelper.save(profile, for: Self.userKey)
        currentUser = profile
        authState = profile.username.hasPrefix("user_") ? .needsUsername : .authenticated
    }

    // MARK: - Token Refresh

    func refreshToken() async throws {
        do {
            _ = try await supabase.auth.refreshSession()
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
        try? KeychainHelper.delete(for: Self.userKey)
    }

    /// Returns nil only when no profile row exists; rethrows transient fetch failures.
    private func fetchProfile(userId: String) async throws -> UserProfile? {
        let rows: [UserProfile] = try await SupabaseConfig.client
            .from("profiles")
            .select()
            .eq("id", value: userId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Returns (profile, isNewAccount)
    private func fetchOrCreateProfile(userId: String, username: String? = nil) async throws -> (UserProfile, Bool) {
        // A transient fetch failure must NOT fall through to creation — the upsert
        // would overwrite an existing profile's username. Only a confirmed zero-rows
        // result proceeds to create; other errors propagate to the caller.
        if let existing = try await fetchProfile(userId: userId) {
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
        }

        let finalUsername = username ?? "user_\(userId.prefix(8))"

        // ignoreDuplicates: a concurrent creation wins and is never overwritten
        let inserted: [UserProfile] = try await SupabaseConfig.client
            .from("profiles")
            .upsert([
                "id": userId,
                "username": finalUsername,
            ], ignoreDuplicates: true)
            .select()
            .execute()
            .value

        if let profile = inserted.first {
            return (profile, true)
        }

        // Insert was skipped because the row appeared concurrently — fetch it
        if let existing = try await fetchProfile(userId: userId) {
            return (existing, false)
        }
        throw APIError.serverError(statusCode: 500, message: "Profile creation failed — please try again.")
    }
}
