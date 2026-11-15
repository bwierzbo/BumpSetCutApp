//
//  ProjectSwitchSyncTests.swift
//  RallyLabTests
//
//  A phone-sync round belongs to one opening of one project. Two projects on
//  disk share a recording name; a fake server parks one reply at an exact call
//  while the test closes, switches or reopens the project; then the reply is
//  released and every file of both projects, every remote write and every
//  editor callback is checked. The owner's scenarios A–G (2026-11-03).
//

import CryptoKit
import XCTest
@testable import RallyLab

@MainActor
final class ProjectSwitchSyncTests: XCTestCase {
    private var base: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var sampler: SamplerModel!
    private var projects: ProjectsModel!
    private var server: FakeLabeling!
    private var sync: LabelingSync!
    private var timesChanged: [String] = []
    private var tracksChanged: [String] = []
    private var recordsSynced: [(URL, String)] = []
    private let now = ISO8601DateFormatter().date(from: "2026-11-03T20:00:00Z")!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
        // A defaults suite of this test's own: opening a fixture never becomes what RallyLab opens next.
        suite = "RallyLabTests.ProjectSwitchSync.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        sampler = SamplerModel(defaults: defaults, root: base.appendingPathComponent("empty"))
        projects = ProjectsModel(sampler: sampler, defaults: defaults)
        server = FakeLabeling()
        sync = LabelingSync(projects: projects, client: server, pendingDirectory: base.appendingPathComponent("pending"))
        sync.onTimesChanged = { [weak self] in self?.timesChanged.append($0) }
        sync.onTracksChanged = { [weak self] in self?.tracksChanged.append($0) }
        sync.onRecordSynced = { [weak self] root, name, _ in self?.recordsSynced.append((root, name)) }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixtures

