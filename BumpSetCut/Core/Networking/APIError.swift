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
    case uploadFailed(Error)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Authentication required. Please sign in."
        case .networkUnavailable:
            return "No network connection. Please check your internet."
        case .serverError(let statusCode, let message):
            return "Server error (\(statusCode)): \(message ?? "Unknown error")"
        case .decodingError(let error):
            return "Failed to process response: \(error.localizedDescription)"
        case .notFound:
            return "The requested content was not found."
        case .rateLimited:
            return "Too many requests. Please try again later."
        case .invalidRequest(let reason):
            return "Invalid request: \(reason)"
        case .uploadFailed(let error):
            return "Upload failed: \(error.localizedDescription)"
        case .unknown(let error):
            return "Unexpected error: \(error.localizedDescription)"
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
