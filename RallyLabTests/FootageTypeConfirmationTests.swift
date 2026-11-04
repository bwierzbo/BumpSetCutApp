//
//  FootageTypeConfirmationTests.swift
//  RallyLabTests
//
//  The footage-type step at the end of the marking pass (D-032): the facts
//  keep completion, the confirmed type, verified coverage and eligibility
//  apart; a cut never characterises a recording; confirming continuous,
//  edited or unknown writes the type and nothing else, keeps the record's
//  spans, refuses over an unreadable record, and lands in the project the
//  recording was marked in, only while that opening holds (A → B → A).
//

import CryptoKit
import XCTest
@testable import RallyLab

@MainActor
final class FootageTypeConfirmationTests: XCTestCase {
    private var base: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var sampler: SamplerModel!
    private var projects: ProjectsModel!
    private let at = "2026-11-03T22:00:00Z"

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ftc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
        suite = "RallyLabTests.FootageTypeConfirmation.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        sampler = SamplerModel(defaults: defaults, root: base.appendingPathComponent("empty"))
        projects = ProjectsModel(sampler: sampler, defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixture

    /// A project with one recording: a footage file, its card with the file's fingerprint, its session (with the cuts
    /// and the declaration asked for) and a rally-marks file beside the footage.
    @discardableResult
    private func project(_ name: String, cuts: [CutRange]? = nil, marked: Bool? = nil) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        let footage = self.footage(name)
        try Data("\(name): video_01 footage".utf8).write(to: footage)
        let store = DatasetStore(root: root)
        try store.prepare()
        var session = VideoSession(name: "video_01", sourcePath: footage.path, split: "train", addedAt: Date(), frames: [])
        session.cuts = cuts
        session.ralliesMarked = marked
        try store.save(session)
        let card = SourceRegistryTests.clip("card_0", number: 1, videos: [SourceRegistryTests.video("video_01", fingerprint: fingerprint(name))])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: name, createdAt: Date(), framesPerRally: 2, clips: [card])).write(to: root.appendingPathComponent("project.json"))
        try JSONEncoder().encode([RallyMarkRecord(startTime: 30, endTime: 36, kind: .rally, contacts: nil)])
            .write(to: RallyMarkModel.labelsURL(for: footage), options: .atomic)
        return root
    }

    private func footage(_ name: String) -> URL { base.appendingPathComponent("\(name)/footage/video_01.mp4") }
    private func fingerprint(_ name: String) -> String? { ProjectsModel.readFileFingerprint(atPath: footage(name).path) }
    private func recording(_ name: String) -> FootageTypeConfirmation.Recording {
        FootageTypeConfirmation.Recording(try! DatasetStore(root: base.appendingPathComponent(name)).loadSessionsStrict().first { $0.name == "video_01" }!)
    }
    private func recordURL(_ name: String) -> URL { FootageProperties.url(in: base.appendingPathComponent(name), video: "video_01") }

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

    private func open(_ name: String) -> ProjectsModel.Opening {
        projects.open(base.appendingPathComponent(name, isDirectory: true))
        return projects.opening!
    }

    // MARK: - The facts

    func testTheFactsKeepCompletionTheTypeVerifiedCoverageAndEligibilityApart() throws {
        // Cuts raw as marked (out of order), the pass declared complete, no footage record, no Stage 1 record.
        let root = try project("A", cuts: [CutRange(start: 141.6, end: 157), CutRange(start: 0, end: 12.4)], marked: true)
        var f = FootageTypeConfirmation.facts(recording("A"), sourceFingerprint: fingerprint("A"), in: root)
        XCTAssertEqual(f.cuts, [CutRange(start: 0, end: 12.4), CutRange(start: 141.6, end: 157)])
        XCTAssertEqual(f.cutSeconds, 27.8, accuracy: 0.001)
        XCTAssertTrue(f.ralliesMarked, "every visible rally marked — the declaration")
        XCTAssertNil(f.record); XCTAssertEqual(f.recordingType, .unknown, "complete, and the type not confirmed: two facts")
        XCTAssertNil(f.verifiedCoverage); XCTAssertFalse(f.stage1Complete)
        XCTAssertNil(f.recordProblem); XCTAssertNil(f.stage1Problem)
        XCTAssertEqual(f.sourceFingerprint, fingerprint("A"))
        // The player's length bounds the cut seconds when there is no Stage 1 record.
        f = FootageTypeConfirmation.facts(recording("A"), sourceFingerprint: fingerprint("A"), duration: 150, in: root)
        XCTAssertEqual(f.cutSeconds, 12.4 + 8.4, accuracy: 0.001)

        // Eligibility is the policy's, previewed for each choice: unknown establishes nothing — no ordinary negatives
        // however complete the marks; continuous does; edited restricts the temporal models and the negatives.
        let unknown = FootageTypeConfirmation.preview(.unknown, facts: f, admission: .admitted, at: at)
        XCTAssertEqual(unknown.fullVideoNegatives.level, .notAssessed)
        XCTAssertEqual(unknown[.rallyClassifier].level, .notAssessed)
        let continuous = FootageTypeConfirmation.preview(.continuous, facts: f, admission: .admitted, at: at)
        XCTAssertEqual(continuous.fullVideoNegatives.level, .standard)
        for m in TrainingEligibility.Model.allCases { XCTAssertEqual(continuous[m].level, .standard, m.rawValue) }
        let edited = FootageTypeConfirmation.preview(.edited, facts: f, admission: .admitted, at: at)
        XCTAssertEqual(edited.fullVideoNegatives.level, .restricted)
        XCTAssertEqual(edited[.rallyClassifier].level, .restricted)
        XCTAssertEqual(edited[.ballDetector].level, .restricted)
        XCTAssertEqual(edited[.netDetector].level, .standard)
        // A withheld recording is ineligible whatever is confirmed.
        XCTAssertEqual(FootageTypeConfirmation.preview(.continuous, facts: f, admission: .withheld, at: at)[.rallyClassifier].level, .ineligible)

        // A Stage 1 record verifies the timeline's coverage — over the footage, less the cuts.
        let stage1 = EventReview.File(video: "video_01", sourceFingerprint: ProjectsModel.fileFingerprint(atPath: footage("A").path), frameRate: 30,
                                      durationSec: 150, tool: "t", coverage: [EventReview.Coverage(start: 0, end: 80, at: at, annotator: "BW")])
        try EventReview.write(stage1, to: EventReview.url(forVideo: footage("A")))
        f = FootageTypeConfirmation.facts(recording("A"), sourceFingerprint: fingerprint("A"), in: root)
        XCTAssertEqual(f.durationSec, 150)
        XCTAssertEqual(f.cutSeconds, 20.8, accuracy: 0.001)
        // Reviewed 0–80 less the cut 0–12.4 = 67.6 s of 150 − 20.8 = 129.2 s of footage.
        XCTAssertEqual(try XCTUnwrap(f.verifiedCoverage), 67.6 / 129.2, accuracy: 0.001)
        XCTAssertFalse(f.stage1Complete)
        XCTAssertTrue(f.ralliesMarked, "the declaration and the verified coverage are different facts")
        XCTAssertEqual(f.recordingType, .unknown, "and neither confirms the type")
    }

    func testMarkingACutNeverCharacterisesTheRecording() throws {
        let root = try project("A")
        open("A")
        // The pass marks a cut (the clip starts mid-rally; a replay): the session takes it, no record is written.
        sampler.setCuts([CutRange(start: 0, end: 12), CutRange(start: 135, end: 147)], session: "video_01")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FootageProperties.directory(in: root).path), "no footage-properties record from a cut")
        let f = FootageTypeConfirmation.facts(recording("A"), sourceFingerprint: fingerprint("A"), in: root)
        XCTAssertEqual(f.cuts.count, 2)
        XCTAssertEqual(f.recordingType, .unknown, "a cut is an exclusion, not a classification as edited")
        XCTAssertEqual(FootageTypeConfirmation.preview(.unknown, facts: f, admission: .admitted, at: at).fullVideoNegatives.level, .notAssessed)
        // Nor does finishing the pass.
        sampler.setRalliesMarked(true, session: "video_01")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FootageProperties.directory(in: root).path))
        XCTAssertEqual(FootageTypeConfirmation.facts(recording("A"), sourceFingerprint: fingerprint("A"), in: root).recordingType, .unknown)
    }

    // MARK: - Confirming

    func testConfirmingWritesTheTypeWhoAndWhenAndNothingElseChanges() throws {
        let root = try project("A", cuts: [CutRange(start: 0, end: 12)], marked: true)
        let opening = open("A")
        let before = try snapshot("A")
        for type in [FootageProperties.RecordingType.continuous, .edited, .unknown] {
            let stamp = "\(at)-\(type.rawValue)"
            let written = try FootageTypeConfirmation.confirm(type, video: "video_01", under: opening, projects: projects, by: "BW", at: stamp)
            XCTAssertEqual(written.recordingType, type)
            XCTAssertEqual(written.recordingTypeBy, "BW")
            XCTAssertEqual(written.recordingTypeAt, stamp)
            XCTAssertEqual(written.updatedAt, stamp)
            XCTAssertEqual(written.sourceFingerprint, fingerprint("A"), "bound to the card's file")
            XCTAssertTrue(written.spans.isEmpty); XCTAssertNil(written.derivedFrom)
            XCTAssertEqual(try FootageProperties.Store(root: root).load("video_01"), written)
            let after = try snapshot("A")
            XCTAssertEqual(after.filter { !$0.key.hasSuffix("/footage-properties/video_01.json") }, before, "every other file byte-identical")
            XCTAssertEqual(after.count, before.count + 1)
            // The facts read it back as the type on file; the cuts and the declaration are untouched by it.
            let f = FootageTypeConfirmation.facts(recording("A"), sourceFingerprint: fingerprint("A"), in: root)
            XCTAssertEqual(f.recordingType, type)
            XCTAssertEqual(f.cuts, [CutRange(start: 0, end: 12)]); XCTAssertTrue(f.ralliesMarked)
            // And the policy judges the type as confirmed: continuous gives ordinary negatives, edited and unknown never.
            let negatives = TrainingEligibility.assess(admission: .admitted, properties: written).fullVideoNegatives.level
            XCTAssertEqual(negatives, type == .continuous ? .standard : type == .edited ? .restricted : .notAssessed, type.rawValue)
        }
    }

    func testChangingAConfirmedTypeKeepsTheRecordsSpansAndDerivation() throws {
        let root = try project("A")
        let opening = open("A")
        let span = FootageProperties.Span(id: UUID(), start: 83, end: 85.5, traits: [.slowMotion], origin: .confirmed, confidence: nil, source: "BW",
                                          note: nil, at: at, by: "BW", rejectedAt: nil)
        let derived = FootageProperties.Derivation(parent: "src:youtube:abc", relation: .highlight, note: nil)
        try FootageProperties.Store(root: root).save(FootageProperties.File(video: "video_01", sourceFingerprint: fingerprint("A"), recordingType: .continuous,
                                                                             recordingTypeBy: "BW", recordingTypeAt: at, spans: [span], derivedFrom: derived, updatedAt: at))
        let f = FootageTypeConfirmation.facts(recording("A"), sourceFingerprint: fingerprint("A"), in: root)
        XCTAssertEqual(f.recordingType, .continuous)
        XCTAssertEqual(f.record?.recordingTypeBy, "BW")
        // Looked at again and found edited: only the type, who and when change.
        let later = "2026-11-04T09:00:00Z"
        let changed = try FootageTypeConfirmation.confirm(.edited, video: "video_01", under: opening, projects: projects, by: "BW2", at: later)
        XCTAssertEqual(changed.recordingType, .edited)
        XCTAssertEqual(changed.recordingTypeBy, "BW2"); XCTAssertEqual(changed.recordingTypeAt, later); XCTAssertEqual(changed.updatedAt, later)
        XCTAssertEqual(changed.spans, [span]); XCTAssertEqual(changed.derivedFrom, derived)
        XCTAssertEqual(changed.sourceFingerprint, fingerprint("A"))
        XCTAssertEqual(TrainingEligibility.assess(admission: .admitted, properties: changed)[.rallyClassifier].level, .restricted)
        // A record without a fingerprint (an earlier writer) is bound to the card's file by the confirmation.
        try FootageProperties.Store(root: root).save(FootageProperties.File(video: "video_01", sourceFingerprint: nil, recordingType: .unknown, spans: [span], updatedAt: at))
        let bound = try FootageTypeConfirmation.confirm(.continuous, video: "video_01", under: opening, projects: projects, by: "BW", at: later)
        XCTAssertEqual(bound.sourceFingerprint, fingerprint("A")); XCTAssertEqual(bound.spans, [span])
    }

    func testAnUnreadableRecordRefusesTheConfirmation() throws {
        let root = try project("A")
        let opening = open("A")
        try FileManager.default.createDirectory(at: FootageProperties.directory(in: root), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: recordURL("A"))
        let before = try snapshot("A")
        let f = FootageTypeConfirmation.facts(recording("A"), sourceFingerprint: fingerprint("A"), in: root)
        XCTAssertNotNil(f.recordProblem); XCTAssertNil(f.record)
        XCTAssertEqual(f.recordingType, .unknown)
        XCTAssertEqual(FootageTypeConfirmation.preview(.continuous, facts: f, admission: .admitted, at: at)[.rallyClassifier].level, .quarantined,
                       "an unreadable record fails closed whatever would be confirmed")
        XCTAssertThrowsError(try FootageTypeConfirmation.confirm(.continuous, video: "video_01", under: opening, projects: projects, by: "BW", at: at))
        XCTAssertEqual(try snapshot("A"), before, "nothing written over it")
    }

    func testARecordNamingAnotherRecordingIsRefusedAndNothingIsWrittenToEitherPath() throws {
        let root = try project("A")
        let opening = open("A")
        // footage-properties/video_01.json holds a decodable record that names video_02 (no fingerprint).
        try FileManager.default.createDirectory(at: FootageProperties.directory(in: root), withIntermediateDirectories: true)
        let stray = FootageProperties.File(video: "video_02", sourceFingerprint: nil, recordingType: .edited, spans: [], updatedAt: at)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stray).write(to: recordURL("A"))
        let before = try snapshot("A")
        XCTAssertThrowsError(try FootageProperties.Store(root: root).load("video_01"))
        let f = FootageTypeConfirmation.facts(recording("A"), sourceFingerprint: fingerprint("A"), in: root)
        XCTAssertNotNil(f.recordProblem); XCTAssertNil(f.record); XCTAssertEqual(f.recordingType, .unknown)
        XCTAssertThrowsError(try FootageTypeConfirmation.confirm(.continuous, video: "video_01", under: opening, projects: projects, by: "BW", at: at))
        XCTAssertEqual(try snapshot("A"), before, "neither video_01.json nor a new video_02.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FootageProperties.url(in: root, video: "video_02").path))
    }

    func testARecordOfAnotherFileIsNotCarriedIntoTheConfirmation() throws {
        let root = try project("A")
        let opening = open("A")
        // The recording was replaced under the same id: the record on file describes the other file.
        let span = FootageProperties.Span(id: UUID(), start: nil, end: nil, traits: [.handheld], origin: .confirmed, confidence: nil, source: "BW",
                                          note: nil, at: at, by: "BW", rejectedAt: nil)
        try FootageProperties.Store(root: root).save(FootageProperties.File(video: "video_01", sourceFingerprint: "file:other", recordingType: .edited,
                                                                             recordingTypeBy: "BW", recordingTypeAt: at, spans: [span], updatedAt: at))
        let f = FootageTypeConfirmation.facts(recording("A"), sourceFingerprint: fingerprint("A"), in: root)
        XCTAssertNil(f.record); XCTAssertNotNil(f.recordOfAnotherFile)
        XCTAssertEqual(f.recordingType, .unknown, "the other file's type is not this recording's")
        // The rule itself, as the Next page's list reads it too: bound to another fingerprint → another file's;
        // bound to the card's, or to none, → this recording's.
        let onFile = try XCTUnwrap(try FootageProperties.Store(root: root).load("video_01"))
        XCTAssertNotNil(FootageTypeConfirmation.anotherFile(onFile, sourceFingerprint: fingerprint("A")))
        XCTAssertNotNil(FootageTypeConfirmation.anotherFile(onFile, sourceFingerprint: nil), "a card with no fingerprint cannot own a bound record")
        XCTAssertNil(FootageTypeConfirmation.anotherFile(onFile, sourceFingerprint: "file:other"))
        var unbound = onFile; unbound.sourceFingerprint = nil
        XCTAssertNil(FootageTypeConfirmation.anotherFile(unbound, sourceFingerprint: fingerprint("A")), "bound by name")
        let written = try FootageTypeConfirmation.confirm(.continuous, video: "video_01", under: opening, projects: projects, by: "BW", at: at)
        XCTAssertEqual(written.sourceFingerprint, fingerprint("A"))
        XCTAssertTrue(written.spans.isEmpty, "the other file's spans are not this recording's")
        XCTAssertEqual(written.recordingType, .continuous)
    }

    // MARK: - The opening (A → B → A)

    func testAConfirmationBelongsToTheOpeningTheRecordingWasMarkedUnder() throws {
        try project("A"); try project("B")
        let a1 = open("A")
        _ = open("B")
        // Marked under A, confirmed after B was opened: refused, and nothing lands in either project.
        XCTAssertThrowsError(try FootageTypeConfirmation.confirm(.continuous, video: "video_01", under: a1, projects: projects, by: "BW", at: at)) {
            XCTAssertTrue($0 is ProjectsModel.OpeningEnded, "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL("A").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL("B").path))
        // A opened again is another opening: the old one still cannot write; the new one writes into A alone.
        let a2 = open("A")
        XCTAssertNotEqual(a1, a2)
        XCTAssertThrowsError(try FootageTypeConfirmation.confirm(.continuous, video: "video_01", under: a1, projects: projects, by: "BW", at: at))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL("A").path))
        let written = try FootageTypeConfirmation.confirm(.edited, video: "video_01", under: a2, projects: projects, by: "BW", at: at)
        XCTAssertEqual(written.sourceFingerprint, fingerprint("A"), "A's card, not B's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL("A").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL("B").path))
        XCTAssertEqual(FootageTypeConfirmation.facts(recording("B"), sourceFingerprint: fingerprint("B"), in: base.appendingPathComponent("B")).recordingType, .unknown)
    }
}
