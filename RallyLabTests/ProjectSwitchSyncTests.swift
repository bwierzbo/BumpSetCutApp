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
}

// MARK: - The fake server

/// The labeling server as the sync sees it, with what it stores kept in memory, every call recorded, a failure to
/// inject once per call, and one hold: the reply of a named call (its n-th occurrence) waits until the test releases
/// it — after the call's effect, for the saves, as a reply delayed on the way back. A cancellable hold throws
/// `CancellationError` when the waiting round is cancelled, as URLSession does.
@MainActor
final class FakeLabeling: LabelingService {
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
    func signIn(email: String, password: String) async throws {}
    func signOut() async {}
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

    func save(_ batch: [LabelTrack]) async throws {
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

    func remove(_ path: String) async throws { try begin("remove"); try await park("remove") }
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
