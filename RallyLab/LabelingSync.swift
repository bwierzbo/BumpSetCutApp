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
//  One round belongs to one opening of one project (`ProjectsModel.Opening`,
//  captured when the round starts). Its files are the captured project's
//  (paths from the opening's root); the open project — its cards, its
//  sampler's sessions — is read only right after `projects.require(opening)`
//  says the opening still holds, with no suspension between the check and
//  the read or write. When the project is closed, switched, or opened again
//  while a round is suspended, the round is cancelled, and whatever of it
//  still runs stops at its next check: nothing of the project open now is
//  read as the old one's, nothing is written to it, no editor is told. The
//  one thing a stopped round still records is an acknowledgement the server
//  already gave for work done while the opening held — the reply to a
//  boundary-record push, the row of a copy whose upload finished, the list
//  of ball paths sent — each in the captured project's own files or rows,
//  with the captured project's own data, so the next sync of that project
//  does not redo or misread it.
//
//  Headless: RallyLab --project <name> --sync-phone (after signing in once
//  in the app; the session is kept in the Keychain).
//

import AppKit
import AVFoundation
import Foundation
import Observation

/// What the sync needs of the labeling server: `LabelingClient` in RallyLab, a fake in tests (which decides when each
/// reply arrives). Every requirement is the client's own method under its own name, except the two transfers, named
/// apart from the client's progress-reporting ones.
protocol LabelingService: Sendable {
    var hasSession: Bool { get async }
    func signIn(email: String, password: String) async throws
    func signOut() async
    func isLabeler() async throws -> Bool
    func videos() async throws -> [LabelVideo]
    @discardableResult func save(_ video: LabelVideo) async throws -> LabelVideo
    func rallyTimes(since: Date?) async throws -> [LabelRallyTimes]
    @discardableResult func save(_ times: LabelRallyTimes) async throws -> LabelRallyTimes
    func trackStamps() async throws -> [LabelingClient.TrackStamp]
    func tracks(ids: [UUID]) async throws -> [LabelTrack]
    func save(_ tracks: [LabelTrack]) async throws
    func rallyEvents(since: Date?) async throws -> [LabelRallyEvents]
    func saveRallyEvents(videoId: UUID, expected: Int, record: EventReview.File) async throws -> LabelRallyEvents
    func publishWithheld(project: String, names: [String]) async throws -> Int
    func recordingTypeClaims(since: Date?) async throws -> [RecordingTypeClaim]
    func recordingTypeClaim(id: UUID) async throws -> RecordingTypeClaim?
    func settleRecordingTypeClaim(_ id: UUID, status: RecordingTypeClaim.Status, reason: String?, confirmedAt: Date?) async throws -> RecordingTypeClaim
    func clearPublishedRecordingType(_ videoId: UUID) async throws
    func setBacklog(_ videoId: UUID, reason: String?, at: Date) async throws
    func save(_ state: LabelProjectState) async throws
    func reviewRally(_ verdict: LabelingClient.RallyVerdict) async throws
    func reviewFrames(_ track: UUID, _ edits: [LabelingClient.FrameEdit]) async throws
    func uploadFile(_ file: URL, to path: String) async throws
    func downloadFile(_ path: String, to destination: URL) async throws
    func remove(_ path: String) async throws
}

