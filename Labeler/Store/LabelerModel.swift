//
//  LabelerModel.swift
//  RallyLab (iPhone)
//
//  The app's state: who's signed in; the project's videos, rally times,
//  tracked rallies and training plan (last loaded copy kept on the phone,
//  so it opens offline); edits queued in an outbox until they're saved;
//  clips kept on the phone; and the next tasks, from the training plan.
//

import Foundation
import Observation

@MainActor
@Observable
final class LabelerModel {

    enum Phase { case starting, signedOut, notLabeler, ready }

    private(set) var phase = Phase.starting
    private(set) var snapshot = LabelSnapshot()
    private(set) var outbox = Outbox()
    private(set) var isLoading = false
    private(set) var isOffline = false
    private(set) var today = DayStats.today
    var error: String?

    private let client = LabelingClient.shared
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    init() {
        snapshot = LocalStore.load(LabelSnapshot.self, "snapshot.json") ?? LabelSnapshot()
        outbox = LocalStore.load(Outbox.self, "outbox.json") ?? Outbox()
    }

    // MARK: - Session

    func start() async {
        guard await client.hasSession else { phase = .signedOut; return }
        if !snapshot.videos.isEmpty { phase = .ready }
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
        snapshot = LabelSnapshot()
        LocalStore.save(snapshot, "snapshot.json")
        phase = .signedOut
    }

