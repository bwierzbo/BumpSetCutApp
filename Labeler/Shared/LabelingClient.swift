//
//  LabelingClient.swift
//  Labeler (also compiled into RallyLab)
//
//  Supabase over plain REST for labeling: sign in with email and password,
//  Apple or Google (the refresh token is kept in the Keychain), read and write the labeling
//  tables, and move clips in and out of the private "labeling" bucket.
//  Plain URLSession, so RallyLab and the Labeler app share it without the
//  Supabase package. Only labelers (public.labelers) get anything back.
//

import CryptoKit
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
    /// The signed-in account's email (an Apple relay address for a hidden one).
    private(set) var email: String?

    // MARK: - Auth

    /// Signed in before (a refresh token is in the Keychain).
    var hasSession: Bool { Keychain.refreshToken != nil }

    func signIn(email: String, password: String) async throws {
        try await token(grant: "password", body: ["email": email, "password": password])
    }

    /// Sign in with Apple: the ID token Apple handed the app, and the raw
    /// nonce whose SHA-256 went into the request (see `nonce()`).
    func signInWithApple(idToken: String, nonce: String) async throws {
        try await token(grant: "id_token", body: ["provider": "apple", "id_token": idToken, "nonce": nonce])
    }

    /// Where a provider's web sign-in returns to (allowed in Supabase's redirect list).
    static let callbackScheme = "rallylab"

    /// A provider's web sign-in (Google), PKCE: the page to open, and the
    /// verifier that goes back with the code it returns.
    nonisolated func webSignIn(_ provider: String) -> (url: URL, verifier: String) {
        let verifier = Self.nonce().raw
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = base.appending(path: "auth/v1/authorize").appending(queryItems: [
            .init(name: "provider", value: provider),
            .init(name: "redirect_to", value: "\(Self.callbackScheme)://auth-callback"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "s256"),
        ])
        return (url, verifier)
    }

    /// Finish a web sign-in with the URL it came back on.
    func finishWebSignIn(callback: URL, verifier: String) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw Failure.server(400, items.first { $0.name == "error_description" }?.value ?? "Sign-in didn't finish.")
        }
        try await token(grant: "pkce", body: ["auth_code": code, "code_verifier": verifier])
    }

    /// A random one-time value, and its SHA-256 in hex (what Apple's request carries).
    nonisolated static func nonce() -> (raw: String, hashed: String) {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: 64)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        let raw = String(bytes.map { charset[Int($0) % charset.count] })
        return (raw, SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// Email a password-reset code (the same as BumpSetCut's Forgot Password).
    func sendPasswordReset(email: String) async throws {
        _ = try await send(try authRequest("auth/v1/recover", method: "POST", body: ["email": email]))
    }

    /// Sign in with the emailed code and set a new password.
    func resetPassword(email: String, code: String, newPassword: String) async throws {
        try keep(try await send(try authRequest("auth/v1/verify", method: "POST",
                                                body: ["type": "recovery", "email": email, "token": code])))
        var request = try authRequest("auth/v1/user", method: "PUT", body: ["password": newPassword])
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    private func authRequest(_ path: String, method: String, body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func signOut() {
        Keychain.refreshToken = nil
        accessToken = nil
        userId = nil
        email = nil
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
        try keep(try await send(request))
    }

    /// Keep a session the auth server handed back.
    private func keep(_ data: Data) throws {
        struct Token: Decodable {
            struct User: Decodable { let id: UUID; let email: String? }
            let accessToken: String, refreshToken: String, expiresIn: Double, user: User
        }
        let t = try Self.decoder.decode(Token.self, from: data)
        accessToken = t.accessToken
        expiresAt = Date().addingTimeInterval(t.expiresIn - 60)
        userId = t.user.id
        email = t.user.email
        Keychain.refreshToken = t.refreshToken
    }

    /// A valid access token, for the live connection (LabelingLive).
    func liveToken() async throws -> String { try await bearer(lasting: 300) }

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

    /// Every video's rally times, or only those changed after `since`.
    func rallyTimes(since: Date? = nil) async throws -> [LabelRallyTimes] {
        try await get("label_rally_times", query: "select=*" + Self.changed(since))
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

    /// Every tracked rally (deleted ones too), or only those changed after `since`.
    func tracks(since: Date? = nil) async throws -> [LabelTrack] {
        try await get("label_tracks", query: "select=*" + Self.changed(since))
    }

    /// Each tracked rally's id, video, whether it's deleted and when it last
    /// changed — a few bytes a rally, to see which changed before fetching
    /// their frames.
    struct TrackStamp: Codable, Hashable {
        let id: UUID
        let videoId: UUID
        let deleted: Bool
        let updatedAt: Date?
    }

    func trackStamps() async throws -> [TrackStamp] {
        try await get("label_tracks", query: "select=id,video_id,deleted,updated_at")
    }

    /// These tracked rallies in full, a batch at a time (the ids go in the URL).
    func tracks(ids: [UUID]) async throws -> [LabelTrack] {
        var out: [LabelTrack] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[start..<min(start + 100, ids.count)].map { $0.uuidString.lowercased() }.joined(separator: ",")
            out += try await get("label_tracks", query: "select=*&id=in.(\(batch))") as [LabelTrack]
        }
        return out
    }

    /// A filter for rows changed after `since` (UTC, so the time has no "+").
    // MARK: - Stage 1 rally-boundary records (migration 048)

    /// Every recording's record row (or those saved after `since`).
    func rallyEvents(since: Date? = nil) async throws -> [LabelRallyEvents] {
        try await get("label_rally_events", query: "select=*" + Self.changed(since))
    }

    /// Saves a record at the revision it was loaded from (0 = none on the server yet) through `rally_events_save`.
    /// The record travels with its own camelCase keys (never this client's snake-case encoder). A stale revision
    /// throws `RallyEventsConflict`; a withheld recording throws `Failure.server(403, "withheld: …")`.
    func saveRallyEvents(videoId: UUID, expected: Int, record: EventReview.File) async throws -> LabelRallyEvents {
        struct Params: Encodable { let p_video: String; let p_expected: Int; let p_record: EventReview.File }
        var request = try await rest("rpc/rally_events_save", query: "")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Params(p_video: videoId.uuidString.lowercased(), p_expected: expected, p_record: record))
        do {
            let rows = try Self.decoder.decode([LabelRallyEvents].self, from: try await send(request))
            guard let row = rows.first else { throw Failure.unreadable }
            return row
        } catch Failure.server(let code, let message) {
            if let conflict = RallyEventsSync.conflict(in: message) { throw conflict }
            throw Failure.server(code, message)
        }
    }

    /// The project's withheld recordings as published by the Mac (empty when none is published: then nothing is
    /// accepted by the server either — the phone shows every listed recording as not reviewable).
    func withheld(project: String) async throws -> (listed: Bool, names: Set<String>) {
        struct Listing: Decodable { let project: String; let names: Int }
        struct Row: Decodable { let sessionName: String }
        let lists: [Listing] = try await get("label_withheld_lists", query: "select=project,names&project=eq.\(Self.encoded(project))")
        let rows: [Row] = try await get("label_withheld", query: "select=session_name&project=eq.\(Self.encoded(project))")
        return (!lists.isEmpty, Set(rows.map(\.sessionName)))
    }

    /// Publishes a project's withheld list whole (leads only on the server). Returns the count stored.
    func publishWithheld(project: String, names: [String]) async throws -> Int {
        struct Params: Encodable { let p_project: String; let p_names: [String] }
        var request = try await rest("rpc/label_withheld_publish", query: "")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Params(p_project: project, p_names: names.sorted()))
        let data = try await send(request)
        return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? names.count
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func changed(_ since: Date?) -> String {
        guard let since else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "&updated_at=gt.\(f.string(from: since))"
    }

    /// Insert or update tracked rallies, by id.
    func save(_ tracks: [LabelTrack]) async throws {
        guard !tracks.isEmpty else { return }
        let now = Date()
        let rows = tracks.map { t -> LabelTrack in var t = t; t.updatedAt = t.updatedAt ?? now; return t }
        // A nil field is left out (the server keeps what it has), and a batch
        // whose rows don't all have the same fields is refused ("All object
        // keys must match"): send rows with the same fields together.
        let groups = Dictionary(grouping: rows) { [$0.reviewed != nil, $0.unsure != nil, $0.machine != nil, $0.isRally != nil] }
        for group in groups.values {
            let _: [LabelTrack] = try await upsert("label_tracks", group, onConflict: "id")
        }
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

    // MARK: - Footage from testers (migration 036)

    /// A video a tester's phone sent for training: its rallies as clips in
    /// the `training-data` bucket.
    struct TesterFootage: Decodable {
        struct Window: Decodable { let start: Double; let end: Double }
        let id: String
        let userId: String
        let username: String?
        let clipUrls: [String]
        let clipWindows: [Window]
        let consentVersion: String?
        let deviceModel: String?
        let createdAt: Date
    }

    /// What testers have sent, leaving out labelers' own footage.
    func testerFootage() async throws -> [TesterFootage] {
        try await rpc("tester_footage", [:])
    }

    /// A rally someone posted to the feed (public).
    struct PostedClip: Decodable {
        struct Author: Decodable { let username: String }
        let id: String
        let createdAt: Date
        let muxPlaybackId: String?
        let videoUrls: [String]?
        let locationName: String?
        let profiles: Author
        /// Its videos: one per carousel page, or the single older one.
        var urls: [URL] { (videoUrls ?? muxPlaybackId.map { [$0] } ?? []).compactMap(URL.init(string:)) }
    }

    /// The rallies these people posted, oldest first.
    func postedClips(by usernames: [String]) async throws -> [PostedClip] {
        let names = usernames.map { "\"\($0)\"" }.joined(separator: ",")
        let query = "select=id,created_at,mux_playback_id,video_urls,location_name,profiles!inner(username)"
            + "&profiles.username=in.(\(names))&order=created_at"
        return try await get("highlights", query: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
    }

    /// Download a public file (a posted rally) to `destination`.
    func downloadPublic(_ url: URL, to destination: URL) async throws {
        let (temp, response) = try await transfers.download(from: url)
        try Self.check(Data(), response)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    // MARK: - Annotation review, several people at once

    /// Claim a rally for review (see migration 033); false when someone
    /// else holds a fresh claim.
    func reviewClaim(_ track: UUID) async throws -> Bool {
        try await rpc("review_claim", ["p_track": track.uuidString.lowercased()])
    }

    /// Take a rally over from whoever is reviewing it (migration 034).
    func reviewTakeOver(_ track: UUID) async throws {
        var request = try await rest("rpc/review_take_over", query: "")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["p_track": track.uuidString.lowercased()])
        _ = try await send(request)
    }

    /// Rallies someone else is reviewing right now.
    func reviewHeldByOthers() async throws -> [UUID] {
        struct Row: Decodable { let track: UUID }
        let rows: [Row] = try await rpc("review_held_by_others", [:])
        return rows.map(\.track)
    }

    /// One review decision on a rally's frame, as the server applies it.
    struct FrameEdit: Codable, Hashable {
        var track: UUID
        var index: Int
        var point: TrackPoint
        var reviewed: Bool { point.reviewed }
        var unsure: Bool { point.unsure }
    }

    /// Save decisions on one rally's frames, frame by frame on the server.
    func reviewFrames(_ track: UUID, _ edits: [FrameEdit]) async throws {
        struct Edit: Encodable { let i: Int; let point: [Double]; let reviewed: Bool; let unsure: Bool }
        struct Params: Encodable { let p_track: String; let p_edits: [Edit] }
        let params = Params(p_track: track.uuidString.lowercased(),
                            p_edits: edits.map { Edit(i: $0.index, point: LabelTrack.PackedPoints.row($0.point), reviewed: $0.reviewed, unsure: $0.unsure) })
        var request = try await rest("rpc/review_frames", query: "")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(params)
        _ = try await send(request)
    }

    /// Whether a pre-tracked rally is a rally (migration 038); nil takes it back.
    struct RallyVerdict: Codable, Hashable {
        let track: UUID
        let isRally: Bool?
    }

    func reviewRally(_ verdict: RallyVerdict) async throws {
        struct Params: Encodable { let p_track: String; let p_is_rally: Bool? }
        var request = try await rest("rpc/review_rally", query: "")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Params(p_track: verdict.track.uuidString.lowercased(), p_is_rally: verdict.isRally))
        _ = try await send(request)
    }

    // MARK: - Checking other labelers (migration 039; leads only)

    /// Another labeler's frames so far: labeled, checked right or wrong, waiting to be checked.
    struct LabelerSummary: Decodable, Hashable, Identifiable {
        let labeler: UUID
        let name: String
        let labeled: Int, approved: Int, wrong: Int, waiting: Int
        let lastAt: Date?
        var id: UUID { labeler }
    }

    /// Everyone else's frames; empty for someone who isn't a lead.
    func labelerSummary() async throws -> [LabelerSummary] {
        try await rpc("labeler_summary", [:])
    }

    /// A labeler's frames waiting to be checked, rally by rally in frame order.
    func labelerFrames(_ labeler: UUID) async throws -> [(track: UUID, index: Int)] {
        struct Row: Decodable { let track: UUID; let i: Int }
        let rows: [Row] = try await rpc("labeler_frames", ["p_labeler": labeler.uuidString.lowercased()])
        return rows.map { ($0.track, $0.i) }
    }

    /// A lead's check of a labeler's frame: right, wrong, or nil to take it back.
    struct LabelVerdict: Encodable {
        let track: UUID
        let i: Int
        let labeler: UUID
        let ok: Bool?
    }

    func labelVerdicts(_ verdicts: [LabelVerdict]) async throws {
        struct Params: Encodable { let p_verdicts: [LabelVerdict] }
        var request = try await rest("rpc/label_verdicts", query: "")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Params(p_verdicts: verdicts))
        _ = try await send(request)
    }

    // MARK: - Final check of finished rallies (migration 044; leads only)

    /// Rallies signed off whose frames haven't been relabeled since.
    func rallyFinals() async throws -> Set<UUID> {
        struct Row: Decodable { let track: UUID }
        let rows: [Row] = try await rpc("rally_finals", [:])
        return Set(rows.map(\.track))
    }

    /// Sign a rally off, or take that back.
    func rallyFinal(_ track: UUID, ok: Bool) async throws {
        struct Params: Encodable { let p_track: String; let p_ok: Bool }
        var request = try await rest("rpc/rally_final", query: "")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Params(p_track: track.uuidString.lowercased(), p_ok: ok))
        _ = try await send(request)
    }

    // MARK: - RallyCoin (migrations 040–041; a joke)

    /// A labeler on the board: coins left, frames labeled, what they bought.
    struct CoinHolder: Decodable, Hashable {
        let name: String
        let coins: Int
        let frames: Int
        let me: Bool
        let owns: [String]
    }

    struct ShopItem: Decodable, Hashable, Identifiable {
        let id: String
        let name: String
        let emoji: String
        let blurb: String
        let price: Int
    }

    func coinBoard() async throws -> [CoinHolder] { try await rpc("rallycoin_board", [:]) }

    func shopItems() async throws -> [ShopItem] { try await get("rallycoin_items", query: "select=*&order=price") }

    /// Buy one; what's left after. The server refuses when it's too dear.
    func buy(_ item: String) async throws -> Int { try await rpc("rallycoin_buy", ["p_item": item]) }

    private func rpc<T: Decodable>(_ name: String, _ params: [String: String]) async throws -> T {
        var request = try await rest("rpc/\(name)", query: "")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(params)
        return try Self.decoder.decode(T.self, from: try await send(request))
    }

    /// Remove a clip from the bucket (one replaced by a newer copy).
    func remove(_ path: String) async throws {
        var request = URLRequest(url: base.appending(path: "storage/v1/object/\(Self.bucket)/\(path)"))
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    /// A link to stream or download a clip, good for `seconds`.
    func signedURL(for path: String, in bucket: String = LabelingClient.bucket, seconds: Int = 6 * 3600) async throws -> URL {
        var request = URLRequest(url: base.appending(path: "storage/v1/object/sign/\(bucket)/\(path)"))
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

    /// Download a clip (from the labeling bucket unless another is named)
    /// to `destination`, replacing anything there, reporting progress 0–1.
    func download(_ path: String, from bucket: String = LabelingClient.bucket, to destination: URL,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let delegate = progress.map(TransferProgress.init)
        let (temp, response) = try await transfers.download(from: try await signedURL(for: path, in: bucket, seconds: 3600),
                                                            delegate: delegate)
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