extension LabelingClient: LabelingService {
    func uploadFile(_ file: URL, to path: String) async throws { try await upload(file, to: path, progress: nil) }
    func downloadFile(_ path: String, to destination: URL) async throws { try await download(path, from: Self.bucket, to: destination, progress: nil) }
}

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
    /// The round running now; cancelled when the opening it started under ends.
    @ObservationIgnored private var round: Task<Bool, Never>?
    /// Review decisions made here not yet sent, frame by frame, and Rally-or-not answers.
    private(set) var pendingFrames: [LabelingClient.FrameEdit]
    private(set) var pendingRallies: [LabelingClient.RallyVerdict]

    private let client: any LabelingService
    private let pending: Pending

    /// Whether a round pulls the phones' uploads into the project (step 1). A guarded headless run (synthetic
    /// acceptance) never does: the uploads a lead can see are real footage, and importing one would move it into the
    /// test project's namespace.
    private let importsPhoneUploads: Bool
    /// Fault injection for the lost-acknowledgement case (guarded acceptance runs only): the first settlement that
    /// follows a written and read-back record is dropped as if the network had failed after the write. The record is
    /// on disk, the claim stays submitted, and the next round must acknowledge it without writing again.
    private let dropFirstSettlement: Bool
    private var settlementDropped = false

    /// `client` and `pendingDirectory` are for tests: a fake server, and a folder of their own for the queued
    /// decisions, so a test never sends or touches the person's. `importsPhoneUploads: false` is the guarded run's.
    init(projects: ProjectsModel, client: any LabelingService = LabelingClient.shared, pendingDirectory: URL = Pending.defaultDirectory,
         importsPhoneUploads: Bool = true, dropFirstSettlement: Bool = false) {
        self.importsPhoneUploads = importsPhoneUploads
        self.dropFirstSettlement = dropFirstSettlement
        let pending = Pending(directory: pendingDirectory)
        var notes: [String] = []
        self.projects = projects
        self.client = client
        self.pending = pending
        pendingFrames = pending.load([LabelingClient.FrameEdit].self, "frames", notes: &notes) ?? []
        pendingRallies = pending.load([LabelingClient.RallyVerdict].self, "rallies", notes: &notes) ?? []
        status = notes.joined(separator: " ")
        // A reply still in flight for a project no longer open is not waited for.
        projects.onOpeningEnded { [weak self] _ in self?.round?.cancel() }
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
        pending.save(pendingFrames, "frames")
        syncSoon()
    }

    func queue(_ verdict: LabelingClient.RallyVerdict) {
        pendingRallies.append(verdict)
        pending.save(pendingRallies, "rallies")
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
    /// someone else is reviewing them — theirs stand). The queues are keyed
    /// by the server's rally ids, not by project: a decision made in one
    /// project goes up whichever project is open when it is sent.
    private func sendPending() async throws -> Set<UUID> {
        for verdict in pendingRallies {
            try await client.reviewRally(verdict)
            pendingRallies.removeFirst()
            pending.save(pendingRallies, "rallies")
        }
        var sent: Set<UUID> = []
        for (track, edits) in Dictionary(grouping: pendingFrames, by: \.track) {
            do {
                try await client.reviewFrames(track, edits)
            } catch LabelingClient.Failure.server(let code, _) where code == 400 {
                // Someone else is reviewing it: their decisions stand.
            }
            pendingFrames.removeAll { edits.contains($0) }
            pending.save(pendingFrames, "frames")
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
    /// `remaking`: videos (session names) whose copy made with an older
    /// encoding is made again — otherwise only videos without one get one.
    @discardableResult
    func sync(videos: Bool = true, remaking: @escaping @Sendable (String) -> Bool = { _ in false }) async -> Bool {
        guard !isSyncing else { again = true; return false }
        guard let opening = projects.opening else { return false }
        isSyncing = true
        MainThreadWatchdog.shared.note("phone sync round")
        defer {
            isSyncing = false
            round = nil
            MainThreadWatchdog.shared.note(nil)
            if again {
                again = false
                syncSoon()
            }
        }
        // The round is a task of its own so that the end of its opening can cancel it; the caller's own
        // cancellation reaches it too.
        let task = Task { await self.run(opening, videos: videos, remaking: remaking) }
        round = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// The round, for the project `opening` names.
    private func run(_ opening: ProjectsModel.Opening, videos: Bool, remaking: @Sendable (String) -> Bool) async -> Bool {
        let project = opening.name
        do {
            let framesSent = try await sendPending()
            var parts: [String] = []
            if videos {
                // Phone uploads come in only when this round is allowed to take them (never in a guarded run).
                let imported = importsPhoneUploads ? try await importPhoneVideos(opening) : 0
                let (listed, uploaded, failed) = try await publishVideos(opening, remaking: remaking)
                let paths = try await publishBallPaths(opening)
                parts.append("\(listed) videos listed (\(uploaded) uploaded\(failed.isEmpty ? "" : ", \(failed.count) failed — next sync retries: \(failed.joined(separator: ", "))")), "
                             + (importsPhoneUploads ? "\(imported) phone videos pulled in" : "phone uploads not pulled in (guarded run)"))
                if let paths { parts.append(paths) }
            }
            let times = try await syncRallyTimes(opening)
            let (tracksSent, tracksReceived) = try await syncTracks(opening, framesSent: framesSent)
            let plan = try await publishPlan(opening)
            parts.append("rally times \(times.pushed) sent · \(times.pulled) received"
                         + (times.unreadable.isEmpty ? "" : " · \(times.unreadable.count) rally-times file(s) unreadable, left untouched: \(times.unreadable.joined(separator: ", "))")
                         + ", tracked rallies \(tracksSent) sent · \(tracksReceived) received")
            if let plan { parts.append(plan) }
            let events = try await syncRallyEvents(opening)
            parts.append("boundary records \(events.pushed) sent · \(events.pulled) received" + (events.conflicts.isEmpty ? "" : " · conflicts kept for: \(events.conflicts.joined(separator: ", "))")
                         + (events.withheldPublished.map { " · withheld list published (\($0))" } ?? " · withheld list NOT published — no boundary record sent"))
            let claims = try await syncRecordingTypeClaims(opening)
            if claims.accepted + claims.rejected + claims.deferred.count > 0 {
                parts.append("footage types from the phone \(claims.accepted) confirmed · \(claims.rejected) declined"
                             + (claims.deferred.isEmpty ? "" : " · left for the next sync: \(claims.deferred.joined(separator: "; "))"))
            }
            status = "Synced: " + parts.joined(separator: ", ") + "."
            lastSynced = Date()
            return true
        } catch LabelingClient.Failure.notSignedIn {
            signedIn = false
            status = "Sign in to sync with the phone."
            return false
        } catch is ProjectsModel.OpeningEnded {
            status = Self.stopped(project)
            return false
        } catch is CancellationError {
            status = projects.opening == opening ? "Sync of \(project) cancelled." : Self.stopped(project)
            return false
        } catch let error as URLError where error.code == .cancelled {
            status = projects.opening == opening ? "Sync of \(project) cancelled." : Self.stopped(project)
            return false
        } catch {
            status = "Sync stopped: \(error.localizedDescription)"
            return false
        }
    }

    /// The status of a round whose project was closed, switched or reopened under it.
    static func stopped(_ project: String) -> String {
        "Sync of \(project) stopped: the project changed — nothing more of it was written or published; the next sync of \(project) starts over."
    }

    // MARK: - 1. Phone videos into the project

    private func importPhoneVideos(_ opening: ProjectsModel.Opening) async throws -> Int {
        let waiting = try await client.videos().filter { $0.status == .uploaded && $0.clipPath != nil }
        var count = 0
        let incoming = opening.root.appendingPathComponent("incoming", isDirectory: true)
        for var video in waiting {
            // The clip cards and the project's videos are the open project's: read only while the opening holds.
            try projects.require(opening)
            guard let clipId = clipCard(for: video), let path = video.clipPath else {
                status = "No clip card for \(video.name) (\(video.surface.rawValue), \(video.camera.title)) — skipped."
                continue
            }
            let file = incoming.appendingPathComponent("phone-\(video.id.uuidString.lowercased()).mp4")
            let title = video.title.isEmpty ? "Phone video \(video.id.uuidString.prefix(8))" : video.title
            let videoId: String
            if let already = projectVideo(from: file) {
                // Pulled in by a sync that stopped before marking it imported.
                videoId = already
            } else {
                status = "Pulling in \(video.name) from the phone…"
                try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
                try await client.downloadFile(path, to: file)
                // Added to the project it was pulled in for, never to one opened meanwhile.
                try projects.require(opening)
                guard let added = projects.addVideo(to: clipId, source: file.path, start: 0, length: video.duration + 1,
                                                    license: ProjectsModel.ownFootageLicense) else {
                    status = "Couldn't add \(title): \(projects.status)"
                    continue
                }
                guard try await projects.waitForSampling(added, in: opening) else {
                    status = "\(title) didn't sample: \(projects.status)"
                    continue
                }
                try? FileManager.default.removeItem(at: file)
                videoId = added
            }
            video.project = opening.name
            video.sessionName = videoId
            video.status = .imported
            if let session = try projects.session(named: videoId, in: opening) {
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

    /// The original's identities on a video row that lacks them, published once with the copy: its frame digest (the
    /// phone proves its copy against it) and its content fingerprint (the server checks every record's footage
    /// against it). A row that has them keeps them.
    private static func withIdentities(_ video: LabelVideo, source: URL) async -> LabelVideo {
        var v = video
        if v.frameTimesDigest == nil, let times = try? await FrameIdentity.allFrameTimes(of: source) { v.frameTimesDigest = FrameIdentity.digest(of: times) }
        if v.sourceFingerprint == nil { v.sourceFingerprint = await Task.detached(priority: .utility) { ProjectsModel.fileFingerprint(atPath: source.path) }.value }
        return v
    }

    /// `--publish-identities`: what migration 048 needs before any record is accepted, and nothing else — the project's
    /// withheld list (leads only), then the identities of the recordings that already have a row on the server. No
    /// copy is uploaded, no row created, no withheld row touched; a recording whose original is not on disk is
    /// reported, not guessed.
    func publishIdentities() async -> Bool {
        guard let opening = projects.opening else { status = "No project."; return false }
        let project = opening.name, root = opening.root
        do {
            guard let withheld = await withheldClosure(root: root) else {
                status = "The withheld closure cannot be read: nothing published."; return false
            }
            try projects.require(opening)
            let listed = try await client.publishWithheld(project: project, names: Array(withheld))
            let sessions = try DatasetStore(root: root).loadSessionsStrict()
            var filled = 0, kept = 0
            var missing: [String] = []
            for var video in try await client.videos().filter({ $0.project == project }) {
                guard let name = video.sessionName, !withheld.contains(name) else { continue }
                guard let session = sessions.first(where: { $0.name == name }), FileManager.default.fileExists(atPath: session.sourcePath) else { missing.append(name); continue }
                if video.frameTimesDigest != nil, video.sourceFingerprint != nil { kept += 1; continue }
                try projects.require(opening)
                video = await Self.withIdentities(video, source: URL(fileURLWithPath: session.sourcePath))
                guard video.frameTimesDigest != nil, video.sourceFingerprint != nil else { missing.append(name); continue }
                _ = try await client.save(video)
                filled += 1
            }
            status = "Withheld list published (\(listed) names); identities published for \(filled) recordings, \(kept) already had them"
                + (missing.isEmpty ? "." : "; not published (original not readable): \(missing.sorted().joined(separator: ", ")).")
            return true
        } catch is ProjectsModel.OpeningEnded {
            status = Self.stopped(project)
            return false
        } catch {
            status = "Not published: \(error.localizedDescription)"
            return false
        }
    }

    private func publishVideos(_ opening: ProjectsModel.Opening, remaking: (String) -> Bool) async throws -> (listed: Int, uploaded: Int, failed: [String]) {
        let project = opening.name, root = opening.root
        let remote = try await client.videos().filter { $0.project == project }
        var listed = 0, uploaded = 0
        var failed: [String] = []
        // Withheld recordings (the L2 closure) are never uploaded for the phone. When the closure cannot be read,
        // nothing is uploaded at all (fail closed). The closure and the sessions are the captured project's (`root`).
        guard let withheld = await withheldClosure(root: root) else { return (0, 0, []) }
        try projects.require(opening)
        // Decoding every session and asking the share whether each file is there is file work: off the main actor.
        // A recording whose original is not on this Mac (moved to the desktop) keeps its row as it is, copy and
        // identities included — those are made from the file — but its type is still published: the record is
        // here, and the phone's display should not wait for the footage to come back.
        let (sessions, away) = try await Task.detached(priority: .utility) {
            let all = try DatasetStore(root: root).loadSessionsStrict().filter { !withheld.contains($0.name) }
            let here = all.filter { FileManager.default.fileExists(atPath: $0.sourcePath) }
            let names = Set(here.map(\.name))
            return (here, all.filter { !names.contains($0.name) })
        }.value
        // The recordings' types as the footage-properties records have them (D-033): published for the phone's
        // display, a copy lead-written like the identities. Nothing published when the folder can't be read.
        let properties = await Task.detached(priority: .utility) { try? FootageProperties.Store(root: root).loadAll() }.value
        for (i, session) in sessions.enumerated() {
            // Each recording's title and lighting are the open project's cards': the opening must still hold here,
            // on every pass of this loop (the pass before it awaited).
            try projects.require(opening)
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
            // The card's fingerprint, read now, while the opening holds (the awaits below suspend; a project opened
            // meanwhile must not lend its cards to this recording's record).
            let card = FootageTypeConfirmation.sourceFingerprint(of: session.name, in: projects.project)
            video.split = session.split
            video.ralliesFound = Self.ralliesFound(in: session)
            if video.duration <= 0 {
                video.duration = (try? await AVURLAsset(url: source).load(.duration).seconds) ?? 0
            }
            video = await Self.withIdentities(video, source: source)
            if let properties { try await publishType(of: session.name, on: &video, existing: existing, card: card, properties: properties) }
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
                    // One clip failing (a dropped connection, or the round cancelled) shouldn't stop the rest; the
                    // next sync retries it.
                    failed.append(session.name)
                    continue
                }
            }
            // The row is the captured project's own (its name, its session, its card's title and lighting read
            // above while the opening held). A copy whose upload finished is recorded on it even if the opening ended
            // during the upload: the copy is on the server, and the row is how the phone finds it and the next sync
            // knows not to make it again. The next pass stops at its check.
            if video != existing {
                try await client.save(video)
            }
            listed += 1
        }
        // The recordings away from this Mac: only the type, on a row already published (a row is never made here
        // without the file — its copy, duration and identities come from it).
        if let properties {
            for session in away {
                try projects.require(opening)
                guard let existing = remote.first(where: { $0.sessionName == session.name }) else { continue }
                let card = FootageTypeConfirmation.sourceFingerprint(of: session.name, in: projects.project)
                var video = existing
                try await publishType(of: session.name, on: &video, existing: existing, card: card, properties: properties)
                if video != existing { try await client.save(video) }
            }
        }
        return (listed, uploaded, failed)
    }

    /// The recording's type as its footage-properties record has it, onto the row to publish. A record is this
    /// recording's only when it is bound to the card's file (the source index's rule, FootageTypeConfirmation.anotherFile):
    /// one left by a file replaced under the same name is not published. No record of this file: nothing is confirmed,
    /// and a type published before is cleared with an explicit null (the row's encoder leaves nil out, and the upsert
    /// keeps what it is not sent). An unreadable record leaves what was published as it is.
    private func publishType(of name: String, on video: inout LabelVideo, existing: LabelVideo?, card: String?,
                             properties: (records: [String: FootageProperties.File], unreadable: [String: String])) async throws {
        if let record = properties.records[name].flatMap({ FootageTypeConfirmation.anotherFile($0, sourceFingerprint: card) == nil ? $0 : nil }) {
            video.recordingType = record.recordingType.rawValue
            video.recordingTypeAt = record.recordingTypeAt.flatMap(RecordingTypeClaims.parse)
        } else if properties.unreadable[name] == nil {
            if let existing, existing.recordingType != nil || existing.recordingTypeAt != nil {
                try await client.clearPublishedRecordingType(existing.id)
            }
            video.recordingType = nil
            video.recordingTypeAt = nil
        }
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
        try await client.uploadFile(out, to: path)
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
    /// The paths and the list are the captured project's (`opening.root`).
    /// Returns a note for the status when the list could not be read: then
    /// nothing is sent (the list is never taken as empty, which would send
    /// every path again) and the list is left as it is.
    private func publishBallPaths(_ opening: ProjectsModel.Opening) async throws -> String? {
        let root = opening.root
        let sentFile = root.appendingPathComponent("ballpaths/sent.json")
        var sent: Set<String> = []
        if FileManager.default.fileExists(atPath: sentFile.path) {
            do { sent = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: sentFile))) }
            catch { return "ball paths not sent: ballpaths/sent.json unreadable (\(error.localizedDescription)), left untouched" }
        }
        let remote = try await client.videos().filter { $0.project == opening.name }
        var sentNow = 0
        // What went up is recorded even when the round stops: the uploads are on the server.
        defer {
            if sentNow > 0, let data = try? JSONEncoder().encode(sent.sorted()) {
                try? FileManager.default.createDirectory(at: sentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: sentFile, options: .atomic)
            }
        }
        for video in remote {
            try projects.require(opening)
            guard let clip = video.clipPath, let name = video.sessionName else { continue }
            let path = BallPathFile.remotePath(forClip: clip)
            let local = BallPathBuilder.url(for: name, in: root)
            guard !sent.contains(path), FileManager.default.fileExists(atPath: local.path) else { continue }
            do {
                try await client.uploadFile(local, to: path)
            } catch LabelingClient.Failure.notSignedIn {
                throw LabelingClient.Failure.notSignedIn
            } catch {
                continue   // next sync
            }
            sent.insert(path)
            sentNow += 1
        }
        return nil
    }

    // MARK: - 3. Rally times, both ways

    // MARK: - Stage 1 rally-boundary records (migration 048)

    /// A Stage 1 record of the open project was written by the sync (a push's reply or a pull): the Review tab
    /// takes it for the recording it has open. Set by RallyLabApp.
    var onRecordSynced: ((_ root: URL, _ session: String, _ record: EventReview.File) -> Void)?

    /// The withheld closure as the Stage 1 review refuses it: the named closure (lineage holdout, legacy holdout,
    /// final test, candidates and their metadata aliases) **plus every session that EventReview.refusal refuses by
    /// path or content** — a session over a withheld recording's file or a byte-identical copy — with the project's
    /// identities and sessions read strictly first. Anything unreadable gives nil, and nothing is published or
    /// uploaded then; the server keeps the list it has (fail closed).
    private func withheldClosure(root: URL) async -> Set<String>? {
        // Fingerprinting the withheld recordings' files is file work: off the main actor, so playback and editing go on.
        await Task.detached(priority: .utility) { try? EventReview.publishedWithheldNames(in: root) }.value
    }

    /// Publishes the project's withheld list (the server refuses events for a project without one), then reconciles
    /// every eligible recording's `rallyevents.json` with the server by `RallyEventsSync.decide`: a push sends the
    /// record at the revision it was loaded from, a pull writes the server's record (and the shadow), a conflict
    /// keeps the server's version beside the local one (`…rallyevents.conflict-r<n>.json`) and changes nothing.
    /// The legacy `rallylabels.json` is never touched; withheld recordings are never read or sent.
    private func syncRallyEvents(_ opening: ProjectsModel.Opening) async throws -> (pushed: Int, pulled: Int, conflicts: [String], withheldPublished: Int?) {
        let project = opening.name, root = opening.root
        // The exclusions and the records are the captured project's (`root`): a project switched under a running
        // sync must never publish another project's list under this name, nor write another project's files.
        guard let withheld = await withheldClosure(root: root) else { return (0, 0, [], nil) }
        try projects.require(opening)
        var published: Int?
        do { published = try await client.publishWithheld(project: project, names: Array(withheld)) } catch LabelingClient.Failure.notSignedIn {
            throw LabelingClient.Failure.notSignedIn
        } catch {
            // Not a lead, or the server refused: the server will refuse every save for the project, so none is attempted.
            return (0, 0, [], nil)
        }
        let videos = try await client.videos().filter { $0.project == project && $0.sessionName != nil }
        let remote = Dictionary(uniqueKeysWithValues: try await client.rallyEvents(since: nil).map { ($0.videoId, $0) })
        var pushed = 0, pulled = 0
        var conflicts: [String] = []
        let sessions = try await Task.detached(priority: .utility) { try DatasetStore(root: root).loadSessionsStrict() }.value
        try projects.require(opening)
        for video in videos {
            guard let name = video.sessionName, !withheld.contains(name), let session = sessions.first(where: { $0.name == DatasetStore.safeName(name) }) else { continue }
            try projects.require(opening)
            let url = EventReview.url(forVideo: URL(fileURLWithPath: session.sourcePath))
            let shadowURL = RallyEventsSync.shadowURL(for: url)
            // A record that is present but cannot be read is left exactly as it is, and said so; never taken as absent.
            let localState = RallyEventsSync.localState(at: url)
            if case .unreadable(let why) = localState { conflicts.append("\(name) (local record unreadable, left untouched: \(why))"); continue }
            let local = localState.record
            let shadow = RallyEventsSync.localState(at: shadowURL).record
            let action = RallyEventsSync.decide(local: local, shadow: shadow, server: remote[video.id])
            if action == .upToDate { continue }
            // Every other action reads or writes this recording's record: both the local and the server record must
            // describe the original footage on disk now (its content fingerprint, computed off the main actor).
            // A mismatch leaves both records exactly as they are and says why.
            let path = session.sourcePath
            let original = await Task.detached(priority: .utility) { ProjectsModel.fileFingerprint(atPath: path) }.value
            // The reviewer may have committed while the fingerprint was computed: the decision above was made on the
            // record as it was then. If the file changed, nothing is done with this recording this round (the next
            // sync decides on the new record); from here to any write below there is no suspension point except the
            // push's own save, whose reply is reconciled with the file again (afterPush).
            try projects.require(opening)
            guard RallyEventsSync.localState(at: url) == localState else { continue }
            if let local, let why = RallyEventsSync.identityMismatch(of: local, session: name, originalFingerprint: original) {
                conflicts.append("\(name) (local record not sent: \(why) — open it in the Review tab to check it)")
                continue
            }
            if let server = remote[video.id], let why = RallyEventsSync.identityMismatch(of: server, project: project, session: name, originalFingerprint: original) {
                conflicts.append("\(name) (server record not adopted, both kept: \(why))")
                continue
            }
            switch action {
            case .upToDate:
                continue
            case .push(let expected):
                guard let local else { continue }
                do {
                    let saved = try await client.saveRallyEvents(videoId: video.id, expected: expected, record: local)
                    // The server accepted the save: its acknowledgement is recorded in the captured project's own files
                    // (the record's revision and the shadow) even if another project was opened meanwhile — those
                    // paths are the captured project's — so this Mac's own save never later reads as a conflict. The
                    // reviewer may have committed again while the save was in flight: the newer content is kept.
                    let (keep, shadowRecord) = RallyEventsSync.afterPush(sent: local, current: RallyEventsSync.localState(at: url).record, saved: saved.record)
                    try EventReview.write(keep, to: url)
                    try EventReview.write(shadowRecord, to: shadowURL)
                    // Only the editor of the project still open hears of it; a switched project stops the sync here.
                    try projects.require(opening)
                    onRecordSynced?(root, name, keep)
                    pushed += 1
                } catch let conflict as RallyEventsConflict {
                    if let server = try? await client.rallyEvents(since: nil).first(where: { $0.videoId == video.id }) {
                        try? EventReview.write(server.record, to: RallyEventsSync.conflictURL(for: url, serverRevision: server.revision))
                    }
                    conflicts.append("\(name) (\(conflict.message))")
                } catch LabelingClient.Failure.server(_, let message) where RallyEventsSync.isIdentityRefusal(message) || RallyEventsSync.isWithheld(message) {
                    // The server refused this recording's record (footage identity, or withheld): nothing is written.
                    conflicts.append("\(name) (refused by the server: \(message))")
                }
            case .pull:
                // Identity was checked above, before anything is written, replaced or handed to the editor.
                guard let server = remote[video.id] else { continue }
                try EventReview.write(server.record, to: url)
                try EventReview.write(server.record, to: shadowURL)
                onRecordSynced?(root, name, server.record)
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

    /// The legacy rally-times file beside a recording, as the sync reads it.
    enum RallyTimesFile {
        case absent
        /// There, but not decodable: never taken as "no marks" — the server's copy would overwrite it.
        case unreadable(String)
        case present([RallyMarkRecord])
    }

    static func rallyTimes(at url: URL) -> RallyTimesFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do { return .present(try JSONDecoder().decode([RallyMarkRecord].self, from: Data(contentsOf: url))) }
        catch { return .unreadable(error.localizedDescription) }
    }

    /// Set a recording aside (the backlog) or put it back (`reason` nil), from the Mac: written on the server
    /// first (the authority both devices read), then on the session. Throws when not signed in or the recording
    /// has no row yet (it has never been published for the phone).
    /// True once the server and the session have it; false — with why in `status` — when not signed in, the
    /// recording has no row yet, or the server could not be reached. Nothing is set aside on a false.
    @discardableResult
    func setBacklog(session name: String, reason: String?) async -> Bool {
        guard let opening = projects.opening else { status = "No project open — nothing to set aside."; return false }
        do {
            guard let row = try await client.videos().first(where: { $0.project == opening.name && $0.sessionName == name }) else {
                status = "\(name) has no row on the server yet (a full sync round lists it for the phone) — not set aside."
                return false
            }
            let at = Date()
            try await client.setBacklog(row.id, reason: reason, at: at)
            try projects.require(opening)
            projects.sampler.setBacklog(reason: reason, at: reason == nil ? nil : at, session: name)
            status = reason == nil ? "\(name) is back in the queue." : "\(name) set aside: \(reason!)."
            return true
        } catch LabelingClient.Failure.notSignedIn {
            status = "Sign in to sync with the phone — \(name) was not set aside."
            return false
        } catch {
            status = "\(name) was not set aside: \(error.localizedDescription)"
            return false
        }
    }

    private func syncRallyTimes(_ opening: ProjectsModel.Opening) async throws -> (pushed: Int, pulled: Int, unreadable: [String]) {
        let videos = try await client.videos().filter { $0.project == opening.name && $0.sessionName != nil }
        let remote = Dictionary(uniqueKeysWithValues: try await client.rallyTimes(since: nil).map { ($0.videoId, $0) })
        var pushed = 0, pulled = 0
        var unreadable: [String] = []
        for video in videos {
            // The session is the captured project's (the lookup refuses once the opening ended); from it to the write
            // below there is no suspension point but the push's own save, after which nothing of the recording is written.
            guard let name = video.sessionName, let session = try projects.session(named: name, in: opening) else { continue }
            // The backlog is the server's (either device may set a recording aside or put it back; the last change
            // stands): the session takes the row's value whenever it differs — before the label file is read, since
            // the backlog has nothing to do with it and an unreadable file must not keep a skip from the Mac.
            if session.backlogReason != video.backlogReason || session.backlogAt != video.backlogAt {
                projects.sampler.setBacklog(reason: video.backlogReason, at: video.backlogAt, session: name)
            }
            let labels = RallyMarkModel.labelsURL(for: URL(fileURLWithPath: session.sourcePath))
            let localRallies: [RallyMarkRecord]?
            switch Self.rallyTimes(at: labels) {
            case .absent: localRallies = nil
            case .unreadable: unreadable.append(name); continue
            case .present(let rallies): localRallies = rallies
            }
            let localChanged = (try? labels.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            // The Mac always says what the cuts are (an empty list when none), so the server's value is its own.
            let local = localRallies.map { rallies in
                LabelRallyTimes(videoId: video.id,
                                rallies: rallies.map { LabelRally(start: $0.startTime, end: $0.endTime, kind: $0.kind, contacts: $0.contacts) },
                                complete: session.ralliesMarked ?? false, cuts: session.cuts ?? [])
            }
            let theirs = remote[video.id]
            switch (local, theirs) {
            case (nil, nil):
                continue
            case (let mine?, nil):
                try await client.save(mine)
                pushed += 1
            case (nil, let theirs?):
                try write(theirs, to: labels, session: name, in: opening)
                pulled += 1
            case (let mine?, let theirs?):
                guard !Self.same(mine, theirs) else { continue }
                if let changed = localChanged, let remoteChanged = theirs.updatedAt, changed > remoteChanged {
                    try await client.save(mine)
                    pushed += 1
                } else {
                    try write(theirs, to: labels, session: name, in: opening)
                    pulled += 1
                }
            }
        }
        return (pushed, pulled, unreadable)
    }

    // MARK: - 4. Tracked rallies, both ways

    /// Per rally, the newer side wins. A rally only on the phone is new from
    /// it — unless it was here at the last sync, then it was deleted here and
    /// is marked deleted there. One the phone marked deleted goes here too.
    ///
    /// Only rallies whose time differs from this Mac's copy are fetched in
    /// full: pre-tracked rallies make hundreds, and most don't change
    /// between syncs.
    private func syncTracks(_ opening: ProjectsModel.Opening, framesSent: Set<UUID>) async throws -> (sent: Int, received: Int) {
        let videos = try await client.videos().filter { $0.project == opening.name && $0.sessionName != nil }
        let stamps = try await client.trackStamps()
        var localTimes: [UUID: Date?] = [:]
        for video in videos {
            guard let name = video.sessionName, let session = try projects.session(named: name, in: opening) else { continue }
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
        // What each session's synced list becomes once the server has this round's batches: its rallies now, plus
        // the rallies deleted here whose tombstones the server has not acknowledged yet.
        var syncedAfter: [(session: String, ids: [UUID], tombstones: [UUID])] = []
        // Sent rallies are stamped with the time they're sent, not when they
        // changed here: the phone takes only rows stamped after its last look,
        // so a rally changed here while syncing was off would never reach it.
        let now = Date()
        for video in videos {
            // The session read here and written below is the captured project's: no suspension point in between.
            guard let name = video.sessionName, let session = try projects.session(named: name, in: opening) else { continue }
            var local = session.tracks ?? []
            let synced = Set(session.syncedTrackIds ?? [])
            let theirs = remote[video.id] ?? []
            let known = remoteIds[video.id] ?? []
            var changedHere = false
            var tombstones: [UUID] = []
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
                        tombstones.append(r.id)
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
            try projects.require(opening)
            if changedHere {
                projects.sampler.setTracks(local, session: name)
                onTracksChanged?(name)
            }
            // The synced list now: the session's rallies (a rally just received from the phone included — deleted
            // here before the next successful round, it must go up as a tombstone, not come back as new) plus the
            // rallies deleted here, every one of them until the server acknowledges its tombstone below.
            projects.sampler.setSyncedTrackIds(local.map(\.id) + tombstones, session: name)
            syncedAfter.append((name, local.map(\.id), tombstones))
        }
        var acknowledged: Set<UUID> = []
        for batch in stride(from: 0, to: outgoing.count, by: 20).map({ Array(outgoing[$0..<min($0 + 20, outgoing.count)]) }) {
            // Rallies not sent because the opening ended go next time: changed here, they are newer than the
            // server's stamp; new here, the server does not know them; deleted here, they stay on the synced list
            // (written below only once every batch is acknowledged).
            try projects.require(opening)
            try await client.save(batch)
            acknowledged.formUnion(batch.map(\.id))
        }
        // Once the server has every batch, the acknowledged tombstones come off the synced lists. A round stopped
        // between batches — the opening ended, the connection dropped — leaves the lists as written above: a
        // deletion whose tombstone was not acknowledged is still on them, so the next round sends it instead of
        // taking the server's still-present rally for a new one; a tombstone the server did acknowledge drops off
        // on that round (its stamp is deleted by then, so nothing is fetched or sent for it).
        try projects.require(opening)
        for entry in syncedAfter {
            projects.sampler.setSyncedTrackIds(entry.ids + entry.tombstones.filter { !acknowledged.contains($0) }, session: entry.session)
        }
        return (outgoing.count, received)
    }

    private static func sameTrack(_ a: TrackedRally, _ b: LabelTrack) -> Bool {
        a.done == b.done && a.isRally == b.isRally && abs(a.start - b.start) < 0.001 && abs(a.end - b.end) < 0.001 && a.points == b.points.points
    }

    // MARK: - 5. The plan, for the phone's Plan tab

    /// The captured project's plan and scores (`opening.root`). Returns a note for the status when the plan file
    /// is there but cannot be read: then nothing is published — an empty plan would replace the phone's copy.
    private func publishPlan(_ opening: ProjectsModel.Opening) async throws -> String? {
        let root = opening.root
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let planURL = root.appendingPathComponent("training_plan.json")
        var plan: [TrainedRound] = []
        if FileManager.default.fileExists(atPath: planURL.path) {
            do { plan = try decoder.decode([TrainedRound].self, from: Data(contentsOf: planURL)) }
            catch { return "plan not published: training_plan.json unreadable (\(error.localizedDescription)), the phone keeps the plan it has" }
        }
        var scores: [String: [String: Double]] = [:]
        for name in plan.flatMap({ $0.runs.compactMap(\.name) }) {
            let url = root.appendingPathComponent("incoming/\(name)/metrics.json")
            guard let s = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder().decode(RunScores.self, from: $0) }) else { continue }
            scores[name] = Dictionary(uniqueKeysWithValues: ["tracked", "indoor", "grass", "beach"].compactMap { k in s.f1(k).map { (k, $0) } })
        }
        try projects.require(opening)
        try await client.save(LabelProjectState(project: opening.name, plan: plan, scores: scores, updatedAt: nil))
        return nil
    }

    /// The server's rally times written beside the captured project's recording, and its session marked: only
    /// while the opening holds (the session is the open project's), and the editor told only then.
    private func write(_ times: LabelRallyTimes, to labels: URL, session: String, in opening: ProjectsModel.Opening) throws {
        try projects.require(opening)
        let rallies = times.rallies.sorted { $0.start < $1.start }
            .map { RallyMarkRecord(startTime: $0.start, endTime: $0.end, kind: $0.kind, contacts: $0.contacts) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(rallies).write(to: labels, options: .atomic)
        projects.sampler.setRalliesMarked(times.complete, session: session)
        // A row with no `cuts` was last written by a build from before cuts: it says nothing about them.
        if let cuts = times.cuts { projects.sampler.setCuts(cuts, session: session) }
        onTimesChanged?(session)
    }

    /// Same rallies (to the frame, with the same kinds and touches), the same
    /// "every rally marked", and the same cut ranges (to the frame).
    static func same(_ a: LabelRallyTimes, _ b: LabelRallyTimes) -> Bool {
        guard a.complete == b.complete, a.rallies.count == b.rallies.count else { return false }
        let x = a.rallies.sorted { $0.start < $1.start }, y = b.rallies.sorted { $0.start < $1.start }
        guard zip(x, y).allSatisfy({
            abs($0.start - $1.start) < 0.02 && abs($0.end - $1.end) < 0.02 && $0.kind == $1.kind && ($0.contacts ?? []) == ($1.contacts ?? [])
        }) else { return false }
        let c = (a.cuts ?? []).sorted { $0.start < $1.start }, d = (b.cuts ?? []).sorted { $0.start < $1.start }
        return c.count == d.count && zip(c, d).allSatisfy { abs($0.start - $1.start) < 0.02 && abs($0.end - $1.end) < 0.02 }
    }

    // MARK: - 6. Recording-type claims from the phone (D-033)

    /// The submitted claims of the captured project, each judged against the project as it is
    /// (RecordingTypeClaims.decide) and, if accepted, written through the one writer of the type and read back
    /// before the server hears of it. What is wrong with a claim is declined with a reason in plain words; what is
    /// wrong on this Mac leaves the claim submitted for the next round. The write lands under `opening` only; a
    /// settlement is a server-committed fact about a write already made, so it may follow the end of the opening.
    private func syncRecordingTypeClaims(_ opening: ProjectsModel.Opening) async throws -> (accepted: Int, rejected: Int, deferred: [String]) {
        let project = opening.name, root = opening.root
        let submitted = try await client.recordingTypeClaims(since: nil).filter { $0.project == project && $0.status == .submitted }
        guard !submitted.isEmpty else { return (0, 0, []) }
        // The withheld closure is the captured project's, read off the main actor.
        guard let withheld = await withheldClosure(root: root) else { return (0, 0, ["the withheld list can't be read — no claim judged"]) }
        try projects.require(opening)
        let store = FootageProperties.Store(root: root)
        var accepted = 0, rejected = 0
        var deferred: [String] = []
        for (_, group) in Dictionary(grouping: submitted, by: \.videoId).sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let ordered = group.sorted { $0.revision > $1.revision }
            // Two still submitted for one recording (a race the server had not ordered when they were read): the newest counts.
            for older in ordered.dropFirst() {
                _ = try await client.settleRecordingTypeClaim(older.id, status: .rejected, reason: "replaced by a newer choice", confirmedAt: nil)
                rejected += 1
            }
            var claim = ordered[0]
            // The claim is applied as the server has it now. A replacement sent from the phone since the round began
            // supersedes it — then the replacement is the claim to apply, in this round; and a supersession that lands
            // between that check and the settlement (the server refuses the settlement as a conflict) is answered the
            // same way, so a superseded choice never stays on file as the decision. Twice at most: a phone changing its
            // mind faster than that waits for the next round.
            var attempts = 0
            while attempts < 3 {
                attempts += 1
                guard let fresh = try await client.recordingTypeClaim(id: claim.id) else { break }   // gone with its recording
                if fresh.status != .submitted {
                    guard let newer = try await newestSubmittedClaim(for: claim.videoId) else { break }
                    claim = newer
                    continue
                }
                let name = DatasetStore.safeName(claim.sessionName)
                try projects.require(opening)
                guard let session = try projects.session(named: name, in: opening) else {
                    _ = try await client.settleRecordingTypeClaim(claim.id, status: .rejected, reason: "the recording is not in the project on the Mac", confirmedAt: nil)
                    rejected += 1
                    break
                }
                // The identity the claim is judged against is the one the phone was given: the published fingerprint of
                // the session's file (what publishVideos/publishIdentities send as label_videos.source_fingerprint). The
                // card's fingerprint is the origin's — a cut clip's differs — and binds the record, not the claim
                // (found by the synthetic acceptance of 2026-11-04: every claim on cut footage was "file changed").
                let sourcePath = session.sourcePath
                let published = await Task.detached(priority: .utility) { ProjectsModel.fileFingerprint(atPath: sourcePath) }.value
                try projects.require(opening)
                // A file that can't be read now (the footage share away) is the Mac's problem, not the claim's: left
                // submitted for the next round. Only a fingerprint read and found different declines it (Codex on #148).
                guard let published else {
                    deferred.append("\(name): the recording's file can't be read on the Mac — judged next round")
                    break
                }
                let card = FootageTypeConfirmation.sourceFingerprint(of: name, in: projects.project)
                // The record as it is now — read here, after every await of the round so far (a settlement of another
                // recording's claim suspends; a confirmation on this Mac may have landed meanwhile), and nothing suspends
                // between this read, the decision and the write below.
                let state: RecordingTypeClaims.RecordState
                var onFile: FootageProperties.File?
                do { onFile = try store.load(name); state = onFile.map { .record(type: $0.recordingType.rawValue, by: $0.recordingTypeBy, at: $0.recordingTypeAt) } ?? .none }
                catch { state = .unreadable(error.localizedDescription) }
                switch RecordingTypeClaims.decide(claim: claim, publishedFingerprint: published, withheld: withheld.contains(name), record: state) {
                case .reject(let why):
                    _ = try await client.settleRecordingTypeClaim(claim.id, status: .rejected, reason: why, confirmedAt: nil)
                    rejected += 1
                case .defer(let why):
                    deferred.append("\(name): \(why)")
                case .alreadyApplied:
                    // The record carries this very claim (its acknowledgement was lost): acknowledged, nothing written again.
                    _ = try await client.settleRecordingTypeClaim(claim.id, status: .accepted, reason: nil,
                                                                 confirmedAt: onFile?.recordingTypeAt.flatMap(RecordingTypeClaims.parse))
                    accepted += 1
                case .accept:
                    guard let type = claim.kind.flatMap({ FootageProperties.RecordingType(rawValue: $0.rawValue) }) else { break }
                    // The one writer, under the opening (no suspension since the record was read and the opening checked),
                    // attributed to the phone's labeler and the claim at the claim's time; read back before the server hears of it.
                    let at = EventReview.stamp(claim.submittedAt)
                    do {
                        _ = try store.confirmRecordingType(type, video: name, sourceFingerprint: card, by: RecordingTypeClaims.attribution(of: claim), at: at)
                    } catch {
                        deferred.append("\(name): the record could not be written — \(error.localizedDescription)")
                        break
                    }
                    guard let back = try? store.load(name), back.recordingType == type, back.recordingTypeAt == at,
                          RecordingTypeClaims.isAttributed(back.recordingTypeBy, to: claim) else {
                        deferred.append("\(name): the record was written but does not read back as written")
                        break
                    }
                    do {
                        if dropFirstSettlement, !settlementDropped {
                            settlementDropped = true
                            throw URLError(.networkConnectionLost)   // the acknowledgement lost after the write (fault injection)
                        }
                        _ = try await client.settleRecordingTypeClaim(claim.id, status: .accepted, reason: nil, confirmedAt: RecordingTypeClaims.parse(at))
                        accepted += 1
                    } catch LabelingClient.Failure.server(_, let message) where message.hasPrefix("conflict:") {
                        // Superseded between the check above and this settlement: what is on file is a replaced choice.
                        // The replacement is applied now (it is the newer decision, so it takes the record over).
                        if let newer = try await newestSubmittedClaim(for: claim.videoId), attempts < 3 { claim = newer; continue }
                        deferred.append("\(name): the choice applied was replaced on the phone as it was confirmed; the replacement is applied by the next sync")
                    }
                }
                break
            }
        }
        return (accepted, rejected, deferred)
    }

    /// The newest claim still waiting for the recording, as the server has it now.
    private func newestSubmittedClaim(for video: UUID) async throws -> RecordingTypeClaim? {
        try await client.recordingTypeClaims(since: nil).filter { $0.videoId == video && $0.status == .submitted }.max { $0.revision < $1.revision }
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

/// Review decisions waiting to go up, kept on disk so a quit doesn't lose them. They are keyed by the server's
/// rally ids, not by project.
struct Pending {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "RallyLab")

    let directory: URL

    func file(_ name: String) -> URL { directory.appending(path: "pending-\(name).json") }

    /// What is waiting, or nil when nothing was saved. A file that is there but cannot be decoded is never taken as
    /// empty — the next save would overwrite it: it is set aside under its own name with the time, kept for repair,
    /// and a note says so (nothing in it is sent).
    func load<T: Decodable>(_ type: T.Type, _ name: String, notes: inout [String]) -> T? {
        let url = file(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = directory.appending(path: "pending-\(name).unreadable-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                notes.append("\(url.lastPathComponent) could not be read (\(error.localizedDescription)): kept as \(aside.lastPathComponent), nothing in it sent.")
            } catch let move {
                notes.append("\(url.lastPathComponent) could not be read (\(error.localizedDescription)) and could not be set aside (\(move.localizedDescription)): left in place, nothing in it sent.")
            }
            return nil
        }
    }

    func save<T: Encodable>(_ value: T, _ name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: file(name), options: .atomic)
    }
}