    /// Send what's waiting, then load everything again.
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            await flush()
            async let v = client.videos()
            async let t = client.rallyTimes()
            async let k = client.tracks()
            async let s = client.projectStates()
            let loaded = try await LabelSnapshot(videos: v, times: t, tracks: k, states: s)
            guard try await client.isLabeler() else { phase = .notLabeler; return }
            snapshot = loaded
            LocalStore.save(snapshot, "snapshot.json")
            isOffline = false
            phase = .ready
        } catch LabelingClient.Failure.notSignedIn {
            phase = .signedOut
        } catch {
            // No connection: keep working from what's on the phone.
            isOffline = true
            if phase == .starting { phase = snapshot.videos.isEmpty ? .signedOut : .ready }
        }
    }

    // MARK: - Reading (local edits over what was loaded)

    var videos: [LabelVideo] { snapshot.videos.filter { $0.clipPath != nil } }

    func video(_ id: UUID) -> LabelVideo? { snapshot.videos.first { $0.id == id } }

    func rallyTimes(for video: LabelVideo) -> LabelRallyTimes {
        outbox.times[video.id] ?? snapshot.times.first { $0.videoId == video.id }
            ?? LabelRallyTimes(videoId: video.id, rallies: [], complete: false)
    }

    /// The video's tracked rallies (not deleted), in time order.
    func tracks(for video: LabelVideo) -> [LabelTrack] { tracks(videoId: video.id) }

    private func tracks(videoId: UUID) -> [LabelTrack] {
        var byId = Dictionary(snapshot.tracks.filter { $0.videoId == videoId }.map { ($0.id, $0) }) { a, _ in a }
        for t in outbox.tracks.values where t.videoId == videoId { byId[t.id] = t }
        return byId.values.filter { !$0.deleted }.sorted { $0.start < $1.start }
    }

    /// Found rallies not marked, not said to be no rally: what review asks about.
    func openFound(in video: LabelVideo) -> [[Double]] {
        let marked = rallyTimes(for: video).rallies
        let rejected = LocalStore.rejected(video)
        return video.ralliesFound.filter { f in
            !rejected.contains(LocalStore.key(f)) && !marked.contains { min($0.end, f[1]) - max($0.start, f[0]) > 0.3 }
        }
    }

    /// Rallies to track, in time order: your marked ones, then the found
    /// ones you haven't marked or turned down — none already tracked.
    func untrackedRallies(in video: LabelVideo) -> [LabelRally] {
        let marked = rallyTimes(for: video).rallies
        let found = openFound(in: video).map { LabelRally(start: $0[0], end: $0[1]) }
        let tracked = tracks(for: video)
        return (marked + found)
            .filter { r in !tracked.contains { min($0.end, r.end) - max($0.start, r.start) > 0.5 * (r.end - r.start) } }
            .sorted { $0.start < $1.start }
    }

    /// A track of `rally` you started and didn't finish.
    func unfinishedTrack(of rally: LabelRally, in video: LabelVideo) -> LabelTrack? {
        tracks(for: video).first { !$0.done && $0.rally.bounds == rally }
    }

    /// The rally to track next in a video: one you started and left first,
    /// so it's picked up where you stopped — tracking begun, else trimmed —
    /// then the untracked ones.
    func nextRally(in video: LabelVideo) -> LabelRally? {
        let untracked = untrackedRallies(in: video)
        return tracks(for: video).first { !$0.done }?.rally.bounds
            ?? untracked.first { LocalStore.trim(of: $0, in: video) != nil }
            ?? untracked.first
    }

    // MARK: - Plan

    var project: String? { snapshot.videos.compactMap(\.project).first }

    var projectState: LabelProjectState? { snapshot.states.first { $0.project == project } }

    /// The first round not trained yet.
    var currentRound: TrainingPlan.Round? {
        let trained = Set(projectState?.plan.map(\.round) ?? [])
        return TrainingPlan.rounds.first { !trained.contains($0.number) }
    }

    func planVideo(_ v: LabelVideo) -> PlanVideo {
        let done = tracks(for: v).filter(\.done)
        return PlanVideo(name: v.name, surface: v.surface.rawValue, split: v.split, available: v.clipPath != nil,
                         doneTracks: done.count, labeledFrames: done.reduce(0) { $0 + $1.labeledFrames },
                         openRallies: untrackedRallies(in: v).count, ralliesMarked: rallyTimes(for: v).complete)
    }

    var progress: PlanProgress { PlanProgress(videos: videos.map(planVideo), round: currentRound) }

    // MARK: - Next tasks

    enum LabelTask: Identifiable, Hashable {
        /// Confirm the rallies found in a video, find missed ones, finish it.
        case review(LabelVideo)
        /// Track one rally's ball, frame by frame.
        case track(LabelVideo, LabelRally)

        var id: String {
            switch self {
            case .review(let v): return "review-\(v.id)"
            case .track(let v, let r): return "track-\(v.id)-\(Int(r.start * 10))"
            }
        }

        var video: LabelVideo {
            switch self { case .review(let v), .track(let v, _): return v }
        }
    }

    /// What to do next (LabelQueue — the same rules as the Mac).
    var tasks: [LabelTask] {
        let byName = Dictionary(videos.map { ($0.name, $0) }) { a, _ in a }
        let queue = videos.map { v in
            LabelQueue.Video(plan: planVideo(v), nextRally: nextRally(in: v),
                             found: v.ralliesFound.count, complete: rallyTimes(for: v).complete)
        }
        return LabelQueue.jobs(queue, round: currentRound).compactMap { job in
            guard let v = byName[job.video] else { return nil }
            switch job {
            case .track(_, let r): return .track(v, r)
            case .review: return .review(v)
            }
        }
    }

    // MARK: - Editing

    func update(_ video: LabelVideo, _ change: (inout LabelRallyTimes) -> Void) {
        var t = rallyTimes(for: video)
        let wasComplete = t.complete
        change(&t)
        t.rallies.sort { $0.start < $1.start }
        t.updatedAt = Date()
        outbox.times[video.id] = t
        if t.complete && !wasComplete { count { $0.videos += 1 } }
        queueFlush()
    }

    /// A tracked rally's own start and end go into the video's rally times
    /// (replacing any marked rally it overlaps).
    func markRally(_ rally: LabelRally, in video: LabelVideo) {
        update(video) { t in
            t.rallies.removeAll { min($0.end, rally.end) - max($0.start, rally.start) > 0.3 }
            t.rallies.append(rally)
        }
    }

    func rejectFound(_ found: [Double], in video: LabelVideo) {
        LocalStore.reject(found, in: video)
        // Reading openFound again picks it up; nothing to sync.
        snapshot = snapshot
    }

    func save(_ track: LabelTrack) {
        var t = track
        let before = tracks(videoId: track.videoId).first { $0.id == track.id }
        t.updatedAt = Date()
        outbox.tracks[t.id] = t
        if t.done && before?.done != true { count { $0.rallies += 1; $0.frames += t.labeledFrames } }
        queueFlush()
    }

    func delete(_ track: LabelTrack) {
        var t = track
        t.deleted = true
        save(t)
        LocalStore.removeTracking(track.id)
    }

    private func count(_ change: (inout DayStats) -> Void) {
        if today.day != DayStats.today.day { today = DayStats.today }
        change(&today)
        LocalStore.save(today, "today.json")
    }

    // MARK: - Outbox

    private func queueFlush() {
        LocalStore.save(outbox, "outbox.json")
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Save everything waiting. What fails stays for next time.
    func flush() async {
        guard !outbox.isEmpty else { return }
        for (id, times) in outbox.times {
            do {
                let saved = try await client.save(times)
                if outbox.times[id] == times { outbox.times[id] = nil }
                snapshot.times.removeAll { $0.videoId == id }
                snapshot.times.append(saved)
            } catch { isOffline = true; break }
        }
        let tracks = Array(outbox.tracks.values)
        if !tracks.isEmpty {
            do {
                try await client.save(tracks)
                for t in tracks where outbox.tracks[t.id] == t {
                    outbox.tracks[t.id] = nil
                    snapshot.tracks.removeAll { $0.id == t.id }
                    snapshot.tracks.append(t)
                }
                isOffline = false
            } catch { isOffline = true }
        }
        LocalStore.save(outbox, "outbox.json")
        LocalStore.save(snapshot, "snapshot.json")
    }

    // MARK: - Clips

    /// Clips downloading, and how far along (0–1).
    private(set) var downloads: [UUID: Double] = [:]
    @ObservationIgnored private var inFlight: [UUID: Task<URL, Error>] = [:]

    /// The clip on the phone, downloading it first if needed (one download
    /// per clip, however many ask).
    func localClip(for video: LabelVideo) async throws -> URL {
        let file = LocalStore.clip(for: video)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        if let running = inFlight[video.id] { return try await running.value }
        guard let path = video.clipPath else { throw LabelingClient.Failure.unreadable }
        let id = video.id
        let partial = file.appendingPathExtension("part")
        let task = Task<URL, Error> { [client] in
            try await client.download(path, to: partial) { p in
                Task { @MainActor [weak self] in if self?.downloads[id] != nil { self?.downloads[id] = p } }
            }
            try FileManager.default.moveItem(at: partial, to: file)
            return file
        }
        inFlight[id] = task
        downloads[id] = 0
        defer { inFlight[id] = nil; downloads[id] = nil }
        return try await task.value
    }

    /// Fetch the next few tasks' clips in the background, one at a time,
    /// so tasks open with their clip already here.
    func prefetch(next n: Int = 3) {
        let wanted = tasks.prefix(n).map(\.video).filter { !LocalStore.hasClip($0) && inFlight[$0.id] == nil }
        guard !wanted.isEmpty, !isOffline else { return }
        Task {
            for v in wanted { _ = try? await localClip(for: v) }
        }
    }

    /// The clip to play: on the phone if it's there, else streamed.
    func playbackURL(for video: LabelVideo) async throws -> URL {
        if LocalStore.hasClip(video) { return LocalStore.clip(for: video) }
        guard let path = video.clipPath else { throw LabelingClient.Failure.unreadable }
        return try await client.signedURL(for: path)
    }

    /// Keep the clips for the next `n` tasks on the phone, for no signal.
    func makeOffline(next n: Int) async {
        for task in tasks.prefix(n) where !LocalStore.hasClip(task.video) {
            do { _ = try await localClip(for: task.video) } catch { self.error = "Couldn't download \(task.video.name): \(error.localizedDescription)"; return }
        }
    }

    /// Clips on the phone for videos that are finished (rally times done and
    /// no rally the plan still wants tracked) — safe to remove.
    func removeFinishedClips() {
        let wanted = Set(tasks.map(\.video.id))
        for v in videos where LocalStore.hasClip(v) && !wanted.contains(v.id) { LocalStore.removeClip(v) }
        snapshot = snapshot
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
    /// RallyLab on the Mac to pull into its project.
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
            snapshot.videos.append(try await client.save(video))
            LocalStore.save(snapshot, "snapshot.json")
            return true
        } catch {
            self.error = "Upload failed: \(error.localizedDescription)"
            return false
        }
    }
}
