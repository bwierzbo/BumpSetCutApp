//
//  EventReviewTests.swift
//  RallyLabTests
//
//  Stage 1 rally-boundary review, data foundation (D-024, S1-a): the rallyevents.json
//  record and its rules, the shared open with its withheld-closure refusal and ledger
//  row, the legacy file left untouched, the L2 exporter unaffected, and the read-only
//  inventory. Videos are the committed fixtures (RallyLabTests/Fixtures).
//

import AVFoundation
import XCTest
@testable import RallyLab

final class EventReviewTests: XCTestCase {
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-10-26T06:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("evr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try DatasetStore(root: root).prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// A committed clip copied under root/footage as `name.mp4`: lead3 is 60 fps, 3 s; h264 is 30 fps.
    private func fixture(_ resource: String, as name: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        let source = try XCTUnwrap(bundle.url(forResource: resource, withExtension: "mp4") ?? bundle.url(forResource: resource, withExtension: "mp4", subdirectory: "Fixtures"),
                                   "\(resource).mp4 is not in the test bundle")
        let url = root.appendingPathComponent("footage/\(name).mp4")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    private func session(_ name: String, split: String = "train", video: URL, times: [Double] = []) throws -> VideoSession {
        let frames = times.map { FrameRecord(id: UUID(), file: "images/\(split)/\(name)_\($0).jpg", time: $0, source: "random", boxes: [], keep: true, reviewed: true) }
        let s = VideoSession(name: name, sourcePath: video.path, split: split, addedAt: now, frames: frames)
        try DatasetStore(root: root).save(s)
        return s
    }

    private func writeValidation(_ text: String) throws {
        try text.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
    }

    private func ledgerRows() throws -> [DatasetSplitManifest.ExposureLogRow] {
        let url = ExposureLog.url(in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([DatasetSplitManifest.ExposureLogRow].self, from: Data(contentsOf: url))
    }

    private func file(frameRate: Double = 60, duration: Double = 3) -> EventReview.File {
        EventReview.File(video: "v", sourceFingerprint: "file:abc", frameRate: frameRate, durationSec: duration, tool: "RallyLab test")
    }

    private func event(_ a: Double, _ b: Double, _ v: EventReview.Visibility = .clear) -> EventReview.EventTime {
        EventReview.EventTime(earliest: a, latest: b, visibility: v)
    }

    private func rally(_ contact: EventReview.EventTime?, _ dead: EventReview.EventTime?, kind: EventReview.RallyKind = .rally,
                       edge: EventReview.Edge? = nil, id: UUID = UUID()) -> EventReview.Rally {
        EventReview.Rally(rallyId: id, kind: kind, contact: contact, dead: dead, edge: edge, annotator: "BW", reviewedAt: EventReview.stamp(now))
    }

    // MARK: - Record

    func testSchemaRoundTripAndVersionRefusal() throws {
        var f = file()
        EventReview.Mutation.markReviewed(from: 0, to: 3, in: &f, at: now, annotator: "BW")
        f.spans = [EventReview.Span(id: UUID(), kind: .nonRallyActivity, start: 0.1, end: 0.4, note: "ball retrieval")]
        let id = EventReview.Mutation.upsert(rally(event(1.0, 1.0167), event(2.0, 2.3, .occluded)), in: &f)
        try EventReview.Mutation.complete(&f, at: now, annotator: "BW", tool: "RallyLab test")
        let url = root.appendingPathComponent("footage/v.rallyevents.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EventReview.write(f, to: url)
        let back = try EventReview.read(url)
        XCTAssertEqual(back, f)
        XCTAssertEqual(back.rallies.first?.rallyId, id)
        XCTAssertEqual(back.rallies.first?.flags, ["ambiguous_dead"], "0.3 s is wider than the 0.2 s rubric; 1/60 s is not")
        XCTAssertNotNil(back.stage1Complete)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"annotationVersion\" : \"rally_event_truth_v1\""))
        // Another version is refused whole, before any field is read.
        try text.replacingOccurrences(of: "rally_event_truth_v1", with: "rally_event_truth_v2").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try EventReview.read(url)) { XCTAssertEqual($0 as? EventReview.Failure, .unsupportedVersion("rally_event_truth_v2")) }
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try EventReview.read(url)) { XCTAssertEqual($0 as? EventReview.Failure, .unsupportedVersion("(none)")) }
        // An invalid record is refused on write: nothing reaches the disk.
        var bad = f
        bad.rallies[0].contact = event(2.5, 2.0)
        XCTAssertThrowsError(try EventReview.write(bad, to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{}", "the previous file is untouched by a refused write")
    }

    /// A record written before the cross-platform fields existed reads with their defaults; a record with them
    /// round-trips; the Mac and the phone read one schema.
    func testRecordReadsWithoutTheCrossPlatformFieldsAndKeepsThem() throws {
        let url = root.appendingPathComponent("footage/old.rallyevents.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"annotationVersion":"rally_event_truth_v1","video":"old","sourceFingerprint":"file:abc","frameRate":30,"durationSec":10,"tool":"t",
         "coverage":[{"start":0,"end":10,"state":"reviewed","at":"2026-10-26T00:00:00Z","annotator":"BW"}],"spans":[],"rallies":[],"stage1Complete":null}
        """.write(to: url, atomically: true, encoding: .utf8)
        let old = try EventReview.read(url)
        XCTAssertNil(old.frameTimesDigest); XCTAssertEqual(old.revision, 0)
        var f = old
        f.frameTimesDigest = FrameIdentity.digest(of: [0, 1.0 / 30, 2.0 / 30]); f.revision = 7
        try EventReview.write(f, to: url)
        let back = try EventReview.read(url)
        XCTAssertEqual(back, f)
        XCTAssertEqual(back.revision, 7); XCTAssertEqual(back.frameTimesDigest?.count, 64)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"revision\" : 7"))
    }

    func testFrameTimesDigestIsStableAndSensitive() {
        let times = (0..<90).map { Double($0) / 30 }
        let d = FrameIdentity.digest(of: times)
        XCTAssertEqual(d.count, 64)
        XCTAssertEqual(FrameIdentity.digest(of: times.map { $0 + 1e-8 }), d, "a billionth of a second is below the microsecond resolution")
        XCTAssertNotEqual(FrameIdentity.digest(of: Array(times.dropLast())), d, "one frame fewer")
        XCTAssertNotEqual(FrameIdentity.digest(of: times.map { ($0 * 30).rounded() / 30 + (($0 * 30).rounded() == 10 ? 0.001 : 0) }), d, "one frame moved by a millisecond")
        XCTAssertNotEqual(FrameIdentity.digest(of: [0] + times), d, "one frame more")
        XCTAssertTrue(FrameIdentity.matches(copy: times, original: d))
        XCTAssertEqual(FrameClock(times: times, frameRate: 30).digest, d)
    }

    func testFrameIdentityOfAFixtureAndItsByteCopy() async throws {
        let a = try fixture("open-gop-hevc-leading3", as: "a")
        let b = try fixture("open-gop-hevc-leading3", as: "b")
        let ta = try await FrameIdentity.allFrameTimes(of: a), tb = try await FrameIdentity.allFrameTimes(of: b)
        XCTAssertEqual(ta.count, 180, "every frame of 3 s at 60 fps, on the presentation timeline")
        XCTAssertEqual(FrameIdentity.digest(of: ta), FrameIdentity.digest(of: tb), "a byte copy shows the same frames")
        let other = try await FrameIdentity.allFrameTimes(of: try fixture("h264-damaged-inter-frame", as: "c"))
        XCTAssertNotEqual(FrameIdentity.digest(of: other), FrameIdentity.digest(of: ta))
        let facts = try await FrameIdentity.videoFacts(a)
        XCTAssertEqual(facts.frameRate, 60, accuracy: 0.01); XCTAssertEqual(facts.duration, 3, accuracy: 0.05)
    }

    func testPersistentIdsAcrossEditAndWithdraw() throws {
        var f = file()
        EventReview.Mutation.markReviewed(from: 0, to: 3, in: &f, at: now, annotator: "BW")
        let id = EventReview.Mutation.upsert(rally(event(1, 1), event(2, 2)), in: &f)
        var edited = f.rallies[0]
        edited.dead = event(2.1, 2.1)
        XCTAssertEqual(EventReview.Mutation.upsert(edited, in: &f), id)
        XCTAssertEqual(f.rallies.count, 1)
        XCTAssertEqual(f.rallies[0].dead, event(2.1, 2.1))
        XCTAssertTrue(EventReview.Mutation.withdraw(id, in: &f, at: now, annotator: "BW"))
        XCTAssertEqual(f.rallies.count, 1, "a withdrawn rally stays, its id with it")
        XCTAssertEqual(f.rallies[0].reviewState, .withdrawn)
        XCTAssertEqual(f.rallies[0].rallyId, id)
        XCTAssertFalse(EventReview.Mutation.withdraw(UUID(), in: &f, at: now, annotator: "BW"))
        XCTAssertNoThrow(try EventReview.Mutation.complete(&f, at: now, annotator: "BW", tool: "t"), "a withdrawn rally needs no events")
        var dup = f
        dup.rallies.append(rally(event(1, 1), event(2, 2), id: id))
        XCTAssertThrowsError(try EventReview.validate(dup))
    }

    func testCoverageUnionAndGapRefusalAtRealFrameRates() throws {
        for (rate, duration) in [(59.94, 3.0), (29.97, 5.0)] {
            var f = file(frameRate: rate, duration: duration)
            let frame = 1 / rate
            EventReview.Mutation.markReviewed(from: 0, to: 1.5, in: &f, at: now, annotator: "BW")
            EventReview.Mutation.markReviewed(from: 1.5 + 0.9 * frame, to: duration, in: &f, at: now, annotator: "BW")
            XCTAssertEqual(f.coverage.count, 2); XCTAssertEqual(EventReview.union(f.coverage).count, 2)
            XCTAssertTrue(EventReview.gaps(in: f).isEmpty, "a gap narrower than one frame at \(rate) fps is not unknown time")
            XCTAssertNil(EventReview.firstUnknown(in: f))
            XCTAssertNoThrow(try EventReview.Mutation.complete(&f, at: now, annotator: "BW", tool: "t"))
            var g = file(frameRate: rate, duration: duration)
            EventReview.Mutation.markReviewed(from: 0, to: 1.5, in: &g, at: now, annotator: "BW")
            EventReview.Mutation.markReviewed(from: 1.5 + 2 * frame, to: duration, in: &g, at: now, annotator: "BW")
            let gaps = EventReview.gaps(in: g)
            XCTAssertEqual(gaps.count, 1)
            XCTAssertEqual(gaps.first?.start ?? -1, 1.5, accuracy: 1e-9)
            XCTAssertEqual(EventReview.firstUnknown(in: g) ?? -1, 1.5, accuracy: 1e-9, "resume at the first unknown stretch")
            XCTAssertThrowsError(try EventReview.Mutation.complete(&g, at: now, annotator: "BW", tool: "t")) { error in
                guard case .incomplete(let why)? = error as? EventReview.Failure else { return XCTFail("\(error)") }
                XCTAssertEqual(why.count, 1); XCTAssertTrue(why[0].hasPrefix("unknown 1.500–"), why[0])
            }
            XCTAssertNil(g.stage1Complete, "a refused completion changes nothing")
            // Overlapping and touching intervals merge; the union is what counts.
            EventReview.Mutation.markReviewed(from: 1.2, to: 1.5 + 3 * frame, in: &g, at: now, annotator: "BW")
            XCTAssertEqual(g.coverage.count, 3, "records are history; nothing is merged away")
            XCTAssertEqual(EventReview.union(g.coverage).count, 1)
            XCTAssertTrue(EventReview.gaps(in: g).isEmpty)
        }
        // Each coverage record keeps who reviewed it and when; a later review never rewrites an earlier one.
        var p = file(duration: 30)
        EventReview.Mutation.markReviewed(from: 0, to: 10, in: &p, at: now, annotator: "A")
        let later = now.addingTimeInterval(3600)
        EventReview.Mutation.markReviewed(from: 20, to: 30, in: &p, at: later, annotator: "B")
        EventReview.Mutation.markReviewed(from: 5, to: 25, in: &p, at: later, annotator: "B")
        XCTAssertEqual(p.coverage.map(\.annotator), ["A", "B", "B"])
        XCTAssertEqual(p.coverage[0], EventReview.Coverage(start: 0, end: 10, at: EventReview.stamp(now), annotator: "A"))
        XCTAssertEqual(EventReview.union(p.coverage).count, 1)
        XCTAssertTrue(EventReview.gaps(in: p).isEmpty)
        // A gap at the start or the end counts too.
        var h = file()
        EventReview.Mutation.markReviewed(from: 0.5, to: 2.5, in: &h, at: now, annotator: "BW")
        XCTAssertEqual(EventReview.gaps(in: h).count, 2)
        XCTAssertEqual(EventReview.firstUnknown(in: h), 0)
    }

    func testSpansMustLieInsideReviewedCoverage() throws {
        var f = file()
        EventReview.Mutation.markReviewed(from: 0, to: 1, in: &f, at: now, annotator: "BW")
        f.spans = [EventReview.Span(id: UUID(), kind: .transition, start: 0.2, end: 0.8, note: nil)]
        XCTAssertNoThrow(try EventReview.validate(f))
        f.spans.append(EventReview.Span(id: UUID(), kind: .uncertain, start: 0.9, end: 1.5, note: nil))
        XCTAssertThrowsError(try EventReview.validate(f)) { XCTAssertTrue("\($0)".contains("outside reviewed coverage"), "\($0)") }
        f.spans = [EventReview.Span(id: UUID(), kind: .nonRallyActivity, start: 0.5, end: 0.5, note: nil)]
        XCTAssertThrowsError(try EventReview.validate(f))
    }

    func testCompletionNeedsResolvedEventsOrAnEdge() throws {
        var f = file()
        EventReview.Mutation.markReviewed(from: 0, to: 3, in: &f, at: now, annotator: "BW")
        EventReview.Mutation.upsert(rally(nil, event(2, 2)), in: &f)
        XCTAssertThrowsError(try EventReview.Mutation.complete(&f, at: now, annotator: "BW", tool: "t")) {
            XCTAssertTrue("\($0)".contains("no serve contact and no start edge"), "\($0)")
        }
        f.rallies[0].edge = .start
        XCTAssertNoThrow(try EventReview.Mutation.complete(&f, at: now, annotator: "BW", tool: "t"), "a truncated start is an edge, not a gap")
        var g = file()
        EventReview.Mutation.markReviewed(from: 0, to: 3, in: &g, at: now, annotator: "BW")
        EventReview.Mutation.upsert(rally(nil, nil, kind: .other), in: &g)
        XCTAssertNoThrow(try EventReview.Mutation.complete(&g, at: now, annotator: "BW", tool: "t"), "`other` may stay unresolved (protocol §4)")
    }

    // MARK: - Opening: refusal, ledger, legacy file

    func testOpenRefusesTheWithheldClosureByNamePathAndContent() async throws {
        let w = try fixture("open-gop-hevc-leading3", as: "w")
        let withheld = try session("w", split: "val", video: w)
        let samePath = try session("x", video: w)                                    // another session over w's file
        let copy = try fixture("open-gop-hevc-leading3", as: "y")                    // a byte copy under another name
        let sameContent = try session("y", video: copy)
        let other = try session("z", video: try fixture("h264-damaged-inter-frame", as: "z"))
        try writeValidation(#"{"tune":[],"holdout":[],"lineageHoldout":["w"]}"#)
        for (s, reason) in [(withheld, "listed"), (samePath, "w's file"), (sameContent, "content is w's")] {
            do {
                _ = try await EventReview.open(s, root: root, tool: "t", now: now)
                XCTFail("\(s.name) must be refused")
            } catch let failure as EventReview.Failure {
                guard case .withheld(let name, let why) = failure else { return XCTFail("\(failure)") }
                XCTAssertEqual(name, s.name); XCTAssertTrue(why.contains(reason), why)
            }
        }
        XCTAssertEqual(try ledgerRows(), [], "a refused open records no use")
        XCTAssertFalse(FileManager.default.fileExists(atPath: EventReview.url(forVideo: w).path))
        let opened = try await EventReview.open(other, root: root, tool: "t", now: now)
        XCTAssertTrue(opened.isNew)
        XCTAssertEqual(opened.file.video, "z")
        XCTAssertEqual(opened.file.frameRate, 30, accuracy: 0.01)
        XCTAssertEqual(opened.file.durationSec, 3, accuracy: 0.05)
        XCTAssertEqual(opened.file.sourceFingerprint, ProjectsModel.fileFingerprint(atPath: other.sourcePath))
        // The legacy holdout is in the closure too; the final test likewise.
        try writeValidation(#"{"tune":[],"holdout":["z"]}"#)
        await XCTAssertThrowsErrorAsync(try await EventReview.open(other, root: root, tool: "t", now: now))
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["z"]}"#)
        await XCTAssertThrowsErrorAsync(try await EventReview.open(other, root: root, tool: "t", now: now))
        // An unreadable validation.json means the reserved set is unknown: refused, not assumed empty.
        try writeValidation("{not json")
        await XCTAssertThrowsErrorAsync(try await EventReview.open(other, root: root, tool: "t", now: now))
        // The withheld original gone (no stored fingerprint, session kept): its content can't be fingerprinted,
        // so a surviving byte copy could not be told apart — nothing opens, and the inventory refuses too.
        try writeValidation(#"{"tune":[],"holdout":[],"lineageHoldout":["w"]}"#)
        try FileManager.default.removeItem(at: w)
        for s in [sameContent, other] {
            do {
                _ = try await EventReview.open(s, root: root, tool: "t", now: now)
                XCTFail("\(s.name) must be refused while w's content is unknown")
            } catch let failure as EventReview.Failure {
                guard case .withheldIdentityUnknown(let why) = failure else { return XCTFail("\(failure)") }
                XCTAssertTrue(why.contains("w"), why)
            }
        }
        XCTAssertThrowsError(try EventInventory.build(root: root, now: now))
        XCTAssertEqual(try ledgerRows().map(\.video), ["z"], "only the earlier, permitted open is on the ledger")
    }

    /// What the sync publishes as withheld is what `open` refuses: the named closure plus the sessions refused
    /// by path or content, and nothing at all when the identities cannot be read.
    func testThePublishedWithheldListCarriesPathAndContentAliases() throws {
        let w = try fixture("open-gop-hevc-leading3", as: "w")
        _ = try session("w", split: "val", video: w)
        _ = try session("x", video: w)                                              // another session over w's file
        _ = try session("y", video: try fixture("open-gop-hevc-leading3", as: "y"))  // a byte copy under another name
        _ = try session("z", video: try fixture("h264-damaged-inter-frame", as: "z"))
        try writeValidation(#"{"tune":[],"holdout":[],"lineageHoldout":["w"]}"#)
        XCTAssertEqual(try EventReview.withheldNames(in: root), ["w"], "the named closure alone")
        XCTAssertEqual(try EventReview.publishedWithheldNames(in: root), ["w", "x", "y"], "the published list refuses the aliases too")
        try writeValidation("{not json")
        XCTAssertThrowsError(try EventReview.publishedWithheldNames(in: root), "unreadable identities: nothing is published")
        try writeValidation(#"{"tune":[],"holdout":[],"lineageHoldout":["w"]}"#)
        try FileManager.default.removeItem(at: w)
        XCTAssertThrowsError(try EventReview.publishedWithheldNames(in: root), "w's content unknown: the list cannot be established")
    }

    /// A withheld recording the project knows only from project.json (no session file) still protects
    /// its cut file: a session over that file, or over a byte copy of it, is refused — even though the
    /// recording's own fingerprint is its YouTube link, not the file's content.
    func testSessionlessWithheldSourcesAreRefusedByCutFileAndContent() async throws {
        let cut = try fixture("h264-damaged-inter-frame", as: "q")
        let source = ClipSource(kind: .link, origin: "https://www.youtube.com/watch?v=abcdefghijk", start: 0, length: 3, license: "permission: test", title: "q",
                                uploader: "test", clipFile: cut.path, fetchedAt: now, videoId: nil, frames: nil, fingerprint: nil, sourceId: nil, sessionId: nil, venueId: nil)
        let project = Project(name: "evr", createdAt: now, framesPerRally: 4,
                              clips: [PlannedClip(id: "q", number: 1, environment: "indoor", camera: "ele", lighting: "bright", orientation: "land", ball: "", notes: "", split: "train", videos: [source])])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: root.appendingPathComponent("project.json"))
        try writeValidation(#"{"tune":[],"holdout":[],"lineageHoldout":["q"]}"#)
        XCTAssertEqual(try EventReview.withheldNames(in: root), ["q"])
        let overCut = try session("r", video: cut)
        let copy = try fixture("h264-damaged-inter-frame", as: "t")
        let sameContent = try session("t", video: copy)
        let eligible = try session("u", video: try fixture("open-gop-hevc-leading3", as: "u"))
        for (s, reason) in [(overCut, "q's cut file"), (sameContent, "content is q's")] {
            do {
                _ = try await EventReview.open(s, root: root, tool: "t", now: now)
                XCTFail("\(s.name) must be refused")
            } catch let failure as EventReview.Failure {
                guard case .withheld(let name, let why) = failure else { return XCTFail("\(failure)") }
                XCTAssertEqual(name, s.name); XCTAssertTrue(why.contains(reason), why)
            }
        }
        XCTAssertEqual(try ledgerRows(), [])
        let opened = try await EventReview.open(eligible, root: root, tool: "t", now: now)
        XCTAssertEqual(opened.file.video, "u")
        // The inventory applies the same guard: the aliases are withheld rows without annotation details.
        try "[{\"startTime\":0.5,\"endTime\":1.0}]".write(to: RallyMarkModel.labelsURL(for: cut), atomically: true, encoding: .utf8)
        let report = try EventInventory.build(root: root, now: now)
        XCTAssertEqual(report.recordings.map { ($0.name, $0.withheld) }.map { "\($0.0):\($0.1)" }, ["r:true", "t:true", "u:false"])
        XCTAssertNil(report.recordings[0].legacyMarks, "a withheld alias's sidecars are not read")
        XCTAssertFalse(report.recordings[0].legacyFile)
        // The identities live only in project.json here: when it can't be read, nothing opens and the inventory refuses.
        try "{not json".write(to: root.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        for s in [overCut, eligible] {
            do {
                _ = try await EventReview.open(s, root: root, tool: "t", now: now)
                XCTFail("\(s.name) must be refused while project.json is unreadable")
            } catch let failure as EventReview.Failure {
                guard case .projectUnreadable = failure else { return XCTFail("\(failure)") }
            }
        }
        XCTAssertThrowsError(try EventInventory.build(root: root, now: now))
        XCTAssertEqual(try ledgerRows().map(\.video), ["u"], "no new row since the refused opens")
    }

    /// A withheld recording's file identity may live only in its session file. When that file can't be
    /// read, the guard cannot know the file is protected — so nothing opens until it can (fail closed).
    func testADamagedSessionFileRefusesEveryOpen() async throws {
        let w = try fixture("open-gop-hevc-leading3", as: "w")
        _ = try session("w", video: w)
        let x = try session("x", video: w)
        let z = try session("z", video: try fixture("h264-damaged-inter-frame", as: "z"))
        try writeValidation(#"{"tune":[],"holdout":[],"lineageHoldout":["w"]}"#)
        try "{not json".write(to: root.appendingPathComponent("sessions/w.json"), atomically: true, encoding: .utf8)
        for s in [x, z] {
            do {
                _ = try await EventReview.open(s, root: root, tool: "t", now: now)
                XCTFail("\(s.name) must be refused while a session file is unreadable")
            } catch let failure as EventReview.Failure {
                guard case .sessionsUnreadable = failure else { return XCTFail("\(failure)") }
            }
        }
        XCTAssertEqual(try ledgerRows(), [])
        XCTAssertThrowsError(try EventInventory.build(root: root, now: now), "the inventory reads strictly too")
    }

    func testOpenRecordsTheUseAndRefusesWhenTheLedgerCannotBeWritten() async throws {
        let v = try fixture("h264-damaged-inter-frame", as: "v")
        let s = try session("v", video: v)
        let opened = try await EventReview.open(s, root: root, tool: "t", now: now)
        XCTAssertTrue(opened.isNew)
        let rows = try ledgerRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.video, "v"); XCTAssertEqual(rows.first?.kind, .eventReview); XCTAssertEqual(rows.first?.ref, EventReview.ledgerRef)
        XCTAssertEqual(rows.first?.date, "2026-10-26")
        _ = try await EventReview.open(s, root: root, tool: "t", now: now)
        XCTAssertEqual(try ledgerRows().count, 1, "the same use is recorded once")
        // An unreadable ledger is never overwritten: the use goes to a sidecar beside it, and the open proceeds.
        let log = ExposureLog.url(in: root)
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let u = try session("u", video: try fixture("h264-damaged-inter-frame", as: "u"))
        _ = try await EventReview.open(u, root: root, tool: "t", now: now)
        let manifests = root.appendingPathComponent("manifests")
        let sidecars = try FileManager.default.contentsOfDirectory(atPath: manifests.path).filter { $0.hasPrefix("exposure-log.unmerged-") }
        XCTAssertEqual(sidecars.count, 1, "the use is parked beside the damaged log")
        let parked = try JSONDecoder().decode([DatasetSplitManifest.ExposureLogRow].self, from: Data(contentsOf: manifests.appendingPathComponent(sidecars[0])))
        XCTAssertEqual(parked.map(\.video), ["u"])
        // Nowhere to write at all (a file where manifests/ should be): the row can't be recorded, so the open is refused.
        try FileManager.default.removeItem(at: manifests)
        try "x".write(to: manifests, atomically: true, encoding: .utf8)
        let t = try session("t", video: try fixture("h264-damaged-inter-frame", as: "t"))
        do {
            _ = try await EventReview.open(t, root: root, tool: "t", now: now)
            XCTFail("must refuse")
        } catch let failure as EventReview.Failure {
            guard case .ledgerNotWritten = failure else { return XCTFail("\(failure)") }
        }
        try FileManager.default.removeItem(at: manifests)
        // A missing original is refused too: review happens on the footage, never a proxy.
        let gone = try session("g", video: root.appendingPathComponent("footage/g.mp4"))
        do {
            _ = try await EventReview.open(gone, root: root, tool: "t", now: now)
            XCTFail("must refuse")
        } catch let failure as EventReview.Failure {
            guard case .videoMissing = failure else { return XCTFail("\(failure)") }
        }
    }

    func testOpenResumesTheRecordAndGuardsItsIdentity() async throws {
        let v = try fixture("open-gop-hevc-leading3", as: "v")
        let s = try session("v", video: v)
        var opened = try await EventReview.open(s, root: root, tool: "t", now: now)
        EventReview.Mutation.markReviewed(from: 0, to: 1.25, in: &opened.file, at: now, annotator: "BW")
        let id = EventReview.Mutation.upsert(rally(event(0.5, 0.5167), event(1.0, 1.0)), in: &opened.file)
        try EventReview.write(opened.file, to: opened.fileURL)
        let again = try await EventReview.open(s, root: root, tool: "t", now: now)
        XCTAssertFalse(again.isNew)
        XCTAssertEqual(again.file, opened.file)
        XCTAssertEqual(again.file.rallies.first?.rallyId, id)
        XCTAssertEqual(EventReview.firstUnknown(in: again.file) ?? -1, 1.25, accuracy: 1e-9, "resume at the first unknown stretch")
        // A record that names another video, or a video whose content changed, is refused.
        var wrong = again.file; wrong.video = "other"
        try EventReview.write(wrong, to: again.fileURL)
        await XCTAssertThrowsErrorAsync(try await EventReview.open(s, root: root, tool: "t", now: now))
        var changed = again.file; changed.sourceFingerprint = "file:0000"
        try EventReview.write(changed, to: again.fileURL)
        await XCTAssertThrowsErrorAsync(try await EventReview.open(s, root: root, tool: "t", now: now))
    }

    func testLegacyMarksAreNeverTouchedAndNeverCreated() async throws {
        let v = try fixture("open-gop-hevc-leading3", as: "v")
        let s = try session("v", video: v)
        let legacyURL = RallyMarkModel.labelsURL(for: v)
        let legacy = "[{\"startTime\":0.5,\"endTime\":1.0}]\n"
        try legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
        var opened = try await EventReview.open(s, root: root, tool: "t", now: now)
        EventReview.Mutation.markReviewed(from: 0, to: 3, in: &opened.file, at: now, annotator: "BW")
        EventReview.Mutation.upsert(rally(event(0.55, 0.55), event(1.1, 1.1)), in: &opened.file)
        try EventReview.Mutation.complete(&opened.file, at: now, annotator: "BW", tool: "t")
        try EventReview.write(opened.file, to: opened.fileURL)
        XCTAssertEqual(try String(contentsOf: legacyURL, encoding: .utf8), legacy, "byte for byte")
        XCTAssertEqual(opened.fileURL.lastPathComponent, "v.rallyevents.json")
        XCTAssertNotEqual(opened.fileURL, legacyURL)
        let u = try session("u", video: try fixture("h264-damaged-inter-frame", as: "u"))
        var other = try await EventReview.open(u, root: root, tool: "t", now: now)
        EventReview.Mutation.markReviewed(from: 0, to: 0.5, in: &other.file, at: now, annotator: "BW")
        try EventReview.write(other.file, to: other.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RallyMarkModel.labelsURL(for: u.sourceURL).path), "no legacy file is created")
    }

    /// The L2 exporter neither reads nor packages a rallyevents.json: the same sessions give the
    /// same package with and without one beside the video.
    func testARallyEventsFileLeavesTheExportUnchanged() async throws {
        let a = try fixture("open-gop-hevc-leading3", as: "a")
        let b = try fixture("open-gop-hevc-leading3", as: "b")
        let sessions = [try session("a", split: "val", video: a, times: [0.5]), try session("b", split: "train", video: b, times: [0.5])]
        let store = DatasetStore(root: root)
        let first = try await MultiFramePackage.export(sessions: sessions, store: store, name: "Fixture-S1-1", longSide: 64, now: now) { _, _ in }
        var f = file(); f.video = "b"
        EventReview.Mutation.markReviewed(from: 0, to: 3, in: &f, at: now, annotator: "BW")
        EventReview.Mutation.upsert(rally(event(0.4, 0.4), event(0.9, 0.9)), in: &f)
        try EventReview.write(f, to: EventReview.url(forVideo: b))
        let second = try await MultiFramePackage.export(sessions: sessions, store: store, name: "Fixture-S1-2", longSide: 64, now: now) { _, _ in }
        XCTAssertGreaterThan(first.summary.frames, 0)
        XCTAssertEqual(first.summary.trainWindows + first.summary.valWindows, 2)
        XCTAssertEqual(first.summary.frames, second.summary.frames)
        XCTAssertEqual(first.summary.trainWindows, second.summary.trainWindows)
        XCTAssertEqual(first.summary.valWindows, second.summary.valWindows)
        for output in [first.output, second.output] {
            let dir = output.pathExtension == "zip" ? output.deletingPathExtension() : output
            let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
            XCTAssertFalse(files.contains { $0.contains("rallyevents") }, "\(files.filter { $0.contains("rallyevents") })")
        }
        XCTAssertEqual(try EventReview.read(EventReview.url(forVideo: b)), f, "the export left the record as it was")
    }

    // MARK: - Inventory

    func testEventInventoryAndStatusAreReadOnly() async throws {
        // a and b share the H.264 fixture (neither withheld); w is the HEVC fixture — a copy of it would be withheld by content.
        let a = try fixture("h264-damaged-inter-frame", as: "a")
        let b = try fixture("h264-damaged-inter-frame", as: "b")
        let w = try fixture("open-gop-hevc-leading3", as: "w")
        _ = try session("a", video: a); _ = try session("b", split: "val", video: b); _ = try session("w", video: w)
        _ = try session("x", video: w)   // another session over the withheld recording's file
        try writeValidation(#"{"tune":[],"holdout":[],"lineageHoldout":["w"]}"#)
        try "[{\"startTime\":0.5,\"endTime\":1.0},{\"startTime\":1.5,\"endTime\":2.0}]".write(to: RallyMarkModel.labelsURL(for: a), atomically: true, encoding: .utf8)
        try "[{\"startTime\":0.5,\"endTime\":1.0}]".write(to: RallyMarkModel.labelsURL(for: w), atomically: true, encoding: .utf8)
        var f = file(); f.video = "a"; f.sourceFingerprint = ProjectsModel.fileFingerprint(atPath: a.path)
        EventReview.Mutation.markReviewed(from: 0, to: 1.5, in: &f, at: now, annotator: "BW")
        EventReview.Mutation.upsert(rally(event(0.5, 0.5), event(1.0, 1.0)), in: &f)
        let gone = EventReview.Mutation.upsert(rally(event(1.2, 1.2), event(1.4, 1.4)), in: &f)
        _ = EventReview.Mutation.withdraw(gone, in: &f, at: now, annotator: "BW")
        f.spans = [EventReview.Span(id: UUID(), kind: .nonRallyActivity, start: 0.1, end: 0.3, note: nil)]
        try EventReview.write(f, to: EventReview.url(forVideo: a))
        // c's record was written for other content (its fingerprint differs); d's names another video:
        // neither is accepted — their figures are not reported, the problem is.
        let c = try fixture("h264-damaged-inter-frame", as: "c"); _ = try session("c", video: c)
        var fc = file(); fc.video = "c"; fc.sourceFingerprint = "file:0000"
        EventReview.Mutation.markReviewed(from: 0, to: 3, in: &fc, at: now, annotator: "BW")
        try EventReview.Mutation.complete(&fc, at: now, annotator: "BW", tool: "t")
        try EventReview.write(fc, to: EventReview.url(forVideo: c))
        let d = try fixture("h264-damaged-inter-frame", as: "d"); _ = try session("d", video: d)
        var fd = file(); fd.video = "someone-else"; fd.sourceFingerprint = ProjectsModel.fileFingerprint(atPath: d.path)
        try EventReview.write(fd, to: EventReview.url(forVideo: d))
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let report = try EventInventory.build(root: root, now: now)
        XCTAssertEqual(report.recordings.map(\.name), ["a", "b", "c", "d", "w", "x"])
        let rc = report.recordings[2], rd = report.recordings[3]
        XCTAssertTrue(rc.eventsFile); XCTAssertFalse(rc.stage1Complete, "a completed record for other content is not this recording's completion")
        XCTAssertEqual(rc.coverageSec, 0); XCTAssertNil(rc.coverageFraction); XCTAssertTrue(rc.recordProblem?.contains("content changed") == true, rc.recordProblem ?? "nil")
        XCTAssertTrue(rd.recordProblem?.contains("belongs to someone-else") == true, rd.recordProblem ?? "nil")
        XCTAssertEqual(report.recordings.filter { $0.recordProblem == nil }.map(\.name), ["a", "b", "w", "x"])
        let ra = report.recordings[0], rb = report.recordings[1], rw = report.recordings[4], rx = report.recordings[5]
        XCTAssertTrue(rx.withheld, "the same guard as open: a session over a withheld recording's file is withheld"); XCTAssertNil(rx.legacyMarks); XCTAssertFalse(rx.eventsFile)
        XCTAssertEqual(ra.legacyMarks, 2); XCTAssertTrue(ra.eventsFile); XCTAssertEqual(ra.reviewedRallies, 1); XCTAssertEqual(ra.withdrawnRallies, 1)
        XCTAssertEqual(ra.spans, 1); XCTAssertEqual(ra.coverageSec, 1.5, accuracy: 1e-9); XCTAssertEqual(ra.coverageFraction ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ra.unknownGaps, 1); XCTAssertFalse(ra.stage1Complete)
        XCTAssertNil(rb.legacyMarks); XCTAssertFalse(rb.legacyFile); XCTAssertFalse(rb.eventsFile); XCTAssertNil(rb.coverageFraction)
        XCTAssertTrue(rw.withheld); XCTAssertNil(rw.legacyMarks, "a withheld recording's sidecars are not read"); XCTAssertNil(rw.durationSec)
        XCTAssertNotNil(report.manifestHashes.sessions); XCTAssertNotNil(report.manifestHashes.validationJson)
        let lines = EventInventory.statusLines(report)
        XCTAssertEqual(lines.first, "Stage 1 review: 0 of 4 eligible recordings complete, 1 started, 1 not started, 2 with a record that is not theirs; 2 withheld (not reviewed)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("  c (train): record not accepted — The video's content changed") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("  a (train):  50 % reviewed · 1 rallies reviewed · 1 span(s) · in progress, 1 unknown gap(s) · 2 legacy mark(s), unverified") }, "\(lines)")
        XCTAssertTrue(lines.contains("  w: withheld")); XCTAssertTrue(lines.contains("  x: withheld"))
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), before, "building the inventory writes nothing")
        XCTAssertEqual(try ledgerRows(), [], "and records no use")
        let out = try EventInventory.write(report, in: root, stamp: "20261026-060000")
        XCTAssertEqual(out.json.lastPathComponent, "event-inventory-20261026-060000.json")
        let csv = try String(contentsOf: out.csv, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(csv.count, 7)
        XCTAssertTrue(csv[1].hasPrefix("a,train,no,2,2,legacy_unknown,yes,1,1,1,1.500,0.5000,1,no,"), csv[1])
        XCTAssertTrue(csv[3].hasPrefix("c,train,no,,,,yes,0,0,0,0.000,,0,no,The video's content changed"), csv[3])
        XCTAssertEqual(csv[5], "w,train,yes,,,,no,0,0,0,0.000,,0,no,"); XCTAssertEqual(csv[6], "x,train,yes,,,,no,0,0,0,0.000,,0,no,")
        XCTAssertEqual(try JSONDecoder().decode(EventInventory.Report.self, from: Data(contentsOf: out.json)), report)
    }
}

/// XCTAssertThrowsError for an async expression.
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("No error was thrown. \(message)", file: file, line: line) } catch {}
}
