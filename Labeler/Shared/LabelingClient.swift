//
//  LabelingClient.swift
//  Labeler (also compiled into RallyLab)
//
//  Supabase over plain REST for labeling: sign in with email and password
//  (the refresh token is kept in the Keychain), read and write the labeling
//  tables, and move clips in and out of the private "labeling" bucket.
//  Plain URLSession, so RallyLab and the Labeler app share it without the
//  Supabase package. Only labelers (public.labelers) get anything back.
//

import Foundation
import Security

actor LabelingClient {

    static let shared = LabelingClient()

    enum Failure: LocalizedError {
        case notSignedIn
        case server(Int, String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in first."
            case .server(let code, let message): return "Supabase \(code): \(message)"
            case .unreadable: return "Unexpected reply from Supabase."
            }
        }
    }

    static let bucket = "labeling"
    /// Clips are tens of megabytes: waits of minutes are normal on a slow
    /// connection (the default 60 s timed out mid-upload).
    private let transfers: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3 * 3600
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()
    private let base = URL(string: Secrets.supabaseURL)!
    private let apiKey = Secrets.supabaseAnonKey
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private(set) var userId: UUID?

    // MARK: - Auth

    /// Signed in before (a refresh token is in the Keychain).
    var hasSession: Bool { Keychain.refreshToken != nil }

    func signIn(email: String, password: String) async throws {
        try await token(grant: "password", body: ["email": email, "password": password])
    }

    func signOut() {
        Keychain.refreshToken = nil
        accessToken = nil
        userId = nil
    }

    /// Whether this account may label (it's in public.labelers).
    func isLabeler() async throws -> Bool {
        guard let userId else { return false }
        let rows: [[String: String]] = try await get("labelers", query: "select=user_id&user_id=eq.\(userId.uuidString.lowercased())")
        return !rows.isEmpty
    }

    private func token(grant: String, body: [String: String]) async throws {
        var request = URLRequest(url: base.appending(path: "auth/v1/token").appending(queryItems: [.init(name: "grant_type", value: grant)]))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        struct Token: Decodable {
            struct User: Decodable { let id: UUID }
            let accessToken: String, refreshToken: String, expiresIn: Double, user: User
        }
        let t = try Self.decoder.decode(Token.self, from: data)
        accessToken = t.accessToken
        expiresAt = Date().addingTimeInterval(t.expiresIn - 60)
        userId = t.user.id
        Keychain.refreshToken = t.refreshToken
    }

    /// A valid access token, refreshed when it's about to run out — or
    /// sooner, when the request needs it good for `lasting` seconds (an
    /// upload of a clip can outlast an hour-long token, and storage checks
    /// it when the upload finishes).
    private func bearer(lasting: TimeInterval = 0) async throws -> String {
        if let accessToken, Date().addingTimeInterval(lasting) < expiresAt { return accessToken }
        guard let refresh = Keychain.refreshToken else { throw Failure.notSignedIn }
        do {
            try await token(grant: "refresh_token", body: ["refresh_token": refresh])
        } catch Failure.server(let code, _) where code == 400 || code == 401 {
            signOut()
            throw Failure.notSignedIn
        }
        guard let accessToken else { throw Failure.notSignedIn }
        return accessToken
    }

    // MARK: - Tables

    func videos() async throws -> [LabelVideo] {
        try await get("label_videos", query: "select=*&order=surface,session_name,created_at")
    }

    func rallyTimes() async throws -> [LabelRallyTimes] {
        try await get("label_rally_times", query: "select=*")
    }

    /// Insert or update a video, by id (RallyLab reuses the id of a video
    /// it listed before).
    @discardableResult
    func save(_ video: LabelVideo) async throws -> LabelVideo {
        var row = video
        row.updatedAt = Date()
        let saved: [LabelVideo] = try await upsert("label_videos", row, onConflict: "id")
        guard let first = saved.first else { throw Failure.unreadable }
        return first
    }

    @discardableResult
    func save(_ times: LabelRallyTimes) async throws -> LabelRallyTimes {
        var row = times
        row.updatedAt = Date()
        let saved: [LabelRallyTimes] = try await upsert("label_rally_times", row, onConflict: "video_id")
        guard let first = saved.first else { throw Failure.unreadable }
        return first
    }

    func tracks() async throws -> [LabelTrack] {
        try await get("label_tracks", query: "select=*")
    }

    /// Insert or update tracked rallies, by id.
    func save(_ tracks: [LabelTrack]) async throws {
        guard !tracks.isEmpty else { return }
        let now = Date()
        let rows = tracks.map { t -> LabelTrack in var t = t; t.updatedAt = t.updatedAt ?? now; return t }
        let _: [LabelTrack] = try await upsert("label_tracks", rows, onConflict: "id")
    }

    func projectStates() async throws -> [LabelProjectState] {
        try await get("label_project_state", query: "select=*")
    }

    func save(_ state: LabelProjectState) async throws {
        var row = state
        row.updatedAt = Date()
        let _: [LabelProjectState] = try await upsert("label_project_state", [row], onConflict: "project")
    }

    private func get<T: Decodable>(_ table: String, query: String) async throws -> T {
        var request = try await rest(table, query: query)
        request.httpMethod = "GET"
        return try Self.decoder.decode(T.self, from: try await send(request))
    }

    private func upsert<T: Codable>(_ table: String, _ row: T, onConflict: String) async throws -> [T] {
        try await upsert(table, [row], onConflict: onConflict)
    }

    private func upsert<T: Codable>(_ table: String, _ rows: [T], onConflict: String) async throws -> [T] {
        var request = try await rest(table, query: "on_conflict=\(onConflict)")
        request.httpMethod = "POST"
        request.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try Self.encoder.encode(rows)
        return try Self.decoder.decode([T].self, from: try await send(request))
    }

    private func rest(_ table: String, query: String) async throws -> URLRequest {
        var components = URLComponents(url: base.appending(path: "rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Clips

    /// Upload (or replace) a clip at `path` in the bucket.
    func upload(_ file: URL, to path: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        var request = URLRequest(url: base.appending(path: "storage/v1/object/\(Self.bucket)/\(path)"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await bearer(lasting: 45 * 60))", forHTTPHeaderField: "Authorization")
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let delegate = progress.map(TransferProgress.init)
        do {
            let (data, response) = try await transfers.upload(for: request, fromFile: file, delegate: delegate)
            try Self.check(data, response)
        } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
            // Once more: a dropped connection mid-upload is common on the go.
            let (data, response) = try await transfers.upload(for: request, fromFile: file, delegate: delegate)
            try Self.check(data, response)
        }
    }

    /// A link to stream or download a clip, good for `seconds`.
    func signedURL(for path: String, seconds: Int = 6 * 3600) async throws -> URL {
        var request = URLRequest(url: base.appending(path: "storage/v1/object/sign/\(Self.bucket)/\(path)"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["expiresIn": seconds])
        struct Signed: Decodable { let signedURL: String }
        let signed = try JSONDecoder().decode(Signed.self, from: try await send(request))
        guard let url = URL(string: base.absoluteString + "/storage/v1" + signed.signedURL) else { throw Failure.unreadable }
        return url
    }

    /// Download a clip to `destination` (replacing anything there),
    /// reporting progress 0–1.
    func download(_ path: String, to destination: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let delegate = progress.map(TransferProgress.init)
        let (temp, response) = try await transfers.download(from: try await signedURL(for: path, seconds: 3600), delegate: delegate)
        try Self.check(Data(), response)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    // MARK: - Plumbing

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(data, response)
        return data
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["message"] ?? $0["msg"] ?? $0["error_description"] ?? $0["error"]) as? String }
            throw Failure.server(http.statusCode, message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Postgres timestamps come with fractional seconds, which .iso8601 rejects.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let precise = ISO8601DateFormatter()
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = precise.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return d
    }()
}

/// Reports an upload's or a download's progress, 0–1. Only watches: a
/// download delegate that handled the finished file would make the async
/// download API hand back a file that's already gone.
private final class TransferProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in report(progress.fractionCompleted) }
    }
}

/// The labeling session's refresh token, in the Keychain.
private enum Keychain {
    private static let service = "app.BumpSetCut.labeling"
    private static let account = "refresh-token"

    static var refreshToken: String? {
        get {
            var item: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
            guard let newValue else { return }
            var add = query
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
