//
//  CoverageAuditRecordingTests.swift
//  RallyLabTests
//
//  The negative-coverage audit's shared operation (CoverageAuditRecording.swift) and its
//  read-only reports (CoverageAuditReport.swift), on synthetic projects in a temporary
//  folder: every refusal, the atomic record and its ledger row (and the save failing
//  when the ledger can't be written), the repeat's 24-hour rule, resolutions, and what
//  the status and the findings list say. The "videos" are small files of bytes: nothing
//  here plays one — the operation reads a recording's identity and marks, never a frame.
//

import XCTest
@testable import RallyLab

final class CoverageAuditRecordingTests: XCTestCase {
    private typealias A = CoverageAudit
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-11-14T18:00:00Z")!
    private let drawId = "20261114-120000"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try DatasetStore(root: root).prepare()
        // A project with something withheld: the legacy holdout `held`, with its own file.
        try recording("held")
        try writeValidation(#"{"tune":[],"holdout":["held"]}"#)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func video(_ name: String) -> URL { root.appendingPathComponent("footage/\(name).mp4") }

    private func writeValidation(_ text: String) throws {
        try text.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
    }

    private func writeMarks(_ name: String, _ marks: [(Double, Double, String?)]) throws {
        let rows = marks.map { m in "{\"startTime\":\(m.0),\"endTime\":\(m.1)" + (m.2.map { ",\"kind\":\"\($0)\"" } ?? "") + "}" }
        try ("[" + rows.joined(separator: ",") + "]").write(to: RallyMarkModel.labelsURL(for: video(name)), atomically: true, encoding: .utf8)
    }

    private func saveSession(_ name: String, complete: Bool = true, cuts: [CutRange]? = nil) throws {
        var s = VideoSession(name: name, sourcePath: video(name).path, split: "train", addedAt: now, frames: [])
        s.ralliesMarked = complete
        s.cuts = cuts
        try DatasetStore(root: root).save(s)
    }

    /// A recording of 10 s with rallies at 2–4 and 6–8 unless told otherwise: unmarked 0–2, 4–6 and 8–10
    /// (ticks 0–1200, 2400–3600, 4800–6000), its pass declared complete.
    private func recording(_ name: String, marks: [(Double, Double, String?)] = [(2, 4, "rally"), (6, 8, "rally")], bytes: String? = nil) throws {
        try FileManager.default.createDirectory(at: video(name).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((bytes ?? "the footage of \(name)").utf8).write(to: video(name), options: .atomic)
        try writeMarks(name, marks)
        try saveSession(name)
    }

    /// The draw as the draw tool freezes it for these recordings as they are now: each 10 s long, its intervals from
    /// its marks, its file's content fingerprint and its marks' hash. `edit` changes a recording's entry afterwards.
    private func draw(_ names: [String], id: String? = nil, repeatSet: [Int] = [1], supersedes: [String]? = nil,
                      edit: (inout [String: Any]) -> Void = { _ in }) throws -> A.LoadedDraw {
        let sessions = try DatasetStore(root: root).loadSessionsStrict()
        let recordings: [[String: Any]] = try names.map { name in
            let session = try XCTUnwrap(sessions.first { $0.name == name })
            let marks = try XCTUnwrap(RallyTruth.records(inSidecarOf: video(name)))
            var entry: [String: Any] = [
                "recordingId": name, "groupId": name, "surface": "beach",
                "contentFingerprint": ProjectsModel.fileFingerprint(atPath: session.sourcePath) ?? "file:none",
                "marksSha256": DatasetSplitManifest.sha256(of: RallyMarkModel.labelsURL(for: video(name))) ?? "",
                "durationTicks": 6000,
                "intervals": A.unmarkedIntervals(marks: marks, cuts: session.cutRanges, durationTicks: 6000).map { ["index": $0.index, "startTick": $0.startTick, "endTick": $0.endTick] },
                "repeatIndices": repeatSet,
            ]
            edit(&entry)
            return entry
        }
        let id = id ?? drawId
        var json: [String: Any] = ["schemaVersion": A.drawVersion, "stage": "pilot", "drawId": id, "dataset": ["name": "rc-v1-20261112", "timescale": 600, "manifestSha256": "aa"],
                                   "seed": 20261114, "recordings": recordings]
        if let supersedes { json["supersedes"] = supersedes }
        let url = A.drawsDirectory(in: root).appendingPathComponent("\(id)-draw.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        return try A.loadDraw(url)
    }

    private func played(_ spans: (Int, Int)..., rate: Double = 2) -> A.PlayedCoverage {
        var coverage = A.PlayedCoverage()
        for (a, b) in spans { coverage.credit(fromTick: a, toTick: b, rate: rate) }
        return coverage
    }

    /// Everything of a 10 s recording, played at 2×.
    private var all: A.PlayedCoverage { played((0, 6000)) }

    private func request(_ name: String, _ index: Int, _ entry: A.Entry, pass: A.Pass = .first, by reviewer: String = "bw",
                         played: A.PlayedCoverage = A.PlayedCoverage(), note: String? = nil) -> A.Request {
        A.Request(recordingId: name, index: index, pass: pass, entry: entry, reviewer: reviewer, played: played, note: note)
    }

    private func auditRows() throws -> [DatasetSplitManifest.ExposureLogRow] {
        try ExposureLog.readStrict(in: root).filter { $0.kind == .coverageAudit }
    }

    private func onDisk(_ name: String) throws -> A.File? {
        let url = A.url(forVideo: video(name))
        return FileManager.default.fileExists(atPath: url.path) ? try A.read(url) : nil
    }

    /// A second look or a resolution put into `name`'s record on disk, as a record from before amendment 2 holds one
    /// (none is given any more, but one that is there is still read).
    private func hold(_ name: String, _ slot: CoverageAuditSync.Slot, _ look: CoverageAuditSync.Look) throws {
        try A.write(CoverageAuditSync.setting(slot, to: look, in: try XCTUnwrap(onDisk(name))), to: A.url(forVideo: video(name)))
    }

    private func refused(_ expected: A.Failure, _ what: String = "", file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), what, file: file, line: line) { XCTAssertEqual($0 as? A.Failure, expected, "\($0)", file: file, line: line) }
    }

    private func refusedAsWithheld(_ name: String, containing text: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case A.Failure.withheld(name, let reason) = error else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue(reason.contains(text), reason, file: file, line: line)
        }
    }

