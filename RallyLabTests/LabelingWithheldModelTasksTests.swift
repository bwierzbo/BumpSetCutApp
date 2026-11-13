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
//    has, the rallies a person tracked by hand, the lead's rally marks;
//  - a rally tracked before opens again by hand for the lead (TrackWork):
//    no detector is built, nothing is solved, a fix changes its frame only
//    and syncs like any correction — and not at all for an ordinary labeler;
//  - no admission outlives the list it was made under: a recording withheld
//    while its rally is open, or while a round is sending, gets frame-only
//    fixes from the next press and nothing more published from the next send.
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

    // MARK: - A rally tracked before, opened again (TrackWork)

    private let withheldLead = LabelAccess(withheld: true, byHand: true), unknownLead = LabelAccess(withheld: nil, byHand: true)
    private let withheldLabeler = LabelAccess(withheld: true, byHand: false), unknownLabeler = LabelAccess(withheld: nil, byHand: false)

    func testAnExistingRallyOfAWithheldRecordingOpensByHandForTheLeadAndANewOneNotAtAll() {
        // No model is kept from the recording: assisted, a rally tracked before or not.
        XCTAssertEqual(TrackWork(access: .open, existingTrack: true), .assisted)
        XCTAssertEqual(TrackWork(access: .open, existingTrack: false), .assisted)
        // Withheld, or not known not to be: the lead opens what was tracked before by hand, with the reason.
        for access in [withheldLead, unknownLead] {
            XCTAssertEqual(TrackWork(access: access, existingTrack: true), .byHand(access.modelRefusal!), "\(access)")
            XCTAssertEqual(TrackWork(access: access, existingTrack: false), .refused(access.modelRefusal!), "a rally not tracked yet needs the detectors: \(access)")
        }
        // An ordinary labeler: nothing opens.
        for access in [withheldLabeler, unknownLabeler] {
            XCTAssertEqual(TrackWork(access: access, existingTrack: true), .refused(access.modelRefusal!), "\(access)")
            XCTAssertEqual(TrackWork(access: access, existingTrack: false), .refused(access.modelRefusal!), "\(access)")
        }
        XCTAssertNil(TrackWork.assisted.modelRefusal)
        XCTAssertNotNil(TrackWork.unchecked.modelRefusal, "a session that has not asked yet runs no model")
    }

    /// The work a session is given when it asks the server, as the operation at hand gets it: reconciled with
    /// the access known at that moment (here, the same).
    private func workNow(_ access: LabelAccess, existing: Bool = true) -> TrackWork.Now {
        var work = TrackWork(access: access, existingTrack: existing)
        return work.now(access: access, existingTrack: existing)
    }

    func testNoDetectorIsEverBuiltForARallyWorkedOnByHandOrRefused() throws {
        // Stands in for the phone's detectors: counts how often one was built.
        var built = 0
        struct Detectors {}
        func make() -> Detectors { built += 1; return Detectors() }
        for access in [withheldLead, unknownLead, withheldLabeler, unknownLabeler] {
            for existing in [true, false] {
                let work = workNow(access, existing: existing)
                // The three detector-backed operations: finding the ball on the frames, looking again, more frames.
                for _ in 0..<3 {
                    XCTAssertThrowsError(try work.models(make), "\(work)") { error in
                        XCTAssertEqual(error as? TrackWork.ModelsRefused, TrackWork.ModelsRefused(reason: access.modelRefusal!))
                        XCTAssertEqual(error.localizedDescription, access.modelRefusal, "the reason is what is shown")
                    }
                }
            }
        }
        var unchecked = TrackWork.unchecked
        XCTAssertThrowsError(try unchecked.now(access: .open, existingTrack: true).models(make), "a session that has not asked the server runs no model")
        XCTAssertEqual(built, 0, "refused before anything is built")
        _ = try workNow(.open).models(make)
        XCTAssertEqual(built, 1, "a recording no model is kept from is unchanged")
    }

    /// A rally a person finished whose frame 3 the solver would take from the detector's candidate if it ran.
    private func rallyTheSolverWouldChange() -> TrackedRally {
        var r = rally("assisted")
        r.points[3] = TrackPoint(time: r.points[3].time, state: .unknown, origin: .auto, box: nil)
        return r
    }

    private let moved = TrackCandidate(rect: CGRect(x: 0.6, y: 0.5, width: 0.03, height: 0.03), confidence: 1)

    private func place(_ box: TrackCandidate, at i: Int) -> (inout TrackedRally) -> Void {
        { r in r.points[i].state = .visible; r.points[i].origin = .user; r.points[i].box = box; r.points[i].reviewed = false }
    }

    func testAFixByHandChangesItsFrameOnlyAndNothingIsSolved() {
        let before = rallyTheSolverWouldChange()
        let byHand = workNow(withheldLead).fixed(before, place(moved, at: 1))
        XCTAssertEqual(byHand.points[1].box, moved)
        XCTAssertEqual(byHand.points[1].origin, .user)
        for i in before.points.indices where i != 1 { XCTAssertEqual(byHand.points[i], before.points[i], "frame \(i) is as it was") }
        XCTAssertEqual(byHand.points[3].state, .unknown, "the detector's candidate on frame 3 was not taken")
        XCTAssertEqual(byHand.candidates, [], "and the rally holds no candidates from here on")
        XCTAssertTrue(byHand.done, "a finished rally stays finished")
        // The same when the state is not known; nothing at all when the work is refused.
        XCTAssertEqual(workNow(unknownLead).fixed(before, place(moved, at: 1)), byHand)
        XCTAssertEqual(workNow(withheldLabeler).fixed(before, place(moved, at: 1)), before)
        // A recording no model is kept from: the fix re-solves the rest, as before.
        let assisted = workNow(.open).fixed(before) { $0.points[1].origin = .user }
        XCTAssertEqual(assisted.points[1].origin, .user)
        XCTAssertEqual(assisted.points[3].state, .visible, "re-solved from the candidates")
        XCTAssertEqual(assisted.candidates, before.candidates)
        XCTAssertFalse(assisted.done, "to be watched again")
    }

    // MARK: - The list changes while a rally is open

    func testWorkOnlyEverNarrowsUntilTheServerIsAskedAgain() {
        let withheldWhy = withheldLead.modelRefusal!, unknownWhy = unknownLead.modelRefusal!
        // Assisted work follows the access known now.
        XCTAssertEqual(TrackWork.assisted.reconciled(with: .open, existingTrack: true), .assisted)
        XCTAssertEqual(TrackWork.assisted.reconciled(with: withheldLead, existingTrack: true), .byHand(withheldWhy))
        XCTAssertEqual(TrackWork.assisted.reconciled(with: unknownLead, existingTrack: true), .byHand(unknownWhy))
        XCTAssertEqual(TrackWork.assisted.reconciled(with: withheldLabeler, existingTrack: true), .refused(withheldWhy))
        XCTAssertEqual(TrackWork.assisted.reconciled(with: withheldLead, existingTrack: false), .refused(withheldWhy))
        // Work by hand stays by hand when the list on the phone says open again (its candidates are gone; only
        // asking the server anew — a new TrackWork — makes it assisted), takes the newer reason, and can close.
        XCTAssertEqual(TrackWork.byHand(unknownWhy).reconciled(with: .open, existingTrack: true), .byHand(unknownWhy))
        XCTAssertEqual(TrackWork.byHand(unknownWhy).reconciled(with: withheldLead, existingTrack: true), .byHand(withheldWhy))
        XCTAssertEqual(TrackWork.byHand(withheldWhy).reconciled(with: withheldLabeler, existingTrack: true), .refused(withheldWhy))
        // Refused stays refused.
        XCTAssertEqual(TrackWork.refused(withheldWhy).reconciled(with: .open, existingTrack: true), .refused(withheldWhy))
        XCTAssertEqual(TrackWork.unchecked.reconciled(with: .open, existingTrack: true), .unchecked)
        // `now` keeps what it narrowed to.
        var session = TrackWork.assisted
        XCTAssertEqual(session.now(access: withheldLead, existingTrack: true).work, .byHand(withheldWhy))
        XCTAssertEqual(session, .byHand(withheldWhy))
        XCTAssertEqual(session.now(access: .open, existingTrack: true).work, .byHand(withheldWhy))
    }

    func testEveryCorrectionAfterTheRecordingIsWithheldMidSessionChangesItsFrameOnly() throws {
        var built = 0
        func make() -> Int { built += 1; return built }
        let before = rallyTheSolverWouldChange()
        // What looking again would hand back, and what was kept on the phone: candidates that would move frames.
        let moreCandidates = before.candidates.map { $0 + [moved] }
        // Every way a person corrects a rally, with the frame it touches (nil: the rally's own flag).
        let corrections: [(name: String, frame: Int?, fix: (inout TrackedRally) -> Void)] = [
            ("the ball is here", 1, place(moved, at: 1)),
            ("the pick is right", 0, { $0.points[0].origin = .user }),
            ("hidden", 2, { $0.points[2].state = .hidden; $0.points[2].origin = .user; $0.points[2].box = nil; $0.points[2].reviewed = false }),
            ("the ball is on the frame nothing was found on", 3, place(moved, at: 3)),
        ]
        for changed in [withheldLead, unknownLead] {
            for correction in corrections {
                // The session was opened while no model was kept from the recording; the list changed since. Each
                // correction is its own first press after the change: none relies on another having reconciled.
                var session = TrackWork(access: .open, existingTrack: true)
                XCTAssertEqual(session, .assisted)
                let now = session.now(access: changed, existingTrack: true)
                XCTAssertEqual(now.work, .byHand(changed.modelRefusal!), "\(correction.name), \(changed)")
                XCTAssertEqual(session, now.work, "and the session stays by hand")
                let after = now.fixed(before, correction.fix)
                for i in before.points.indices where i != correction.frame {
                    XCTAssertEqual(after.points[i], before.points[i], "\(correction.name): frame \(i) was not re-solved (\(changed))")
                }
                XCTAssertNotEqual(after.points[correction.frame!], before.points[correction.frame!], correction.name)
                XCTAssertEqual(after.candidates, [], "\(correction.name): no candidate is kept, none was read")
                XCTAssertEqual(after.done, before.done)
                // Repeated, as Hidden pressed again and again: still that frame only.
                XCTAssertEqual(now.fixed(after, correction.fix).points, after.points)
            }
            var session = TrackWork.assisted
            let now = session.now(access: changed, existingTrack: true)
            // Done, and its taking back (no re-solve either way).
            XCTAssertEqual(now.fixed(before, resolve: false) { $0.done = false }.points, before.points)
            // Looking again, more frames, finding the ball: no detector; what a search already running brings
            // back, or what was kept on the phone, is not taken.
            for _ in 0..<3 { XCTAssertThrowsError(try now.models(make)) }
            let taken = now.taking(moreCandidates, into: before)
            XCTAssertEqual(taken.points, before.points, "nothing solved from candidates (\(changed))")
            XCTAssertEqual(taken.candidates, [])
        }
        // Closed to the account (an ordinary labeler): nothing changes at all.
        var closing = TrackWork.assisted
        let closed = closing.now(access: withheldLabeler, existingTrack: true)
        XCTAssertEqual(closed.work, .refused(withheldLabeler.modelRefusal!))
        XCTAssertEqual(closed.fixed(before, place(moved, at: 1)), before)
        XCTAssertThrowsError(try closed.models(make))
        XCTAssertEqual(built, 0, "no detector was built after the list changed")
    }

    func testARecordingStillOpenIsWorkedOnAsBefore() throws {
        var built = 0
        var session = TrackWork(access: .open, existingTrack: true)
        let before = rallyTheSolverWouldChange()
        for _ in 0..<3 {
            let now = session.now(access: .open, existingTrack: true)
            XCTAssertEqual(now.work, .assisted)
            let fixed = now.fixed(before) { $0.points[1].origin = .user }
            XCTAssertEqual(fixed.points[3].state, .visible, "each fix re-solves the rest")
            XCTAssertFalse(fixed.done)
            XCTAssertEqual(now.fixed(before, resolve: false) { $0.done = true }.points, before.points, "done does not re-solve")
            _ = try now.models { built += 1 }
            var cleared = before
            cleared.candidates = []
            XCTAssertEqual(now.taking(before.candidates, into: cleared).points[3].state, .visible, "found candidates are taken and solved")
        }
        XCTAssertEqual(built, 3)
        XCTAssertEqual(session, .assisted)
    }

    func testWorkByHandNeverAddsWhatAModelFound() {
        let work = workNow(withheldLead)
        func modelFrames(_ r: TrackedRally) -> Int { r.points.filter { $0.origin == .auto && $0.box != nil }.count }
        // Every fix a person can make: the ball is here, the pick is right, the ball is hidden.
        var r = rallyTheSolverWouldChange()
        var seen = modelFrames(r)
        let fixes: [(inout TrackedRally) -> Void] = [place(moved, at: 3), { $0.points[0].origin = .user },
                                                    { $0.points[2].state = .hidden; $0.points[2].origin = .user; $0.points[2].box = nil }]
        for fix in fixes {
            r = work.fixed(r, fix)
            XCTAssertLessThan(modelFrames(r), seen + 1, "a fix by hand never adds a frame a model found")
            seen = modelFrames(r)
        }
        XCTAssertTrue(r.carriesModelOutput, "frames 1 and 4 are still the detector's picks")
        r = work.fixed(r) { $0.points[1].origin = .user }
        r = work.fixed(r) { $0.points[4].origin = .user }
        XCTAssertFalse(r.carriesModelOutput, "every frame confirmed or placed by a person: by hand")
        // A pre-tracked rally stays a model's, whatever is fixed in it.
        var machine = rally("machine")
        for i in machine.points.indices { machine = work.fixed(machine) { $0.points[i].origin = .user } }
        XCTAssertTrue(machine.carriesModelOutput)
    }

    func testACorrectionByHandOnAWithheldRecordingsExistingRallySyncsBothWays() async throws {
        try makeProject()
        let work = workNow(withheldLead)
        guard case .byHand = work.work else { return XCTFail("\(work)") }
        // Both rallies went up before their recordings were withheld.
        func onServer(_ name: String) throws -> LabelTrack {
            let local = try XCTUnwrap(projects.session(named: name)?.tracks?.first { $0.id == machine[name] })
            var row = LabelTrack(local, videoId: rows[name]!.id)
            row.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            server.tracks[row.id] = row
            server.stamps.append(LabelingClient.TrackStamp(id: row.id, videoId: row.videoId, deleted: false, updatedAt: row.updatedAt))
            return row
        }
        let copyRow = try onServer(copy), lineageRow = try onServer(lineage)
        // On the phone, the lead moves the ball on frame 2 of the copy's rally, by hand, and it is saved.
        var corrected = LabelTrack(work.fixed(copyRow.rally, place(moved, at: 2)), videoId: copyRow.videoId)
        corrected.updatedAt = Date()
        server.tracks[corrected.id] = corrected
        server.stamps.removeAll { $0.id == corrected.id }
        server.stamps.append(LabelingClient.TrackStamp(id: corrected.id, videoId: corrected.videoId, deleted: false, updatedAt: corrected.updatedAt))
        // On the Mac, a frame of the lineage holdout's rally is hidden by hand.
        var tracks = try XCTUnwrap(projects.session(named: lineage)?.tracks)
        let i = try XCTUnwrap(tracks.firstIndex { $0.id == lineageRow.id })
        tracks[i] = work.fixed(tracks[i]) { $0.points[0].state = .hidden; $0.points[0].origin = .user; $0.points[0].box = nil }
        tracks[i].updatedAt = Date()
        projects.sampler.setTracks(tracks, session: lineage)

        let synced = await sync.sync(videos: false)
        XCTAssertTrue(synced, sync.status)
        let here = try XCTUnwrap(projects.session(named: copy)?.tracks?.first { $0.id == copyRow.id })
        XCTAssertEqual(here.points[2].box, moved, "the phone's correction came down")
        XCTAssertEqual(here.points[2].origin, .user)
        let there = try XCTUnwrap(server.tracks[lineageRow.id])
        XCTAssertEqual(there.points.points[0].state, .hidden, "the Mac's correction went up")
        XCTAssertEqual(there.points.points[0].origin, .user)
        // And nothing a model found went up with them: the rallies the server never had stay held.
        XCTAssertTrue(sentTracks.isDisjoint(with: ids(withheld, assisted)))
        XCTAssertFalse(sentTracks.contains(machine[holdout]!))
        XCTAssertTrue(sync.status.contains("kept on this Mac, not published"), sync.status)
    }

    // MARK: - The closure changes while a round is sending

    private func withhold(_ names: [String]) throws {
        let list = names.map { "\"\($0)\"" }.joined(separator: ",")
        try "{\"tune\":[],\"holdout\":[\(list)],\"finalTest\":[],\"lineageHoldout\":[]}".write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
    }

    func testABallPathIsNotSentUnderTheClosureAnEarlierOneWentUpUnder() async throws {
        try makeProject(validation: nil)
        server.hold("upload")   // the first path's upload is on its way back
        let round = Task { await self.sync.sync(videos: true) }
        let parked = await server.arrived()
        XCTAssertTrue(parked, "\(server.calls)")
        try withhold([train])   // withheld while the round is sending
        server.release()
        let synced = await round.value
        XCTAssertTrue(synced, sync.status)
        XCTAssertEqual(server.uploads, [lineage, copy, holdout].map(ballPath), "the path of the recording withheld meanwhile stayed here")
        XCTAssertTrue(sync.status.contains("ball paths of 1 withheld recording kept on this Mac"), sync.status)
    }

    func testAModelRallyIsNotSentUnderTheClosureAnEarlierBatchWentUpUnder() async throws {
        try makeProject(validation: nil)
        // Thirty pre-tracked rallies on the ordinary recording: with the others' nine, two batches of twenty.
        let many = (0..<30).map { _ in rally("machine") }
        projects.sampler.setTracks(many, session: train)
        server.hold("save(tracks)")   // the first batch is acknowledged, its reply on its way back
        let round = Task { await self.sync.sync(videos: false) }
        let parked = await server.arrived()
        XCTAssertTrue(parked, "\(server.calls)")
        try withhold([train])
        server.release()
        let synced = await round.value
        XCTAssertTrue(synced, sync.status)
        XCTAssertEqual(server.savedTracks.count, 1, "the second batch held only the withheld recording's model rallies: nothing was sent")
        XCTAssertEqual(sentTracks.count, 20)
        XCTAssertEqual(sentTracks.intersection(Set(many.map(\.id))).count, 11, "the eleven that went up before the recording was withheld")
        XCTAssertTrue(sync.status.contains("19 kept on this Mac, not published"), sync.status)
        XCTAssertEqual(projects.session(named: train)?.tracks?.count, 30, "all thirty stay in the session")
        // The next round holds them like any other withheld recording's.
        let again = await sync.sync(videos: false)
        XCTAssertTrue(again, sync.status)
        XCTAssertEqual(server.savedTracks.count, 1)
        XCTAssertTrue(sync.status.contains("19 kept on this Mac, not published"), sync.status)
    }

    func testARowWithWhatThePipelineFoundIsNotPublishedUnderTheClosureAnEarlierRowWentUpUnder() async throws {
        try makeProject(validation: nil)
        server.hold("save(video)")   // the first row's save is on its way back
        let round = Task { await self.sync.sync(videos: true) }
        let parked = await server.arrived()
        XCTAssertTrue(parked, "\(server.calls)")
        let first = try XCTUnwrap(server.savedVideos.first?.sessionName)
        // One not published yet this round, and no other recording's alias (the lineage holdout and its copy go together).
        let later = try XCTUnwrap([holdout, train].first { $0 != first })
        try withhold([later])
        server.release()
        let synced = await round.value
        XCTAssertTrue(synced, sync.status)
        XCTAssertEqual(Set(server.savedVideos.compactMap(\.sessionName)), Set(all).subtracting([later]), "the row of the recording withheld meanwhile was not published")
        XCTAssertFalse(server.uploads.contains(ballPath(later)), "nor its ball path")
    }

    // MARK: - Model work asks before every unit; what comes back late is dropped (ModelLeave)

    func testTheLeaveIsWhatTheDeviceKnowsNowFromAnyThread() async {
        let leave = ModelLeave()
        let recording = UUID(), other = UUID()
        let ask = leave.question(for: recording)
        XCTAssertFalse(ask(), "a recording never heard of is not open")
        leave.set(open: [recording])
        XCTAssertTrue(ask())
        XCTAssertFalse(leave.isOpen(other))
        // Asked off the main actor, where the detectors run, after the list changed on it.
        leave.set(open: [other])
        let seenOffMain = await Task.detached { ask() }.value
        XCTAssertFalse(seenOffMain)
        // Units stop at the next one, and what the earlier ones gave is not handed on.
        leave.set(open: [recording])
        var run: [Int] = []
        let stopped = ModelLeave.each(0..<10, whileAllowed: ask) { unit -> Int in
            run.append(unit)
            if unit == 3 { leave.set(open: []) }
            return unit
        }
        XCTAssertNil(stopped)
        XCTAssertEqual(run, [0, 1, 2, 3], "no unit ran after the change")
        leave.set(open: [recording])
        XCTAssertEqual(ModelLeave.each(0..<4, whileAllowed: ask) { $0 * 2 }, [0, 2, 4, 6], "an open recording runs them all")
    }

    /// Stands in for the multi-frame model's windows: every push and the finish count as a window run.
    private struct CountingWindows: HeatWindowing {
        final class Count { var pushes = 0; var finishes = 0; var onPush: (Int) -> Void = { _ in } }
        let count = Count()
        mutating func push(_ frame: Int) -> [[HeatmapBallDetector.Peak]] {
            count.pushes += 1
            count.onPush(count.pushes)
            return [[]]
        }
        mutating func finish() -> [[HeatmapBallDetector.Peak]] {
            count.finishes += 1
            return [[], []]
        }
    }

    func testTheHeatmapPassStopsAtTheNextWindowWhenTheRecordingIsWithheldMidPass() {
        let leave = ModelLeave()
        let recording = UUID()
        let frames: [Int?] = Array(0..<12)
        for narrowedAt in [1, 5, 12] {
            leave.set(open: [recording])
            var windows = CountingWindows()
            // The list withholds the recording while window `narrowedAt` is running.
            windows.count.onPush = { n in if n == narrowedAt { leave.set(open: []) } }
            let peaks = TrackFinder.heatPeaks(&windows, frames: frames, whileAllowed: leave.question(for: recording))
            XCTAssertNil(peaks, "nothing is handed back (narrowed at \(narrowedAt))")
            XCTAssertEqual(windows.count.pushes, narrowedAt, "windows run after the change: 0")
            XCTAssertEqual(windows.count.finishes, 0, "the last window did not run either")
        }
        // Withheld before the pass: no window at all.
        leave.set(open: [])
        var none = CountingWindows()
        XCTAssertNil(TrackFinder.heatPeaks(&none, frames: frames, whileAllowed: leave.question(for: recording)))
        XCTAssertEqual(none.count.pushes + none.count.finishes, 0)
        // A recording still open: every window, and the answers in order.
        leave.set(open: [recording])
        var all = CountingWindows()
        let peaks = TrackFinder.heatPeaks(&all, frames: frames, whileAllowed: leave.question(for: recording))
        XCTAssertEqual(all.count.pushes, 12)
        XCTAssertEqual(all.count.finishes, 1)
        XCTAssertEqual(peaks?.count, 14)
    }

    private func picture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    func testLookingAgainStopsAtTheNextCropWhenTheRecordingIsWithheldMidSearch() throws {
        let image = try picture()
        // A fix on frame 10 of 21, nothing found on the frames around it: the search goes to the detector's crops.
        let box = TrackCandidate(rect: CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.05), confidence: 1)
        var points = (0..<21).map { TrackPoint(time: Double($0) / 30, state: .unknown, origin: .auto, box: nil) }
        points[10] = TrackPoint(time: 10.0 / 30, state: .visible, origin: .user, box: box)
        let rally = TrackedRally(id: UUID(), start: 0, end: 20.0 / 30, points: points, candidates: points.map { _ in [] }, done: false)
        let leave = ModelLeave()
        let recording = UUID()
        var windows = 0, crops = 0
        var narrowAtCrop: Int?, narrowAtWindows = false
        func search() -> [Int: [TrackCandidate]] {
            windows = 0; crops = 0
            leave.set(open: [recording])
            return TrackFinder.lookAgain(from: 10, in: rally, whileAllowed: leave.question(for: recording), faint: { span in
                var counting = CountingWindows()
                counting.count.onPush = { _ in windows += 1; if narrowAtWindows { leave.set(open: []) } }
                return TrackFinder.heatPeaks(&counting, frames: span.map { Optional($0) }, whileAllowed: leave.question(for: recording))
            }, detect: { _ in
                crops += 1
                if crops == narrowAtCrop { leave.set(open: []) }
                return []
            }, image: { _ in image })
        }
        // Still open: the whole search — every window, then two frames each way, two crops each.
        XCTAssertEqual(search(), [:], "the stand-ins find nothing")
        XCTAssertEqual(crops, 8)
        XCTAssertGreaterThan(windows, 1)
        // Withheld while the first crop is in the detector: no crop after it.
        narrowAtCrop = 1
        XCTAssertEqual(search(), [:])
        XCTAssertEqual(crops, 1, "crops run after the change: 0")
        narrowAtCrop = 5
        XCTAssertEqual(search(), [:])
        XCTAssertEqual(crops, 5)
        // Withheld during the multi-frame model's first window: no further window, and no crop at all.
        narrowAtCrop = nil; narrowAtWindows = true
        XCTAssertEqual(search(), [:])
        XCTAssertEqual(windows, 1, "windows run after the change: 0")
        XCTAssertEqual(crops, 0)
    }

    /// The marking screen as far as its ball path goes: what the phone knows of the recording, how often the
    /// path was fetched, and the path installed for snapping.
    @MainActor private final class MarkingScreen {
        var access = LabelAccess.open
        var downloads = 0
        var installed: [Double]?

        /// LabelerModel.ballPath, then MarkRalliesView's install — with a stand-in client whose download waits
        /// until `download` is opened.
        func fetchAndInstall(_ download: Latch) async {
            let seen = await ModelLeave.delivered(if: { access == .open }) { () async -> [Double] in
                downloads += 1
                try? await download.wait()
                return [1, 2, 3]
            }
            if let seen { installed = seen }
        }
    }

    func testABallPathWhoseDownloadCompletesAfterTheRecordingIsWithheldIsNotInstalled() async {
        let screen = MarkingScreen()
        // Withheld while the download is suspended: the access change clears the path; the samples that then
        // arrive are not installed over it.
        let suspended = Latch()
        let late = Task { await screen.fetchAndInstall(suspended) }
        while screen.downloads == 0 { await Task.yield() }
        screen.access = withheldLead
        screen.installed = nil
        suspended.open()
        await late.value
        XCTAssertNil(screen.installed, "a late ball path for a recording withheld meanwhile is dropped")
        // Not known is the same; and nothing is fetched at all for a recording already withheld.
        screen.access = unknownLead
        let already = Latch(); already.open()
        await screen.fetchAndInstall(already)
        XCTAssertEqual(screen.downloads, 1, "not fetched")
        XCTAssertNil(screen.installed)
        // A recording still open: fetched and installed.
        screen.access = .open
        let open = Latch(); open.open()
        await screen.fetchAndInstall(open)
        XCTAssertEqual(screen.downloads, 2)
        XCTAssertEqual(screen.installed, [1, 2, 3])
    }

    func testARallyGoesUpByWhatItsRecordingIsWhenItIsSent() {
        // The Mac's sync and the phone's outbox ask the same rule at the moment of sending.
        for access in [withheldLead, unknownLead, withheldLabeler, unknownLabeler] {
            XCTAssertFalse(rally("machine").mayGoUp(new: true, access: access), "\(access)")
            XCTAssertFalse(rally("assisted").mayGoUp(new: true, access: access), "tracked while it was open, sent after it was withheld: \(access)")
            XCTAssertTrue(rally("hand").mayGoUp(new: true, access: access), "every frame placed by a person")
            XCTAssertTrue(rally("machine").mayGoUp(new: false, access: access), "a row the server already has keeps syncing")
        }
        for kind in ["machine", "assisted", "hand"] { XCTAssertTrue(rally(kind).mayGoUp(new: true, access: .open), kind) }
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
