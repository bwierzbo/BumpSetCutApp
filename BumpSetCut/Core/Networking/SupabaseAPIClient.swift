import Foundation
import Supabase

// MARK: - Helper Types

private struct FollowRow: Decodable { let following_id: String }

// MARK: - Supabase API Client

final class SupabaseAPIClient: APIClient, @unchecked Sendable {

    static let shared = SupabaseAPIClient()

    private let supabase = SupabaseConfig.client

    private init() {}

    // MARK: - APIClient

    nonisolated func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        switch endpoint {

        // MARK: Feed & Highlights

        case .getFeed(let page, let pageSize):
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("highlights")
                .select("*, author:profiles(*)")
                .order("created_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .getFollowingFeed(let page, let pageSize):
            let myId = try await currentUserId()
            let from = page * pageSize
            let to = from + pageSize - 1

            // Get IDs of users the current user follows
            let follows: [FollowRow] = try await supabase
                .from("follows")
                .select("following_id")
                .eq("follower_id", value: myId)
                .execute()
                .value
            let followedIds = follows.map(\.following_id)

            guard !followedIds.isEmpty else {
                return [] as! T
            }

            let response: T = try await supabase
                .from("highlights")
                .select("*, author:profiles(*)")
                .in("author_id", values: followedIds)
                .order("created_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .getUserHighlights(let userId, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("highlights")
                .select("*, author:profiles(*)")
                .eq("author_id", value: userId)
                .order("created_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .getHighlight(let id):
            let response: T = try await supabase
                .from("highlights")
                .select("*, author:profiles(*)")
                .eq("id", value: id)
                .single()
                .execute()
                .value
            return response

        case .createHighlight(let upload):
            let response: T = try await supabase
                .from("highlights")
                .insert(upload)
                .select("*, author:profiles(*)")
                .single()
                .execute()
                .value
            return response

        case .searchHighlights(let query, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("highlights")
                .select("*, author:profiles(*)")
                .or("caption.ilike.%\(query)%,tags.cs.{\(query)}")
                .order("created_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .deleteHighlight(let id):
            try await supabase
                .from("highlights")
                .delete()
                .eq("id", value: id)
                .execute()
            return EmptyResponse() as! T

        // MARK: Likes

        case .likeHighlight(let id):
            let userId = try await currentUserId()
            try await supabase
                .from("likes")
                .insert(["highlight_id": id, "user_id": userId])
                .execute()
            return EmptyResponse() as! T

        case .unlikeHighlight(let id):
            let userId = try await currentUserId()
            try await supabase
                .from("likes")
                .delete()
                .eq("highlight_id", value: id)
                .eq("user_id", value: userId)
                .execute()
            return EmptyResponse() as! T

        // MARK: Comments

        case .getComments(let highlightId, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("comments")
                .select("*, author:profiles(*)")
                .eq("highlight_id", value: highlightId)
                .order("created_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .addComment(let highlightId, let text):
            let userId = try await currentUserId()
            let response: T = try await supabase
                .from("comments")
                .insert(["highlight_id": highlightId, "author_id": userId, "text": text])
                .select("*, author:profiles(*)")
                .single()
                .execute()
                .value
            return response

        case .deleteComment(let id):
            try await supabase
                .from("comments")
                .delete()
                .eq("id", value: id)
                .execute()
            return EmptyResponse() as! T

        // MARK: Profiles

        case .getProfile(let userId):
            let response: T = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            return response

        case .updateProfile(let update):
            let userId = try await currentUserId()
            let response: T = try await supabase
                .from("profiles")
                .update(update)
                .eq("id", value: userId)
                .select()
                .single()
                .execute()
                .value
            return response

        case .searchUsers(let query, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("profiles")
                .select()
                .or("display_name.ilike.%\(query)%,username.ilike.%\(query)%")
                .range(from: from, to: to)
                .execute()
                .value
            return response

        // MARK: Follows

        case .follow(let userId):
            let myId = try await currentUserId()
            try await supabase
                .from("follows")
                .insert(["follower_id": myId, "following_id": userId])
                .execute()
            return EmptyResponse() as! T

        case .unfollow(let userId):
            let myId = try await currentUserId()
            try await supabase
                .from("follows")
                .delete()
                .eq("follower_id", value: myId)
                .eq("following_id", value: userId)
                .execute()
            return EmptyResponse() as! T

        case .getFollowers(let userId, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("follows")
                .select("follower:profiles!follower_id(*)")
                .eq("following_id", value: userId)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .getFollowing(let userId, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("follows")
                .select("following:profiles!following_id(*)")
                .eq("follower_id", value: userId)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        // MARK: Auth (handled via Supabase Auth, not DB)

        case .signInWithApple, .refreshToken, .signOut, .deleteAccount:
            throw APIError.invalidRequest("Auth endpoints are handled by AuthenticationService, not APIClient")

        // MARK: Upload URL

        case .createUploadURL:
            throw APIError.invalidRequest("Use upload(fileURL:to:progress:) for file uploads")
        }
    }

    // MARK: - Upload

    nonisolated func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let userId = try await currentUserId()
        let fileName = "\(userId)/\(UUID().uuidString).mp4"

        // Get auth token for the storage API request
        let session = try await supabase.auth.session
        let accessToken = session.accessToken

        // Build the storage upload URL: {projectURL}/storage/v1/object/videos/{fileName}
        let storageURL = SupabaseConfig.projectURL
            .appendingPathComponent("storage/v1/object/videos")
            .appendingPathComponent(fileName)

        // Write multipart form data to a temp file (streams video, never loads into memory)
        let boundary = "Boundary-\(UUID().uuidString)"
        let tempMultipartURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload_\(UUID().uuidString).tmp")

        try writeMultipartFile(
            boundary: boundary,
            fileURL: fileURL,
            fileName: fileName,
            to: tempMultipartURL
        )

        defer { try? FileManager.default.removeItem(at: tempMultipartURL) }

        // Build the request
        var request = URLRequest(url: storageURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("false", forHTTPHeaderField: "x-upsert")

        // Upload from file (streams from disk, no memory pressure)
        let delegate = UploadProgressDelegate(onProgress: progress)
        let session2 = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session2.finishTasksAndInvalidate() }

        let (data, response) = try await session2.upload(for: request, fromFile: tempMultipartURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(statusCode: statusCode, message: "Storage upload failed: \(body)")
        }

        progress(1.0)

        let publicURL = try supabase.storage.from("videos").getPublicURL(path: fileName)
        return publicURL
    }

    // MARK: - Multipart File Writer

    /// Writes multipart form data to a temp file, streaming the video to avoid memory pressure.
    private nonisolated func writeMultipartFile(
        boundary: String,
        fileURL: URL,
        fileName: String,
        to outputURL: URL
    ) throws {
        let outputStream = OutputStream(url: outputURL, append: false)!
        outputStream.open()
        defer { outputStream.close() }

        func writeString(_ string: String) {
            let data = Data(string.utf8)
            data.withUnsafeBytes { buffer in
                outputStream.write(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: data.count)
            }
        }

        // Multipart header for the file field
        writeString("--\(boundary)\r\n")
        writeString("Content-Disposition: form-data; name=\"\"; filename=\"\(fileName)\"\r\n")
        writeString("Content-Type: video/mp4\r\n\r\n")

        // Stream video file in chunks (64KB at a time)
        guard let inputStream = InputStream(url: fileURL) else {
            throw APIError.invalidRequest("Cannot read file at \(fileURL)")
        }
        inputStream.open()
        defer { inputStream.close() }

        let bufferSize = 65_536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                outputStream.write(buffer, maxLength: bytesRead)
            } else {
                break
            }
        }

        // Multipart footer
        writeString("\r\n--\(boundary)--\r\n")
    }

    // MARK: - Private

    private func currentUserId() async throws -> String {
        guard let user = try? await SupabaseConfig.client.auth.session.user else {
            throw APIError.unauthorized
        }
        return user.id.uuidString.lowercased()
    }
}

// MARK: - Upload Progress Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @Sendable @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(min(fraction, 0.95))  // Cap at 95% until server confirms
    }
}
