import Foundation
import Supabase

// MARK: - Helper Types

struct FollowRow: Decodable {
    let followingId: String

    enum CodingKeys: String, CodingKey {
        case followingId = "following_id"
    }
}

struct FollowerWrapper: Decodable {
    let follower: UserProfile
}

struct FollowingWrapper: Decodable {
    let following: UserProfile
}

struct UsernameAvailability: Decodable {
    let isAvailable: Bool
}

struct BlockStatusResult: Decodable {
    let isBlocked: Bool
}

struct PollVoteRow: Decodable {
    let optionId: String
}


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
                .select("*, author:profiles(*), poll:polls(*, options:poll_options(*))")
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
            let followedIds = follows.map(\.followingId)

            guard !followedIds.isEmpty else {
                // Safe empty array cast — T is always [Highlight] for feed endpoints
                guard let empty = [Highlight]() as? T else {
                    throw URLError(.cannotDecodeContentData)
                }
                return empty
            }

            let response: T = try await supabase
                .from("highlights")
                .select("*, author:profiles(*), poll:polls(*, options:poll_options(*))")
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
                .select("*, author:profiles(*), poll:polls(*, options:poll_options(*))")
                .eq("author_id", value: userId)
                .order("created_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .getHighlight(let id):
            let response: T = try await supabase
                .from("highlights")
                .select("*, author:profiles(*), poll:polls(*, options:poll_options(*))")
                .eq("id", value: id)
                .single()
                .execute()
                .value
            return response

        case .createHighlight(let upload):
            let response: T = try await supabase
                .from("highlights")
                .insert(upload)
                .select("*, author:profiles(*), poll:polls(*, options:poll_options(*))")
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
                .select("*, author:profiles(*), poll:polls(*, options:poll_options(*))")
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
            return try safeCast(EmptyResponse())

        // MARK: Likes

        case .likeHighlight(let id):
            let userId = try await currentUserId()
            try await supabase
                .from("likes")
                .insert(["highlight_id": id, "user_id": userId])
                .execute()
            return try safeCast(EmptyResponse())

        case .unlikeHighlight(let id):
            let userId = try await currentUserId()
            try await supabase
                .from("likes")
                .delete()
                .eq("highlight_id", value: id)
                .eq("user_id", value: userId)
                .execute()
            return try safeCast(EmptyResponse())

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
            return try safeCast(EmptyResponse())

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
                .ilike("username", pattern: "%\(query)%")
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .checkUsernameAvailability(let username):
            let rows: [UserProfile] = try await supabase
                .from("profiles")
                .select()
                .eq("username", value: username)
                .limit(1)
                .execute()
                .value
            return try safeCast(UsernameAvailability(isAvailable: rows.isEmpty))

        // MARK: Follows

        case .follow(let userId):
            let myId = try await currentUserId()
            try await supabase
                .from("follows")
                .insert(["follower_id": myId, "following_id": userId])
                .execute()
            return try safeCast(EmptyResponse())

        case .unfollow(let userId):
            let myId = try await currentUserId()
            try await supabase
                .from("follows")
                .delete()
                .eq("follower_id", value: myId)
                .eq("following_id", value: userId)
                .execute()
            return try safeCast(EmptyResponse())

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

        // MARK: Follow Status

        case .checkFollowStatus(let userId):
            let myId = try await currentUserId()
            let response: T = try await supabase
                .from("follows")
                .select("following_id")
                .eq("follower_id", value: myId)
                .eq("following_id", value: userId)
                .execute()
                .value
            return response

        case .checkFollowStatusBatch(let userIds):
            guard !userIds.isEmpty else {
                return try safeCast([FollowRow]())
            }
            let myId = try await currentUserId()
            let response: T = try await supabase
                .from("follows")
                .select("following_id")
                .eq("follower_id", value: myId)
                .in("following_id", values: userIds)
                .execute()
                .value
            return response

        // MARK: Moderation

        case .createReport(let report):
            let response: T = try await supabase
                .from("content_reports")
                .insert(report)
                .select()
                .single()
                .execute()
                .value
            return response

        case .getMyReports(let page):
            let myId = try await currentUserId()
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("content_reports")
                .select()
                .eq("reporter_id", value: myId)
                .order("created_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .blockUser(let userId, let reason):
            let myId = try await currentUserId()
            let blockData: [String: String] = [
                "blocker_id": myId,
                "blocked_id": userId,
            ].merging(reason.map { ["reason": $0] } ?? [:]) { _, new in new }
            let response: T = try await supabase
                .from("user_blocks")
                .insert(blockData)
                .select()
                .single()
                .execute()
                .value
            return response

        case .unblockUser(let userId):
            let myId = try await currentUserId()
            try await supabase
                .from("user_blocks")
                .delete()
                .eq("blocker_id", value: myId)
                .eq("blocked_id", value: userId)
                .execute()
            return try safeCast(EmptyResponse())

        case .getBlockedUsers:
            let myId = try await currentUserId()
            let response: T = try await supabase
                .from("user_blocks")
                .select()
                .eq("blocker_id", value: myId)
                .execute()
                .value
            return response

        case .isUserBlocked(let userId):
            let myId = try await currentUserId()
            let rows: [UserBlock] = try await supabase
                .from("user_blocks")
                .select()
                .eq("blocker_id", value: myId)
                .eq("blocked_id", value: userId)
                .limit(1)
                .execute()
                .value
            return try safeCast(BlockStatusResult(isBlocked: !rows.isEmpty))

        // MARK: Polls

        case .createPoll(let upload):
            let response: T = try await supabase
                .from("polls")
                .insert(upload)
                .select()
                .single()
                .execute()
                .value
            return response

        case .createPollOptions(_, let options):
            let response: T = try await supabase
                .from("poll_options")
                .insert(options)
                .select()
                .execute()
                .value
            return response

        case .votePoll(let vote):
            try await supabase
                .from("poll_votes")
                .insert(vote)
                .execute()
            return try safeCast(EmptyResponse())

        case .getMyPollVote(let pollId):
            let userId = try await currentUserId()
            let rows: [PollVoteRow] = try await supabase
                .from("poll_votes")
                .select("option_id")
                .eq("poll_id", value: pollId)
                .eq("user_id", value: userId)
                .limit(1)
                .execute()
                .value
            return try safeCast(rows)

        case .deletePollVote(let pollId):
            let userId = try await currentUserId()
            try await supabase
                .from("poll_votes")
                .delete()
                .eq("poll_id", value: pollId)
                .eq("user_id", value: userId)
                .execute()
            return try safeCast(EmptyResponse())

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
        guard let outputStream = OutputStream(url: outputURL, append: false) else {
            throw APIError.invalidRequest("Cannot write to \(outputURL)")
        }
        outputStream.open()
        defer { outputStream.close() }

        func writeString(_ string: String) {
            let data = Data(string.utf8)
            _ = data.withUnsafeBytes { buffer in
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

    // MARK: - Avatar Upload

    /// Uploads avatar image data to Supabase Storage and returns the public URL.
    nonisolated func uploadAvatar(imageData: Data) async throws -> URL {
        let userId = try await currentUserId()
        let fileName = "\(userId)/avatar.jpg"

        // Upload to "avatars" storage bucket (upsert so re-uploads replace)
        try await supabase.storage.from("avatars").upload(
            fileName,
            data: imageData,
            options: .init(contentType: "image/jpeg", upsert: true)
        )

        let publicURL = try supabase.storage.from("avatars").getPublicURL(path: fileName)
        // Append cache-buster so AsyncImage re-fetches after update
        guard var components = URLComponents(url: publicURL, resolvingAgainstBaseURL: false) else {
            return publicURL
        }
        components.queryItems = [URLQueryItem(name: "t", value: "\(Int(Date().timeIntervalSince1970))")]
        return components.url ?? publicURL
    }

    // MARK: - Private

    /// Safe cast helper — avoids force cast (`as! T`) crashes at runtime.
    private nonisolated func safeCast<T>(_ value: Any) throws -> T {
        guard let result = value as? T else {
            throw URLError(.cannotDecodeContentData)
        }
        return result
    }

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
