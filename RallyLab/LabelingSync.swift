//
//  LabelingSync.swift
//  RallyLab
//
//  The open project ↔ the Labeler iPhone app, through Supabase (see
//  Labeler/Shared/LabelingClient.swift):
//
//  1. Videos recorded on the phone are downloaded and added to the project,
//     on the clip card matching where they were filmed, and sampled.
//  2. Every video in the project is listed for the phone with the rallies
//     the pipeline found, and a small copy of its cut (720p, ~2 Mbit/s) is
//     uploaded once.
//  3. Rally times go both ways: whichever side changed them last wins.
//  4. Tracked rallies go both ways the same way, deletions included.
//  5. The training plan and its runs' scores go up for the phone's Plan tab.
//
//  Headless: RallyLab --project <name> --sync-phone (after signing in once
//  in the app; the session is kept in the Keychain).
//

import AppKit
import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class LabelingSync {

    let projects: ProjectsModel
    private(set) var signedIn = false
    private(set) var isSyncing = false
    private(set) var status = ""
    private(set) var lastSynced: Date?
    /// A session's tracked rallies / rally times were changed by a sync:
    /// whatever has that session open takes the new ones.
    var onTracksChanged: ((String) -> Void)?
    var onTimesChanged: ((String) -> Void)?
    @ObservationIgnored private var auto: Task<Void, Never>?
    @ObservationIgnored private var activation: Any?

    private let client = LabelingClient.shared

    init(projects: ProjectsModel) {
        self.projects = projects
        Task { signedIn = await client.hasSession }
    }

    func signIn(email: String, password: String) async {
        do {
            try await client.signIn(email: email, password: password)
            signedIn = true
            status = try await client.isLabeler() ? "Signed in." : "Signed in, but this account isn't a labeler (public.labelers)."
        } catch {
            status = error.localizedDescription
        }
    }

    func signOut() async {
        await client.signOut()
        signedIn = false
    }

    // MARK: - Automatic

    /// Labels sync this often while RallyLab runs (and when it comes to the
    /// front); videos — new ones to send, the phone's to pull in — every
    /// `videoEvery` of those.
    static let interval: UInt64 = 30
    static let videoEvery = 10

    /// Keep the project synced with the phone from now on, while signed in.
    func startAutomatic() {
        guard auto == nil else { return }
        auto = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.signedIn, self.projects.project != nil {
                    await self.sync(videos: round % Self.videoEvery == 0)
                    round += 1
                }
                try? await Task.sleep(nanoseconds: Self.interval * 1_000_000_000)
            }
        }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.signedIn else { return }
                Task { await self.sync(videos: false) }
            }
        }
    }

    /// Run the sync: labels both ways and the plan, and with `videos` the
    /// videos too. False if it stopped on an error (status says why).
    @discardableResult
    func sync(videos: Bool = true) async -> Bool {
        guard !isSyncing, let project = projects.project?.name else { return false }
        isSyncing = true
        defer { isSyncing = false }
        do {
            var parts: [String] = []
            if videos {
                let imported = try await importPhoneVideos(project: project)
                let (listed, uploaded, failed) = try await publishVideos(project: project)
                parts.append("\(listed) videos listed (\(uploaded) uploaded\(failed.isEmpty ? "" : ", \(failed.count) failed — next sync retries: \(failed.joined(separator: ", "))")), \(imported) phone videos pulled in")
            }
            let (pushed, pulled) = try await syncRallyTimes(project: project)
            let (tracksSent, tracksReceived) = try await syncTracks(project: project)
            try await publishPlan(project: project)
            parts.append("rally times \(pushed) sent · \(pulled) received, tracked rallies \(tracksSent) sent · \(tracksReceived) received")
            status = "Synced: " + parts.joined(separator: ", ") + "."
            lastSynced = Date()
            return true
        } catch LabelingClient.Failure.notSignedIn {
            signedIn = false
            status = "Sign in to sync with the phone."
            return false
        } catch {
            status = "Sync stopped: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 1. Phone videos into the project

    private func importPhoneVideos(project: String) async throws -> Int {
        let waiting = try await client.videos().filter { $0.status == .uploaded && $0.clipPath != nil }
        var count = 0
        for var video in waiting {
            guard let clipId = clipCard(for: video), let path = video.clipPath, let dir = projects.projectDir else {
                status = "No clip card for \(video.name) (\(video.surface.rawValue), \(video.camera.title)) — skipped."
                continue
            }
            let incoming = dir.appendingPathComponent("incoming", isDirectory: true)
            let file = incoming.appendingPathComponent("phone-\(video.id.uuidString.lowercased()).mp4")
            let title = video.title.isEmpty ? "Phone video \(video.id.uuidString.prefix(8))" : video.title
            let videoId: String
            if let already = projectVideo(from: file) {
                // Pulled in by a sync that stopped before marking it imported.
                videoId = already
            } else {
                status = "Pulling in \(video.name) from the phone…"
                try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
                try await client.download(path, to: file)
                guard let added = projects.addVideo(to: clipId, source: file.path, start: 0, length: video.duration + 1,
                                                    license: ProjectsModel.ownFootageLicense) else {
                    status = "Couldn't add \(title): \(projects.status)"
                    continue
                }
                guard await waitForSampling(added) else {
                    status = "\(title) didn't sample: \(projects.status)"
                    continue
                }
                try? FileManager.default.removeItem(at: file)
                videoId = added
            }
            video.project = project
            video.sessionName = videoId
            video.status = .imported
            if let session = projects.session(named: videoId) {
                video.split = session.split
                video.ralliesFound = Self.ralliesFound(in: session)
            }
            try await client.save(video)
            count += 1
        }
        return count
    }

    /// The project video cut from `file` (a phone video pulled in), if any.
    private func projectVideo(from file: URL) -> String? {
        projects.project?.clips.lazy.compactMap { clip in
            clip.videos.first { $0.origin == file.path }.map { clip.videoId(of: $0) }
        }.first
    }

    /// The project's clip card for where a phone video was filmed: same
    /// surface, camera and lighting if there is one, else surface and camera.
    private func clipCard(for video: LabelVideo) -> String? {
        let clips = projects.project?.clips.filter { $0.environment == video.surface.rawValue } ?? []
        let camera = clips.filter { Self.camera(of: $0.id) == video.camera }
        return (camera.first { $0.lighting == video.lighting } ?? camera.first ?? clips.first)?.id
    }

    private func waitForSampling(_ videoId: String) async -> Bool {
        while true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            switch projects.progress(ofVideo: videoId) {
            case .pulled: return true
            case .failed: return false
            case .busy: continue
            case .notStarted:
                if projects.sampler.isIngesting || !projects.sampler.queue.allSatisfy(\.isFinished) { continue }
                return false
            }
        }
    }

    // MARK: - 2. Project videos to the phone

    private func publishVideos(project: String) async throws -> (listed: Int, uploaded: Int, failed: [String]) {
        let remote = try await client.videos().filter { $0.project == project }
        var listed = 0, uploaded = 0
        var failed: [String] = []
        let sessions = projects.sampler.sessions.filter { FileManager.default.fileExists(atPath: $0.sourcePath) }
        for (i, session) in sessions.enumerated() {
            guard let surface = LabelSurface(rawValue: Coverage.environment(session.name)) else { continue }
            let existing = remote.first { $0.sessionName == session.name }
            let source = URL(fileURLWithPath: session.sourcePath)
            var video = existing ?? LabelVideo(id: UUID(), project: project, sessionName: session.name, title: "",
                                               surface: surface, camera: Self.camera(of: session.name), lighting: "",
                                               split: session.split, clipPath: nil, duration: 0, ralliesFound: [],
                                               status: .rallylab, updatedAt: nil)
            video.title = clipVideo(named: session.name)?.title ?? video.title
            video.lighting = projects.project?.clips.first { clip in clip.videos.contains { clip.videoId(of: $0) == session.name } }?
                .lighting ?? video.lighting
            video.split = session.split
            video.ralliesFound = Self.ralliesFound(in: session)
            if video.duration <= 0 {
                video.duration = (try? await AVURLAsset(url: source).load(.duration).seconds) ?? 0
            }
            if video.clipPath == nil {
                status = "Uploading \(session.name) for the phone (\(i + 1) of \(sessions.count))…"
                let path = "rallylab/\(DatasetStore.safeName(project))/\(session.name).mp4"
                do {
                    try await uploadSmallCopy(of: source, to: path)
                    video.clipPath = path
                    uploaded += 1
                } catch LabelingClient.Failure.notSignedIn {
                    throw LabelingClient.Failure.notSignedIn
                } catch {
                    // One clip failing (a dropped connection) shouldn't stop the rest.
                    failed.append(session.name)
                    continue
                }
            }
            if video != existing {
                try await client.save(video)
            }
            listed += 1
        }
        return (listed, uploaded, failed)
    }

    private func clipVideo(named videoId: String) -> ClipSource? {
        projects.project?.clips.lazy.compactMap { clip in clip.videos.first { clip.videoId(of: $0) == videoId } }.first
    }

    /// The cut re-encoded small for the phone: upright, fitted in 1280×1280,
    /// ~2 Mbit/s, no sound, streamable — every frame at its original time,
    /// so a frame tracked on the phone is the same frame here.
    private func uploadSmallCopy(of source: URL, to path: String) async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let run = await ToolEnvironment.run("ffmpeg", [
            "-y", "-loglevel", "error", "-i", source.path, "-an",
            "-vf", "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))'", "-fps_mode", "passthrough",
            "-c:v", "libx264", "-preset", "veryfast", "-b:v", "2M", "-maxrate", "2500k", "-bufsize", "4M",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", out.path,
        ])
        guard run.status == 0 else { throw SyncError.encode(run.lines.last ?? "ffmpeg failed") }
        try await client.upload(out, to: path)
    }

    enum SyncError: LocalizedError {
        case encode(String)
        var errorDescription: String? {
            switch self { case .encode(let why): return "Couldn't make the phone copy: \(why)" }
        }
    }

    // MARK: - 3. Rally times, both ways

    private func syncRallyTimes(project: String) async throws -> (pushed: Int, pulled: Int) {
        let videos = try await client.videos().filter { $0.project == project && $0.sessionName != nil }
        let remote = Dictionary(uniqueKeysWithValues: try await client.rallyTimes().map { ($0.videoId, $0) })
        var pushed = 0, pulled = 0
        for video in videos {
            guard let name = video.sessionName, let session = projects.session(named: name) else { continue }
            let labels = RallyMarkModel.labelsURL(for: URL(fileURLWithPath: session.sourcePath))
            let localRallies = (try? Data(contentsOf: labels)).flatMap { try? JSONDecoder().decode([LabeledRally].self, from: $0) }
            let localChanged = (try? labels.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let local = localRallies.map { rallies in
                LabelRallyTimes(videoId: video.id, rallies: rallies.map { LabelRally(start: $0.startTime, end: $0.endTime) },
                                complete: session.ralliesMarked ?? false)
            }
            let theirs = remote[video.id]
            switch (local, theirs) {
            case (nil, nil):
                continue
            case (let mine?, nil):
                try await client.save(mine)
                pushed += 1
            case (nil, let theirs?):
                write(theirs, to: labels, session: name)
                pulled += 1
            case (let mine?, let theirs?):
                guard !Self.same(mine, theirs) else { continue }
                if let changed = localChanged, let remoteChanged = theirs.updatedAt, changed > remoteChanged {
                    try await client.save(mine)
                    pushed += 1
                } else {
                    write(theirs, to: labels, session: name)
                    pulled += 1
                }
            }
        }
        return (pushed, pulled)
    }

    // MARK: - 4. Tracked rallies, both ways

    /// Per rally, the newer side wins. A rally only on the phone is new from
    /// it — unless it was here at the last sync, then it was deleted here and
    /// is marked deleted there. One the phone marked deleted goes here too.
    private func syncTracks(project: String) async throws -> (sent: Int, received: Int) {
        let videos = try await client.videos().filter { $0.project == project && $0.sessionName != nil }
        let remote = Dictionary(grouping: try await client.tracks(), by: \.videoId)
        var outgoing: [LabelTrack] = []
        var received = 0
        for video in videos {
            guard let name = video.sessionName, let session = projects.session(named: name) else { continue }
            var local = session.tracks ?? []
            let synced = Set(session.syncedTrackIds ?? [])
            let theirs = remote[video.id] ?? []
            var changedHere = false
            for r in theirs {
                let i = local.firstIndex { $0.id == r.id }
                if r.deleted {
                    if let i { local.remove(at: i); changedHere = true; received += 1 }
                    continue
                }
                guard let i else {
                    if synced.contains(r.id) {
                        var gone = r
                        gone.deleted = true
                        gone.updatedAt = Date()
                        outgoing.append(gone)           // deleted here since the last sync
                    } else {
                        local.append(r.rally)          // new from the phone
                        changedHere = true
                        received += 1
                    }
                    continue
                }
                let mine = local[i]
                guard !Self.sameTrack(mine, r) else { continue }
                if (r.updatedAt ?? .distantPast) > (mine.updatedAt ?? .distantPast) {
                    var taken = r.rally
                    // Keep the detector's candidates when they still line up.
                    if mine.candidates.count == taken.points.count { taken.candidates = mine.candidates }
                    local[i] = taken
                    changedHere = true
                    received += 1
                } else {
                    outgoing.append(LabelTrack(mine, videoId: video.id))
                }
            }
            for mine in local where !theirs.contains(where: { $0.id == mine.id }) {
                outgoing.append(LabelTrack(mine, videoId: video.id))   // new here
            }
            local.sort { $0.start < $1.start }
            if changedHere {
                projects.sampler.setTracks(local, session: name)
                onTracksChanged?(name)
            }
            projects.sampler.setSyncedTrackIds(local.map(\.id), session: name)
        }
        for batch in stride(from: 0, to: outgoing.count, by: 20).map({ Array(outgoing[$0..<min($0 + 20, outgoing.count)]) }) {
            try await client.save(batch)
        }
        return (outgoing.count, received)
    }

    private static func sameTrack(_ a: TrackedRally, _ b: LabelTrack) -> Bool {
        a.done == b.done && abs(a.start - b.start) < 0.001 && abs(a.end - b.end) < 0.001 && a.points == b.points.points
    }

    // MARK: - 5. The plan, for the phone's Plan tab

    private func publishPlan(project: String) async throws {
        let root = projects.sampler.datasetRoot
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plan = (try? Data(contentsOf: root.appendingPathComponent("training_plan.json")))
            .flatMap { try? decoder.decode([TrainedRound].self, from: $0) } ?? []
        var scores: [String: [String: Double]] = [:]
        for name in plan.flatMap({ $0.runs.compactMap(\.name) }) {
            let url = root.appendingPathComponent("incoming/\(name)/metrics.json")
            guard let s = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder().decode(RunScores.self, from: $0) }) else { continue }
            scores[name] = Dictionary(uniqueKeysWithValues: ["tracked", "indoor", "grass", "beach"].compactMap { k in s.f1(k).map { (k, $0) } })
        }
        try await client.save(LabelProjectState(project: project, plan: plan, scores: scores, updatedAt: nil))
    }

    private func write(_ times: LabelRallyTimes, to labels: URL, session: String) {
        defer { onTimesChanged?(session) }
        let rallies = times.rallies.sorted { $0.start < $1.start }.map { LabeledRally(startTime: $0.start, endTime: $0.end) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(rallies).write(to: labels, options: .atomic)
        projects.sampler.setRalliesMarked(times.complete, session: session)
    }

    /// Same rallies (to the frame) and the same "every rally marked".
    private static func same(_ a: LabelRallyTimes, _ b: LabelRallyTimes) -> Bool {
        guard a.complete == b.complete, a.rallies.count == b.rallies.count else { return false }
        let x = a.rallies.sorted { $0.start < $1.start }, y = b.rallies.sorted { $0.start < $1.start }
        return zip(x, y).allSatisfy { abs($0.start - $1.start) < 0.02 && abs($0.end - $1.end) < 0.02 }
    }

    // MARK: - Naming

    /// The camera a clip ID describes (as RallyLab's camera setup reads it).
    static func camera(of clipId: String) -> LabelCamera {
        if clipId.contains("_sid_") { return .sideline }
        if clipId.contains("_tri_") || clipId.contains("_hnd_") { return .corner }
        if clipId.contains("_gnd_") { return .endlineGround }
        return .endlineRaised
    }

    /// The rally stretches the Sampler found in a video.
    static func ralliesFound(in session: VideoSession) -> [[Double]] {
        TrackLabelModel.suggestions(from: session, excluding: []).map { [$0.start, $0.end] }
    }
}
