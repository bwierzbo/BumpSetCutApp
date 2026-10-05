import Foundation

// MARK: - API Error

enum APIError: Error, LocalizedError {
    case unauthorized
    case networkUnavailable
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)
    case notFound
    case rateLimited
    case invalidRequest(String)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Authentication required. Please sign in.")
        case .networkUnavailable:
            return String(localized: "No network connection. Please check your internet.")
        case .serverError(let statusCode, let message):
            // `message` comes from the server (or a localized client string).
            let detail = message ?? String(localized: "Unknown error")
            return String(localized: "Server error (\(statusCode)): \(detail)", comment: "%1$lld is the HTTP status code, %2$@ the server's message")
        case .decodingError(let error):
            return String(localized: "Failed to process response: \(error.localizedDescription)")
        case .notFound:
            return String(localized: "The requested content was not found.")
        case .rateLimited:
            return String(localized: "Too many requests. Please try again later.")
        case .invalidRequest(let reason):
            return String(localized: "Invalid request: \(reason)")
        case .unknown(let error):
            return String(localized: "Unexpected error: \(error.localizedDescription)")
        }
    }

    var isRetryable: Bool {
        switch self {
        case .serverError(let code, _): return code >= 500
        case .networkUnavailable, .rateLimited: return true
        default: return false
        }
    }
}
