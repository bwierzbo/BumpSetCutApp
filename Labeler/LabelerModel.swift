//
//  LabelerModel.swift
//  Labeler
//
//  The app's state: who's signed in, the videos to label with their rally
//  times, and uploading a video recorded on this phone.
//

import Foundation
import Observation

@MainActor
@Observable
final class LabelerModel {

    enum Phase { case starting, signedOut, notLabeler, ready }

    private(set) var phase = Phase.starting
    private(set) var videos: [LabelVideo] = []
    private(set) var times: [UUID: LabelRallyTimes] = [:]
    private(set) var isLoading = false
    var error: String?

    private let client = LabelingClient.shared
    /// Edits waiting to be saved, per video (saved a moment after the last change).
    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    // MARK: - Session

    func start() async {
        guard await client.hasSession else { phase = .signedOut; return }
        await reload()
    }

    func signIn(email: String, password: String) async {
        do {
            try await client.signIn(email: email, password: password)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() async {
        await client.signOut()
        videos = []
        times = [:]
        phase = .signedOut
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let v = client.videos()
            async let t = client.rallyTimes()
            let (loadedVideos, loadedTimes) = try await (v, t)
            guard try await client.isLabeler() else { phase = .notLabeler; return }
            videos = loadedVideos
            // Keep local edits not saved yet over what the server has.
            let fromServer = Dictionary(uniqueKeysWithValues: loadedTimes.map { ($0.videoId, $0) })
            times = fromServer.merging(times.filter { pendingSaves[$0.key] != nil }) { _, local in local }
            phase = .ready
        } catch LabelingClient.Failure.notSignedIn {
            phase = .signedOut
        } catch {
            self.error = error.localizedDescription
            if phase == .starting { phase = .ready }
        }
    }

    // MARK: - Rally times

    func rallyTimes(for video: LabelVideo) -> LabelRallyTimes {
        times[video.id] ?? LabelRallyTimes(videoId: video.id, rallies: [], complete: false)
    }

    /// Change a video's rally times; saved a second after the last change.
    func update(_ video: LabelVideo, _ change: (inout LabelRallyTimes) -> Void) {
        var t = rallyTimes(for: video)
        change(&t)
        t.rallies.sort { $0.start < $1.start }
        times[video.id] = t
        pendingSaves[video.id]?.cancel()
        pendingSaves[video.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, let latest = self.times[video.id] else { return }
            do {
                _ = try await self.client.save(latest)
            } catch {
                self.error = "Couldn't save rally times: \(error.localizedDescription)"
            }
            self.pendingSaves[video.id] = nil
        }
    }

    func playbackURL(for video: LabelVideo) async throws -> URL {
        guard let path = video.clipPath else { throw LabelingClient.Failure.unreadable }
        return try await client.signedURL(for: path)
    }

    // MARK: - Uploading from this phone

    struct UploadRequest {
        let source: URL
        let start: Double
        let length: Double
        let title: String
        let surface: LabelSurface
        let camera: LabelCamera
        let lighting: String
    }

    private(set) var uploadStage: String?
    private(set) var uploadProgress: Double = 0

    /// Re-encode the chosen stretch small, upload it, and list it for
    /// RallyLab to pull into its project.
    func upload(_ request: UploadRequest) async -> Bool {
        let id = UUID()
        let encoded = FileManager.default.temporaryDirectory.appendingPathComponent("\(id.uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: encoded)
            uploadStage = nil
        }
        do {
            uploadStage = "Preparing the clip…"
            uploadProgress = 0
            let duration = try await ClipEncoder.encode(request.source, from: request.start, length: request.length, to: encoded) { p in
                Task { @MainActor [weak self] in self?.uploadProgress = p }
            }
            uploadStage = "Uploading…"
            uploadProgress = 0
            let path = "phone/\(id.uuidString.lowercased()).mp4"
            try await client.upload(encoded, to: path) { p in
                Task { @MainActor [weak self] in self?.uploadProgress = p }
            }
            let video = LabelVideo(id: id, project: nil, sessionName: nil, title: request.title, surface: request.surface,
                                   camera: request.camera, lighting: request.lighting, split: "train", clipPath: path,
                                   duration: duration, ralliesFound: [], status: .uploaded, updatedAt: nil)
            videos.append(try await client.save(video))
            return true
        } catch {
            self.error = "Upload failed: \(error.localizedDescription)"
            return false
        }
    }
}
