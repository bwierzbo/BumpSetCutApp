//
//  CoverageAuditModelTests.swift
//  RallyLabTests
//
//  The Audit tab's model against a real player: a committed 3 s clip in a synthetic
//  project, played by the model's own AVPlayer. What plays earns coverage and a clean;
//  a seek earns none; the queue moves on after a verdict; findings take the playhead or
//  the marked in/out; undo takes the last verdict back; leaving the tab releases the
//  player and coming back reopens the place. Every verdict here went through
//  CoverageAudit.record — the records and the ledger are read back from disk.
//

import AVFoundation
import XCTest
@testable import RallyLab

@MainActor
final class CoverageAuditModelTests: XCTestCase {
    private typealias A = CoverageAudit
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let now = ISO8601DateFormatter().date(from: "2026-11-14T18:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("covm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try DatasetStore(root: root).prepare()
        suite = "CoverageAuditModelTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // Something withheld, so the closure is not empty; and two recordings of 3 s with a rally at 1–2 s:
        // unmarked 0–1 s (ticks 0–600) and 2–3 s (1200–1800).
        try recording("held", bytes: Data("the footage of held".utf8))
        try "{\"tune\":[],\"holdout\":[\"held\"]}".write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
        let clip = try Data(contentsOf: fixture("h264-damaged-inter-frame"))
        try recording("v", bytes: clip)
        try recording("w", bytes: clip + Data([0]))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ resource: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        return try XCTUnwrap(bundle.url(forResource: resource, withExtension: "mp4") ?? bundle.url(forResource: resource, withExtension: "mp4", subdirectory: "Fixtures"),
                             "\(resource).mp4 is not in the test bundle")
    }

    private func video(_ name: String) -> URL { root.appendingPathComponent("footage/\(name).mp4") }

    private func recording(_ name: String, bytes: Data) throws {
        try FileManager.default.createDirectory(at: video(name).deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: video(name), options: .atomic)
        try "[{\"startTime\":1.0,\"endTime\":2.0,\"kind\":\"rally\"}]".write(to: RallyMarkModel.labelsURL(for: video(name)), atomically: true, encoding: .utf8)
        var s = VideoSession(name: name, sourcePath: video(name).path, split: "train", addedAt: now, frames: [])
        s.ralliesMarked = true
        try DatasetStore(root: root).save(s)
    }

