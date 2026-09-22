//
//  MessageMediaClient.swift
//  BumpSetCut
//
//  Playback access to the private `message-media` bucket. Clips are no
//  longer sent from the app — only posts travel through DMs — but existing
//  clip messages still play, so signed URLs remain. Kept off `APIClient` so
//  the existing test mocks stay untouched.
//

import Foundation

protocol MessageMediaClient: Sendable {
    /// One-hour signed playback URL. RLS lets the uploader and anyone in a
    /// conversation that references the object read it.
    func signedURL(forMessageClip path: String) async throws -> URL
}

/// Previews and tests.
struct StubMessageMediaClient: MessageMediaClient {
    func signedURL(forMessageClip path: String) async throws -> URL {
        throw APIError.serverError(statusCode: 501, message: "Stub: not implemented")
    }
}
