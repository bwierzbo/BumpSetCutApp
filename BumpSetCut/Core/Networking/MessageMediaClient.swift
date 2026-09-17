//
//  MessageMediaClient.swift
//  BumpSetCut
//
//  Private clip storage for direct messages. Kept off `APIClient` so the
//  existing test mocks stay untouched and message view models can stub media
//  on its own.
//

import Foundation

protocol MessageMediaClient: Sendable {
    /// Uploads to `message-media/{userId}/{uuid}.mp4` and returns the object
    /// path to hand to `SendMessageParams.clipPath`.
    func uploadMessageClip(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String

    /// One-hour signed playback URL. RLS lets the uploader and anyone in a
    /// conversation that references the object read it.
    func signedURL(forMessageClip path: String) async throws -> URL

    /// Best-effort cleanup when a send fails after the upload succeeded —
    /// otherwise the object is orphaned and nobody can ever see or delete it.
    func deleteMessageClip(path: String) async throws
}

/// Previews and tests.
struct StubMessageMediaClient: MessageMediaClient {
    func uploadMessageClip(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        throw APIError.serverError(statusCode: 501, message: "Stub: not implemented")
    }

    func signedURL(forMessageClip path: String) async throws -> URL {
        throw APIError.serverError(statusCode: 501, message: "Stub: not implemented")
    }

    func deleteMessageClip(path: String) async throws {
        throw APIError.serverError(statusCode: 501, message: "Stub: not implemented")
    }
}
