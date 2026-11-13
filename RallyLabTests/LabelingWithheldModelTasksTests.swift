//
//  LabelingWithheldModelTasksTests.swift
//  RallyLabTests
//
//  A recording the project withholds from every model (final test,
//  candidates, lineage holdout, legacy holdout and every alias) gets no
//  labeling task that runs a model or carries a model's output — from any
//  account, the lead's included, which the server's protection (migration
//  049) exempts (owner decisions of 2026-11-12, D-036 §5C and §5E):
//
//  - the shared queue (the Mac's and the phone's) offers no track job for
//    it, and nothing at all to an ordinary labeler; a state that is not
//    known is never read as "not withheld";
//  - the Mac's sync publishes no new ball-path sidecar and no new rally a
//    model found the ball in for it, and none at all when the closure can't
//    be read;
//  - what was there stays and keeps syncing: the rows the server already
//    has, the rallies a person tracked by hand, the lead's rally marks.
//
//  A project on disk (a lineage holdout, a train copy of it by a confirmed
//  sourceId, a legacy holdout, an ordinary train recording) against the
//  fake server of ProjectSwitchSyncTests.
//

import XCTest
@testable import RallyLab

@MainActor
final class LabelingWithheldModelTasksTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var projects: ProjectsModel!
    private var server: FakeLabeling!
    private var sync: LabelingSync!
    private let now = ISO8601DateFormatter().date(from: "2026-11-12T20:00:00Z")!

    private let lineage = "bch_lineage_01", copy = "bch_copy_01", holdout = "bch_holdout_01", train = "bch_train_01"
    private var withheld: [String] { [lineage, copy, holdout] }
    private var all: [String] { withheld + [train] }
    /// Per recording, the rallies its session starts with: pre-tracked, tracked with the detector's picks, by hand.
    private var machine: [String: UUID] = [:], assisted: [String: UUID] = [:], byHand: [String: UUID] = [:]
    private var rows: [String: LabelVideo] = [:]

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("lwm-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("P", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
        suite = "RallyLabTests.LabelingWithheldModelTasks.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        let sampler = SamplerModel(defaults: defaults, root: base.appendingPathComponent("empty"))
        projects = ProjectsModel(sampler: sampler, defaults: defaults)
        server = FakeLabeling()
        sync = LabelingSync(projects: projects, client: server, pendingDirectory: base.appendingPathComponent("pending"))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixtures

    private func rally(_ kind: String) -> TrackedRally {
        switch kind {
        case "machine": return SourceRegistryTests.rally(done: false, machine: true)
        case "assisted":
            // A person's rally whose boxes are still the detector's picks (not pre-tracked).
            var r = SourceRegistryTests.rally(done: true)
            for i in r.points.indices { r.points[i].origin = .auto }
            return r
        default: return SourceRegistryTests.rally(done: true)   // every frame placed by a person
        }
    }

    /// The project on disk and open, a server row with a clip per recording, and a ball path here per recording.
    /// `validation`: the reservations file's text, nil for none.
    private func makeProject(validation: String? = #"{"tune":[],"holdout":["bch_holdout_01"],"finalTest":[],"lineageHoldout":["bch_lineage_01"]}"#) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ballpaths"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        let store = DatasetStore(root: root)
        try store.prepare()
        var clips: [PlannedClip] = []
        for (n, name) in all.enumerated() {
            let file = root.appendingPathComponent("footage/\(name).mp4")
            try Data("\(name) footage".utf8).write(to: file)
            // The copy is the lineage holdout's recording under another name: a confirmed sourceId (D-036).
            let source = SourceRegistryTests.video(name, fingerprint: ProjectsModel.readFileFingerprint(atPath: file.path),
                                                   sourceId: [lineage, copy].contains(name) ? "camera-roll-1" : nil)
            clips.append(SourceRegistryTests.clip("card_\(n)", number: n + 1, videos: [source]))
            var session = VideoSession(name: name, sourcePath: file.path, split: "train", addedAt: now, frames: [])
            let tracks = [rally("machine"), rally("assisted"), rally("hand")]
            (machine[name], assisted[name], byHand[name]) = (tracks[0].id, tracks[1].id, tracks[2].id)
            session.tracks = tracks
            try store.save(session)
            try Data("path of \(name)".utf8).write(to: BallPathBuilder.url(for: name, in: root))
            let row = LabelVideo(id: UUID(), project: "P", sessionName: name, title: "", surface: .beach, camera: .endlineGround, lighting: "",
                                 split: "train", clipPath: "rallylab/P/\(name)-v\(LabelingSync.copyVersion).mp4", duration: 60, ralliesFound: [],
                                 status: .rallylab, updatedAt: now)
            server.videos.append(row)
            rows[name] = row
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: "P", createdAt: now, framesPerRally: 2, clips: clips)).write(to: root.appendingPathComponent("project.json"))
        if let validation { try validation.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8) }
        projects.open(root)
        XCTAssertEqual(projects.opening?.name, "P")
    }

    private func ballPath(_ name: String) -> String { BallPathFile.remotePath(forClip: rows[name]!.clipPath!) }
    private var sentTracks: Set<UUID> { Set(server.savedTracks.flatMap { $0 }.map(\.id)) }
    private func ids(_ names: [String], _ kinds: [String: UUID]...) -> Set<UUID> { Set(names.flatMap { n in kinds.compactMap { $0[n] } }) }
    private func labels(_ name: String) -> URL { RallyMarkModel.labelsURL(for: root.appendingPathComponent("footage/\(name).mp4")) }

    // MARK: - The closure the fixture gives

    func testTheClosureHoldsTheHoldoutsAndTheCopyByItsConfirmedSource() async throws {
        try makeProject()
        let closure = await LabelingSync.withheldClosure(root: root)
        XCTAssertEqual(closure, Set(withheld), "the lineage holdout, its copy under another name, and the legacy holdout")
    }

    // MARK: - The Mac's sync

    func testNoBallPathAndNoRallyAModelFoundTheBallInGoesUpForAWithheldRecording() async throws {
        try makeProject()
        let synced = await sync.sync(videos: true)
        XCTAssertTrue(synced, sync.status)
        XCTAssertEqual(server.uploads.filter { $0.hasSuffix(".ballpath.json") }, [ballPath(train)], "only the ordinary recording's ball path goes up")
        XCTAssertEqual(sentTracks, ids([train], machine, assisted, byHand).union(ids(withheld, byHand)),
                       "the ordinary recording's rallies all go up; a withheld one's only where a person placed every frame")
        XCTAssertTrue(sync.status.contains("6 kept on this Mac, not published"), sync.status)
        XCTAssertTrue(sync.status.contains("their recording is withheld"), sync.status)
        XCTAssertTrue(sync.status.contains("ball paths of 3 withheld recordings kept on this Mac"), sync.status)
        // Nothing is lost here: every session keeps its three rallies, and the list of sent paths names one.
        for name in all { XCTAssertEqual(projects.session(named: name)?.tracks?.count, 3, name) }
        let sent = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("ballpaths/sent.json")))
        XCTAssertEqual(sent, [ballPath(train)])
        for name in withheld {
            XCTAssertTrue(FileManager.default.fileExists(atPath: BallPathBuilder.url(for: name, in: root).path), "\(name)'s path stays on this Mac")
            XCTAssertEqual(Set(projects.session(named: name)?.syncedTrackIds ?? []), [byHand[name]!], "a held rally is not on the synced list: it was never sent")
        }
        // The next rounds hold them again and send nothing twice.
        let tracksBefore = server.savedTracks.count, uploadsBefore = server.uploads
        let again = await sync.sync(videos: true)
        XCTAssertTrue(again, sync.status)
        XCTAssertEqual(server.savedTracks.count, tracksBefore, "nothing new to send")
        XCTAssertEqual(server.uploads, uploadsBefore)
        XCTAssertTrue(sync.status.contains("6 kept on this Mac, not published"), sync.status)
    }

    func testARecordingNoLongerWithheldSendsWhatWasHeld() async throws {
        try makeProject()
        let first = await sync.sync(videos: true)
        XCTAssertTrue(first, sync.status)
        // The legacy holdout is released: its held rallies and its ball path go up; the lineage pair stays held.
        try #"{"tune":[],"holdout":[],"finalTest":[],"lineageHoldout":["bch_lineage_01"]}"#.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
        let second = await sync.sync(videos: true)
        XCTAssertTrue(second, sync.status)
        XCTAssertTrue(sentTracks.isSuperset(of: ids([holdout], machine, assisted)), "held, not dropped")
        XCTAssertTrue(sentTracks.isDisjoint(with: ids([lineage, copy], machine, assisted)))
        XCTAssertEqual(Set(server.uploads.filter { $0.hasSuffix(".ballpath.json") }), [ballPath(train), ballPath(holdout)])
    }

    func testRowsTheServerAlreadyHasKeepSyncingForAWithheldRecording() async throws {
        try makeProject()
        // The copy's pre-tracked rally went up before the recording was withheld; the lead has since checked it here.
        let session = try XCTUnwrap(projects.session(named: copy))
        var tracks = try XCTUnwrap(session.tracks)
        let i = try XCTUnwrap(tracks.firstIndex { $0.id == machine[copy] })
        var before = LabelTrack(tracks[i], videoId: rows[copy]!.id)
        before.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)   // long before the check made here
        server.tracks[before.id] = before
        server.stamps.append(LabelingClient.TrackStamp(id: before.id, videoId: before.videoId, deleted: false, updatedAt: before.updatedAt))
        tracks[i].isRally = true
        tracks[i].updatedAt = Date()
        projects.sampler.setTracks(tracks, session: copy)
        // And the phone holds a rally of the lineage holdout from before, which this Mac does not have.
        let fromPhone = LabelTrack(rally("machine"), videoId: rows[lineage]!.id)
        server.tracks[fromPhone.id] = fromPhone
        server.stamps.append(LabelingClient.TrackStamp(id: fromPhone.id, videoId: fromPhone.videoId, deleted: false, updatedAt: now))

        let synced = await sync.sync(videos: false)
        XCTAssertTrue(synced, sync.status)
        XCTAssertEqual(server.tracks[before.id]?.isRally, true, "the check made by hand on a row the server has goes up")
        XCTAssertTrue(sentTracks.contains(before.id))
        XCTAssertTrue(projects.session(named: lineage)?.tracks?.contains { $0.id == fromPhone.id } ?? false, "a record already on the server still comes down")
        XCTAssertFalse(server.tracks.values.contains { $0.deleted }, "nothing is deleted on the server")
        XCTAssertTrue(sentTracks.isDisjoint(with: ids(withheld, assisted)), "the rallies the server never had stay held")
        XCTAssertFalse(sentTracks.contains(machine[lineage]!))
    }

    func testTheLeadsRallyMarksOnAWithheldRecordingStillSyncBothWays() async throws {
        try makeProject()
        // Marked here on the copy; marked on the phone on the legacy holdout.
        try JSONEncoder().encode([RallyMarkRecord(startTime: 3, endTime: 9, kind: nil, contacts: nil)]).write(to: labels(copy), options: .atomic)
        server.times[rows[holdout]!.id] = LabelRallyTimes(videoId: rows[holdout]!.id, rallies: [LabelRally(start: 12, end: 20), LabelRally(start: 30, end: 41)],
                                                         complete: true, updatedAt: now)
        let synced = await sync.sync(videos: false)
        XCTAssertTrue(synced, sync.status)
        XCTAssertEqual(server.savedTimes.map(\.videoId), [rows[copy]!.id], "the marks made here go up")
        XCTAssertEqual(server.savedTimes.first?.rallies.map(\.start), [3])
        let pulled = try JSONDecoder().decode([RallyMarkRecord].self, from: Data(contentsOf: labels(holdout)))
        XCTAssertEqual(pulled.map(\.startTime), [12, 30], "the marks made on the phone come down")
        XCTAssertEqual(projects.session(named: holdout)?.ralliesMarked, true)
    }

    func testAClosureThatCannotBeReadPublishesNoModelOutputForAnyRecording() async throws {
        try makeProject(validation: "{ not json")
        let closure = await LabelingSync.withheldClosure(root: root)
        XCTAssertNil(closure, "unreadable reservations: the closure is not known")
        try JSONEncoder().encode([RallyMarkRecord(startTime: 3, endTime: 9, kind: nil, contacts: nil)]).write(to: labels(copy), options: .atomic)
        let synced = await sync.sync(videos: true)
        XCTAssertTrue(synced, sync.status)
        XCTAssertEqual(server.uploads, [], "no ball path goes up, the ordinary recording's neither")
        XCTAssertEqual(sentTracks, ids(all, byHand), "only the rallies a person placed every frame of")
        XCTAssertTrue(sync.status.contains("8 kept on this Mac, not published"), sync.status)
        XCTAssertTrue(sync.status.contains("the withheld closure can't be read"), sync.status)
        XCTAssertTrue(sync.status.contains("ball paths not sent: the withheld closure can't be read"), sync.status)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ballpaths/sent.json").path))
        XCTAssertEqual(server.savedTimes.map(\.videoId), [rows[copy]!.id], "marks made by hand still go up")
    }

    func testAProjectThatWithholdsNothingIsUnaffected() async throws {
        try makeProject(validation: nil)
        let synced = await sync.sync(videos: true)
        XCTAssertTrue(synced, sync.status)
        XCTAssertEqual(Set(server.uploads.filter { $0.hasSuffix(".ballpath.json") }), Set(all.map(ballPath)))
        XCTAssertEqual(sentTracks, ids(all, machine, assisted, byHand))
        XCTAssertFalse(sync.status.contains("kept on this Mac"), sync.status)
    }

    // MARK: - What a model found the ball in

    func testARallyCarriesModelOutputWhenPreTrackedOrWhenABoxIsTheDetectorsPick() {
        XCTAssertTrue(rally("machine").carriesModelOutput)
        XCTAssertTrue(rally("assisted").carriesModelOutput)
        XCTAssertFalse(rally("hand").carriesModelOutput)
        // Frames nobody placed and no detector found are no model's output.
        var empty = rally("hand")
        for i in empty.points.indices { empty.points[i] = TrackPoint(time: empty.points[i].time, state: .unknown, origin: .auto, box: nil) }
        XCTAssertFalse(empty.carriesModelOutput)
        empty.machine = true
        XCTAssertTrue(empty.carriesModelOutput)
    }

    // MARK: - The queue (the Mac's and the phone's)

    private func plan(_ name: String) -> PlanVideo {
        PlanVideo(name: name, surface: "Beach", split: "train", available: true, rallies: 0, labeledFrames: 0, checkedFrames: 0, openRallies: 1, ralliesMarked: false)
    }

    private func queued(_ name: String, _ access: LabelAccess) -> LabelQueue.Video {
        LabelQueue.Video(plan: plan(name), nextRally: LabelRally(start: 10, end: 20), found: 3, marked: 0, complete: false, access: access)
    }

    func testAccessByWhatIsKnownOfTheListAndWhoIsAsking() {
        XCTAssertEqual(LabelAccess(withheld: false, byHand: true), .open)
        XCTAssertEqual(LabelAccess(withheld: false, byHand: false), .open)
        XCTAssertEqual(LabelAccess(withheld: true, byHand: true), .byHandOnly(.withheld), "the lead, and the Mac: by hand only")
        XCTAssertEqual(LabelAccess(withheld: true, byHand: false), .closed(.withheld), "an ordinary labeler: nothing")
        XCTAssertEqual(LabelAccess(withheld: nil, byHand: true), .byHandOnly(.unknown), "not known is never read as not withheld")
        XCTAssertEqual(LabelAccess(withheld: nil, byHand: false), .closed(.unknown))
        XCTAssertNil(LabelAccess.open.modelRefusal)
        for access in [LabelAccess.byHandOnly(.withheld), .closed(.withheld), .byHandOnly(.unknown), .closed(.unknown)] {
            XCTAssertNotNil(access.modelRefusal, "no model task for \(access), whoever asks")
        }
        XCTAssertTrue(LabelAccess.byHandOnly(.unknown).modelRefusal?.contains("not known") ?? false)
        XCTAssertTrue(LabelAccess.byHandOnly(.withheld).modelRefusal?.contains("withheld from every model") ?? false)
        XCTAssertTrue(LabelAccess.open.offersMarking)
        XCTAssertTrue(LabelAccess.byHandOnly(.withheld).offersMarking)
        XCTAssertFalse(LabelAccess.closed(.withheld).offersMarking)
        XCTAssertFalse(LabelAccess.closed(.unknown).offersMarking)
    }

    func testAWithheldRecordingIsNeverATrackJobForTheLeadAndNoJobForALabeler() {
        let rally = LabelRally(start: 10, end: 20)
        let round = TrainingPlan.rounds.first
        // The lead (and the Mac): marked by hand, never tracked — withheld, or not known not to be.
        let lead = [queued("open", .open), queued("withheld", .byHandOnly(.withheld)), queued("unknown", .byHandOnly(.unknown))]
        let leadJobs = LabelQueue.jobs(lead, round: round)
        XCTAssertEqual(leadJobs.filter { if case .track = $0 { return true } else { return false } }, [.track("open", rally)])
        XCTAssertEqual(Set(LabelQueue.markingJobs(lead).map(\.video)), ["open", "withheld", "unknown"], "marking by hand goes on")
        // An ordinary labeler: nothing of either kind.
        let labeler = [queued("open", .open), queued("withheld", .closed(.withheld)), queued("unknown", .closed(.unknown))]
        XCTAssertEqual(Set(LabelQueue.jobs(labeler, round: round).map(\.video)), ["open"])
        // Opening one directly is refused the same way, with the reason.
        XCTAssertNil(LabelQueue.refusal(of: .track("open", rally), access: .open))
        XCTAssertNotNil(LabelQueue.refusal(of: .track("withheld", rally), access: .byHandOnly(.withheld)))
        XCTAssertNotNil(LabelQueue.refusal(of: .track("unknown", rally), access: .byHandOnly(.unknown)), "an unknown state starts no detector task")
        XCTAssertNil(LabelQueue.refusal(of: .review("withheld"), access: .byHandOnly(.withheld)))
        XCTAssertNotNil(LabelQueue.refusal(of: .review("withheld"), access: .closed(.withheld)))
    }

    func testAWithheldRecordingsPlanSlotGoesToAnother() {
        // Every preferred candidate withheld: the plan's track slots go to the others instead of standing empty.
        let rally = LabelRally(start: 10, end: 20)
        let held = (0..<8).map { queued("held\($0)", .byHandOnly(.withheld)) }
        let others = (0..<3).map { queued("other\($0)", .open) }
        let jobs = LabelQueue.jobs(held + others, round: TrainingPlan.rounds.first)
        XCTAssertTrue(others.allSatisfy { jobs.contains(.track($0.plan.name, rally)) }, "\(jobs)")
        XCTAssertFalse(jobs.contains { if case .track(let v, _) = $0 { return v.hasPrefix("held") } else { return false } })
    }

    func testTheMacsQueueOffersNoTrackJobForAWithheldSession() throws {
        try makeProject()
        let session = try XCTUnwrap(projects.session(named: copy))
        var begun = SourceRegistryTests.rally(done: false)
        begun.start = 30; begun.end = 40
        var withRally = session
        withRally.tracks = [begun]
        XCTAssertEqual(LabelQueue.Video.nextRally(in: withRally), begun.bounds, "there is a rally to track")
        let round = TrainingPlan.rounds.first
        let open = LabelQueue.jobs([LabelQueue.Video(session: withRally, access: .open)], round: round)
        XCTAssertTrue(open.contains(.track(copy, begun.bounds)), "\(open)")
        for access in [LabelAccess(withheld: true, byHand: true), LabelAccess(withheld: nil, byHand: true)] {
            let jobs = LabelQueue.jobs([LabelQueue.Video(session: withRally, access: access)], round: round)
            XCTAssertEqual(jobs, [.review(copy)], "marked by hand, not tracked: \(access)")
        }
    }
}