    // MARK: - Clean is a verdict on an interval played whole

    func testCleanIsRefusedUntilTheWholeIntervalWasPlayed() throws {
        try recording("a")
        let d = try draw(["a"])
        refused(.notPlayed(index: 1, missingSec: 2.0), "nothing played") { try A.record(request("a", 1, .clean), draw: d, root: root, tool: "t", now: now) }
        refused(.notPlayed(index: 1, missingSec: 0.5), "the middle half-second never played") {
            try A.record(request("a", 1, .clean, played: played((1800, 2900), (3200, 4200))), draw: d, root: root, tool: "t", now: now)
        }
        refused(.notPlayed(index: 1, missingSec: 2.0), "played at 4× earns nothing") {
            try A.record(request("a", 1, .clean, played: played((0, 6000), rate: 4)), draw: d, root: root, tool: "t", now: now)
        }
        XCTAssertNil(try onDisk("a"), "a refused verdict writes no record")
        XCTAssertEqual(try auditRows(), [], "and no ledger row")

        let written = try A.record(request("a", 1, .clean, played: played((1800, 4200), rate: 1)), draw: d, root: root, tool: "RallyLab test", now: now)
        XCTAssertEqual(try onDisk("a"), written, "what was returned is what is on disk")
        XCTAssertEqual(written.intervals, [A.Review(index: 1, startTick: 2400, endTick: 3600, verdict: .clean, reviewer: "bw", reviewedAt: "2026-11-14T18:00:00Z", playedAllAtMaxRate: 1)])
        XCTAssertEqual(written.recordingId, "a"); XCTAssertEqual(written.drawId, drawId); XCTAssertEqual(written.drawSha256, d.sha256)
        XCTAssertEqual(written.datasetName, "rc-v1-20261112"); XCTAssertEqual(written.tool, "RallyLab test"); XCTAssertTrue(written.blindToPipeline)
        XCTAssertEqual(written.sourceFingerprint, ProjectsModel.fileFingerprint(atPath: video("a").path))
        XCTAssertEqual(written.marksSha256, DatasetSplitManifest.sha256(of: RallyMarkModel.labelsURL(for: video("a"))))
        XCTAssertEqual(A.cleanIntervals(written), [A.Span(startTick: 2400, endTick: 3600)])
        XCTAssertEqual(A.state(of: written, intervals: try XCTUnwrap(d.draw.recording("a")).intervals).name, "partial", "two intervals are still to review")
    }

    func testEveryVerdictPutsOneLedgerRowPerRecordingPerDraw() throws {
        try recording("a"); try recording("b")
        let d = try draw(["a", "b"])
        try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        try A.record(request("b", 0, .finding(A.Finding(kind: .missedServe, approxStartSec: 1))), draw: d, root: root, tool: "t", now: now)
        let rows = try auditRows()
        XCTAssertEqual(rows.map(\.video), ["a", "b"], "the same use is recorded once")
        XCTAssertEqual(rows.first?.ref, "coverage-audit \(drawId)")
        XCTAssertEqual(rows.first?.kind.rawValue, "coverage_audit")
        XCTAssertEqual(rows.first?.date, "2026-11-14")
        XCTAssertEqual(try ExposureLog.readStrict(in: root).filter { $0.video == "held" }, [], "nothing of the withheld recording")
    }

    func testRecordingsOpenedAtOnceEachKeepTheirLedgerRow() throws {
        let names = (0..<8).map { "r\($0)" }
        for name in names { try recording(name) }
        let d = try draw(names, repeatSet: [])
        let root: URL = self.root, now = self.now
        DispatchQueue.concurrentPerform(iterations: names.count) { i in _ = try? A.open(names[i], draw: d, root: root, now: now) }
        XCTAssertEqual(Set(try auditRows().map(\.video)), Set(names), "no open overwrote another's row")
    }