    /// A project on disk: a card per video with the footage file's fingerprint, a session per video over a small
    /// footage file (its bytes name the project, so the two projects' same-named recordings differ), and, if asked,
    /// one finished tracked rally per session.
    @discardableResult
    private func project(_ name: String, videos: [String] = ["video_01"], tracks: Bool = false) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        let store = DatasetStore(root: root)
        try store.prepare()
        var clips: [PlannedClip] = []
        for (n, video) in videos.enumerated() {
            let file = root.appendingPathComponent("footage/\(video).mp4")
            try Data("\(name): \(video) footage".utf8).write(to: file)
            clips.append(SourceRegistryTests.clip("card_\(n)", number: n + 1, videos: [SourceRegistryTests.video(video, fingerprint: ProjectsModel.readFileFingerprint(atPath: file.path))]))
            var session = VideoSession(name: video, sourcePath: file.path, split: "train", addedAt: now, frames: [])
            if tracks { session.tracks = [SourceRegistryTests.rally(done: true)] }
            try store.save(session)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: name, createdAt: now, framesPerRally: 2, clips: clips)).write(to: root.appendingPathComponent("project.json"))
        return root
    }

    private func open(_ name: String) -> ProjectsModel.Opening {
        projects.open(base.appendingPathComponent(name, isDirectory: true))
        return projects.opening!
    }

    private func footage(_ name: String, _ video: String = "video_01") -> URL {
        base.appendingPathComponent("\(name)/footage/\(video).mp4")
    }

    private func labels(_ name: String, _ video: String = "video_01") -> URL { RallyMarkModel.labelsURL(for: footage(name, video)) }

    /// A server row for the recording of `project`.
    @discardableResult
    private func row(_ project: String, _ video: String = "video_01", status: LabelVideo.Status = .rallylab, clipPath: String? = nil) -> LabelVideo {
        let v = LabelVideo(id: UUID(), project: project, sessionName: video, title: "", surface: .beach, camera: .endlineGround, lighting: "",
                           split: "train", clipPath: clipPath, duration: 0, ralliesFound: [], status: status, updatedAt: now)
        server.videos.append(v)
        return v
    }

    private func serverTimes(for row: LabelVideo, rallies: Int, updatedAt: Date? = nil) {
        server.times[row.id] = LabelRallyTimes(videoId: row.id, rallies: (0..<rallies).map { LabelRally(start: Double($0) * 10, end: Double($0) * 10 + 5) },
                                               complete: true, updatedAt: updatedAt ?? now)
    }

    private func writeLocalTimes(_ name: String, rallies: Int) throws {
        let records = (0..<rallies).map { RallyMarkRecord(startTime: Double($0) * 7, endTime: Double($0) * 7 + 3, kind: nil, contacts: nil) }
        try JSONEncoder().encode(records).write(to: labels(name), options: .atomic)
    }

    /// Every file under `root`, by relative path, with its content hash.
    private func snapshot(_ name: String) throws -> [String: String] {
        let root = base.appendingPathComponent(name, isDirectory: true)
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in e where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            out[String(url.path.dropFirst(root.path.count))] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    /// Starts a round and waits until the server has parked its reply at the hold.
    private func startRound(videos: Bool = false) async -> Task<Bool, Never> {
        let round = Task { await self.sync.sync(videos: videos) }
        let reached = await server.arrived()
        XCTAssertTrue(reached, "the round never reached the hold; calls made: \(server.calls)")
        return round
    }

    // MARK: - The opening

    func testEveryOpeningIsItsOwnAndEndsBeforeTheNext() throws {
        try project("A"); try project("B")
        var ended: [ProjectsModel.Opening] = []
        projects.onOpeningEnded { ended.append($0) }
        let a1 = open("A")
        XCTAssertEqual(a1.name, "A")
        XCTAssertEqual(a1.root, base.appendingPathComponent("A", isDirectory: true).standardizedFileURL)
        XCTAssertNoThrow(try projects.require(a1))
        XCTAssertNotNil(try projects.session(named: "video_01", in: a1))
        let b = open("B")
        XCTAssertNotEqual(a1, b)
        XCTAssertEqual(ended, [a1], "the handler hears of A's opening ending when B opens")
        XCTAssertThrowsError(try projects.require(a1)) { XCTAssertEqual($0 as? ProjectsModel.OpeningEnded, ProjectsModel.OpeningEnded(name: "A")) }
        XCTAssertThrowsError(try projects.session(named: "video_01", in: a1), "B's same-named session is never handed out for A's opening")
        let a2 = open("A")
        XCTAssertNotEqual(a2, a1, "A opened again is a new opening: its sessions were reloaded")
        XCTAssertEqual(a2.root, a1.root)
        XCTAssertEqual(ended, [a1, b])
        XCTAssertThrowsError(try projects.require(a1))
        XCTAssertNoThrow(try projects.require(a2))
        let a3 = open("A")
        XCTAssertNotEqual(a3, a2, "even the same folder opened over itself")
        projects.close()
        XCTAssertNil(projects.opening)
        XCTAssertEqual(ended, [a1, b, a2, a3])
        XCTAssertThrowsError(try projects.require(a3))
        projects.open(base.appendingPathComponent("A"))
        projects.forget(base.appendingPathComponent("A"))
        XCTAssertNil(projects.opening, "forgetting the open project ends its opening too")
        XCTAssertEqual(ended.count, 5)
    }

    func testACreatedProjectIsAnOpeningOfItsOwn() async throws {
        // From the welcome window, with nothing open: the new project is open, with an opening — so its sync runs
        // and a cut made for it is recorded.
        XCTAssertNil(projects.opening)
        projects.create(name: "C", in: base)
        let c = try XCTUnwrap(projects.opening, "a created project is an opening like an opened one")
        XCTAssertEqual(c.name, "C")
        XCTAssertEqual(c.root, base.appendingPathComponent("C", isDirectory: true).standardizedFileURL)
        XCTAssertEqual(projects.projectDir, c.root)
        XCTAssertNoThrow(try projects.require(c))
        let outcome = await sync.sync(videos: false)
        XCTAssertTrue(outcome, sync.status)
        XCTAssertEqual(server.states.map(\.project), ["C"], "the new project's plan went up under its own name")
        // Creating a project whose folder already is one opens it, as a new opening.
        try project("A")
        projects.create(name: "A", in: base)
        let a = try XCTUnwrap(projects.opening)
        XCTAssertEqual(a.name, "A")
        XCTAssertNotEqual(a, c)
        XCTAssertThrowsError(try projects.require(c))
        projects.create(name: "A", in: base)
        XCTAssertNotEqual(projects.opening, a, "created over itself: a new opening, like opened over itself")
    }

    func testCreatingAProjectUnderARoundEndsTheOpeningTheRoundStartedFor() async throws {
        try project("A")
        let a = open("A")
        serverTimes(for: row("A"), rallies: 1)
        var ended: [ProjectsModel.Opening] = []
        projects.onOpeningEnded { ended.append($0) }
        server.hold("videos")
        let round = await startRound()
        // The person creates a new project while A's listing is on its way back.
        projects.create(name: "New", in: base)
        let new = try XCTUnwrap(projects.opening)
        XCTAssertEqual(new.name, "New")
        XCTAssertEqual(ended, [a], "A's opening ended when New was created")
        XCTAssertThrowsError(try projects.require(a))
        let before = try snapshot("New")
        server.release()
        let outcome = await round.value
        XCTAssertFalse(outcome)
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        XCTAssertEqual(try snapshot("New"), before, "nothing of A's reply was written into the new project")
        XCTAssertFalse(FileManager.default.fileExists(atPath: labels("A").path), "nor into A, whose opening ended")
        XCTAssertEqual(timesChanged, [])
        XCTAssertEqual(server.savedTimes, [])
        XCTAssertEqual(projects.opening, new)
        XCTAssertFalse(sync.isSyncing)
    }

    func testTheSamplingWaitEndsWhenItsOpeningEndsOrItsTaskIsCancelled() async throws {
        // A phone video pulled in is waited for while it's cut and sampled; the wait checks every half second.
        try project("A"); try project("B")
        let a = open("A")
        let wait = Task { try await self.projects.waitForSampling("card_0_02", in: a) }
        // The project changes before the wait's first check: it ends there, before reading any progress of B's.
        open("B")
        let result = await wait.result
        guard case .failure(let error) = result else { return XCTFail("the wait went on under B: \(result)") }
        XCTAssertTrue(error is ProjectsModel.OpeningEnded, "\(error)")
        // A cancelled wait ends at once — no polling on with sleeps that no longer sleep.
        let a2 = open("A")
        let started = Date()
        let cancelled = Task { try await self.projects.waitForSampling("card_0_02", in: a2) }
        cancelled.cancel()
        let result2 = await cancelled.result
        guard case .failure(let error2) = result2 else { return XCTFail("the cancelled wait returned \(result2)") }
        XCTAssertTrue(error2 is CancellationError, "\(error2)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4)
        // Under its own opening, idle, the wait answers as before: nothing of that video is there.
        let idle = try await projects.waitForSampling("card_0_02", in: a2)
        XCTAssertFalse(idle)
    }

    // MARK: - A and B: identical names, a stale reply

    func testAStaleReplyNeverWritesTheServersTimesBesideAnotherProjectsSameNamedRecording() async throws {
        try project("A"); try project("B")
        let a = open("A")
        serverTimes(for: row("A"), rallies: 2)
        // The reply listing A's videos is delayed; the person switches to B meanwhile.
        server.hold("videos")
        let round = await startRound()
        let b = open("B")
        let before = try snapshot("B")
        server.release()
        let outcome1 = await round.value
        XCTAssertFalse(outcome1)
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        XCTAssertEqual(try snapshot("B"), before, "nothing of A's reply was written into B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: labels("B").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: labels("A").path), "nor into A, whose opening ended")
        XCTAssertNil(projects.session(named: "video_01")?.ralliesMarked, "B's session was not marked from A's rows")
        XCTAssertEqual(timesChanged, [], "no editor was told")
        XCTAssertEqual(server.savedTimes.count, 0)
        XCTAssertEqual(projects.opening, b)
        XCTAssertFalse(sync.isSyncing)
        // The next round of A, under its new opening, does the work.
        let a2 = open("A")
        XCTAssertNotEqual(a2, a)
        let outcome2 = await sync.sync(videos: false)
        XCTAssertTrue(outcome2)
        XCTAssertEqual(try JSONDecoder().decode([RallyMarkRecord].self, from: Data(contentsOf: labels("A"))).count, 2)
        XCTAssertEqual(projects.session(named: "video_01")?.ralliesMarked, true)
        XCTAssertEqual(timesChanged, ["video_01"])
        XCTAssertEqual(try snapshot("B"), before)
    }

    func testAStaleReplyNeverPutsThePhonesRalliesIntoAnotherProjectsSameNamedSession() async throws {
        try project("A", tracks: true); try project("B", tracks: true)
        open("A")
        let a = row("A")
        // A rally new from the phone on A's row, arriving after the person switched to B.
        let phone = LabelTrack(SourceRegistryTests.rally(done: true), videoId: a.id)
        server.tracks[phone.id] = phone
        server.stamps = [LabelingClient.TrackStamp(id: phone.id, videoId: a.id, deleted: false, updatedAt: now)]
        server.hold("tracks")
        let round = await startRound()
        open("B")
        let before = try snapshot("B")
        let tracksInB = projects.session(named: "video_01")?.tracks?.map(\.id)
        server.release()
        let outcome3 = await round.value
        XCTAssertFalse(outcome3)
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        XCTAssertEqual(try snapshot("B"), before, "B's session file is untouched")
        XCTAssertEqual(projects.session(named: "video_01")?.tracks?.map(\.id), tracksInB, "and so is B's session in memory")
        XCTAssertNil(projects.session(named: "video_01")?.syncedTrackIds)
        XCTAssertEqual(tracksChanged, [])
        XCTAssertEqual(server.savedTracks, [], "nothing of B was sent as A's")
        let aSession = try DatasetStore(root: base.appendingPathComponent("A")).loadSessionsStrict().first { $0.name == "video_01" }
        XCTAssertEqual(aSession?.tracks?.count, 1, "A's session on disk is as it was")
        XCTAssertNil(aSession?.syncedTrackIds)
    }

    // MARK: - C: A → B → A

    func testARoundOfTheFirstOpeningCannotTouchTheSameProjectOpenedAgain() async throws {
        try project("A"); try project("B")
        let a1 = open("A")
        serverTimes(for: row("A"), rallies: 1)
        server.hold("videos")
        let round = await startRound()
        open("B")
        let a2 = open("A")
        XCTAssertNotEqual(a1, a2)
        let before = try snapshot("A")
        server.release()
        let outcome4 = await round.value
        XCTAssertFalse(outcome4, "the round of the first opening stops, though A is open again")
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        XCTAssertEqual(try snapshot("A"), before)
        XCTAssertEqual(timesChanged, [])
        XCTAssertEqual(server.savedTimes, [])
        XCTAssertEqual(projects.opening, a2)
        let outcome5 = await sync.sync(videos: false)
        XCTAssertTrue(outcome5, "a round of the new opening does the work")
        XCTAssertEqual(try JSONDecoder().decode([RallyMarkRecord].self, from: Data(contentsOf: labels("A"))).count, 1)
        XCTAssertEqual(timesChanged, ["video_01"])
        XCTAssertEqual(projects.opening, a2)
    }

    // MARK: - D: closed during a round

    func testAProjectClosedUnderARoundGetsNoWriteAndNoEditorUpdate() async throws {
        try project("A", tracks: true)
        open("A")
        let a = row("A")
        serverTimes(for: a, rallies: 1)
        let phone = LabelTrack(SourceRegistryTests.rally(done: true), videoId: a.id)
        server.tracks[phone.id] = phone
        server.stamps = [LabelingClient.TrackStamp(id: phone.id, videoId: a.id, deleted: false, updatedAt: now)]
        server.hold("rallyTimes")
        let round = await startRound()
        let before = try snapshot("A")
        projects.close()
        XCTAssertNil(projects.opening)
        server.release()
        let outcome6 = await round.value
        XCTAssertFalse(outcome6)
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        XCTAssertEqual(try snapshot("A"), before)
        XCTAssertEqual(timesChanged, [])
        XCTAssertEqual(tracksChanged, [])
        XCTAssertEqual(recordsSynced.count, 0)
        XCTAssertEqual(server.savedTimes, [])
        XCTAssertEqual(server.savedTracks, [])
        XCTAssertEqual(server.states, [])
        let outcome7 = await sync.sync(videos: false)
        XCTAssertFalse(outcome7, "no project: no round")
        XCTAssertFalse(sync.isSyncing)
    }

    func testADeletionWhoseTombstoneWasNotSentIsKeptForTheNextRoundNotTakenBackFromTheServer() async throws {
        // 21 rallies were synced, then all deleted here: 21 tombstones go up in two batches (20 + 1). The project
        // changes while the first batch's reply is on its way back.
        try project("A"); try project("B")
        let a1 = open("A")
        let r = row("A")
        let rallies = (0..<21).map { _ in SourceRegistryTests.rally(done: true) }
        for rally in rallies {
            let track = LabelTrack(rally, videoId: r.id)
            server.tracks[track.id] = track
            server.stamps.append(LabelingClient.TrackStamp(id: track.id, videoId: r.id, deleted: false, updatedAt: now))
        }
        sampler.setSyncedTrackIds(rallies.map(\.id), session: "video_01")
        let before = try snapshot("A")
        server.hold("save(tracks)")
        let round = await startRound()
        open("B")
        server.release()
        let outcome = await round.value
        XCTAssertFalse(outcome)
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        XCTAssertEqual(server.savedTracks.map(\.count), [20], "the first batch was acknowledged, the second never sent")
        XCTAssertTrue(server.savedTracks[0].allSatisfy(\.deleted))
        XCTAssertEqual(try snapshot("A"), before, "A's session — its synced list with all 21 — is exactly as it was")
        XCTAssertEqual(tracksChanged, [])
        // A again: the one tombstone the server does not have goes up; the 20 it has are not sent again; the server's
        // still-present rally is NOT restored here.
        let a2 = open("A")
        XCTAssertNotEqual(a2, a1)
        let outcome2 = await sync.sync(videos: false)
        XCTAssertTrue(outcome2, sync.status)
        XCTAssertEqual(server.savedTracks.map(\.count), [20, 1])
        let last = try XCTUnwrap(server.savedTracks.last?.first)
        XCTAssertTrue(last.deleted)
        XCTAssertFalse(server.savedTracks[0].map(\.id).contains(last.id))
        XCTAssertTrue(server.tracks.values.allSatisfy(\.deleted), "the server has all 21 deletions")
        XCTAssertEqual(projects.session(named: "video_01")?.tracks?.count ?? 0, 0, "nothing came back from the server as new")
        XCTAssertEqual(projects.session(named: "video_01")?.syncedTrackIds ?? [], [], "every deletion acknowledged: the synced list is empty")
        XCTAssertEqual(tracksChanged, [])
    }

    func testARallyReceivedInARoundWhosePushFailedCanStillBeDeletedHereNotRestoredAsNew() async throws {
        // A mixed round: a rally new from the phone comes down, a rally new here goes up — and the push fails.
        try project("A", tracks: true)
        open("A")
        let r = row("A")
        let phone = LabelTrack(SourceRegistryTests.rally(done: true), videoId: r.id)
        server.tracks[phone.id] = phone
        server.stamps = [LabelingClient.TrackStamp(id: phone.id, videoId: r.id, deleted: false, updatedAt: now)]
        server.failures["save(tracks)"] = URLError(.networkConnectionLost)
        let outcome = await sync.sync(videos: false)
        XCTAssertFalse(outcome)
        XCTAssertTrue(sync.status.hasPrefix("Sync stopped:"), sync.status)
        XCTAssertEqual(projects.session(named: "video_01")?.tracks?.count, 2, "the phone's rally was received")
        XCTAssertEqual(tracksChanged, ["video_01"])
        XCTAssertEqual(Set(projects.session(named: "video_01")?.syncedTrackIds ?? []),
                       Set((projects.session(named: "video_01")?.tracks ?? []).map(\.id)), "the received rally is on the synced list at once")
        // Deleted here before the next successful round.
        sampler.setTracks((projects.session(named: "video_01")?.tracks ?? []).filter { $0.id != phone.id }, session: "video_01")
        let outcome2 = await sync.sync(videos: false)
        XCTAssertTrue(outcome2, sync.status)
        XCTAssertEqual(projects.session(named: "video_01")?.tracks?.count, 1, "the deleted rally did not come back as new")
        XCTAssertEqual(server.tracks[phone.id]?.deleted, true, "its tombstone went up")
        XCTAssertEqual(Set(server.savedTracks.last?.map(\.deleted) ?? []), [false, true], "with the rally new here")
        XCTAssertEqual(server.savedTracks.last?.count, 2)
        XCTAssertEqual(Set(projects.session(named: "video_01")?.syncedTrackIds ?? []),
                       Set((projects.session(named: "video_01")?.tracks ?? []).map(\.id)), "acknowledged: the tombstone is off the list")
    }

    // MARK: - E: failure, cancellation, delayed acknowledgement

    func testAFailedPushIsRetriedOnceAndNeverDuplicated() async throws {
        try project("A")
        open("A")
        row("A")
        try writeLocalTimes("A", rallies: 1)
        server.failures["save(times)"] = URLError(.notConnectedToInternet)
        let outcome8 = await sync.sync(videos: false)
        XCTAssertFalse(outcome8)
        XCTAssertTrue(sync.status.hasPrefix("Sync stopped:"), sync.status)
        XCTAssertEqual(server.savedTimes.count, 0, "the failed save committed nothing")
        XCTAssertEqual(try JSONDecoder().decode([RallyMarkRecord].self, from: Data(contentsOf: labels("A"))).count, 1, "the local marks are as they were")
        let outcome9 = await sync.sync(videos: false)
        XCTAssertTrue(outcome9)
        XCTAssertEqual(server.savedTimes.count, 1, "sent once on the retry")
        let outcome10 = await sync.sync(videos: false)
        XCTAssertTrue(outcome10)
        XCTAssertEqual(server.savedTimes.count, 1, "and not again: both sides agree")
    }

    func testQueuedDecisionsSurviveAFailedSendAndGoUpExactlyOnce() async throws {
        try project("A")
        open("A")
        let track = UUID()
        let point = SourceRegistryTests.rally(done: true).points[0]
        sync.queue(LabelingClient.FrameEdit(track: track, index: 0, point: point))
        sync.queue(LabelingClient.FrameEdit(track: track, index: 1, point: point))
        sync.queue(LabelingClient.RallyVerdict(track: track, isRally: true))
        server.failures["reviewFrames"] = URLError(.timedOut)
        let outcome11 = await sync.sync(videos: false)
        XCTAssertFalse(outcome11)
        XCTAssertEqual(sync.pendingFrames.count, 2, "the frames stay queued")
        XCTAssertEqual(sync.pendingRallies.count, 0, "the verdict before them went")
        XCTAssertEqual(server.verdicts.count, 1)
        let pending = base.appendingPathComponent("pending/pending-frames.json")
        XCTAssertEqual(try JSONDecoder().decode([LabelingClient.FrameEdit].self, from: Data(contentsOf: pending)).count, 2, "and on disk")
        let outcome12 = await sync.sync(videos: false)
        XCTAssertTrue(outcome12)
        XCTAssertEqual(server.reviewed.map(\.edits.count), [2], "sent once, together")
        XCTAssertEqual(sync.pendingFrames, [])
        XCTAssertEqual(try JSONDecoder().decode([LabelingClient.FrameEdit].self, from: Data(contentsOf: pending)), [])
        XCTAssertEqual(server.verdicts.count, 1, "the verdict was not sent again")
    }

    func testARoundIsCancelledWhenItsOpeningEndsAndTheNextOpeningStartsOver() async throws {
        try project("A"); try project("B")
        open("A")
        row("A")
        try writeLocalTimes("A", rallies: 1)
        // The server honours cancellation (as URLSession does): the parked reply throws when the round is cancelled.
        server.hold("videos", cancellable: true)
        let round = await startRound()
        open("B")
        let outcome13 = await round.value
        XCTAssertFalse(outcome13, "cancelled by the end of A's opening: nothing to release")
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        XCTAssertEqual(server.savedTimes.count, 0)
        XCTAssertFalse(sync.isSyncing)
        open("A")
        let outcome14 = await sync.sync(videos: false)
        XCTAssertTrue(outcome14)
        XCTAssertEqual(server.savedTimes.count, 1, "sent once, by the new opening's round")
    }

    func testAnAcknowledgementThatArrivesAfterTheSwitchIsRecordedInTheCapturedProjectOnly() async throws {
        try project("A"); try project("B")
        open("A")
        let a = row("A")
        // A's Stage 1 record, new here (revision 0, over A's footage).
        var record = EventReview.File(video: "video_01", sourceFingerprint: ProjectsModel.readFileFingerprint(atPath: footage("A").path)!, frameRate: 30, durationSec: 10, tool: "t", frameTimesDigest: nil, revision: 0)
        EventReview.Mutation.markReviewed(from: 0, to: 10, in: &record, at: now, annotator: "BW")
        let url = EventReview.url(forVideo: footage("A"))
        try EventReview.write(record, to: url)
        // The server commits the push, but its reply is delayed past the switch to B.
        server.hold("saveRallyEvents")
        let round = await startRound()
        open("B")
        let bBefore = try snapshot("B")
        server.release()
        let outcome15 = await round.value
        XCTAssertFalse(outcome15)
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        XCTAssertEqual(server.events[a.id]?.revision, 1, "the server has the record")
        XCTAssertEqual(try EventReview.read(url).revision, 1, "the acknowledgement is recorded on A's record")
        XCTAssertEqual(try EventReview.read(RallyEventsSync.shadowURL(for: url)).revision, 1, "and in A's shadow")
        XCTAssertEqual(recordsSynced.count, 0, "but no editor is told: A is not open")
        XCTAssertEqual(try snapshot("B"), bBefore)
        // A opened again: nothing to push, no conflict — the save was not lost or repeated.
        open("A")
        let outcome16 = await sync.sync(videos: false)
        XCTAssertTrue(outcome16)
        XCTAssertEqual(server.calls.filter { $0 == "saveRallyEvents" }.count, 1)
        XCTAssertFalse(sync.status.contains("conflict"), sync.status)
        XCTAssertEqual(recordsSynced.count, 0)
    }

    // MARK: - F: edits while a round runs

    func testAnEditMadeWhileThePushWasInFlightIsKeptAndSentNext() async throws {
        try project("A")
        open("A")
        row("A")
        try writeLocalTimes("A", rallies: 1)
        server.hold("save(times)")
        let round = await startRound()
        try writeLocalTimes("A", rallies: 2)   // the person marks another rally while the save is in flight
        server.release()
        let outcome17 = await round.value
        XCTAssertTrue(outcome17)
        XCTAssertEqual(server.savedTimes.map { $0.rallies.count }, [1])
        XCTAssertEqual(try JSONDecoder().decode([RallyMarkRecord].self, from: Data(contentsOf: labels("A"))).count, 2, "the edit stands")
        let outcome18 = await sync.sync(videos: false)
        XCTAssertTrue(outcome18)
        XCTAssertEqual(server.savedTimes.map { $0.rallies.count }, [1, 2], "and goes up next, newer than the server's")
    }

    func testARallyTrackedWhileTheStampsWereInFlightIsSentWithTheRest() async throws {
        try project("A", tracks: true)
        open("A")
        row("A")
        server.hold("trackStamps")
        let round = await startRound()
        let added = SourceRegistryTests.rally(done: true)
        sampler.setTracks((projects.session(named: "video_01")?.tracks ?? []) + [added], session: "video_01")
        server.release()
        let outcome19 = await round.value
        XCTAssertTrue(outcome19)
        XCTAssertEqual(server.savedTracks.flatMap { $0 }.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       (projects.session(named: "video_01")?.tracks ?? []).map(\.id).sorted { $0.uuidString < $1.uuidString }, "both rallies went up")
        XCTAssertEqual(projects.session(named: "video_01")?.tracks?.count, 2)
        XCTAssertEqual(Set(projects.session(named: "video_01")?.syncedTrackIds ?? []), Set(server.tracks.keys))
    }

    // MARK: - G: unreadable records fail closed

    func testAnUnreadableRallyTimesFileIsLeftAloneAndNeverTakenAsNoMarks() async throws {
        try project("A", videos: ["video_01", "video_02"])
        open("A")
        let a1 = row("A", "video_01"), a2 = row("A", "video_02")
        serverTimes(for: a1, rallies: 2)
        serverTimes(for: a2, rallies: 1)
        try Data("{not json".utf8).write(to: labels("A", "video_01"))
        let bytes = try Data(contentsOf: labels("A", "video_01"))
        let outcome20 = await sync.sync(videos: false)
        XCTAssertTrue(outcome20)
        XCTAssertEqual(try Data(contentsOf: labels("A", "video_01")), bytes, "the unreadable file is exactly as it was")
        XCTAssertNil(projects.session(named: "video_01")?.ralliesMarked)
        XCTAssertTrue(sync.status.contains("1 rally-times file(s) unreadable, left untouched: video_01"), sync.status)
        XCTAssertEqual(try JSONDecoder().decode([RallyMarkRecord].self, from: Data(contentsOf: labels("A", "video_02"))).count, 1, "the readable recording synced")
        XCTAssertEqual(timesChanged, ["video_02"])
        XCTAssertEqual(server.savedTimes, [])
    }

    func testAnUnreadablePlanIsNotPublishedAsAnEmptyOne() async throws {
        try project("A")
        open("A")
        try Data("[{".utf8).write(to: base.appendingPathComponent("A/training_plan.json"))
        let outcome21 = await sync.sync(videos: false)
        XCTAssertTrue(outcome21)
        XCTAssertEqual(server.states, [], "no plan went up")
        XCTAssertTrue(sync.status.contains("plan not published: training_plan.json unreadable"), sync.status)
        try FileManager.default.removeItem(at: base.appendingPathComponent("A/training_plan.json"))
        let outcome22 = await sync.sync(videos: false)
        XCTAssertTrue(outcome22)
        XCTAssertEqual(server.states.map(\.plan.count), [0], "no plan file at all is an empty plan, as before")
    }

    func testAnUnreadableSentListStopsBallPathsFromBeingSentAgain() async throws {
        try project("A")
        open("A")
        row("A", clipPath: "rallylab/A/video_01-v3.mp4")
        let paths = base.appendingPathComponent("A/ballpaths")
        try FileManager.default.createDirectory(at: paths, withIntermediateDirectories: true)
        try Data("path".utf8).write(to: BallPathBuilder.url(for: "video_01", in: base.appendingPathComponent("A")))
        try Data("??".utf8).write(to: paths.appendingPathComponent("sent.json"))
        let outcome23 = await sync.sync(videos: true)
        XCTAssertTrue(outcome23)
        XCTAssertEqual(server.uploads, [], "nothing uploaded on an unreadable list")
        XCTAssertEqual(try Data(contentsOf: paths.appendingPathComponent("sent.json")), Data("??".utf8))
        XCTAssertTrue(sync.status.contains("ball paths not sent: ballpaths/sent.json unreadable"), sync.status)
    }

    func testAnUnreadablePendingQueueIsSetAsideNotOverwritten() throws {
        let dir = base.appendingPathComponent("pending2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("pending-frames.json"))
        let sync = LabelingSync(projects: projects, client: server, pendingDirectory: dir)
        XCTAssertEqual(sync.pendingFrames, [])
        XCTAssertTrue(sync.status.contains("pending-frames.json could not be read"), sync.status)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("pending-frames.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside[0])), Data("not json".utf8), "kept byte for byte")
        sync.queue(LabelingClient.FrameEdit(track: UUID(), index: 0, point: SourceRegistryTests.rally(done: true).points[0]))
        XCTAssertEqual(try JSONDecoder().decode([LabelingClient.FrameEdit].self, from: Data(contentsOf: dir.appendingPathComponent("pending-frames.json"))).count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside[0])), Data("not json".utf8))
    }

    func testAnUnreadableProjectIsNotOpenedAndTheOpenOneGoesOn() async throws {
        try project("A"); try project("B")
        let a = open("A")
        serverTimes(for: row("A"), rallies: 1)
        try Data("{".utf8).write(to: base.appendingPathComponent("B/project.json"))
        server.hold("videos")
        let round = await startRound()
        projects.open(base.appendingPathComponent("B"))
        XCTAssertEqual(projects.opening, a, "B could not be opened: A's opening holds")
        server.release()
        let outcome24 = await round.value
        XCTAssertTrue(outcome24)
        XCTAssertEqual(try JSONDecoder().decode([RallyMarkRecord].self, from: Data(contentsOf: labels("A"))).count, 1)
    }

    // MARK: - The video steps

    func testPhoneVideosAreNeverPulledIntoAProjectOpenedMeanwhile() async throws {
        try project("A"); try project("B")
        open("A")
        row("A", status: .uploaded, clipPath: "phone/one.mp4")
        server.hold("videos")   // the first listing: the phone's videos
        let round = await startRound(videos: true)
        open("B")
        let before = try snapshot("B")
        server.release()
        let outcome25 = await round.value
        XCTAssertFalse(outcome25)
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        XCTAssertEqual(server.downloads, [], "not downloaded into B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("B/incoming").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("A/incoming").path))
        XCTAssertEqual(server.savedVideos, [])
        XCTAssertEqual(try snapshot("B"), before)
    }

    func testAPhoneVideoAlreadyPulledInIsMarkedImportedForItsOwnProject() async throws {
        let root = try project("A")
        let phone = row("A", status: .uploaded, clipPath: "phone/one.mp4")
        // The sync that pulled it in stopped before marking it: A's card has the pulled-in file as a video's origin.
        let file = root.appendingPathComponent("incoming/phone-\(phone.id.uuidString.lowercased()).mp4")
        var card = SourceRegistryTests.clip("card_phone", number: 9, videos: [])
        var video = SourceRegistryTests.video("phone_01", fingerprint: nil)
        video.origin = file.path
        card.videos = [video]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var project = try decoder.decode(Project.self, from: Data(contentsOf: root.appendingPathComponent("project.json")))
        project.clips.append(card)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: root.appendingPathComponent("project.json"))
        try DatasetStore(root: root).save(VideoSession(name: "phone_01", sourcePath: file.path, split: "train", addedAt: now, frames: []))
        open("A")
        let outcome26 = await sync.sync(videos: true)
        XCTAssertTrue(outcome26, sync.status)
        XCTAssertEqual(server.downloads, [])
        XCTAssertEqual(server.savedVideos.map { ($0.project ?? "", $0.sessionName ?? "", $0.status) }.map { "\($0.0)/\($0.1)/\($0.2)" }, ["A/phone_01/imported"])
    }

    func testACutFinishedAfterTheSwitchIsNotRecordedOnTheProjectOpenNow() throws {
        // The phone video's cut (scripts/fetch_clip.py) runs for minutes; its completion is `finishFetch`.
        try project("A"); try project("B")
        let a = open("A")
        let result = ProjectsModel.FetchResult(file: footage("A", "cut").path, duration: 12, start: 0, title: "t", uploader: "u", url: "")
        open("B")
        let before = try snapshot("B")
        var heard: [Bool] = []
        projects.finishFetch(.success(result), videoId: "card_0_02", clipId: "card_0", opening: a, kind: .file, origin: "x", license: "Own footage",
                             frames: nil, fingerprint: nil, provenance: nil) { heard.append($0) }
        XCTAssertEqual(heard, [false])
        XCTAssertTrue(projects.status.contains("the project changed while A was being cut: not recorded"), projects.status)
        XCTAssertEqual(try snapshot("B"), before, "B's project.json has no new video")
        XCTAssertEqual(sampler.queue, [], "nothing queued for sampling")
        // Under the opening it started for, the cut is recorded and queued for that dataset.
        let b = projects.opening!
        projects.finishFetch(.success(result), videoId: "card_0_02", clipId: "card_0", opening: b, kind: .file, origin: "x", license: "Own footage",
                             frames: nil, fingerprint: nil, provenance: nil) { heard.append($0) }
        XCTAssertEqual(heard, [false, true])
        XCTAssertEqual(projects.project?.clips.first { $0.id == "card_0" }?.videos.count, 2)
        XCTAssertEqual(sampler.queue.map(\.root), [b.root], "the sampling job carries the dataset it was queued for")
    }

    func testProjectVideosArePublishedWithTheirOwnCardsAndNeverAnotherProjects() async throws {
        // Names the phone knows a surface for ("bch…"); the row has its copy, so nothing is encoded or uploaded.
        try project("A", videos: ["bch_01"]); try project("B", videos: ["bch_01"])
        open("A")
        row("A", "bch_01", clipPath: "rallylab/A/bch_01-v3.mp4")
        let outcome27 = await sync.sync(videos: true)
        XCTAssertTrue(outcome27, sync.status)
        XCTAssertEqual(server.savedVideos.map(\.lighting), ["Sunny"], "the row took A's card's lighting")
        XCTAssertEqual(server.savedVideos.map(\.project), ["A"])
        XCTAssertEqual(server.uploads, [])
        server.savedVideos = []
        server.videos[0].lighting = ""   // out of date again
        server.hold("videos", at: 2)     // the second listing: A's rows for publishing
        let round = await startRound(videos: true)
        open("B")
        server.release()
        let outcome28 = await round.value
        XCTAssertFalse(outcome28)
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        XCTAssertEqual(server.savedVideos, [], "no row was filled from B's cards")
    }

    func testATypeIsPublishedForARecordingWhoseFootageIsNotOnThisMac() async throws {
        // bch_01's original is here; bch_02's and bch_03's were moved off the Mac. All three have the type on file.
        let root = try project("A", videos: ["bch_01", "bch_02", "bch_03", "bch_04"])
        open("A")
        // bch_04 is away too, with a type published before and no record of it now: the copy is cleared.
        var stale = row("A", "bch_04", clipPath: "rallylab/A/bch_04-v3.mp4")
        stale.recordingType = "edited"; stale.recordingTypeAt = now
        server.videos[server.videos.count - 1] = stale
        row("A", "bch_01", clipPath: "rallylab/A/bch_01-v3.mp4")
        row("A", "bch_02", clipPath: "rallylab/A/bch_02-v3.mp4")
        let at = "2026-11-07T17:08:42Z"
        for video in ["bch_01", "bch_02", "bch_03"] {
            let card = ProjectsModel.readFileFingerprint(atPath: footage("A", video).path)
            try FootageProperties.Store(root: root).save(FootageProperties.File(video: video, sourceFingerprint: card, recordingType: .continuous,
                                                                                recordingTypeBy: "BW", recordingTypeAt: at, spans: [], updatedAt: at))
        }
        try FileManager.default.removeItem(at: footage("A", "bch_02"))
        try FileManager.default.removeItem(at: footage("A", "bch_03"))
        try FileManager.default.removeItem(at: footage("A", "bch_04"))
        let outcome = await sync.sync(videos: true)
        XCTAssertTrue(outcome, sync.status)
        let saved = Dictionary(server.savedVideos.map { ($0.sessionName ?? "", $0) }, uniquingKeysWith: { $1 })
        XCTAssertEqual(saved["bch_01"]?.recordingType, "continuous")
        XCTAssertEqual(saved["bch_02"]?.recordingType, "continuous", "the type went up without the footage")
        XCTAssertEqual(saved["bch_02"]?.recordingTypeAt, RecordingTypeClaims.parse(at))
        XCTAssertEqual(saved["bch_02"]?.clipPath, "rallylab/A/bch_02-v3.mp4", "the rest of the row is as it was")
        XCTAssertNil(saved["bch_03"], "no row is made for a recording whose footage is not here")
        XCTAssertEqual(server.cleared, [stale.id], "a type with no record behind it is taken off, footage here or not")
        XCTAssertEqual(server.uploads, [])
    }

    func testBallPathsComeFromTheCapturedProjectNotTheOneOpenNow() async throws {
        try project("A"); try project("B")
        open("A")
        row("A", clipPath: "rallylab/A/video_01-v3.mp4")
        // B has a ball path for its same-named recording; A has none.
        try FileManager.default.createDirectory(at: base.appendingPathComponent("B/ballpaths"), withIntermediateDirectories: true)
        try Data("B's path".utf8).write(to: BallPathBuilder.url(for: "video_01", in: base.appendingPathComponent("B")))
        server.hold("videos", at: 3)     // the third listing: the rows whose ball paths go up
        let round = await startRound(videos: true)
        open("B")
        let before = try snapshot("B")
        server.release()
        let outcome29 = await round.value
        XCTAssertFalse(outcome29)
        XCTAssertEqual(server.uploads, [], "B's path was not sent as A's")
        XCTAssertEqual(try snapshot("B"), before, "no sent list written in B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("A/ballpaths/sent.json").path))
    }

    func testThePlanPublishedIsTheCapturedProjectsAndNotAfterItsOpeningEnded() async throws {
        try project("A", tracks: true); try project("B")
        open("A")
        row("A")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([TrainedRound(round: 1, date: now, package: "p", frames: [:], runs: [])]).write(to: base.appendingPathComponent("B/training_plan.json"))
        server.hold("tracks")   // the last reply before the plan goes up
        let round = await startRound()
        open("B")
        server.release()
        let outcome30 = await round.value
        XCTAssertFalse(outcome30)
        XCTAssertEqual(server.states, [], "no plan published under A after its opening ended — not B's, not an empty one")
        open("A")
        let outcome31 = await sync.sync(videos: false)
        XCTAssertTrue(outcome31)
        XCTAssertEqual(server.states.map { ($0.project, $0.plan.count) }.map { "\($0.0):\($0.1)" }, ["A:0"], "A's own (empty) plan")
    }
    // MARK: - Ball paths: jobs belong to the dataset they were queued from

    private func reserve(_ names: [String], in project: String) throws {
        let dir = base.appendingPathComponent("\(project)/pipeline_tuning", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(PipelineTuner.ValidationSet(tune: [], holdout: [], finalTest: names)).write(to: dir.appendingPathComponent("validation.json"))
    }

    private func ballPathRows(_ project: String) -> [String] {
        ExposureLog.read(in: base.appendingPathComponent(project, isDirectory: true)).filter { $0.kind == .ballPath }.map(\.video).sorted()
    }

    /// Waits (up to 5 s) for the builder to get there.
    private func until(_ what: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out waiting for: \(what)")
    }

    func testBallPathJobsQueuedUnderAnEndedOpeningDoNotRunWhenTheSameProjectIsOpenedAgain() async throws {
        // A → B → A: the reopened A is another opening (same folder). Jobs queued under the first opening and not
        // started are dropped when it ends; they run only if queued afresh under the new one.
        try project("A", videos: ["video_01", "video_02", "video_03"]); try project("B")
        let a1 = open("A")
        let latch = Latch()
        var runs: [String] = []
        let builder = BallPathBuilder(sampler: sampler, projects: projects) { playback, _, _ in
            runs.append(playback.path)
            if runs.count == 1 { try await latch.wait() }
            return [BallPath.Sample(time: 1, center: CGPoint(x: 0.5, y: 0.5), size: 0.02)]
        }
        let aSessions = sampler.sessions.sorted { $0.name < $1.name }
        builder.ensure(aSessions)
        try await until("the first job began") { runs.count == 1 }
        XCTAssertTrue(builder.isBuilding(aSessions[0]))
        // Switch to B and back to A while the first job is suspended.
        open("B")
        let a2 = open("A")
        XCTAssertNotEqual(a2, a1)
        XCTAssertFalse(builder.isBuilding(aSessions[0]), "the running job is the first opening's, not this one's")
        let before = try snapshot("A")
        latch.open()
        try await until("the first job finished") { builder.finished == 1 && builder.building == nil }
        try await Task.sleep(for: .milliseconds(150))   // anything that would start, has
        // The running job finished into A (its own dataset); the two unstarted ones did not run under the new opening.
        XCTAssertEqual(runs, [footage("A").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: BallPathBuilder.url(for: "video_01", in: a2.root).path))
        XCTAssertEqual(ballPathRows("A"), ["video_01"], "no exposure row for a job that was not started")
        let changed = Set(try snapshot("A").keys).symmetricDifference(Set(before.keys))
        XCTAssertEqual(changed.map { $0.hasSuffix("/ballpaths/video_01.ballpath.json") }, [true], "the first job's file is the only thing new in A: \(changed)")
        XCTAssertEqual(ballPathRows("B"), [])
        // Queued afresh under the new opening, they run — under it.
        builder.ensure(sampler.sessions.sorted { $0.name < $1.name })
        try await until("the requeued jobs ran") { builder.finished == 3 && builder.building == nil }
        XCTAssertEqual(runs, [footage("A").path, footage("A", "video_02").path, footage("A", "video_03").path])
        XCTAssertEqual(ballPathRows("A"), ["video_01", "video_02", "video_03"])
        XCTAssertEqual(projects.opening, a2)
    }

    func testBallPathJobsBelongToTheDatasetTheyWereQueuedFromNotTheOneOpenWhenTheyRun() async throws {
        // A and B each hold video_01 and video_02. B reserves video_02 as final test; A reserves video_03 (B has none).
        try project("A", videos: ["video_01", "video_02", "video_03"]); try project("B", videos: ["video_01", "video_02"])
        try reserve(["video_03"], in: "A"); try reserve(["video_02"], in: "B")
        open("A")
        let rootA = sampler.datasetRoot, rootB = base.appendingPathComponent("B", isDirectory: true).standardizedFileURL
        let latch = Latch()   // the first run waits here until the test lets it finish
        var runs: [String] = []
        let builder = BallPathBuilder(sampler: sampler, projects: projects) { playback, _, _ in
            runs.append(playback.path)
            if runs.count == 1 { try await latch.wait() }
            return [BallPath.Sample(time: 1, center: CGPoint(x: 0.5, y: 0.5), size: 0.02)]
        }
        let aSessions = sampler.sessions.sorted { $0.name < $1.name }
        XCTAssertEqual(aSessions.map(\.name), ["video_01", "video_02", "video_03"])
        // Three jobs queued from A; the first begins and is suspended.
        builder.ensure(aSessions)
        try await until("the first job began") { runs.count == 1 }
        XCTAssertTrue(builder.isBuilding(aSessions[0]))
        XCTAssertEqual(ballPathRows("A"), ["video_01"], "its run is on A's ledger before it starts")
        // The person switches to B before the second job begins, then the first run ends.
        open("B")
        let bBefore = try snapshot("B")
        XCTAssertFalse(builder.isBuilding(aSessions[0]), "B's same-named video_01 is not the one being built")
        latch.open()
        try await until("the queue drained") { builder.finished == 1 && builder.building == nil }
        try await Task.sleep(for: .milliseconds(100))   // anything that would start, has
        // Only A's first video ran; the second and third jobs, queued from A, were dropped — not run under B's
        // root, not judged by B's reservations, not put on B's ledger.
        XCTAssertEqual(runs, [footage("A").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: BallPathBuilder.url(for: "video_01", in: rootA).path), "A's path, in A's folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: BallPathBuilder.url(for: "video_01", in: rootB).path))
        XCTAssertEqual(try snapshot("B"), bBefore, "nothing of A's jobs was written into B")
        XCTAssertEqual(ballPathRows("A"), ["video_01"])
        XCTAssertEqual(ballPathRows("B"), [])
        XCTAssertNil(builder.refusal(for: aSessions[1]), "B's reservation of video_02 was never applied to A's job")
        XCTAssertNil(builder.refusal(for: aSessions[2]))
        // Back on A: the dropped jobs are queued afresh and judged by A's rules — video_02 (reserved only in B)
        // runs, video_03 (reserved in A) is refused with A's reason.
        open("A")
        builder.ensure(sampler.sessions.sorted { $0.name < $1.name })
        try await until("A's second video ran") { builder.finished == 2 && builder.building == nil }
        XCTAssertEqual(runs, [footage("A").path, footage("A", "video_02").path])
        XCTAssertEqual(ballPathRows("A"), ["video_01", "video_02"])
        XCTAssertEqual(ballPathRows("B"), [])
        XCTAssertNil(builder.refusal(for: aSessions[1]))
        XCTAssertEqual(builder.refusal(for: aSessions[2])?.contains("reserved as final_test"), true)
        // On B, its same-named video_02 is B's own job: refused by B's rule; its video_01 runs as B's, on B's ledger.
        open("B")
        let bSessions = sampler.sessions.sorted { $0.name < $1.name }
        builder.ensure(bSessions)
        try await until("B's first video ran") { builder.finished == 3 && builder.building == nil }
        XCTAssertEqual(runs.last, footage("B").path)
        XCTAssertEqual(builder.refusal(for: bSessions[1])?.contains("reserved as final_test"), true)
        XCTAssertEqual(ballPathRows("B"), ["video_01"])
        XCTAssertEqual(ballPathRows("A"), ["video_01", "video_02"], "A's ledger has nothing of B's runs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: BallPathBuilder.url(for: "video_01", in: rootB).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BallPathBuilder.url(for: "video_02", in: rootB).path))
        // And A's video_02, by name the same as B's refused one, is still A's own, not refused.
        open("A")
        XCTAssertNil(builder.refusal(for: aSessions[1]))
    }
}

// MARK: - The fake server

/// The labeling server as the sync sees it, with what it stores kept in memory, every call recorded, a failure to
/// inject once per call, and one hold: the reply of a named call (its n-th occurrence) waits until the test releases
/// it — after the call's effect, for the saves, as a reply delayed on the way back. A cancellable hold throws
/// `CancellationError` when the waiting round is cancelled, as URLSession does.
@MainActor
final class FakeLabeling: LabelingService {
    /// The signed-in account (the lead's, as the Mac's is).
    var me: UUID? = UUID()
    var videos: [LabelVideo] = []
    var times: [UUID: LabelRallyTimes] = [:]
    var stamps: [LabelingClient.TrackStamp] = []
    var tracks: [UUID: LabelTrack] = [:]
    var events: [UUID: LabelRallyEvents] = [:]
    var states: [LabelProjectState] = []
    var calls: [String] = []
    var savedTimes: [LabelRallyTimes] = []
    var savedTracks: [[LabelTrack]] = []
    var savedVideos: [LabelVideo] = []
    var reviewed: [(track: UUID, edits: [LabelingClient.FrameEdit])] = []
    var verdicts: [LabelingClient.RallyVerdict] = []
    var uploads: [String] = []
    var downloads: [String] = []
    var failures: [String: Error] = [:]

    private struct Hold { let call: String; let at: Int; let cancellable: Bool }
    private var pendingHold: Hold?
    private var counts: [String: Int] = [:]
    private var parked: CheckedContinuation<Void, Never>?
    private var latch: Latch?
    private var isParked = false
    private var arrival: CheckedContinuation<Void, Never>?

    /// Holds the reply of the `at`-th call of `call` made from now on (earlier rounds' calls don't count).
    func hold(_ call: String, at: Int = 1, cancellable: Bool = false) {
        counts = [:]
        pendingHold = Hold(call: call, at: at, cancellable: cancellable)
    }

    /// Returns once the round is parked at the hold — true — or after `seconds` without it getting there — false,
    /// so a hold the round never reaches fails the test instead of hanging it.
    func arrived(within seconds: Double = 10) async -> Bool {
        if isParked { return true }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard let waiting = arrival else { return }
            arrival = nil
            waiting.resume()
        }
        await withCheckedContinuation { arrival = $0 }
        timeout.cancel()
        return isParked
    }

    func release() {
        parked?.resume()
        parked = nil
        latch?.open()
        latch = nil
    }

    private func begin(_ call: String) throws {
        calls.append(call)
        counts[call, default: 0] += 1
        if let error = failures.removeValue(forKey: call) { throw error }
    }

    private func park(_ call: String) async throws {
        guard let hold = pendingHold, hold.call == call, hold.at == counts[call] else { return }
        pendingHold = nil
        isParked = true
        arrival?.resume()
        arrival = nil
        defer { isParked = false }
        if hold.cancellable {
            let latch = Latch()
            self.latch = latch
            try await latch.wait()
        } else {
            await withCheckedContinuation { parked = $0 }
        }
    }

    var hasSession: Bool { true }
    var userId: UUID? { me }
    func signIn(email: String, password: String) async throws {}
    func signOut() async {}
    func authorize(forTransfer: Bool) async throws {}
    func isLabeler() async throws -> Bool { true }

    func videos() async throws -> [LabelVideo] {
        try begin("videos"); try await park("videos")
        return videos
    }

    @discardableResult
    func save(_ video: LabelVideo) async throws -> LabelVideo {
        try begin("save(video)")
        var v = video; v.updatedAt = Date()
        if let i = videos.firstIndex(where: { $0.id == v.id }) { videos[i] = v } else { videos.append(v) }
        savedVideos.append(v)
        try await park("save(video)")
        return v
    }

    func rallyTimes(since: Date?) async throws -> [LabelRallyTimes] {
        try begin("rallyTimes"); try await park("rallyTimes")
        return Array(times.values)
    }

    @discardableResult
    func save(_ times: LabelRallyTimes) async throws -> LabelRallyTimes {
        try begin("save(times)")
        var t = times; t.updatedAt = Date()
        self.times[t.videoId] = t
        savedTimes.append(t)
        try await park("save(times)")
        return t
    }

    func trackStamps() async throws -> [LabelingClient.TrackStamp] {
        try begin("trackStamps"); try await park("trackStamps")
        return stamps
    }

    func tracks(ids: [UUID]) async throws -> [LabelTrack] {
        try begin("tracks"); try await park("tracks")
        return ids.compactMap { tracks[$0] }
    }

    /// One request per batch here (the real client makes one per group of rows with the same fields): `allowed`
    /// is asked right before it, a request with nothing left is not made, and a failure — injected, or a reply
    /// lost to a cancelled hold after the server stored the rows — acknowledges nothing.
    func save(_ tracks: [LabelTrack], allowed: @Sendable ([LabelTrack]) async -> [LabelTrack]) async -> LabelingClient.TrackSave {
        let batch = await allowed(tracks)
        guard !batch.isEmpty else { return LabelingClient.TrackSave() }
        do {
            try await store(batch)
            return LabelingClient.TrackSave(sent: Set(batch.map(\.id)))
        } catch {
            return LabelingClient.TrackSave(failure: error)
        }
    }

    private func store(_ batch: [LabelTrack]) async throws {
        try begin("save(tracks)")
        for t in batch {
            tracks[t.id] = t
            stamps.removeAll { $0.id == t.id }
            stamps.append(LabelingClient.TrackStamp(id: t.id, videoId: t.videoId, deleted: t.deleted, updatedAt: t.updatedAt))
        }
        savedTracks.append(batch)
        try await park("save(tracks)")
    }

    func rallyEvents(since: Date?) async throws -> [LabelRallyEvents] {
        try begin("rallyEvents"); try await park("rallyEvents")
        return Array(events.values)
    }

    func saveRallyEvents(videoId: UUID, expected: Int, record: EventReview.File) async throws -> LabelRallyEvents {
        try begin("saveRallyEvents")
        guard (events[videoId]?.revision ?? 0) == expected else { throw RallyEventsConflict(serverRevision: events[videoId]?.revision ?? 0, message: "revision \(expected) expected") }
        var saved = record; saved.revision = expected + 1
        let video = videos.first { $0.id == videoId }
        let row = LabelRallyEvents(videoId: videoId, project: video?.project ?? "", sessionName: video?.sessionName ?? "", annotationVersion: EventReview.annotationVersion,
                                   record: saved, revision: expected + 1, updatedBy: nil, updatedAt: Date())
        events[videoId] = row
        try await park("saveRallyEvents")
        return row
    }

    func publishWithheld(project: String, names: [String]) async throws -> Int {
        try begin("publishWithheld"); try await park("publishWithheld")
        return names.count
    }

    /// Claims by id, and what the Mac settled, in order (the server's settle rules: the same settlement again is a
    /// no-op; any other change to a settled claim is a conflict).
    var claims: [UUID: RecordingTypeClaim] = [:]
    var settled: [(id: UUID, status: RecordingTypeClaim.Status, reason: String?, confirmedAt: Date?)] = []

    func recordingTypeClaims(since: Date?) async throws -> [RecordingTypeClaim] {
        try begin("recordingTypeClaims"); try await park("recordingTypeClaims")
        return claims.values.sorted { ($0.videoId.uuidString, $0.revision) < ($1.videoId.uuidString, $1.revision) }
    }

    /// The row as it was when asked — a reply delayed on the way back (the hold) carries the state of that moment.
    func recordingTypeClaim(id: UUID) async throws -> RecordingTypeClaim? {
        try begin("recordingTypeClaim")
        let row = claims[id]
        try await park("recordingTypeClaim")
        return row
    }

    /// The phone's replacement choice for a recording, as the server would record it: the waiting claim superseded,
    /// the new one the next revision.
    @discardableResult
    func phoneReplaces(video: UUID, with kind: String, at: Date = Date()) -> RecordingTypeClaim {
        for (id, var c) in claims where c.videoId == video && c.status == .submitted {
            c.status = .superseded; c.reason = "replaced by a newer choice"; c.settledAt = at; c.updatedAt = at
            claims[id] = c
        }
        let old = claims.values.filter { $0.videoId == video }.first!   // the same labeler changes their mind
        let revision = (claims.values.filter { $0.videoId == video }.map(\.revision).max() ?? 0) + 1
        let new = RecordingTypeClaim(id: UUID(), videoId: video, project: old.project, sessionName: old.sessionName, sourceFingerprint: old.sourceFingerprint,
                                     recordingType: kind, revision: revision, status: .submitted, reason: nil, submittedBy: old.submittedBy, submittedAt: at, settledBy: nil, settledAt: nil, updatedAt: at)
        claims[new.id] = new
        return new
    }

    func settleRecordingTypeClaim(_ id: UUID, status: RecordingTypeClaim.Status, reason: String?, confirmedAt: Date?) async throws -> RecordingTypeClaim {
        try begin("settleRecordingTypeClaim")
        guard var claim = claims[id] else { throw LabelingClient.Failure.server(400, "recording_type_claim_settle: no such claim") }
        if claim.status != status {
            guard claim.status == .submitted else { throw LabelingClient.Failure.server(400, "conflict: claim \(id) is already \(claim.status.rawValue)") }
            claim.status = status; claim.reason = reason; claim.settledAt = Date(); claim.updatedAt = claim.settledAt
            claims[id] = claim
            if status == .accepted, let i = videos.firstIndex(where: { $0.id == claim.videoId }) {
                videos[i].recordingType = claim.recordingType
                videos[i].recordingTypeAt = confirmedAt ?? Date()
            }
        }
        settled.append((id, status, reason, confirmedAt))
        try await park("settleRecordingTypeClaim")
        return claim
    }

    var backlogged: [(UUID, String?, Date)] = []

    func setBacklog(_ videoId: UUID, reason: String?, at: Date) async throws {
        try begin("setBacklog")
        if let i = videos.firstIndex(where: { $0.id == videoId }) {
            videos[i].backlogReason = reason; videos[i].backlogAt = reason == nil ? nil : at; videos[i].updatedAt = at
        }
        backlogged.append((videoId, reason, at))
        try await park("setBacklog")
    }

    var cleared: [UUID] = []

    func clearPublishedRecordingType(_ videoId: UUID) async throws {
        try begin("clearPublishedRecordingType")
        if let i = videos.firstIndex(where: { $0.id == videoId }) { videos[i].recordingType = nil; videos[i].recordingTypeAt = nil; videos[i].updatedAt = Date() }
        cleared.append(videoId)
        try await park("clearPublishedRecordingType")
    }

    func save(_ state: LabelProjectState) async throws {
        try begin("save(state)")
        states.append(state)
        try await park("save(state)")
    }

    func reviewRally(_ verdict: LabelingClient.RallyVerdict) async throws {
        try begin("reviewRally")
        verdicts.append(verdict)
        try await park("reviewRally")
    }

    func reviewFrames(_ track: UUID, _ edits: [LabelingClient.FrameEdit]) async throws {
        try begin("reviewFrames")
        reviewed.append((track, edits))
        try await park("reviewFrames")
    }

    func uploadFile(_ file: URL, to path: String) async throws {
        try begin("upload")
        uploads.append(path)
        try await park("upload")
    }

    func downloadFile(_ path: String, to destination: URL) async throws {
        try begin("download")
        downloads.append(path)
        try Data("phone video".utf8).write(to: destination)
        try await park("download")
    }

    var removed: [String] = []

    func remove(_ path: String) async throws {
        try begin("remove")
        removed.append(path)
        try await park("remove")
    }
}

/// A wait that ends when opened, or throws `CancellationError` when the waiting task is cancelled.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var opened = false

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); defer { lock.unlock() }
                if opened { c.resume(); return }
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                continuation = c
            }
        } onCancel: {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(throwing: CancellationError())
        }
    }

    func open() {
        lock.lock()
        let c = continuation
        continuation = nil
        opened = true
        lock.unlock()
        c?.resume()
    }
}
