//
//  RecordingTypeClaimSyncTests.swift
//  RallyLabTests
//
//  The Mac's side of a footage-type claim (D-033): a sync round reads the
//  submitted claims of its opening's project, judges each against the
//  project as it is, writes the accepted ones through the one writer of
//  the type and reads them back before the server hears of it, and
//  settles the rest with a reason — under the opening the round started
//  for, nothing into a project opened meanwhile. A write whose
//  acknowledgement was lost is recognised and acknowledged without a
//  second write. Synthetic projects, a fake server.
//

import CryptoKit
import XCTest
@testable import RallyLab

@MainActor
final class RecordingTypeClaimSyncTests: XCTestCase {
    private var base: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var sampler: SamplerModel!
    private var projects: ProjectsModel!
    private var server: FakeLabeling!
    private var sync: LabelingSync!
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T10:00:00Z")!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rtc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
        suite = "RallyLabTests.RecordingTypeClaimSync.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        sampler = SamplerModel(defaults: defaults, root: base.appendingPathComponent("empty"))
        projects = ProjectsModel(sampler: sampler, defaults: defaults)
        server = FakeLabeling()
        sync = LabelingSync(projects: projects, client: server, pendingDirectory: base.appendingPathComponent("pending"))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixtures

    /// A project with one recording: a footage file, its card with the file's fingerprint, its session (with cuts),
    /// and rally marks beside the footage; its row on the server with the published fingerprint.
    @discardableResult
    private func project(_ name: String, videos: [String] = ["video_01"]) throws -> (root: URL, row: LabelVideo) {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        let store = DatasetStore(root: root)
        try store.prepare()
        var clips: [PlannedClip] = []
        var rows: [LabelVideo] = []
        for (n, video) in videos.enumerated() {
            let footage = root.appendingPathComponent("footage/\(video).mp4")
            try Data("\(name): \(video) footage".utf8).write(to: footage)
            var session = VideoSession(name: video, sourcePath: footage.path, split: "train", addedAt: now, frames: [])
            session.cuts = [CutRange(start: 0, end: 12)]
            session.ralliesMarked = true
            try store.save(session)
            let fingerprint = ProjectsModel.readFileFingerprint(atPath: footage.path)
            clips.append(SourceRegistryTests.clip("card_\(n)", number: n + 1, videos: [SourceRegistryTests.video(video, fingerprint: fingerprint)]))
            try JSONEncoder().encode([RallyMarkRecord(startTime: 30, endTime: 36, kind: .rally, contacts: nil)]).write(to: RallyMarkModel.labelsURL(for: footage), options: .atomic)
            rows.append(LabelVideo(id: UUID(), project: name, sessionName: video, title: "", surface: .beach, camera: .endlineGround, lighting: "",
                                   split: "train", clipPath: "rallylab/\(name)/\(video)-v3.mp4", duration: 300, ralliesFound: [], status: .rallylab, updatedAt: now,
                                   frameTimesDigest: nil, sourceFingerprint: fingerprint))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: name, createdAt: now, framesPerRally: 2, clips: clips)).write(to: root.appendingPathComponent("project.json"))
        server.videos.append(contentsOf: rows)
        return (root, rows[0])
    }

    private func fingerprint(_ name: String) -> String { ProjectsModel.readFileFingerprint(atPath: base.appendingPathComponent("\(name)/footage/video_01.mp4").path)! }

    /// A project as RallyLab makes one from a recording: the card carries the ORIGIN file's fingerprint (addVideo
    /// fingerprints the source), the session is over the CUT clip (other bytes), and the server row was published with
    /// the cut clip's fingerprint (publishVideos/publishIdentities fingerprint the session's file) — the identity the
    /// phone copies into its claim. Found by the synthetic acceptance of 2026-11-04.
    @discardableResult
    private func cutProject(_ name: String) throws -> (root: URL, row: LabelVideo, origin: String, cut: String) {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        let store = DatasetStore(root: root)
        try store.prepare()
        let origin = root.appendingPathComponent("footage/origin_01.mov")
        try Data("\(name): the original recording, long".utf8).write(to: origin)
        let cut = root.appendingPathComponent("footage/video_01.mp4")
        try Data("\(name): the cut clip".utf8).write(to: cut)
        var session = VideoSession(name: "video_01", sourcePath: cut.path, split: "train", addedAt: now, frames: [])
        session.ralliesMarked = true
        try store.save(session)
        let originFingerprint = ProjectsModel.readFileFingerprint(atPath: origin.path)!
        let cutFingerprint = ProjectsModel.readFileFingerprint(atPath: cut.path)!
        XCTAssertNotEqual(originFingerprint, cutFingerprint)
        var source = SourceRegistryTests.video("video_01", fingerprint: originFingerprint)
        source.origin = origin.path
        source.clipFile = cut.path
        let clips = [SourceRegistryTests.clip("card_0", number: 1, videos: [source])]
        try JSONEncoder().encode([RallyMarkRecord(startTime: 30, endTime: 36, kind: .rally, contacts: nil)]).write(to: RallyMarkModel.labelsURL(for: cut), options: .atomic)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: name, createdAt: now, framesPerRally: 2, clips: clips)).write(to: root.appendingPathComponent("project.json"))
        let row = LabelVideo(id: UUID(), project: name, sessionName: "video_01", title: "", surface: .beach, camera: .endlineGround, lighting: "",
                             split: "train", clipPath: "rallylab/\(name)/video_01-v3.mp4", duration: 300, ralliesFound: [], status: .rallylab, updatedAt: now,
                             frameTimesDigest: nil, sourceFingerprint: cutFingerprint)
        server.videos.append(row)
        return (root, row, originFingerprint, cutFingerprint)
    }

    @discardableResult
    /// A claim from the phone: by default sent from the lead's own account (this Mac's), which counts at once.
    private func submit(_ kind: String, for row: LabelVideo, fingerprint: String? = nil, revision: Int = 1, at: Date? = nil, by: UUID? = nil) -> RecordingTypeClaim {
        let claim = RecordingTypeClaim(id: UUID(), videoId: row.id, project: row.project!, sessionName: row.sessionName!,
                                       sourceFingerprint: fingerprint ?? row.sourceFingerprint!, recordingType: kind, revision: revision, status: .submitted,
                                       reason: nil, submittedBy: by ?? server.me, submittedAt: at ?? now, settledBy: nil, settledAt: nil, updatedAt: at ?? now)
        server.claims[claim.id] = claim
        return claim
    }

    private func record(_ name: String, video: String = "video_01") throws -> FootageProperties.File? {
        try FootageProperties.Store(root: base.appendingPathComponent(name)).load(video)
    }

    private func recordURL(_ name: String, video: String = "video_01") -> URL { FootageProperties.url(in: base.appendingPathComponent(name), video: video) }

    private func open(_ name: String) -> ProjectsModel.Opening {
        projects.open(base.appendingPathComponent(name, isDirectory: true))
        return projects.opening!
    }

    /// Every file under the project, by relative path, with its content hash.
    private func snapshot(_ name: String) throws -> [String: String] {
        let root = base.appendingPathComponent(name, isDirectory: true)
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in e where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            out[String(url.path.dropFirst(root.path.count))] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    private func settlements() -> [(status: RecordingTypeClaim.Status, reason: String?)] { server.settled.map { ($0.status, $0.reason) } }

    // MARK: - Accepting

    func testAnAcceptedClaimIsWrittenThroughTheOneWriterReadBackAndOnlyThenSettled() async throws {
        let (_, row) = try project("A")
        open("A")
        // A first round brings the session to its synced state (the rally-times step re-saves it): the baseline.
        let settled = await sync.sync(videos: false)
        XCTAssertTrue(settled)
        let claim = submit("continuous", for: row)
        let before = try snapshot("A")
        XCTAssertNil(try record("A"), "nothing on file before")
        let awaited1 = await sync.sync(videos: false)
        XCTAssertTrue(awaited1)
        // The record: the claim's type, attributed to the phone's labeler and the claim, at the claim's time.
        let written = try XCTUnwrap(try record("A"))
        XCTAssertEqual(written.recordingType, .continuous)
        XCTAssertEqual(written.recordingTypeAt, "2026-11-04T10:00:00Z")
        XCTAssertTrue(RecordingTypeClaims.isAttributed(written.recordingTypeBy, to: claim))
        XCTAssertEqual(written.sourceFingerprint, fingerprint("A"), "bound to the card's file")
        // Settled accepted, with the confirmation time, after the write; the server's row shows the published type.
        XCTAssertEqual(settlements().map(\.status), [.accepted])
        XCTAssertEqual(server.settled.last?.confirmedAt, now)
        XCTAssertEqual(server.videos.first?.recordingType, "continuous")
        XCTAssertTrue(sync.status.contains("footage types from the phone 1 confirmed · 0 declined"), sync.status)
        // Only the record was written: cuts, rally marks, the session — every other file byte-identical.
        let after = try snapshot("A")
        XCTAssertEqual(after.filter { !$0.key.hasSuffix("/footage-properties/video_01.json") }, before)
        // Eligibility follows the written record, and only it: continuous → standard, ordinary negatives allowed.
        let assessed = TrainingEligibility.assess(admission: .admitted, properties: written)
        XCTAssertEqual(assessed[.rallyClassifier].level, .standard); XCTAssertEqual(assessed.fullVideoNegatives.level, .standard)
    }

    func testAClaimOnCutFootageIsJudgedAgainstThePublishedClipIdentityAndTheRecordIsBoundToTheCard() async throws {
        // The phone's claim carries the fingerprint the Mac published (the cut clip's); the card's is the origin's.
        let (_, row, origin, cut) = try cutProject("C")
        open("C")
        let claim = submit("continuous", for: row)
        XCTAssertEqual(claim.sourceFingerprint, cut)
        let awaited = await sync.sync(videos: false)
        XCTAssertTrue(awaited)
        XCTAssertEqual(settlements().map(\.status), [.accepted], "\(settlements())")
        let written = try XCTUnwrap(try record("C"))
        XCTAssertEqual(written.recordingType, .continuous)
        XCTAssertTrue(RecordingTypeClaims.isAttributed(written.recordingTypeBy, to: claim))
        XCTAssertEqual(written.sourceFingerprint, origin, "the record stays bound to the card's file, as the Mac's own confirmation binds it")
        XCTAssertEqual(server.videos.first?.recordingType, "continuous")
    }

    func testAClaimAboutAReplacedClipIsDeclinedAsFileChanged() async throws {
        // The cut clip's bytes change after the claim was made and the Mac publishes the new identity: the identity
        // the claim names is gone.
        let (root, row, _, cut) = try cutProject("C")
        open("C")
        let claim = submit("edited", for: row)
        XCTAssertEqual(claim.sourceFingerprint, cut)
        let clip = root.appendingPathComponent("footage/video_01.mp4")
        try Data("C: the cut clip, re-encoded afterwards".utf8).write(to: clip)
        server.videos[0].sourceFingerprint = ProjectsModel.readFileFingerprint(atPath: clip.path)
        let awaited = await sync.sync(videos: false)
        XCTAssertTrue(awaited)
        XCTAssertEqual(settlements().map(\.status), [.rejected])
        XCTAssertTrue(settlements().first?.reason?.contains("file changed") == true, settlements().first?.reason ?? "")
        XCTAssertNil(try record("C"), "nothing written")
    }

    func testTheLeadsOwnClaimIsAcceptedWithTheFootageAwayFromTheMac() async throws {
        // The footage share away: the clip can't be read. The lead's claim is judged against the identity the phone
        // was given (the row's), as a confirmation on this Mac would be: accepted, bound to the card.
        let (root, row, origin, cut) = try cutProject("C")
        open("C")
        let claim = submit("continuous", for: row)
        try FileManager.default.removeItem(at: root.appendingPathComponent("footage/video_01.mp4"))
        let first = await sync.sync(videos: false)
        XCTAssertTrue(first)
        XCTAssertEqual(settlements().map(\.status), [.accepted], "\(settlements())")
        XCTAssertEqual(claim.sourceFingerprint, cut)
        XCTAssertEqual(try XCTUnwrap(try record("C")).sourceFingerprint, origin)
    }

    func testAnotherLabelersClaimWaitsForTheLeadsCheckThenIsAppliedOrDeclined() async throws {
        let (_, row) = try project("A", videos: ["video_01", "video_02"])
        let second = server.videos[1]
        open("A")
        let theirs = submit("continuous", for: row, by: UUID())
        let declined = submit("edited", for: second, by: UUID())
        let first = await sync.sync(videos: false)
        XCTAssertTrue(first)
        XCTAssertEqual(settlements().count, 0, "nothing settled before the lead looked: \(settlements())")
        XCTAssertNil(try record("A"), "nothing written")
        XCTAssertTrue(sync.status.contains("2 from other labelers waiting for your check"), sync.status)
        // The lead accepts one and declines the other.
        let accepted = await sync.checkClaim(theirs, accept: true)
        XCTAssertNil(accepted)
        let refused = await sync.checkClaim(declined, accept: false)
        XCTAssertNil(refused)
        XCTAssertEqual(server.claims[declined.id]?.status, .rejected)
        XCTAssertEqual(server.claims[declined.id]?.reason, "not accepted on the Mac — choose again if that is wrong")
        let after = await sync.sync(videos: false)
        XCTAssertTrue(after)
        XCTAssertEqual(server.claims[theirs.id]?.status, .accepted)
        let written = try XCTUnwrap(try record("A"))
        XCTAssertEqual(written.recordingType, .continuous)
        XCTAssertTrue(RecordingTypeClaims.isAttributed(written.recordingTypeBy, to: theirs))
        XCTAssertNil(try record("A", video: "video_02"), "the declined choice wrote nothing")
    }

    func testALeadsCheckCoversTheClaimItLookedAtNotAReplacementSentSince() async throws {
        let (_, row) = try project("A")
        open("A")
        let labeler = UUID()
        let looked = submit("continuous", for: row, revision: 1, by: labeler)
        let accepted = await sync.checkClaim(looked, accept: true)
        XCTAssertNil(accepted)
        // The labeler changes their mind before the round: the newer choice supersedes the one the lead accepted.
        server.claims[looked.id]?.status = .superseded
        let newer = submit("edited", for: row, revision: 2, at: now.addingTimeInterval(60), by: labeler)
        let round = await sync.sync(videos: false)
        XCTAssertTrue(round)
        XCTAssertNil(try record("A"), "the replacement was never looked at: nothing written")
        XCTAssertEqual(server.claims[newer.id]?.status, .submitted)
        XCTAssertTrue(sync.status.contains("1 from other labelers waiting for your check"), sync.status)
    }

    func testALostAcknowledgementIsRecoveredByTheNextRoundWithoutASecondWrite() async throws {
        // Fault injection: the settlement after the write is dropped (network lost). The record is on disk, the claim
        // stays submitted; the next round recognises the record and settles without writing again.
        let (_, row, origin, _) = try cutProject("C")
        open("C")
        let claim = submit("continuous", for: row)
        let faulty = LabelingSync(projects: projects, client: server, pendingDirectory: base.appendingPathComponent("pending"), dropFirstSettlement: true)
        let first = await faulty.sync(videos: false)
        XCTAssertFalse(first, faulty.status)
        XCTAssertTrue(faulty.status.hasPrefix("Sync stopped"), faulty.status)
        XCTAssertEqual(settlements().count, 0, "no settlement reached the server")
        XCTAssertEqual(server.claims[claim.id]?.status, .submitted)
        let written = try XCTUnwrap(try record("C"))
        XCTAssertTrue(RecordingTypeClaims.isAttributed(written.recordingTypeBy, to: claim), "the write happened before the ack was lost")
        let before = try snapshot("C")
        // The next round (a fresh sync, as a relaunch would be).
        let second = await sync.sync(videos: false)
        XCTAssertTrue(second)
        XCTAssertEqual(settlements().map(\.status), [.accepted])
        XCTAssertEqual(server.settled.last?.confirmedAt, RecordingTypeClaims.parse(written.recordingTypeAt!))
        XCTAssertEqual(try snapshot("C"), before, "nothing written again")
        XCTAssertEqual(try XCTUnwrap(try record("C")).sourceFingerprint, origin)
    }

    func testAnotherLabelersCheckedClaimWrittenBeforeARelaunchIsAcknowledgedWithoutANewCheck() async throws {
        // The lead's check is in memory; the write happened, the acknowledgement was lost, RallyLab relaunched.
        let (_, row) = try project("A")
        open("A")
        let theirs = submit("continuous", for: row, by: UUID())
        let faulty = LabelingSync(projects: projects, client: server, pendingDirectory: base.appendingPathComponent("pending"), dropFirstSettlement: true)
        let checked = await faulty.checkClaim(theirs, accept: true)
        XCTAssertNil(checked)
        let first = await faulty.sync(videos: false)
        XCTAssertFalse(first, faulty.status)
        XCTAssertTrue(RecordingTypeClaims.isAttributed(try XCTUnwrap(try record("A")).recordingTypeBy, to: theirs))
        XCTAssertEqual(server.claims[theirs.id]?.status, .submitted)
        let before = try snapshot("A")
        // A fresh sync (the relaunch): no check in memory, the record on file carries the claim.
        let second = await sync.sync(videos: false)
        XCTAssertTrue(second, sync.status)
        XCTAssertEqual(server.claims[theirs.id]?.status, .accepted)
        XCTAssertEqual(try snapshot("A"), before, "nothing written again")
    }

    func testTwoReplacementsDuringOneRoundRollBackToTheRecordFromBeforeTheRound() async throws {
        // A (the lead's) is written and replaced by B (the lead's, counts); B is written and replaced by C, another
        // labeler's, unchecked. The record goes back to what it was before the round (none) — never to A.
        let (_, row) = try project("A")
        open("A")
        let a = submit("continuous", for: row)
        server.hold("recordingTypeClaim", at: 1)
        let round = Task { await self.sync.sync(videos: false) }
        let first = await server.arrived()
        XCTAssertTrue(first, "the round never reached the first hold; calls made: \(server.calls)")
        let b = server.phoneReplaces(video: row.id, with: "edited", at: now.addingTimeInterval(30))
        server.release()
        server.hold("recordingTypeClaim", at: 1)   // B's re-check
        let second = await server.arrived()
        XCTAssertTrue(second, "the round never reached the second hold; calls made: \(server.calls)")
        let c = server.phoneReplaces(video: row.id, with: "unknown", at: now.addingTimeInterval(60))
        server.claims[c.id]?.submittedBy = UUID()   // another labeler's
        server.release()
        let ok = await round.value
        XCTAssertTrue(ok, sync.status)
        XCTAssertNil(try record("A"), "neither A nor B is left on file")
        XCTAssertEqual(server.claims[a.id]?.status, .superseded)
        XCTAssertEqual(server.claims[b.id]?.status, .superseded)
        XCTAssertEqual(server.claims[c.id]?.status, .submitted)
    }

    func testAClaimAlreadyWrittenCannotBeDeclinedAndIsAcknowledged() async throws {
        let (_, row) = try project("A")
        open("A")
        let theirs = submit("continuous", for: row, by: UUID())
        let faulty = LabelingSync(projects: projects, client: server, pendingDirectory: base.appendingPathComponent("pending"), dropFirstSettlement: true)
        let checked = await faulty.checkClaim(theirs, accept: true)
        XCTAssertNil(checked)
        let first = await faulty.sync(videos: false)
        XCTAssertFalse(first, faulty.status)
        // Written, not acknowledged: Decline is refused, so the type on file and the server never disagree.
        let refused = await sync.checkClaim(theirs, accept: false)
        XCTAssertEqual(refused?.contains("already applied"), true, refused ?? "")
        XCTAssertEqual(server.claims[theirs.id]?.status, .submitted)
        let second = await sync.sync(videos: false)
        XCTAssertTrue(second, sync.status)
        XCTAssertEqual(server.claims[theirs.id]?.status, .accepted)
    }

    func testADeclineThatLandsWhileTheAcceptedClaimIsWrittenTakesTheWriteOff() async throws {
        let (_, row) = try project("A")
        open("A")
        let theirs = submit("continuous", for: row, by: UUID())
        let checked = await sync.checkClaim(theirs, accept: true)
        XCTAssertNil(checked)
        server.hold("recordingTypeClaim", at: 1)
        let round = Task { await self.sync.sync(videos: false) }
        let reached = await server.arrived()
        XCTAssertTrue(reached, "the round never reached the hold; calls made: \(server.calls)")
        // The lead changes their mind on another window: declined on the server before the Mac writes.
        let declined = await sync.checkClaim(theirs, accept: false)
        XCTAssertNil(declined)
        server.release()
        let ok = await round.value
        XCTAssertTrue(ok, sync.status)
        XCTAssertEqual(server.claims[theirs.id]?.status, .rejected)
        XCTAssertNil(try record("A"), "the declined choice is not left on file")
    }

    func testAnExplicitUnknownIsAcceptedAndEstablishesNothing() async throws {
        let (_, row) = try project("A")
        open("A")
        submit("unknown", for: row)
        let awaited2 = await sync.sync(videos: false)
        XCTAssertTrue(awaited2)
        let written = try XCTUnwrap(try record("A"))
        XCTAssertEqual(written.recordingType, .unknown)
        XCTAssertEqual(settlements().map(\.status), [.accepted])
        let assessed = TrainingEligibility.assess(admission: .admitted, properties: written)
        XCTAssertEqual(assessed.fullVideoNegatives.level, .notAssessed, "unknown yields no ordinary negatives")
        XCTAssertEqual(assessed[.rallyClassifier].level, .notAssessed)
    }

    func testAnEditedClaimRestrictsTheTemporalModelsAndTheNegatives() async throws {
        let (_, row) = try project("A")
        open("A")
        submit("edited", for: row)
        let awaited3 = await sync.sync(videos: false)
        XCTAssertTrue(awaited3)
        let assessed = TrainingEligibility.assess(admission: .admitted, properties: try XCTUnwrap(try record("A")))
        XCTAssertEqual(assessed[.rallyClassifier].level, .restricted); XCTAssertEqual(assessed[.netDetector].level, .standard)
        XCTAssertEqual(assessed.fullVideoNegatives.level, .restricted)
    }

    // MARK: - Declining

    func testAStaleFingerprintAWithheldRecordingAndAMissingRecordingAreDeclinedWithoutAWrite() async throws {
        let (root, row) = try project("A")
        open("A")
        submit("continuous", for: row, fingerprint: "file:old", revision: 1)
        let awaited4 = await sync.sync(videos: false)
        XCTAssertTrue(awaited4)
        XCTAssertNil(try record("A"))
        XCTAssertEqual(settlements().map(\.reason), ["the recording's file changed since this was sent — confirm again"])
        XCTAssertEqual(settlements().map(\.status), [.rejected])
        // Withheld on the Mac (the L2 closure): declined whatever the fingerprint.
        let dir = root.appendingPathComponent("pipeline_tuning", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(PipelineTuner.ValidationSet(tune: [], holdout: [], finalTest: ["video_01"])).write(to: dir.appendingPathComponent("validation.json"))
        server.claims = [:]; server.settled = []
        submit("continuous", for: row, revision: 2)
        let awaited5 = await sync.sync(videos: false)
        XCTAssertTrue(awaited5)
        XCTAssertNil(try record("A"))
        XCTAssertEqual(settlements().map(\.reason), ["this recording is withheld from labeling on the Mac"])
        // A recording the project does not have: declined.
        try FileManager.default.removeItem(at: dir)
        server.claims = [:]; server.settled = []
        var other = row; other.id = UUID(); other.sessionName = "video_99"
        server.videos.append(other)
        submit("continuous", for: other, fingerprint: "file:x")
        let awaited6 = await sync.sync(videos: false)
        XCTAssertTrue(awaited6)
        XCTAssertEqual(settlements().map(\.reason), ["the recording is not in the project on the Mac"])
        XCTAssertTrue(sync.status.contains("0 confirmed · 1 declined"), sync.status)
    }

    func testANewerDecisionOnTheMacWinsAndIsNeverDowngradedByAStaleClaim() async throws {
        let (root, row) = try project("A")
        let opening = open("A")
        // Confirmed on the Mac an hour after the phone's claim was made (the claim arrives late).
        let settled = await sync.sync(videos: false)
        XCTAssertTrue(settled)
        submit("unknown", for: row, at: now.addingTimeInterval(-3600))
        try FootageTypeConfirmation.confirm(.edited, video: "video_01", under: opening, projects: projects, by: "BW", at: "2026-11-04T10:00:00Z")
        let before = try snapshot("A")
        let awaited7 = await sync.sync(videos: false)
        XCTAssertTrue(awaited7)
        XCTAssertEqual(try snapshot("A"), before, "the Mac's record untouched")
        XCTAssertEqual(try record("A")?.recordingType, .edited)
        XCTAssertEqual(settlements().map(\.reason), ["confirmed on the Mac as edited recording after this was sent — confirm again if that is wrong"])
        _ = root
    }

    func testTwoClaimsStillSubmittedForOneRecordingTheNewerCountsTheOlderIsDeclinedAsReplaced() async throws {
        let (_, row) = try project("A")
        open("A")
        let older = submit("continuous", for: row, revision: 1, at: now)
        let newer = submit("edited", for: row, revision: 2, at: now.addingTimeInterval(60))
        let awaited8 = await sync.sync(videos: false)
        XCTAssertTrue(awaited8)
        XCTAssertEqual(try record("A")?.recordingType, .edited)
        XCTAssertTrue(RecordingTypeClaims.isAttributed(try record("A")?.recordingTypeBy, to: newer))
        XCTAssertEqual(server.settled.map { ($0.id, $0.status) }.map { "\($0.0 == older.id ? "older" : "newer"):\($0.1.rawValue)" }, ["older:rejected", "newer:accepted"])
        XCTAssertEqual(server.settled.first?.reason, "replaced by a newer choice")
    }

    // MARK: - The Mac's own state: deferred, retried, recovered

    func testAnUnreadableRecordDefersTheClaimAndWritesNothing() async throws {
        let (root, row) = try project("A")
        open("A")
        try FileManager.default.createDirectory(at: FootageProperties.directory(in: root), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: recordURL("A"))
        let settled = await sync.sync(videos: false)
        XCTAssertTrue(settled)
        submit("continuous", for: row)
        let before = try snapshot("A")
        let awaited9 = await sync.sync(videos: false)
        XCTAssertTrue(awaited9)
        XCTAssertEqual(try snapshot("A"), before, "nothing written over an unreadable record")
        XCTAssertTrue(server.settled.isEmpty, "left submitted for the next round")
        XCTAssertEqual(server.claims.values.first?.status, .submitted)
        XCTAssertTrue(sync.status.contains("left for the next sync: video_01: the recording's footage record can't be read on the Mac"), sync.status)
    }

    func testAWriteWhoseAcknowledgementWasLostIsRecognisedNextRoundAndNotWrittenAgain() async throws {
        let (_, row) = try project("A")
        open("A")
        let claim = submit("continuous", for: row)
        // The settlement fails once (the connection dropped after the write): the round stops there.
        server.failures["settleRecordingTypeClaim"] = URLError(.networkConnectionLost)
        let awaited10 = await sync.sync(videos: false)
        XCTAssertFalse(awaited10)
        let written = try XCTUnwrap(try record("A"))
        XCTAssertTrue(RecordingTypeClaims.isAttributed(written.recordingTypeBy, to: claim))
        XCTAssertEqual(server.claims[claim.id]?.status, .submitted, "the server never heard")
        let bytes = try Data(contentsOf: recordURL("A"))
        // The next round finds the claim on file: acknowledged, the record untouched (byte for byte).
        let awaited11 = await sync.sync(videos: false)
        XCTAssertTrue(awaited11)
        XCTAssertEqual(settlements().map(\.status), [.accepted])
        XCTAssertEqual(server.settled.last?.confirmedAt, now)
        XCTAssertEqual(try Data(contentsOf: recordURL("A")), bytes)
        XCTAssertEqual(server.claims[claim.id]?.status, .accepted)
        // A third round: nothing submitted, nothing settled again.
        let awaited12 = await sync.sync(videos: false)
        XCTAssertTrue(awaited12)
        XCTAssertEqual(server.settled.count, 1)
    }

    func testAConfirmationMadeOnTheMacBetweenTwoSettlementsIsNotOverwrittenByTheLaterClaim() async throws {
        let (_, row1) = try project("A", videos: ["video_01", "video_02"])
        let opening = open("A")
        let row2 = try XCTUnwrap(server.videos.first { $0.sessionName == "video_02" })
        submit("continuous", for: row1)
        submit("continuous", for: row2)
        // The round takes the recordings in the order of their ids; it parks while the server settles the first one's
        // claim, and meanwhile the owner confirms the second on the Mac.
        let ordered = [row1, row2].sorted { $0.id.uuidString < $1.id.uuidString }
        let first = ordered[0].sessionName!, later = ordered[1].sessionName!
        server.hold("settleRecordingTypeClaim", at: 1)
        let round = Task { await self.sync.sync(videos: false) }
        let reached = await server.arrived()
        XCTAssertTrue(reached, "the round never reached the hold; calls made: \(server.calls)")
        try FootageTypeConfirmation.confirm(.edited, video: later, under: opening, projects: projects, by: "BW", at: EventReview.stamp(now.addingTimeInterval(60)))
        server.release()
        let ok = await round.value
        XCTAssertTrue(ok)
        XCTAssertEqual(try record("A", video: first)?.recordingType, .continuous, "the first claim applied")
        let second = try XCTUnwrap(try record("A", video: later))
        XCTAssertEqual(second.recordingType, .edited, "the Mac's newer decision stands")
        XCTAssertEqual(second.recordingTypeBy, "BW")
        XCTAssertEqual(settlements().map(\.status), [.accepted, .rejected])
        XCTAssertEqual(settlements().last?.reason, "confirmed on the Mac as edited recording after this was sent — confirm again if that is wrong")
    }

    func testThePublishedTypeFollowsTheRecordAndIsClearedWithAnExplicitNullWhenTheRecordIsGone() async throws {
        // A recording the videos round publishes (its name carries the surface, as project recordings' do).
        let (root, row) = try project("A", videos: ["bch_v01"])
        let opening = open("A")
        // A type published earlier, no record on the Mac any more: cleared explicitly, not left as it was.
        server.videos[0].recordingType = "edited"
        server.videos[0].recordingTypeAt = now
        server.videos[0].updatedAt = now
        let first = await sync.sync(videos: true)
        XCTAssertTrue(first, sync.status)
        XCTAssertEqual(server.cleared, [row.id])
        XCTAssertNil(server.videos[0].recordingType); XCTAssertNil(server.videos[0].recordingTypeAt)
        XCTAssertNotEqual(server.videos[0].updatedAt, now, "the clearing dates the row, so a phone's pull of the rows changed since sees it")
        // A record left by a file replaced under the same name (bound to another fingerprint) is not this file's: not published, cleared.
        try FootageProperties.Store(root: root).save(FootageProperties.File(video: "bch_v01", sourceFingerprint: "file:other", recordingType: .continuous,
                                                                             recordingTypeBy: "BW", recordingTypeAt: "2026-11-04T09:00:00Z", updatedAt: "2026-11-04T09:00:00Z"))
        server.videos[0].recordingType = "continuous"
        let replaced = await sync.sync(videos: true)
        XCTAssertTrue(replaced, sync.status)
        XCTAssertNil(server.videos[0].recordingType, "another file's record is not this recording's type")
        XCTAssertEqual(server.cleared.count, 2)
        // A confirmation on the Mac is published with its time; nothing is cleared again.
        try FootageTypeConfirmation.confirm(.continuous, video: "bch_v01", under: opening, projects: projects, by: "BW", at: "2026-11-04T11:00:00Z")
        let second = await sync.sync(videos: true)
        XCTAssertTrue(second, sync.status)
        XCTAssertEqual(server.videos[0].recordingType, "continuous")
        XCTAssertEqual(server.videos[0].recordingTypeAt, RecordingTypeClaims.parse("2026-11-04T11:00:00Z"))
        XCTAssertEqual(server.cleared.count, 2)
        // An unreadable record leaves what was published as it is.
        try Data("{ not json".utf8).write(to: recordURL("A", video: "bch_v01"))
        let third = await sync.sync(videos: true)
        XCTAssertTrue(third, sync.status)
        XCTAssertEqual(server.videos[0].recordingType, "continuous")
        XCTAssertEqual(server.cleared.count, 2)
        _ = root
    }

    // MARK: - A replacement from the phone while the round runs

    func testAClaimSupersededWhileTheRoundAwaitsIsNotWrittenAndTheReplacementIsAppliedInTheSameRound() async throws {
        let (_, row1) = try project("A", videos: ["video_01", "video_02"])
        open("A")
        let row2 = try XCTUnwrap(server.videos.first { $0.sessionName == "video_02" })
        submit("continuous", for: row1)
        let old = submit("continuous", for: row2)
        let ordered = [row1, row2].sorted { $0.id.uuidString < $1.id.uuidString }
        let later = ordered[1]
        // The round parks while the server settles the first recording's claim; meanwhile the phone replaces the
        // second's choice (the server supersedes the waiting claim and records the new one).
        server.hold("settleRecordingTypeClaim", at: 1)
        let round = Task { await self.sync.sync(videos: false) }
        let reached = await server.arrived()
        XCTAssertTrue(reached, "the round never reached the hold; calls made: \(server.calls)")
        let replacement = server.phoneReplaces(video: later.id, with: "edited", at: now.addingTimeInterval(30))
        server.release()
        let ok = await round.value
        XCTAssertTrue(ok, sync.status)
        let laterName = later.sessionName!
        let written = try XCTUnwrap(try record("A", video: laterName))
        XCTAssertEqual(written.recordingType, .edited, "the replacement, not the superseded choice")
        XCTAssertTrue(RecordingTypeClaims.isAttributed(written.recordingTypeBy, to: replacement))
        let superseded = later.id == row2.id ? old : nil
        if let superseded { XCTAssertFalse(RecordingTypeClaims.isAttributed(written.recordingTypeBy, to: superseded)) }
        XCTAssertEqual(settlements().map(\.status), [.accepted, .accepted])
        XCTAssertEqual(server.settled.last?.id, replacement.id)
        XCTAssertTrue(sync.status.contains("2 confirmed · 0 declined"), sync.status)
    }

    func testACheckedClaimReplacedAsItIsSettledIsTakenOffAndTheUncheckedReplacementWaits() async throws {
        // Another labeler's choice, accepted by the lead; the labeler replaces it while the Mac re-checks it. The Mac
        // writes the checked choice, the settlement comes back a conflict, and the replacement has not been looked at:
        // the record goes back to what it was (none), and the replacement waits for the lead.
        let (_, row) = try project("A")
        open("A")
        let labeler = UUID()
        let old = submit("continuous", for: row, by: labeler)
        let checked = await sync.checkClaim(old, accept: true)
        XCTAssertNil(checked)
        server.hold("recordingTypeClaim", at: 1)
        let round = Task { await self.sync.sync(videos: false) }
        let reached = await server.arrived()
        XCTAssertTrue(reached, "the round never reached the hold; calls made: \(server.calls)")
        let replacement = server.phoneReplaces(video: row.id, with: "edited", at: now.addingTimeInterval(30))
        server.release()
        let ok = await round.value
        XCTAssertTrue(ok, sync.status)
        XCTAssertNil(try record("A"), "the replaced choice is not left on file")
        XCTAssertEqual(server.claims[replacement.id]?.status, .submitted)
        XCTAssertEqual(server.claims[old.id]?.status, .superseded)
        XCTAssertTrue(sync.status.contains("1 from other labelers waiting for your check"), sync.status)
        // Declining the replacement leaves nothing confirmed.
        let declined = await sync.checkClaim(replacement, accept: false)
        XCTAssertNil(declined)
        let after = await sync.sync(videos: false)
        XCTAssertTrue(after)
        XCTAssertNil(try record("A"))
    }

    func testACheckMadeWhileARoundRunsIsKeptForTheNextRound() async throws {
        let (_, row) = try project("A", videos: ["video_01", "video_02"])
        let second = server.videos[1]
        open("A")
        submit("continuous", for: row)   // the lead's own: the round works on it
        server.hold("recordingTypeClaim", at: 1)
        let round = Task { await self.sync.sync(videos: false) }
        let reached = await server.arrived()
        XCTAssertTrue(reached, "the round never reached the hold; calls made: \(server.calls)")
        // Meanwhile another labeler's choice arrives and the lead accepts it.
        let theirs = submit("edited", for: second, by: UUID())
        let checked = await sync.checkClaim(theirs, accept: true)
        XCTAssertNil(checked)
        server.release()
        let ok = await round.value
        XCTAssertTrue(ok, sync.status)
        let next = await sync.sync(videos: false)
        XCTAssertTrue(next, sync.status)
        XCTAssertEqual(server.claims[theirs.id]?.status, .accepted, "the check survived the round that was running when it was made")
        XCTAssertEqual(try XCTUnwrap(try record("A", video: "video_02")).recordingType, .edited)
    }

    func testASupersessionThatLandsBetweenTheCheckAndTheSettlementIsAnsweredByApplyingTheReplacement() async throws {
        let (_, row) = try project("A")
        open("A")
        let old = submit("continuous", for: row)
        // The reply to the claim's re-check is parked; meanwhile the phone replaces the choice. The Mac, told the claim
        // is still waiting, writes it — and the settlement comes back a conflict: the replacement is applied at once.
        server.hold("recordingTypeClaim", at: 1)
        let round = Task { await self.sync.sync(videos: false) }
        let reached = await server.arrived()
        XCTAssertTrue(reached, "the round never reached the hold; calls made: \(server.calls)")
        let replacement = server.phoneReplaces(video: row.id, with: "unknown", at: now.addingTimeInterval(30))
        server.release()
        let ok = await round.value
        XCTAssertTrue(ok, sync.status)
        let written = try XCTUnwrap(try record("A"))
        XCTAssertEqual(written.recordingType, .unknown, "the replacement took the record over in the same round")
        XCTAssertTrue(RecordingTypeClaims.isAttributed(written.recordingTypeBy, to: replacement))
        XCTAssertFalse(RecordingTypeClaims.isAttributed(written.recordingTypeBy, to: old))
        XCTAssertEqual(settlements().map(\.status), [.accepted], "the superseded claim's settlement was refused, the replacement's accepted")
        XCTAssertEqual(server.settled.last?.id, replacement.id)
        XCTAssertEqual(server.calls.filter { $0 == "settleRecordingTypeClaim" }.count, 2)
        XCTAssertEqual(server.claims[old.id]?.status, .superseded)
    }

    // MARK: - The opening (A → B → A)

    func testAClaimIsWrittenOnlyUnderTheOpeningTheRoundStartedFor() async throws {
        let (_, rowA) = try project("A"); try project("B")
        open("A")
        submit("continuous", for: rowA)
        // The round is parked while the server answers with the claims; the project switches to B meanwhile.
        server.hold("recordingTypeClaims", cancellable: true)
        let round = Task { await self.sync.sync(videos: false) }
        let awaited13 = await server.arrived()
        XCTAssertTrue(awaited13, "the round never reached the hold; calls made: \(server.calls)")
        _ = open("B")
        server.release()
        let awaited14 = await round.value
        XCTAssertFalse(awaited14)
        XCTAssertNil(try record("A"), "nothing written into A after its opening ended")
        XCTAssertNil(try record("B"), "nothing written into B, whose name matches")
        XCTAssertTrue(server.settled.isEmpty)
        XCTAssertEqual(server.claims.values.first?.status, .submitted)
        XCTAssertEqual(sync.status, LabelingSync.stopped("A"))
        // A opened again is another opening: its own round applies the claim, into A alone.
        _ = open("A")
        let awaited15 = await sync.sync(videos: false)
        XCTAssertTrue(awaited15)
        XCTAssertEqual(try record("A")?.recordingType, .continuous)
        XCTAssertNil(try record("B"))
        XCTAssertEqual(settlements().map(\.status), [.accepted])
    }

    func testBsClaimIsNotAsAndAsRoundLeavesBAlone() async throws {
        let (_, rowA) = try project("A"); let (_, rowB) = try project("B")
        open("A")
        submit("continuous", for: rowA)
        submit("edited", for: rowB)
        let awaited16 = await sync.sync(videos: false)
        XCTAssertTrue(awaited16)
        XCTAssertEqual(try record("A")?.recordingType, .continuous)
        XCTAssertNil(try record("B"), "B's claim waits for a round of B")
        XCTAssertEqual(server.settled.count, 1)
        _ = open("B")
        let awaited17 = await sync.sync(videos: false)
        XCTAssertTrue(awaited17)
        XCTAssertEqual(try record("B")?.recordingType, .edited)
        XCTAssertEqual(server.settled.count, 2)
    }
}