    private func writeDraw(_ names: [String]) throws {
        let recordings: [[String: Any]] = names.map { name in
            ["recordingId": name, "groupId": name, "contentFingerprint": ProjectsModel.fileFingerprint(atPath: video(name).path) ?? "",
             "marksSha256": DatasetSplitManifest.sha256(of: RallyMarkModel.labelsURL(for: video(name))) ?? "", "durationTicks": 1800,
             "intervals": [["index": 0, "startTick": 0, "endTick": 600], ["index": 1, "startTick": 1200, "endTick": 1800]], "repeatIndices": [1]]
        }
        let json: [String: Any] = ["schemaVersion": A.drawVersion, "stage": "pilot", "drawId": "20261114-120000", "dataset": ["name": "rc-test", "timescale": 600], "recordings": recordings]
        let url = A.drawsDirectory(in: root).appendingPathComponent("20261114-120000-draw.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }

    private func wait(_ what: String, seconds: Double = 20, file: StaticString = #filePath, line: UInt = #line, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func onDisk(_ name: String) throws -> A.File? {
        let url = A.url(forVideo: video(name))
        return FileManager.default.fileExists(atPath: url.path) ? try A.read(url) : nil
    }

    private func model() async throws -> CoverageAuditModel {
        try writeDraw(["v", "w"])
        // Nobody signed in, whatever session the test host keeps: the reviewer is the typed name.
        let model = CoverageAuditModel(sampler: SamplerModel(defaults: defaults, root: root), tool: "RallyLab test", signedIn: { .nobody })
        model.typedName = "bw"
        model.activate()
        // Until the account is told, no verdict would be taken.
        XCTAssertEqual(model.reviewer, "")
        while model.signedIn == .unknown { await Task.yield() }
        XCTAssertEqual(model.reviewer, "bw")
        XCTAssertEqual(model.drawFiles.map(\.lastPathComponent), ["20261114-120000-draw.json"])
        model.openDraw(try XCTUnwrap(model.drawFiles.first))
        XCTAssertEqual(model.draw?.draw.drawId, "20261114-120000")
        return model
    }

    func testPlayingAnIntervalEarnsItsCleanAndTheQueueMovesOn() async throws {
        let model = try await model()
        try await wait("the recordings' status") { model.statuses.count == 2 }
        await model.open("v")
        XCTAssertEqual(model.recordingId, "v")
        XCTAssertNotNil(model.player)
        XCTAssertEqual(model.intervalIndex, 0, "the first interval to review is on screen")
        XCTAssertEqual(model.rate, 2, "at 2× unless slowed")
        XCTAssertTrue(model.isPlaying, "and playing")
        XCTAssertEqual(try ExposureLog.readStrict(in: root).filter { $0.kind == .coverageAudit }.map(\.video), ["v"], "opening put the use on the ledger")

        // Clean at once: refused, nothing written.
        model.markClean()
        try await wait("the refusal") { !model.busy }
        XCTAssertTrue(model.lastRefused); XCTAssertTrue(model.status.contains("has not been played whole"), model.status)
        XCTAssertNil(try onDisk("v"))

        // Played through its second of lead-out, the player stops by itself; the interval is covered.
        try await wait("interval 0 to play through") { !model.isPlaying }
        let first = try XCTUnwrap(model.interval)
        XCTAssertEqual(first.span, A.Span(startTick: 0, endTick: 600))
        XCTAssertTrue(model.played.covers(first.span), "\(model.played.spans)")
        XCTAssertGreaterThanOrEqual(model.playhead, 2.0 - 0.01, "it played the second after the interval too")
        XCTAssertLessThan(model.playhead, 2.3, "and stopped there")

        model.markClean()
        try await wait("the clean to be saved and the next interval to open") { !model.busy && model.intervalIndex == 1 }
        XCTAssertFalse(model.lastRefused, model.status)
        XCTAssertEqual(try onDisk("v")?.review(0)?.verdict, .clean)
        XCTAssertEqual(try onDisk("v")?.review(0)?.playedAllAtMaxRate, 2)
        XCTAssertEqual(try onDisk("v")?.review(0)?.reviewer, "bw")
        XCTAssertEqual(model.look(at: 0)?.verdict, .clean); XCTAssertNil(model.look(at: 1))

        // The last interval runs to the end of the file: played to its end, it is covered to the last tick.
        try await wait("interval 1 to play to the end of the file") { !model.isPlaying }
        XCTAssertTrue(model.played.covers(A.Span(startTick: 1200, endTick: 1800)), "\(model.played.spans)")
        model.markClean()
        // Nothing is left in `v`: the queue opens the draw's next recording.
        try await wait("the next recording to open") { !model.busy && model.recordingId == "w" && model.intervalIndex == 0 }
        let written = try XCTUnwrap(onDisk("v"))
        XCTAssertEqual(A.cleanIntervals(written), [A.Span(startTick: 0, endTick: 600), A.Span(startTick: 1200, endTick: 1800)])
        XCTAssertEqual(written.tool, "RallyLab test"); XCTAssertEqual(written.drawId, "20261114-120000")
        try await wait("the status to follow") { model.statuses.first?.state.name == "audited_clean" }
        XCTAssertEqual(try ExposureLog.readStrict(in: root).filter { $0.kind == .coverageAudit }.map(\.video), ["v", "w"])
        model.deactivate()
    }

    func testAFindingNotedMidIntervalIsCompletedOnceTheIntervalHasPlayed() async throws {
        let model = try await model()
        await model.open("v")
        // Something is seen at once and noted; the interval keeps playing.
        model.addFinding(.nonRallyActivity)
        try await wait("the finding") { !model.busy && model.currentLook != nil }
        XCTAssertEqual(model.currentLook?.playedWhole, false)
        XCTAssertNil(try onDisk("v")?.review(0)?.playedAllAtMaxRate)
        XCTAssertTrue(model.isPlaying, "noting a finding does not stop the interval")
        try await wait("interval 0 to play through") { !model.isPlaying }
        // Return: the verdict is completed (the interval was watched whole), then the queue moves on.
        await model.nextToReview()
        XCTAssertEqual(try onDisk("v")?.review(0)?.playedAllAtMaxRate, 2)
        XCTAssertEqual(try onDisk("v")?.review(0)?.findings.map(\.kind), [.nonRallyActivity])
        XCTAssertEqual(model.intervalIndex, 1)
        // Left before it has played whole, an interval with findings is not reviewed: Return moves on, the recording
        // stays partial and in the queue.
        model.addFinding(.missedServe)
        try await wait("the second finding") { !model.busy && model.currentLook != nil }
        model.togglePlay()
        XCTAssertFalse(model.isPlaying)
        await model.nextToReview()
        XCTAssertEqual(model.recordingId, "w", "on to the draw's next recording")
        XCTAssertNil(try onDisk("v")?.review(1)?.playedAllAtMaxRate)
        try await wait("the status") { model.statuses.first?.partialLooks == 1 }
        XCTAssertEqual(model.statuses.first?.state.text, "contaminated (and partial)")
        // Back in `v` nothing else is open: Return goes to the interval that was left.
        model.deactivate()
        await model.open("v", at: 0, play: false)
        await model.nextToReview()
        XCTAssertEqual(model.recordingId, "v"); XCTAssertEqual(model.intervalIndex, 1)
        model.deactivate()
    }

    func testSeekingEarnsNothingAndFindingsUndoAndTheNoteWork() async throws {
        let model = try await model()
        await model.open("w", at: 1, play: false)
        XCTAssertEqual(model.intervalIndex, 1); XCTAssertFalse(model.isPlaying)
        // Scrub all over the interval without playing: no coverage, no clean.
        for t in [1.2, 2.0, 2.6, 2.95, 1.5] { model.seek(to: t) }
        model.skip(1)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.played.spans, [], "a seek earns nothing")
        XCTAssertEqual(model.playhead, 2.5, accuracy: 0.05)
        model.markClean()
        try await wait("the refusal") { !model.busy }
        XCTAssertTrue(model.status.contains("has not been played whole"), model.status)
        XCTAssertNil(try onDisk("w"))

        // A finding takes the marked in and the playhead as its approximate times.
        model.seek(to: 2.2)
        model.setMarkIn()
        model.seek(to: 2.7)
        try await Task.sleep(nanoseconds: 300_000_000)
        model.addFinding(.missedServe)
        try await wait("the finding to be saved") { !model.busy && model.currentLook != nil }
        var finding = try XCTUnwrap(onDisk("w")?.review(1)?.findings.first)
        XCTAssertEqual(finding.kind, .missedServe)
        XCTAssertEqual(try XCTUnwrap(finding.approxStartSec), 2.2, accuracy: 0.05); XCTAssertEqual(try XCTUnwrap(finding.approxEndSec), 2.7, accuracy: 0.05)
        XCTAssertNil(model.markIn, "the in mark is used up")
        XCTAssertNil(try onDisk("w")?.review(1)?.playedAllAtMaxRate, "found without the interval played whole")

        // Uncertain asks for its note first; Return in the note field records it.
        model.addFinding(.uncertain)
        XCTAssertEqual(model.awaitingNote, .uncertain)
        XCTAssertEqual(try onDisk("w")?.review(1)?.findings.count, 1, "nothing is recorded until the note is typed")
        model.note = "the camera is bumped"
        model.noteSubmitted()
        try await wait("the uncertain finding") { !model.busy && model.currentLook?.findings.count == 2 }
        XCTAssertEqual(try onDisk("w")?.review(1)?.findings.last?.note, "the camera is bumped")
        XCTAssertEqual(model.note, "", "the note is used up")

        // A boundary error near the interval's start is the mark before ending early; ⇧ says the other one.
        model.seek(to: 2.1)
        try await Task.sleep(nanoseconds: 300_000_000)
        model.addFinding(.boundaryError)
        try await wait("the boundary error") { !model.busy && model.currentLook?.findings.count == 3 }
        finding = try XCTUnwrap(onDisk("w")?.review(1)?.findings.last)
        XCTAssertEqual(finding.edge, .leading)
        // A missed rally clipped by the recording's end, in the interval that runs to it.
        model.seek(to: 2.9)
        try await Task.sleep(nanoseconds: 300_000_000)
        model.addFinding(.missedRally, alternate: true)
        try await wait("the clipped rally") { !model.busy && model.currentLook?.findings.count == 4 }
        XCTAssertEqual(try onDisk("w")?.review(1)?.findings.last?.edge, .end)

        // Undo takes the last verdict back, one at a time; ⌫ the whole verdict.
        await model.undo()
        try await wait("the undo") { !model.busy && model.currentLook?.findings.count == 3 }
        XCTAssertEqual(try onDisk("w")?.review(1)?.findings.map(\.kind), [.missedServe, .uncertain, .boundaryError])
        model.withdraw()
        try await wait("the withdrawal") { !model.busy && model.currentLook == nil }
        XCTAssertNil(try onDisk("w")?.review(1))
        XCTAssertEqual(try XCTUnwrap(RallyTruth.marks(inSidecarOf: video("w"))).count, 1, "the audit wrote no mark")

        // Leaving the tab releases the player; coming back reopens the place.
        model.deactivate()
        XCTAssertNil(model.player); XCTAssertNil(model.recordingId)
        model.activate()
        try await wait("the recording to reopen") { model.recordingId == "w" && model.intervalIndex == 1 && model.player != nil }
        XCTAssertFalse(model.isPlaying, "it does not start playing by itself on the way back")
        model.projectChanged()
        XCTAssertNil(model.draw); XCTAssertNil(model.player); XCTAssertEqual(model.statuses, [])
    }

    /// A Mac with a labeling session records the labeler's id, never a typed name — and nothing while the account
    /// is not confirmed, so one person is not recorded under two names.
    func testNoVerdictIsTakenUntilTheSignedInLabelerIsConfirmed() async throws {
        final class Account: @unchecked Sendable {
            private let lock = NSLock()
            private var value = CoverageAuditModel.SignedIn.unknown
            func set(_ new: CoverageAuditModel.SignedIn) { lock.lock(); value = new; lock.unlock() }
            func get() -> CoverageAuditModel.SignedIn { lock.lock(); defer { lock.unlock() }; return value }
        }
        let account = Account()
        try writeDraw(["v", "w"])
        let model = CoverageAuditModel(sampler: SamplerModel(defaults: defaults, root: root), tool: "RallyLab test", signedIn: { account.get() })
        model.typedName = "bw"
        model.activate()
        model.openDraw(try XCTUnwrap(model.drawFiles.first))
        await model.open("w", at: 1, play: false)
        model.addFinding(.missedServe)
        XCTAssertTrue(model.lastRefused); XCTAssertTrue(model.status.contains("not confirmed yet"), model.status)
        XCTAssertFalse(model.busy, "nothing was sent to be saved")
        XCTAssertNil(try onDisk("w"))
        // The session is restored: the refusal asked again, and the id — not the typed name — is the reviewer.
        account.set(.labeler("0f0e0d0c-0000-4000-8000-000000000001"))
        model.addFinding(.missedServe)
        try await wait("the account") { model.signedIn != .unknown }
        XCTAssertEqual(model.reviewer, "0f0e0d0c-0000-4000-8000-000000000001")
        model.addFinding(.missedServe)
        try await wait("the finding") { !model.busy && model.currentLook != nil }
        XCTAssertEqual(try onDisk("w")?.review(1)?.reviewer, "0f0e0d0c-0000-4000-8000-000000000001")
        model.deactivate()
    }

    func testTheRepeatPassShowsOnlyItsOwnLookAndKeepsTheFirstReviewerOut() async throws {
        // Both intervals of `v` reviewed by bw a moment ago; interval 1 is the draw's repeat.
        try writeDraw(["v", "w"])
        let draw = try A.loadDraw(A.drawsDirectory(in: root).appendingPathComponent("20261114-120000-draw.json"))
        var all = A.PlayedCoverage()
        all.credit(fromTick: 0, toTick: 1800, rate: 2)
        try A.record(A.Request(recordingId: "v", index: 0, pass: .first, entry: .clean, reviewer: "bw", played: all), draw: draw, root: root, tool: "t")
        try A.record(A.Request(recordingId: "v", index: 1, pass: .first, entry: .finding(A.Finding(kind: .nonRallyActivity, approxStartSec: 2.5)), reviewer: "bw", played: all),
                     draw: draw, root: root, tool: "t")

        let model = try await model()
        model.setPass(.repeatLook)
        await model.open("v", at: 1, play: false)
        XCTAssertEqual(model.visibleIntervals.map(\.index), [1], "only the repeat set")
        XCTAssertNil(model.currentLook, "the first verdict is not the look on screen")
        XCTAssertNil(model.look(at: 1))
        // The first reviewer, minutes later: refused by the shared operation.
        model.addFinding(.nonRallyActivity)
        try await wait("the refusal") { !model.busy }
        XCTAssertTrue(model.lastRefused); XCTAssertTrue(model.status.contains("less than 24 hours ago"), model.status)
        XCTAssertNil(try onDisk("v")?.repeatPass)
        // A second reviewer's look is taken, and disagrees: the resolution pass shows it.
        model.typedName = "jr"
        model.addFinding(.missedServe)
        try await wait("the repeat verdict") { !model.busy && model.currentLook != nil }
        XCTAssertEqual(try onDisk("v")?.repeatPass?.method, "second_reviewer")
        XCTAssertEqual(model.currentLook?.findings.map(\.kind), [.missedServe])
        model.setPass(.resolution)
        XCTAssertEqual(model.visibleIntervals.map(\.index), [1])
        XCTAssertEqual(model.intervalIndex, 1)
        XCTAssertNil(model.currentLook, "no resolution yet")
        model.setPass(.first)
        XCTAssertEqual(model.visibleIntervals.map(\.index), [0, 1])
        model.deactivate()
    }

    func testWhatOneReviewerWatchedNeverCountsForAnother() async throws {
        let model = try await model()
        await model.open("v")
        try await wait("interval 0 to play through") { !model.isPlaying }
        XCTAssertTrue(model.played.covers(try XCTUnwrap(model.interval).span), "bw watched it")
        // Handed over without a labeling session: jr has watched nothing.
        model.typedName = "jr"
        XCTAssertFalse(model.played.covers(try XCTUnwrap(model.interval).span))
        model.markClean()
        try await wait("the refusal") { !model.busy }
        XCTAssertTrue(model.lastRefused); XCTAssertTrue(model.status.contains("has not been played whole"), model.status)
        XCTAssertNil(try onDisk("v"), "no verdict on another person's viewing")
        // Back to bw: bw's viewing still counts for bw.
        model.typedName = "bw"
        model.markClean()
        try await wait("bw's clean") { !model.busy && model.intervalIndex == 1 }
        XCTAssertEqual(try onDisk("v")?.review(0)?.reviewer, "bw")
        // Undo belongs to whoever gave the verdict.
        model.typedName = "jr"
        await model.undo()
        XCTAssertTrue(model.lastRefused); XCTAssertTrue(model.status.contains("only bw can undo it"), model.status)
        XCTAssertEqual(try onDisk("v")?.review(0)?.verdict, .clean)
        model.deactivate()
    }

    func testEnteringTheBlindRepeatShowsNothingOfTheFirstLook() async throws {
        let model = try await model()
        await model.open("v", play: false)
        // A first-pass finding, its feedback on screen; then straight to the repeat.
        model.addFinding(.missedServe)
        try await wait("the finding") { !model.busy && model.currentLook != nil }
        XCTAssertTrue(model.status.contains("missedServe") || model.status.contains("missed_serve"), model.status)
        model.setPass(.repeatLook)
        XCTAssertEqual(model.status, CoverageAuditModel.opening(.repeatLook))
        // A note typed in the first look and never sent is not on screen in the repeat either.
        model.setPass(.first)
        model.note = "a ball rolled in from the next court"
        model.setPass(.repeatLook)
        XCTAssertEqual(model.note, "", "the draft note was the first look's")
        // A first-pass save still in flight when the pass changes is kept, and says nothing.
        model.setPass(.first)
        await model.open("v", at: 1, play: false)
        model.addFinding(.nonRallyActivity)
        model.setPass(.repeatLook)
        try await wait("the save") { !model.busy }
        XCTAssertEqual(model.status, CoverageAuditModel.opening(.repeatLook), "nothing of the first look reaches the repeat")
        XCTAssertEqual(try onDisk("v")?.review(1)?.findings.map(\.kind), [.nonRallyActivity], "the save itself is kept")
        model.deactivate()
    }
}
