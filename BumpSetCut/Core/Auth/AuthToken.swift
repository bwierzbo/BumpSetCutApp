import Foundation

// MARK: - Auth Token

struct AuthToken: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }

    /// Token needs refresh if within 5 minutes of expiry.
    var needsRefresh: Bool {
        Date().addingTimeInterval(300) >= expiresAt
    }

    var remainingSeconds: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }
}