    func testTheSaveFailsWhenTheLedgerCannotBeWritten() throws {
        try recording("a")
        let d = try draw(["a"])
        try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        let before = try Data(contentsOf: A.url(forVideo: video("a")))
        // A file where manifests/ should be: the row can't be recorded, so nothing is saved.
        let manifests = root.appendingPathComponent("manifests")
        try FileManager.default.removeItem(at: manifests)
        try "not a folder".write(to: manifests, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now)) { error in
            guard case A.Failure.ledgerNotWritten = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: A.url(forVideo: video("a"))), before, "the record is as it was: no verdict without its ledger row")
        XCTAssertThrowsError(try A.open("a", draw: d, root: root, now: now), "and nothing opens") { error in
            guard case A.Failure.ledgerNotWritten = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - A record from the phone (adoptSynced)

    /// A record made the way the phone makes one (the shared rules), for this Mac's draw.
    private func phoneRecord(_ d: A.LoadedDraw, _ name: String, reviewer: String = "phone-account", looks: [(Int, A.Entry)]) throws -> A.File {
        let recording = try XCTUnwrap(d.draw.recording(name))
        var file = A.File(recordingId: name, sourceFingerprint: recording.contentFingerprint, drawId: d.draw.drawId, drawSha256: d.sha256,
                          datasetName: d.draw.datasetName, marksSha256: "m", tool: "Labeler test")
        for (index, entry) in looks {
            let interval = try XCTUnwrap(recording.interval(index))
            file = try A.applying(A.Request(recordingId: name, index: index, pass: .first, entry: entry, reviewer: reviewer, played: all),
                                  reviewer: reviewer, to: file, interval: interval, recording: recording, now: now)
        }
        return file
    }

    func testAPhoneRecordIsTakenOnlyAfterItsUseIsOnTheLedgerAndByEveryLocalRule() throws {
        try recording("a")
        let d = try draw(["a"])
        let phone = try phoneRecord(d, "a", looks: [(0, .clean), (2, .finding(A.Finding(kind: .missedServe, approxStartSec: 9)))])
        let used = now.addingTimeInterval(-3600)
        try A.adoptSynced(phone, draw: d, root: root, firstUse: used, expectedLocal: nil, now: now)
        XCTAssertEqual(try onDisk("a"), phone)
        let rows = try auditRows()
        XCTAssertEqual(rows.map(\.video), ["a"], "one ledger row, the phone's use")
        XCTAssertEqual(try A.status(draw: d, root: root).first?.reviewed, 2, "the Mac counts the phone's looks as its own")
        // Another verdict here meanwhile: the synchronised record is not written over it.
        try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        XCTAssertThrowsError(try A.adoptSynced(phone, draw: d, root: root, firstUse: used, expectedLocal: phone, now: now)) { XCTAssertTrue($0 is A.LocalChanged, "\($0)") }
        XCTAssertEqual(try onDisk("a")?.review(1)?.verdict, .clean)
    }

    func testAPhoneRecordIsRefusedForOtherFootageAnotherDrawWrongBoundsABrokenRuleOrNoLedger() throws {
        try recording("a")
        let d = try draw(["a"])
        let good = try phoneRecord(d, "a", looks: [(0, .clean)])
        var other = good; other.sourceFingerprint = "file:other"
        XCTAssertThrowsError(try A.adoptSynced(other, draw: d, root: root, firstUse: nil, expectedLocal: nil, now: now), "other footage")
        other = good; other.drawSha256 = "beef"
        XCTAssertThrowsError(try A.adoptSynced(other, draw: d, root: root, firstUse: nil, expectedLocal: nil, now: now), "another draw's bytes")
        other = good; other.intervals[0].endTick += 1
        XCTAssertThrowsError(try A.adoptSynced(other, draw: d, root: root, firstUse: nil, expectedLocal: nil, now: now), "not the draw's bounds")
        other = good; other.intervals[0].playedAllAtMaxRate = nil
        XCTAssertThrowsError(try A.adoptSynced(other, draw: d, root: root, firstUse: nil, expectedLocal: nil, now: now), "a clean never played whole")
        XCTAssertNil(try onDisk("a"))
        XCTAssertEqual(try auditRows(), [], "a refused record puts nothing on the ledger")
        // The ledger can't be written: nothing is taken.
        let manifests = root.appendingPathComponent("manifests")
        try FileManager.default.removeItem(at: manifests)
        try "not a folder".write(to: manifests, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try A.adoptSynced(good, draw: d, root: root, firstUse: nil, expectedLocal: nil, now: now)) { error in
            guard case A.Failure.ledgerNotWritten = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(try onDisk("a"))
    }

    func testAPhoneRecordOfAWithheldRecordingIsRefused() throws {
        try recording("a")
        let d = try draw(["a"])
        let phone = try phoneRecord(d, "a", looks: [(0, .clean)])
        try writeValidation(#"{"tune":[],"holdout":["held","a"]}"#)
        refusedAsWithheld("a", containing: "holdout") { try A.adoptSynced(phone, draw: d, root: root, firstUse: nil, expectedLocal: nil, now: now) }
        XCTAssertNil(try onDisk("a"))
    }

    // MARK: - The withheld closure

    func testAWithheldRecordingIsRefusedByNameByTheDrawsIdentitiesAndByContent() throws {
        try recording("a")
        // By name: a draw that holds the withheld recording itself.
        let withHeld = try draw(["held"])
        refusedAsWithheld("held", containing: "withheld") { try A.record(request("held", 0, .clean, played: all), draw: withHeld, root: root, tool: "t", now: now) }
        refusedAsWithheld("held", containing: "withheld") { _ = try A.open("held", draw: withHeld, root: root, now: now) }
        // The final test is named as such.
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["held"]}"#)
        refusedAsWithheld("held", containing: "final_test") { _ = try A.open("held", draw: withHeld, root: root, now: now) }
        try writeValidation(#"{"tune":[],"holdout":["held"]}"#)

        // By content: another session over a byte copy of the withheld recording's file.
        try recording("copy", bytes: "the footage of held")
        let withCopy = try draw(["copy"])
        refusedAsWithheld("copy", containing: "content") { try A.record(request("copy", 0, .clean, played: all), draw: withCopy, root: root, tool: "t", now: now) }

        // By the identities the draw carries: the withheld card's confirmed source and registered fingerprint.
        let source = ClipSource(kind: .file, origin: video("held").path, start: 0, length: 10, license: "own", title: "held", uploader: "self", clipFile: video("held").path,
                                fetchedAt: now, videoId: nil, frames: nil, fingerprint: "file:registered-held", sourceId: "src-held", sessionId: nil, venueId: nil)
        let project = Project(name: "cov", createdAt: now, framesPerRally: 4, clips: [
            PlannedClip(id: "held", number: 1, environment: "beach", camera: "ele", lighting: "sun", orientation: "land", ball: "", notes: "", split: "train", videos: [source])])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: root.appendingPathComponent("project.json"))
        let bySource = try draw(["a"], id: "20261114-130000") { $0["sourceId"] = "src-held" }
        refusedAsWithheld("a", containing: "sourceId") { try A.record(request("a", 0, .clean, played: all), draw: bySource, root: root, tool: "t", now: now) }
        let byFingerprint = try draw(["a"], id: "20261114-140000") { $0["fingerprint"] = "file:registered-held" }
        refusedAsWithheld("a", containing: "fingerprint") { _ = try A.open("a", draw: byFingerprint, root: root, now: now) }

        XCTAssertEqual(try auditRows(), [], "no refused recording reaches the ledger")
        for name in ["held", "copy", "a"] { XCTAssertNil(try onDisk(name), "\(name): no record") }
        // The status names them and reads nothing of them.
        XCTAssertTrue(try XCTUnwrap(A.status(draw: withHeld, root: root).first?.problem).hasPrefix("withheld"))
    }

    func testAnEmptyOrUnreadableClosureAuditsNothing() throws {
        try recording("a")
        let d = try draw(["a"])
        try writeValidation(#"{"tune":[],"holdout":[]}"#)
        refused(.emptyClosure) { try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        refused(.emptyClosure) { _ = try A.open("a", draw: d, root: root, now: now) }
        refused(.emptyClosure) { _ = try A.status(draw: d, root: root) }
        try FileManager.default.removeItem(at: PipelineTuner.ValidationSet.file(in: root))
        refused(.emptyClosure, "no validation.json at all") { try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        try writeValidation("{not json")
        XCTAssertThrowsError(try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now), "unreadable reservations clear nothing")
        XCTAssertNil(try onDisk("a"))
        XCTAssertEqual(try auditRows(), [])
    }

    func testADamagedSessionFileRefusesEverything() throws {
        try recording("a"); try recording("b")
        let d = try draw(["a"])
        try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        // Another session's file can't be read: it may be a withheld recording's, so nothing is admitted.
        try "{not json".write(to: root.appendingPathComponent("sessions/b.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now))
        XCTAssertEqual(try onDisk("a")?.intervals.count, 1)
        // Repaired: the sessions are read again.
        try saveSession("b")
        XCTAssertNoThrow(try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now))
    }

    // MARK: - The draw, the file, the marks

    func testOnlyTheDrawsRecordingsAndIntervalsAreAudited() throws {
        try recording("a"); try recording("b")
        let d = try draw(["a"])
        refused(.notInDraw("b")) { try A.record(request("b", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        refused(.notInDraw("b")) { _ = try A.open("b", draw: d, root: root, now: now) }
        refused(.intervalNotInDraw(recording: "a", index: 3)) { try A.record(request("a", 3, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        // A recording the draw names that the project does not hold.
        let ghost = try draw(["a"], id: "20261114-130000") { $0["recordingId"] = "ghost" }
        refused(.noSession("ghost")) { _ = try A.open("ghost", draw: ghost, root: root, now: now) }
        refused(.noReviewer) { try A.record(request("a", 0, .clean, by: "  ", played: all), draw: d, root: root, tool: "t", now: now) }
        XCTAssertEqual(try auditRows(), [])
    }

    func testARecordingWhoseFileIsNotTheDrawsIsRefused() throws {
        try recording("a")
        let d = try draw(["a"])
        try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        let drawn = try XCTUnwrap(d.draw.recording("a")).contentFingerprint
        // The file is replaced (a re-encode, another cut): nothing is recorded against it.
        try Data("another cut of a, longer".utf8).write(to: video("a"), options: .atomic)
        let current = try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: video("a").path))
        XCTAssertNotEqual(current, drawn)
        refused(.sourceChanged(recording: "a", draw: drawn, current: current)) { try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        refused(.sourceChanged(recording: "a", draw: drawn, current: current)) { _ = try A.open("a", draw: d, root: root, now: now) }
        XCTAssertTrue(try XCTUnwrap(A.status(draw: d, root: root).first?.problem).contains("not the one the draw was made from"))
        // Gone altogether: the original is needed, not a review copy.
        try FileManager.default.removeItem(at: video("a"))
        refused(.videoMissing(video("a").path)) { try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
    }

    func testMarksChangedSinceTheDrawRefuseTheIntervalsTheyMoved() throws {
        try recording("a")
        let d = try draw(["a"])
        try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        // The second rally now starts at 5.5 s: interval 1 (4–6 s) is no longer an unmarked interval as drawn.
        try writeMarks("a", [(2, 4, "rally"), (5.5, 8, "rally")])
        refused(.marksChanged(recording: "a", index: 1)) { try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        refused(.marksChanged(recording: "a", index: 1)) {
            try A.record(request("a", 1, .finding(A.Finding(kind: .missedServe))), draw: d, root: root, tool: "t", now: now)
        }
        // The intervals the change left alone are still the draw's, and the record carries the marks as they are now.
        let after = try A.record(request("a", 2, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        XCTAssertEqual(after.marksSha256, DatasetSplitManifest.sha256(of: RallyMarkModel.labelsURL(for: video("a"))))
        XCTAssertNotEqual(after.marksSha256, try XCTUnwrap(d.draw.recording("a")).marksSha256)
        XCTAssertEqual(try XCTUnwrap(A.status(draw: d, root: root).first).movedIntervals, 1)
        // A cut range moves intervals as a mark does.
        try writeMarks("a", [(2, 4, "rally"), (6, 8, "rally")])
        try saveSession("a", cuts: [CutRange(start: 0, end: 0.5)])
        XCTAssertNil(try A.record(request("a", 0, .withdraw), draw: d, root: root, tool: "t", now: now).review(0), "a verdict on an interval that moved can still be withdrawn")
        refused(.marksChanged(recording: "a", index: 0)) { try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        // A mark that changes kind covers the same time: nothing moved.
        try saveSession("a")
        try writeMarks("a", [(2, 4, "missedServe"), (6, 8, nil)])
        XCTAssertNoThrow(try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now))
    }

    func testARecordingNotDeclaredCompleteOrWithoutMarksIsRefused() throws {
        try recording("a")
        let d = try draw(["a"])
        try saveSession("a", complete: false)
        refused(.notComplete("a")) { try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        try saveSession("a")
        XCTAssertNoThrow(try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now), "the session is read again once it changed")
        try "{not json".write(to: RallyMarkModel.labelsURL(for: video("a")), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now)) { error in
            guard case A.Failure.marksUnreadable = error else { return XCTFail("\(error)") }
        }
        try FileManager.default.removeItem(at: RallyMarkModel.labelsURL(for: video("a")))
        XCTAssertThrowsError(try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now)) { error in
            guard case A.Failure.marksUnreadable = error else { return XCTFail("\(error)") }
        }
    }

    func testOneRecordBelongsToOneDrawAndADamagedRecordIsNeverOverwritten() throws {
        try recording("a")
        let d = try draw(["a"])
        try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        let other = try draw(["a"], id: "20261120-090000")
        refused(.otherDraw(recording: "a", recorded: drawId, given: "20261120-090000")) { try A.record(request("a", 1, .clean, played: all), draw: other, root: root, tool: "t", now: now) }
        refused(.otherDraw(recording: "a", recorded: drawId, given: "20261120-090000")) { _ = try A.open("a", draw: other, root: root, now: now) }
        XCTAssertEqual(try auditRows().map(\.ref), ["coverage-audit \(drawId)"], "nothing of the refused draw")
        let url = A.url(forVideo: video("a"))
        try "{\"annotationVersion\":\"coverage_audit_v2\",\"broken\":true}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("broken"), "left as it is, for a person to repair")
    }

    // MARK: - Findings

    func testFindingsAddUpAndAreWithdrawnOneAtATime() throws {
        try recording("a")
        let d = try draw(["a"])
        func save(_ entry: A.Entry, played: A.PlayedCoverage = A.PlayedCoverage()) throws -> A.File {
            try A.record(request("a", 1, entry, played: played), draw: d, root: root, tool: "t", now: now)
        }
        let rally = A.Finding(kind: .missedRally, approxStartSec: 4.2, approxEndSec: 5.5), activity = A.Finding(kind: .nonRallyActivity, approxStartSec: 5.6)
        var file = try save(.finding(rally))
        XCTAssertEqual(file.review(1)?.verdict, .notClean)
        XCTAssertNil(file.review(1)?.playedAllAtMaxRate, "found before the interval was played whole")
        file = try save(.finding(activity), played: all)
        XCTAssertEqual(file.review(1)?.findings, [rally, activity])
        XCTAssertEqual(file.review(1)?.playedAllAtMaxRate, 2, "the whole interval has been played by now")
        refused(.hasFindings(index: 1), "clean never erases findings") { _ = try save(.clean, played: all) }
        file = try save(.withdrawLast)
        XCTAssertEqual(file.review(1)?.findings, [rally])
        file = try save(.withdrawLast)
        XCTAssertNil(file.review(1), "the last finding withdrawn leaves the interval unreviewed, never clean")
        refused(.nothingToWithdraw(index: 1)) { _ = try save(.withdrawLast) }
        refused(.nothingToWithdraw(index: 1)) { _ = try save(.withdraw) }
        // A finding over a clean makes it not clean; withdrawing a clean leaves nothing.
        _ = try save(.clean, played: all)
        file = try save(.finding(activity))
        XCTAssertEqual(file.review(1)?.verdict, .notClean); XCTAssertEqual(file.review(1)?.findings, [activity])
        XCTAssertEqual(file.review(1)?.playedAllAtMaxRate, 2, "it had been played whole for the clean")
        _ = try save(.withdraw)
        _ = try save(.clean, played: all)
        XCTAssertNil(try save(.withdrawLast).review(1))
    }

    func testFindingsFromAPartialLookLeaveTheIntervalOpenUntilItIsPlayedWhole() throws {
        try recording("a")
        let d = try draw(["a"], repeatSet: [])
        let intervals = try XCTUnwrap(d.draw.recording("a")).intervals
        for i in [0, 2] { try A.record(request("a", i, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        // Something is seen a second into interval 1 and noted at once: the rest of it has not been watched.
        let activity = A.Finding(kind: .nonRallyActivity, approxStartSec: 4.5)
        var file = try A.record(request("a", 1, .finding(activity), played: played((1800, 3000))), draw: d, root: root, tool: "t", now: now)
        XCTAssertNil(file.review(1)?.playedAllAtMaxRate)
        XCTAssertEqual(A.state(of: file, intervals: intervals).name, "partial", "an interval not watched whole is not reviewed")
        XCTAssertEqual(try XCTUnwrap(A.status(draw: d, root: root).first).partialLooks, 1)
        refused(.notPlayed(index: 1, missingSec: 1.0)) { try A.record(request("a", 1, .playedWhole, played: played((1800, 3000))), draw: d, root: root, tool: "t", now: now) }
        refused(.noFindings(index: 0), "a clean was played whole already") { try A.record(request("a", 0, .playedWhole, played: all), draw: d, root: root, tool: "t", now: now) }
        // Watched to its end: said on the verdict, the findings as they were.
        file = try A.record(request("a", 1, .playedWhole, played: played((1800, 4200), rate: 1)), draw: d, root: root, tool: "t", now: now.addingTimeInterval(60))
        XCTAssertEqual(file.review(1)?.playedAllAtMaxRate, 1)
        XCTAssertEqual(file.review(1)?.findings, [activity]); XCTAssertEqual(file.review(1)?.reviewedAt, "2026-11-14T18:00:00Z")
        XCTAssertEqual(A.state(of: file, intervals: intervals).name, "audited_clean")
        XCTAssertEqual(A.cleanIntervals(file).map(\.startTick), [0, 4800], "an interval with non-rally activity is reviewed, never clean")
        let status = try XCTUnwrap(A.status(draw: d, root: root).first)
        XCTAssertEqual(status.partialLooks, 0); XCTAssertEqual(status.reviewed, 3)
    }

    func testAFindingMustBeWellFormedAndInsideItsInterval() throws {
        try recording("a")
        let d = try draw(["a"])
        func save(_ finding: A.Finding) throws { try A.record(request("a", 1, .finding(finding)), draw: d, root: root, tool: "t", now: now) }
        refused(.uncertainWithoutNote) { try save(A.Finding(kind: .uncertain)) }
        refused(.uncertainWithoutNote) { try save(A.Finding(kind: .uncertain, note: " ")) }
        XCTAssertThrowsError(try save(A.Finding(kind: .missedServe, edge: .leading))) { guard case A.Failure.badFinding = $0 else { return XCTFail("\($0)") } }
        XCTAssertThrowsError(try save(A.Finding(kind: .missedRally, approxStartSec: 5, approxEndSec: 4.5))) { guard case A.Failure.badFinding = $0 else { return XCTFail("\($0)") } }
        XCTAssertThrowsError(try save(A.Finding(kind: .missedRally, approxStartSec: 8.5)), "interval 1 is 4–6 s") { guard case A.Failure.badFinding = $0 else { return XCTFail("\($0)") } }
        XCTAssertNil(try onDisk("a"))
        // Inside the second of context either side is where the reviewer was looking.
        XCTAssertNoThrow(try save(A.Finding(kind: .boundaryError, approxStartSec: 3.2, approxEndSec: 4.4, edge: .leading)))
        XCTAssertNoThrow(try save(A.Finding(kind: .uncertain, note: "the camera is knocked over")))
        XCTAssertNoThrow(try save(A.Finding(kind: .editedFootage, approxStartSec: 5, note: "slow-motion replay")))
        XCTAssertEqual(try onDisk("a")?.review(1)?.findings.map(\.kind), [.boundaryError, .uncertain, .editedFootage])
    }

    // MARK: - One look at each interval (amendment 2)

    func testNoSecondLookOrResolutionIsGivenWhateverTheDrawsRepeatSet() throws {
        try recording("a")
        let d = try draw(["a"], repeatSet: [1])
        func save(_ index: Int, _ entry: A.Entry, pass: A.Pass, by reviewer: String, after hours: Double) throws -> A.File {
            try A.record(request("a", index, entry, pass: pass, by: reviewer, played: all), draw: d, root: root, tool: "t", now: now.addingTimeInterval(hours * 3600))
        }
        _ = try save(0, .clean, pass: .first, by: "bw", after: 0)
        _ = try save(1, .clean, pass: .first, by: "bw", after: 0)
        _ = try save(2, .finding(A.Finding(kind: .uncertain, note: "glare")), pass: .first, by: "bw", after: 0)
        // Neither the draw's repeat interval nor the one left uncertain takes a second look — from anyone, at any time.
        refused(.noSecondLook(index: 1)) { _ = try save(1, .clean, pass: .repeatLook, by: "jr", after: 1) }
        refused(.noSecondLook(index: 1)) { _ = try save(1, .clean, pass: .repeatLook, by: "bw", after: 48) }
        refused(.noSecondLook(index: 2)) { _ = try save(2, .clean, pass: .repeatLook, by: "jr", after: 1) }
        refused(.noSecondLook(index: 1)) { _ = try save(1, .clean, pass: .resolution, by: "bw", after: 1) }
        let file = try XCTUnwrap(onDisk("a"))
        XCTAssertNil(file.repeatPass); XCTAssertEqual(file.resolutions, [])
        let status = try XCTUnwrap(A.status(draw: d, root: root).first)
        XCTAssertEqual([status.firstLeft, status.resolveLeft, status.unresolved], [0, 0, 0], "the review is finished with the first looks")
        XCTAssertEqual(status.findings, [.uncertain: 1], "the uncertain interval stands as uncertain")
        XCTAssertEqual(A.cleanIntervals(file).map(\.startTick), [0, 2400], "and supplies no negative")
    }

    func testARecordThatHoldsASecondLookIsStillReadAndItsResolutionCounts() throws {
        try recording("a")
        let d = try draw(["a"], repeatSet: [0, 1])
        for i in 0...2 { try A.record(request("a", i, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        let at = EventReview.stamp(now)
        try hold("a", .init(pass: .repeatLook, index: 1), .repeatLook(A.RepeatReview(index: 1, verdict: .notClean, reviewer: "jr", reviewedAt: at, playedAllAtMaxRate: 2,
                                                                                    findings: [A.Finding(kind: .missedRally, approxStartSec: 4.5)])))
        var file = try XCTUnwrap(onDisk("a"))
        XCTAssertEqual(A.disagreements(in: file), [1])
        XCTAssertEqual(A.cleanIntervals(file).map(\.startTick), [0, 4800], "the disputed interval is not clean until a resolution settles it")
        XCTAssertEqual(try XCTUnwrap(A.status(draw: d, root: root).first).unresolved, 1)
        refused(.frozen(index: 1, by: "repeat verdict")) { try A.record(request("a", 1, .withdraw, played: all), draw: d, root: root, tool: "t", now: now) }
        try hold("a", .init(pass: .resolution, index: 1), .resolution(A.Resolution(index: 1, verdict: .clean, reviewer: "bw", resolvedAt: at, playedAllAtMaxRate: 2)))
        file = try XCTUnwrap(onDisk("a"))
        XCTAssertEqual(A.cleanIntervals(file).map(\.startTick), [0, 2400, 4800])
        XCTAssertEqual(A.state(of: file, intervals: try XCTUnwrap(d.draw.recording("a")).intervals).name, "audited_clean")
    }

    // MARK: - Opening

    func testOpenAdmitsLogsTheUseAndReturnsTheRecord() throws {
        try recording("a")
        let d = try draw(["a"])
        let first = try A.open("a", draw: d, root: root, now: now)
        XCTAssertNil(first.file, "no record before the first verdict")
        XCTAssertNil(try onDisk("a"), "opening writes no record")
        XCTAssertEqual(first.admission.currentIntervals, try XCTUnwrap(d.draw.recording("a")).intervals)
        XCTAssertEqual(first.admission.video.path, video("a").path)
        XCTAssertEqual(try auditRows().map(\.video), ["a"], "the use is on the ledger before a frame is shown")
        let written = try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        XCTAssertEqual(try A.open("a", draw: d, root: root, now: now).file, written)
        XCTAssertEqual(try auditRows().count, 1)
    }

    // MARK: - Reports

    func testStatusCountsWhatTheRecordsSay() throws {
        try recording("a"); try recording("b"); try recording("c", marks: [(0, 10, "rally")])
        let d = try draw(["a", "b", "c"], repeatSet: [])
        for i in 0...2 { try A.record(request("a", i, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        try A.record(request("b", 0, .finding(A.Finding(kind: .missedRally, approxStartSec: 0.5, approxEndSec: 1.5, edge: .start)), played: all), draw: d, root: root, tool: "t", now: now)
        try A.record(request("b", 1, .finding(A.Finding(kind: .uncertain, note: "a tree")), played: all), draw: d, root: root, tool: "t", now: now)
        let ledger = try Data(contentsOf: ExposureLog.url(in: root))
        let statuses = try A.status(draw: d, root: root)
        XCTAssertEqual(statuses.map(\.recordingId), ["a", "b", "c"])
        XCTAssertEqual(statuses.map(\.state.text), ["audited_clean", "contaminated (and partial)", "audited_clean"])
        XCTAssertEqual(statuses.map(\.reviewed), [3, 2, 0]); XCTAssertEqual(statuses.map(\.total), [3, 3, 0])
        XCTAssertEqual(statuses[1].findings, [.missedRally: 1, .uncertain: 1])
        XCTAssertEqual(statuses.map(\.rallyMarks), [2, 2, 1])
        XCTAssertEqual(statuses.compactMap(\.problem), [])
        let lines = A.statusLines(statuses, draw: d.draw)
        XCTAssertTrue(lines[0].contains("draw \(drawId) (rc-v1-20261112): 3 recording(s), 6 interval(s)"), lines[0])
        XCTAssertTrue(lines[2].contains("2/3 reviewed · contaminated (and partial) · findings: missed_rally 1, uncertain 1"), lines[2])
        XCTAssertTrue(lines[4].contains("5/6 intervals reviewed · audited_clean 2 · partial 0 · contaminated 1"), lines[4])
        XCTAssertTrue(lines[5].contains("missed rallies + missed serves 1 against 5 rally mark(s)"), lines[5])
        XCTAssertEqual(try Data(contentsOf: ExposureLog.url(in: root)), ledger, "the status writes nothing")
        XCTAssertNil(try onDisk("c"))
    }

    /// The draw holds only recordings typed continuous. One a person typed otherwise since is named with the reason,
    /// counted nowhere, and does not hold the stage open; a type that can't be read is a problem, and does.
    func testARecordingTypedOtherwiseSinceTheDrawIsSetAsideAndCountsNowhere() throws {
        try recording("a"); try recording("b")
        let d = try draw(["a", "b"], repeatSet: [])
        for i in 0...2 { try A.record(request("a", i, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        try A.record(request("b", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        let properties = FootageProperties.Store(root: root)
        try properties.save(FootageProperties.File(video: "a", recordingType: .continuous, updatedAt: EventReview.stamp(now)))
        XCTAssertEqual(try A.status(draw: d, root: root).compactMap(\.setAside), [], "typed continuous: audited as before")
        XCTAssertNotNil(A.incompleteness(of: try A.status(draw: d, root: root)), "b owes two looks")

        try properties.save(FootageProperties.File(video: "b", recordingType: .edited, updatedAt: EventReview.stamp(now)))
        let statuses = try A.status(draw: d, root: root)
        XCTAssertEqual(statuses.map(\.setAside), [nil, "typed edited since the draw: not audited, and no source of negatives"])
        XCTAssertEqual(statuses.map(\.reviewed), [3, 0], "nothing of its record is counted")
        XCTAssertNil(statuses[1].problem)
        XCTAssertNil(A.incompleteness(of: statuses), "a set-aside recording owes no look")
        let lines = A.statusLines(statuses, draw: d.draw)
        XCTAssertTrue(lines[2].hasSuffix("typed edited since the draw: not audited, and no source of negatives"), lines[2])
        XCTAssertTrue(lines[3].contains("3/3 intervals reviewed · audited_clean 1 · partial 0 · contaminated 0"), lines[3])
        XCTAssertTrue(lines[4].contains("against 2 rally mark(s)"), lines[4])

        try Data("not json".utf8).write(to: FootageProperties.url(in: root, video: "b"))
        let unread = try A.status(draw: d, root: root)
        XCTAssertNil(unread[1].setAside)
        XCTAssertTrue(unread[1].problem?.contains("footage type can't be read") == true, unread[1].problem ?? "nil")
        XCTAssertNotNil(A.incompleteness(of: unread))
    }

    func testTheFindingsListIsWhatCountsAndIsNeverOverwritten() throws {
        try recording("a"); try recording("b")
        let d = try draw(["a", "b"], repeatSet: [1])
        try A.record(request("a", 0, .finding(A.Finding(kind: .boundaryError, approxStartSec: 0.2, approxEndSec: 1.6, edge: .trailing)), played: all), draw: d, root: root, tool: "t", now: now)
        try A.record(request("a", 1, .clean, played: all), draw: d, root: root, tool: "t", now: now)
        // A second look from before amendment 2, disagreeing with the first.
        try hold("a", .init(pass: .repeatLook, index: 1), .repeatLook(A.RepeatReview(index: 1, verdict: .notClean, reviewer: "jr", reviewedAt: EventReview.stamp(now), playedAllAtMaxRate: 2,
                                                                                    findings: [A.Finding(kind: .missedServe, approxStartSec: 5)])))
        try A.record(request("b", 2, .finding(A.Finding(kind: .editedFootage, approxStartSec: 8.5, note: "replay")), played: all), draw: d, root: root, tool: "t", now: now)
        var list = try A.findingsList(draw: d, root: root, now: now)
        XCTAssertEqual(list.findings.map { "\($0.recordingId) \($0.intervalIndex) \($0.kind.rawValue)" }, ["a 0 boundary_error", "b 2 edited_footage"])
        XCTAssertEqual(list.notListed, ["a interval 1: the first and the repeat verdict disagree, not resolved"])
        XCTAssertEqual(list.findings[0].intervalEndSec, 2.0); XCTAssertEqual(list.findings[0].edge, .trailing)
        // Resolved: the resolution's finding is the one listed.
        try hold("a", .init(pass: .resolution, index: 1), .resolution(A.Resolution(index: 1, verdict: .notClean, findings: [A.Finding(kind: .missedServe, approxStartSec: 5.1)],
                                                                                   reviewer: "bw", resolvedAt: EventReview.stamp(now), playedAllAtMaxRate: 2)))
        list = try A.findingsList(draw: d, root: root, now: now)
        XCTAssertEqual(list.findings.map(\.kind), [.boundaryError, .missedServe, .editedFootage]); XCTAssertEqual(list.notListed, [])
        let text = A.findingsText(list)
        XCTAssertTrue(text.contains("The audit wrote no mark."), text)
        XCTAssertTrue(text.contains("  interval 0 (0:00.0–0:02.0)  boundary_error  ~0:00.2–0:01.6  edge: trailing"), text)
        XCTAssertTrue(text.contains("  interval 2 (0:08.0–0:10.0)  edited_footage  ~0:08.5  — replay"), text)
        let out = try A.writeFindings(list, in: root, stamp: "20261114-180000")
        XCTAssertEqual(out.json.lastPathComponent, "\(drawId)-findings-20261114-180000.json")
        XCTAssertEqual(try JSONDecoder().decode(A.FindingsList.self, from: Data(contentsOf: out.json)), list)
        XCTAssertEqual(try String(contentsOf: out.text, encoding: .utf8), text)
        XCTAssertThrowsError(try A.writeFindings(list, in: root, stamp: "20261114-180000"), "an existing list is never written over")
        let a = try XCTUnwrap(DatasetStore(root: root).loadSessionsStrict().first { $0.name == "a" })
        XCTAssertEqual(try XCTUnwrap(RallyTruth.of(a)).positives.count, 2, "the audit wrote no mark: still the two rallies")
        // The footage of `b` replaced since: its findings describe other footage and are not listed.
        try Data("other footage".utf8).write(to: video("b"))
        list = try A.findingsList(draw: d, root: root, now: now)
        XCTAssertEqual(list.findings.map(\.recordingId), ["a", "a"])
        XCTAssertEqual(list.notListed, ["b: its file is not the one the draw was made from (replaced since): the findings' times describe other footage"])
    }

    func testTheReportsReadNothingOfASessionRepointedAtAWithheldFileAfterTheDraw() throws {
        try recording("a")
        let d = try draw(["a"], repeatSet: [])
        try A.record(request("a", 0, .finding(A.Finding(kind: .missedServe, approxStartSec: 0.5)), played: all), draw: d, root: root, tool: "t", now: now)
        XCTAssertEqual(try A.findingsList(draw: d, root: root, now: now).findings.count, 1)
        // `a`'s session now points at the withheld recording's file: the draw's frozen identities say nothing of it.
        var s = VideoSession(name: "a", sourcePath: video("held").path, split: "train", addedAt: now, frames: [])
        s.ralliesMarked = true
        try DatasetStore(root: root).save(s)
        let status = try XCTUnwrap(A.status(draw: d, root: root).first)
        XCTAssertTrue(status.problem?.hasPrefix("withheld (") == true, status.problem ?? "no problem")
        XCTAssertEqual([status.rallyMarks, status.reviewed], [0, 0], "nothing of the withheld recording's marks or record is read")
        let list = try A.findingsList(draw: d, root: root, now: now)
        XCTAssertEqual(list.findings.count, 0)
        XCTAssertTrue(list.notListed.first?.hasPrefix("a: withheld (") == true, "\(list.notListed)")
    }

    func testFirstPassWorkLeftCountsOnlyIntervalsStillAsDrawn() throws {
        try recording("a")
        let d = try draw(["a"], repeatSet: [])
        for i in 0...1 { try A.record(request("a", i, .clean, played: all), draw: d, root: root, tool: "t", now: now) }
        XCTAssertEqual(try XCTUnwrap(A.status(draw: d, root: root).first).firstLeft, 1)
        // The first rally now starts earlier: interval 0, reviewed, is no longer as drawn; interval 2 is still unwatched.
        try writeMarks("a", [(1.5, 4, "rally"), (6, 8, "rally")])
        let status = try XCTUnwrap(A.status(draw: d, root: root).first)
        XCTAssertEqual([status.movedIntervals, status.reviewed, status.firstLeft], [1, 2, 1], "the unwatched interval is still work left")
        // A finding given before the interval played whole is work left too.
        try A.record(request("a", 2, .finding(A.Finding(kind: .missedServe, approxStartSec: 9)), played: A.PlayedCoverage()), draw: d, root: root, tool: "t", now: now)
        XCTAssertEqual(try XCTUnwrap(A.status(draw: d, root: root).first).firstLeft, 1)
        try A.record(request("a", 2, .playedWhole, played: all), draw: d, root: root, tool: "t", now: now)
        XCTAssertEqual(try XCTUnwrap(A.status(draw: d, root: root).first).firstLeft, 0)
    }

    func testAnUnfinishedLookIsCompletedBeneathALaterOneByItsOwnReviewerOnly() throws {
        try recording("a")
        let d = try draw(["a"], repeatSet: [1])
        // bw gives a finding before interval 1 has played whole; the record also holds jr's second look (from before amendment 2).
        try A.record(request("a", 1, .finding(A.Finding(kind: .missedServe, approxStartSec: 5)), played: A.PlayedCoverage()), draw: d, root: root, tool: "t", now: now)
        try hold("a", .init(pass: .repeatLook, index: 1), .repeatLook(A.RepeatReview(index: 1, verdict: .clean, reviewer: "jr", reviewedAt: EventReview.stamp(now), playedAllAtMaxRate: 2)))
        refused(.frozen(index: 1, by: "repeat verdict"), "a verdict under a later look is still frozen") {
            try A.record(request("a", 1, .finding(A.Finding(kind: .uncertain, note: "?")), played: all), draw: d, root: root, tool: "t", now: now)
        }
        refused(.othersLook(index: 1, reviewer: "bw"), "only the look's own reviewer can say it was watched to its end") {
            try A.record(request("a", 1, .playedWhole, by: "jr", played: all), draw: d, root: root, tool: "t", now: now)
        }
        let file = try A.record(request("a", 1, .playedWhole, played: all), draw: d, root: root, tool: "t", now: now)
        XCTAssertEqual(file.review(1)?.playedAllAtMaxRate, 2)
        XCTAssertEqual(file.review(1)?.findings.map(\.kind), [.missedServe], "the verdict is as it was")
        XCTAssertEqual(file.repeatReview(1)?.verdict, .clean, "the later look stays")
    }

    func testNoOneChangesAnotherReviewersLook() throws {
        try recording("a")
        let d = try draw(["a"], repeatSet: [0])
        try A.record(request("a", 0, .clean, played: all), draw: d, root: root, tool: "t", now: now)            // bw watched it whole
        // jr, having watched nothing, can neither add to bw's look (and inherit its play coverage) nor take it back.
        refused(.othersLook(index: 0, reviewer: "bw")) {
            try A.record(request("a", 0, .finding(A.Finding(kind: .missedServe, approxStartSec: 1)), by: "jr"), draw: d, root: root, tool: "t", now: now)
        }
        refused(.othersLook(index: 0, reviewer: "bw")) { try A.record(request("a", 0, .withdraw, by: "jr"), draw: d, root: root, tool: "t", now: now) }
        let file = try XCTUnwrap(onDisk("a"))
        XCTAssertEqual([file.review(0)?.reviewer, file.review(0)?.verdict.rawValue], ["bw", "clean"])
    }

    func testAReplacementDrawKeepsTheOldRecordAndStartsAFreshOne() throws {
        try recording("a")
        let old = try draw(["a"], repeatSet: [])
        try A.record(request("a", 0, .finding(A.Finding(kind: .missedRally, approxStartSec: 1)), played: all), draw: old, root: root, tool: "t", now: now)
        let before = try Data(contentsOf: A.url(forVideo: video("a")))
        // A draw that does not say it replaces the old one: the old record stands in its way.
        let other = try draw(["a"], id: "20261116-090000")
        XCTAssertThrowsError(try A.open("a", draw: other, root: root, now: now)) { error in
            guard case A.Failure.otherDraw = error else { return XCTFail("\(error)") }
        }
        // The replacement (the draw tool's --reason, recorded in `supersedes`): the status says what will happen …
        let replacement = try draw(["a"], id: "20261116-100000", repeatSet: [], supersedes: [drawId])
        XCTAssertTrue(try XCTUnwrap(A.status(draw: replacement, root: root).first).problem?.contains("which this draw supersedes") == true)
        // … and opening keeps the old record whole under its draw's id and starts afresh: no old verdict is reused.
        let opened = try A.open("a", draw: replacement, root: root, now: now)
        XCTAssertNil(opened.file)
        XCTAssertEqual(try Data(contentsOf: A.supersededURL(forVideo: video("a"), drawId: drawId)), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: A.url(forVideo: video("a")).path))
        let fresh = try A.record(request("a", 0, .clean, played: all), draw: replacement, root: root, tool: "t", now: now)
        XCTAssertEqual([fresh.drawId, fresh.review(0)?.verdict.rawValue], ["20261116-100000", "clean"])
    }
}
