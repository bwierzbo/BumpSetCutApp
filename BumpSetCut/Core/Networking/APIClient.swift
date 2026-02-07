import Foundation

// MARK: - API Client Protocol

protocol APIClient: Sendable {
    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T
    func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @Sendable (Double) -> Void) async throws -> URL
}

// MARK: - Stub API Client

/// Stub implementation for compilation and local development.
/// Replace with SupabaseAPIClient when backend is integrated.
@MainActor
final class StubAPIClient: APIClient, @unchecked Sendable {

    nonisolated func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        print("StubAPIClient: \(endpoint.method.rawValue) \(endpoint.path)")
        throw APIError.serverError(statusCode: 501, message: "Stub: not implemented")
    }

    nonisolated func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @Sendable (Double) -> Void) async throws -> URL {
        print("StubAPIClient: upload \(fileURL.lastPathComponent) to \(endpoint.path)")
        throw APIError.serverError(statusCode: 501, message: "Stub: not implemented")
    }
}
