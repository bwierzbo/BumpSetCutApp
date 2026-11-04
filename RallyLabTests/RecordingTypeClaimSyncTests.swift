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
    private func project(_ name: String) throws -> (root: URL, row: LabelVideo) {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        let footage = root.appendingPathComponent("footage/video_01.mp4")
        try Data("\(name): video_01 footage".utf8).write(to: footage)
        let store = DatasetStore(root: root)
        try store.prepare()
        var session = VideoSession(name: "video_01", sourcePath: footage.path, split: "train", addedAt: now, frames: [])
        session.cuts = [CutRange(start: 0, end: 12)]
        session.ralliesMarked = true
        try store.save(session)
        let fingerprint = ProjectsModel.readFileFingerprint(atPath: footage.path)
        let card = SourceRegistryTests.clip("card_0", number: 1, videos: [SourceRegistryTests.video("video_01", fingerprint: fingerprint)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: name, createdAt: now, framesPerRally: 2, clips: [card])).write(to: root.appendingPathComponent("project.json"))
        try JSONEncoder().encode([RallyMarkRecord(startTime: 30, endTime: 36, kind: .rally, contacts: nil)]).write(to: RallyMarkModel.labelsURL(for: footage), options: .atomic)
        let row = LabelVideo(id: UUID(), project: name, sessionName: "video_01", title: "", surface: .beach, camera: .endlineGround, lighting: "",
                             split: "train", clipPath: "rallylab/\(name)/video_01-v3.mp4", duration: 300, ralliesFound: [], status: .rallylab, updatedAt: now,
                             frameTimesDigest: nil, sourceFingerprint: fingerprint)
        server.videos.append(row)
        return (root, row)
    }

    private func fingerprint(_ name: String) -> String { ProjectsModel.readFileFingerprint(atPath: base.appendingPathComponent("\(name)/footage/video_01.mp4").path)! }

    @discardableResult
    private func submit(_ kind: String, for row: LabelVideo, fingerprint: String? = nil, revision: Int = 1, at: Date? = nil) -> RecordingTypeClaim {
        let claim = RecordingTypeClaim(id: UUID(), videoId: row.id, project: row.project!, sessionName: row.sessionName!,
                                       sourceFingerprint: fingerprint ?? row.sourceFingerprint!, recordingType: kind, revision: revision, status: .submitted,
                                       reason: nil, submittedBy: UUID(), submittedAt: at ?? now, settledBy: nil, settledAt: nil, updatedAt: at ?? now)
        server.claims[claim.id] = claim
        return claim
    }

    private func record(_ name: String) throws -> FootageProperties.File? {
        try FootageProperties.Store(root: base.appendingPathComponent(name)).load("video_01")
    }

    private func recordURL(_ name: String) -> URL { FootageProperties.url(in: base.appendingPathComponent(name), video: "video_01") }

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
