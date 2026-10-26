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
//  4. Review decisions made here go frame by frame (queued, kept on disk
//     until sent), like the phone's — so several people reviewing at once
//     never overwrite each other's frames. Tracked rallies otherwise go
//     both ways whole, whichever side changed them last, deletions included;
//     a rally with frame decisions sent takes the server's copy (which has
//     them, and everyone else's).
//  Live: someone else's save syncs here at once (LabelingLive), and a
//  decision here goes up within a couple of seconds; every 30 s as a backstop.
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
    /// After each automatic sync (e.g. fitting new rallies' boxes); true if
    /// it changed something worth sending at once.
    var afterSync: (() async -> Bool)?
    @ObservationIgnored private var auto: Task<Void, Never>?
    @ObservationIgnored private var activation: Any?
    @ObservationIgnored private var live: LabelingLive?
    @ObservationIgnored private var soon: Task<Void, Never>?
    /// A sync was asked for while one ran: run again after it.
    @ObservationIgnored private var again = false
    /// Review decisions made here not yet sent, frame by frame, and Rally-or-not answers.
    private(set) var pendingFrames: [LabelingClient.FrameEdit] = Pending.load([LabelingClient.FrameEdit].self, "frames") ?? []
    private(set) var pendingRallies: [LabelingClient.RallyVerdict] = Pending.load([LabelingClient.RallyVerdict].self, "rallies") ?? []

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

    // MARK: - Review decisions made here

    /// A review decision on a frame: sent on its own within a couple of seconds.
    func queue(_ edit: LabelingClient.FrameEdit) {
        pendingFrames.append(edit)
        Pending.save(pendingFrames, "frames")
        syncSoon()
    }

    func queue(_ verdict: LabelingClient.RallyVerdict) {
        pendingRallies.append(verdict)
        Pending.save(pendingRallies, "rallies")
        syncSoon()
    }

    /// Sync in a moment (several asks in a row make one sync).
    func syncSoon() {
        soon?.cancel()
        soon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.signedIn else { return }
            await self.sync(videos: false)
        }
    }

    /// Send what's waiting: Rally-or-not answers, then frame decisions rally
    /// by rally. The rallies whose frames went (or were refused because
    /// someone else is reviewing them — theirs stand).
    private func sendPending() async throws -> Set<UUID> {
        for verdict in pendingRallies {
            try await client.reviewRally(verdict)
            pendingRallies.removeFirst()
            Pending.save(pendingRallies, "rallies")
        }
        var sent: Set<UUID> = []
        for (track, edits) in Dictionary(grouping: pendingFrames, by: \.track) {
            do {
                try await client.reviewFrames(track, edits)
            } catch LabelingClient.Failure.server(let code, _) where code == 400 {
                // Someone else is reviewing it: their decisions stand.
            }
            pendingFrames.removeAll { edits.contains($0) }
            Pending.save(pendingFrames, "frames")
            sent.insert(track)
        }
        return sent
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
        live = LabelingLive { [weak self] in
            guard let self, self.signedIn else { return }
            await self.sync(videos: false)
        }
        live?.start()
        auto = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.signedIn, self.projects.project != nil {
                    await self.sync(videos: round % Self.videoEvery == 0)
                    if await self.afterSync?() == true { await self.sync(videos: false) }
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
    /// `remaking`: videos (session names) whose copy made with an older
    /// encoding is made again — otherwise only videos without one get one.
    func sync(videos: Bool = true, remaking: @escaping (String) -> Bool = { _ in false }) async -> Bool {
        guard !isSyncing else { again = true; return false }
        guard let project = projects.project?.name else { return false }
        isSyncing = true
        defer {
            isSyncing = false
            if again {
                again = false
                syncSoon()
            }
        }
        do {
            let framesSent = try await sendPending()
            var parts: [String] = []
            if videos {
                let imported = try await importPhoneVideos(project: project)
                let (listed, uploaded, failed) = try await publishVideos(project: project, remaking: remaking)
                try await publishBallPaths(project: project)
                parts.append("\(listed) videos listed (\(uploaded) uploaded\(failed.isEmpty ? "" : ", \(failed.count) failed — next sync retries: \(failed.joined(separator: ", "))")), \(imported) phone videos pulled in")
            }
            let (pushed, pulled) = try await syncRallyTimes(project: project)
            let (tracksSent, tracksReceived) = try await syncTracks(project: project, framesSent: framesSent)
            try await publishPlan(project: project)
            parts.append("rally times \(pushed) sent · \(pulled) received, tracked rallies \(tracksSent) sent · \(tracksReceived) received")
            let events = try await syncRallyEvents(project: project)
            parts.append("boundary records \(events.pushed) sent · \(events.pulled) received" + (events.conflicts.isEmpty ? "" : " · conflicts kept for: \(events.conflicts.joined(separator: ", "))")
                         + (events.withheldPublished.map { " · withheld list published (\($0))" } ?? " · withheld list NOT published — no boundary record sent"))
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
                guard await projects.waitForSampling(added) else {
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

    // MARK: - 2. Project videos to the phone

    private func publishVideos(project: String, remaking: (String) -> Bool) async throws -> (listed: Int, uploaded: Int, failed: [String]) {
        let remote = try await client.videos().filter { $0.project == project }
        var listed = 0, uploaded = 0
        var failed: [String] = []
        // Withheld recordings (the L2 closure) are never uploaded for the phone. When the closure cannot be read,
        // nothing is uploaded at all (fail closed).
        guard let withheld = withheldClosure() else { return (0, 0, []) }
        let sessions = projects.sampler.sessions.filter { FileManager.default.fileExists(atPath: $0.sourcePath) && !withheld.contains($0.name) }
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
            // The original's frame identity, published once with the copy: the phone proves its copy against it.
            if video.frameTimesDigest == nil, let times = try? await FrameIdentity.allFrameTimes(of: source) {
                video.frameTimesDigest = FrameIdentity.digest(of: times)
            }
            if video.sourceFingerprint == nil { video.sourceFingerprint = ProjectsModel.fileFingerprint(atPath: source.path) }
            // A copy RallyLab made with an older encoding is made again when
            // asked (the new name tells the phone to fetch it); the old one is
            // removed. Remaking them all takes hours, so it isn't automatic.
            let path = "rallylab/\(DatasetStore.safeName(project))/\(session.name)-v\(Self.copyVersion).mp4"
            let stale = video.clipPath.map { remaking(session.name) && $0.hasPrefix("rallylab/") && $0 != path } ?? true
            if stale {
                status = "Uploading \(session.name) for the phone (\(i + 1) of \(sessions.count))…"
                do {
                    try await uploadSmallCopy(of: source, to: path)
                    if let old = video.clipPath { try? await client.remove(old) }
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
    /// The phone copy's encoding: 2 = to a quality (x264 slow, CRF 20, at
    /// most 5 Mbps) rather than 2 Mbps flat, which grainy footage fell apart at;
    /// 3 = frame times kept exactly (the encoder's own time base snapped
    /// variable-rate phone footage to a fixed grid, so the phone showed the
    /// frame next to the one asked for, and frames sharing a time decoded grey).
    static let copyVersion = 3

    private func uploadSmallCopy(of source: URL, to path: String) async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let run = await ToolEnvironment.run("ffmpeg", [
            "-y", "-loglevel", "error", "-i", source.path, "-an",
            "-vf", "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))'", "-fps_mode", "passthrough",
            "-enc_time_base", "demux", "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-maxrate", "5M", "-bufsize", "10M",
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

    /// The ball's path over each video (BallPathBuilder), sent up next to
    /// its clip once it exists here, so marking on the phone snaps too.
    /// Footage moved to the desktop counts: the path was made from the
    /// review copy. What's been sent is remembered in ballpaths/sent.json.
    private func publishBallPaths(project: String) async throws {
        let root = projects.sampler.datasetRoot
        let sentFile = root.appendingPathComponent("ballpaths/sent.json")
        var sent = Set((try? Data(contentsOf: sentFile)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        let remote = try await client.videos().filter { $0.project == project }
        var sentNow = 0
        for video in remote {
            guard let clip = video.clipPath, let name = video.sessionName else { continue }
            let path = BallPathFile.remotePath(forClip: clip)
            let local = BallPathBuilder.url(for: name, in: root)
            guard !sent.contains(path), FileManager.default.fileExists(atPath: local.path) else { continue }
            do {
                try await client.upload(local, to: path)
            } catch LabelingClient.Failure.notSignedIn {
                throw LabelingClient.Failure.notSignedIn
            } catch {
                continue   // next sync
            }
            sent.insert(path)
            sentNow += 1
        }
        if sentNow > 0, let data = try? JSONEncoder().encode(sent.sorted()) {
            try? FileManager.default.createDirectory(at: sentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: sentFile, options: .atomic)
        }
    }

    // MARK: - 3. Rally times, both ways

    // MARK: - Stage 1 rally-boundary records (migration 048)

    /// A Stage 1 record of the open project was written by the sync (a push's reply or a pull): the Review tab
    /// takes it for the recording it has open. Set by RallyLabApp.
    var onRecordSynced: ((_ session: String, _ record: EventReview.File) -> Void)?

    /// The withheld closure as RallyLab computes it, with the project's identities read strictly first
    /// (EventReview.projectSourcesStrict): an unreadable project.json or validation.json gives nil, and nothing is
    /// published or uploaded then — the server keeps the list it has (fail closed).
    private func withheldClosure() -> Set<String>? {
        guard let root = projects.projectDir else { return nil }
        do {
            _ = try EventReview.projectSourcesStrict(in: root)
            return try ReservedVideos.lineageWithheldNames(in: root)
        } catch { return nil }
    }

    /// Publishes the project's withheld list (the server refuses events for a project without one), then reconciles
    /// every eligible recording's `rallyevents.json` with the server by `RallyEventsSync.decide`: a push sends the
    /// record at the revision it was loaded from, a pull writes the server's record (and the shadow), a conflict
    /// keeps the server's version beside the local one (`…rallyevents.conflict-r<n>.json`) and changes nothing.
    /// The legacy `rallylabels.json` is never touched; withheld recordings are never read or sent.
    private func syncRallyEvents(project: String) async throws -> (pushed: Int, pulled: Int, conflicts: [String], withheldPublished: Int?) {
        guard let withheld = withheldClosure() else { return (0, 0, [], nil) }
        var published: Int?
        do { published = try await client.publishWithheld(project: project, names: Array(withheld)) } catch LabelingClient.Failure.notSignedIn {
            throw LabelingClient.Failure.notSignedIn
        } catch {
            // Not a lead, or the server refused: the server will refuse every save for the project, so none is attempted.
            return (0, 0, [], nil)
        }
        let videos = try await client.videos().filter { $0.project == project && $0.sessionName != nil }
        let remote = Dictionary(uniqueKeysWithValues: try await client.rallyEvents().map { ($0.videoId, $0) })
        var pushed = 0, pulled = 0
        var conflicts: [String] = []
        for video in videos {
            guard let name = video.sessionName, !withheld.contains(name), let session = projects.session(named: name) else { continue }
            let url = EventReview.url(forVideo: URL(fileURLWithPath: session.sourcePath))
            let shadowURL = RallyEventsSync.shadowURL(for: url)
            // A record that is present but cannot be read is left exactly as it is, and said so; never taken as absent.
            let localState = RallyEventsSync.localState(at: url)
            if case .unreadable(let why) = localState { conflicts.append("\(name) (local record unreadable, left untouched: \(why))"); continue }
            let local = localState.record
            let shadow = RallyEventsSync.localState(at: shadowURL).record
            switch RallyEventsSync.decide(local: local, shadow: shadow, server: remote[video.id]) {
            case .upToDate:
                continue
            case .push(let expected):
                guard let local else { continue }
                do {
                    let saved = try await client.saveRallyEvents(videoId: video.id, expected: expected, record: local)
                    // The reviewer may have committed again while the save was in flight: keep the newer content.
                    let (keep, shadowRecord) = RallyEventsSync.afterPush(sent: local, current: RallyEventsSync.localState(at: url).record, saved: saved.record)
                    try EventReview.write(keep, to: url)
                    try EventReview.write(shadowRecord, to: shadowURL)
                    onRecordSynced?(name, keep)
                    pushed += 1
                } catch let conflict as RallyEventsConflict {
                    if let server = try? await client.rallyEvents().first(where: { $0.videoId == video.id }) {
                        try? EventReview.write(server.record, to: RallyEventsSync.conflictURL(for: url, serverRevision: server.revision))
                    }
                    conflicts.append("\(name) (\(conflict.message))")
                }
            case .pull:
                guard let server = remote[video.id] else { continue }
                try EventReview.write(server.record, to: url)
                try EventReview.write(server.record, to: shadowURL)
                onRecordSynced?(name, server.record)
                pulled += 1
            case .conflict(_, let serverRevision):
                if let server = remote[video.id] {
                    try? EventReview.write(server.record, to: RallyEventsSync.conflictURL(for: url, serverRevision: serverRevision))
                }
                conflicts.append(name)
            }
        }
        return (pushed, pulled, conflicts, published)
    }

    private func syncRallyTimes(project: String) async throws -> (pushed: Int, pulled: Int) {
        let videos = try await client.videos().filter { $0.project == project && $0.sessionName != nil }
        let remote = Dictionary(uniqueKeysWithValues: try await client.rallyTimes().map { ($0.videoId, $0) })
        var pushed = 0, pulled = 0
        for video in videos {
            guard let name = video.sessionName, let session = projects.session(named: name) else { continue }
            let labels = RallyMarkModel.labelsURL(for: URL(fileURLWithPath: session.sourcePath))
            let localRallies = (try? Data(contentsOf: labels)).flatMap { try? JSONDecoder().decode([RallyMarkRecord].self, from: $0) }
            let localChanged = (try? labels.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let local = localRallies.map { rallies in
                LabelRallyTimes(videoId: video.id,
                                rallies: rallies.map { LabelRally(start: $0.startTime, end: $0.endTime, kind: $0.kind, contacts: $0.contacts) },
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
    ///
    /// Only rallies whose time differs from this Mac's copy are fetched in
    /// full: pre-tracked rallies make hundreds, and most don't change
    /// between syncs.
    private func syncTracks(project: String, framesSent: Set<UUID>) async throws -> (sent: Int, received: Int) {
        let videos = try await client.videos().filter { $0.project == project && $0.sessionName != nil }
        let stamps = try await client.trackStamps()
        var localTimes: [UUID: Date?] = [:]
        for video in videos {
            guard let name = video.sessionName, let session = projects.session(named: name) else { continue }
            for t in session.tracks ?? [] { localTimes[t.id] = t.updatedAt }
        }
        let changed = stamps.filter { s in
            if framesSent.contains(s.id) { return true }
            guard let mine = localTimes[s.id] else { return !s.deleted }   // a tombstone of one gone here: nothing to do
            guard let a = mine, let b = s.updatedAt else { return true }
            return abs(a.timeIntervalSince(b)) > 0.002
        }
        let remote = Dictionary(grouping: try await client.tracks(ids: changed.map(\.id)), by: \.videoId)
        let remoteIds = Dictionary(grouping: stamps, by: \.videoId).mapValues { Set($0.map(\.id)) }
        var outgoing: [LabelTrack] = []
        var received = 0
        // Sent rallies are stamped with the time they're sent, not when they
        // changed here: the phone takes only rows stamped after its last look,
        // so a rally changed here while syncing was off would never reach it.
        let now = Date()
        for video in videos {
            guard let name = video.sessionName, let session = projects.session(named: name) else { continue }
            var local = session.tracks ?? []
            let synced = Set(session.syncedTrackIds ?? [])
            let theirs = remote[video.id] ?? []
            let known = remoteIds[video.id] ?? []
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
                // Its frame decisions went up on their own: the server's copy
                // has them and everyone else's, so take it rather than send ours whole.
                if framesSent.contains(r.id) || (r.updatedAt ?? .distantPast) > (mine.updatedAt ?? .distantPast) {
                    var taken = r.rally
                    // Keep the detector's candidates when they still line up.
                    if mine.candidates.count == taken.points.count { taken.candidates = mine.candidates }
                    // Decisions not sent yet (offline) stay on top.
                    for e in pendingFrames where e.track == r.id && taken.points.indices.contains(e.index) { taken.points[e.index] = e.point }
                    local[i] = taken
                    changedHere = true
                    received += 1
                } else {
                    local[i] = mine.with(updatedAt: now)
                    outgoing.append(LabelTrack(local[i], videoId: video.id))
                    changedHere = true
                }
            }
            for i in local.indices where !known.contains(local[i].id) {
                local[i] = local[i].with(updatedAt: now)
                outgoing.append(LabelTrack(local[i], videoId: video.id))   // new here
                changedHere = true
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
        a.done == b.done && a.isRally == b.isRally && abs(a.start - b.start) < 0.001 && abs(a.end - b.end) < 0.001 && a.points == b.points.points
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
        let rallies = times.rallies.sorted { $0.start < $1.start }
            .map { RallyMarkRecord(startTime: $0.start, endTime: $0.end, kind: $0.kind, contacts: $0.contacts) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(rallies).write(to: labels, options: .atomic)
        projects.sampler.setRalliesMarked(times.complete, session: session)
    }

    /// Same rallies (to the frame, with the same kinds and touches) and the
    /// same "every rally marked".
    private static func same(_ a: LabelRallyTimes, _ b: LabelRallyTimes) -> Bool {
        guard a.complete == b.complete, a.rallies.count == b.rallies.count else { return false }
        let x = a.rallies.sorted { $0.start < $1.start }, y = b.rallies.sorted { $0.start < $1.start }
        return zip(x, y).allSatisfy {
            abs($0.start - $1.start) < 0.02 && abs($0.end - $1.end) < 0.02 && $0.kind == $1.kind && ($0.contacts ?? []) == ($1.contacts ?? [])
        }
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

/// Review decisions waiting to go up, kept on disk so a quit doesn't lose them.
private enum Pending {
    private static func file(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "RallyLab")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "pending-\(name).json")
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        (try? Data(contentsOf: file(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        try? JSONEncoder().encode(value).write(to: file(name), options: .atomic)
    }
}
