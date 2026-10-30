//
//  NetLabelsTests.swift
//  RallyLabTests
//
//  The net labels' rules: which recordings are skipped, where the frame is
//  taken, how a box becomes a YOLO line, the store failing closed, the export
//  plan refusing withheld recordings and labels of another recording, and the
//  tab never opening a skipped recording or saving a box for a frame that
//  isn't on screen.
//

import CoreGraphics
import XCTest
@testable import RallyLab

final class NetLabelsTests: XCTestCase {

    private static let box = TrackCandidate(rect: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1), confidence: 1)

    private static func label(fingerprint: String = "fp-a", time: Double = 1) -> NetLabel {
        NetLabel(time: time, box: box, proposed: false, adjusted: false, reviewedAt: Date(timeIntervalSince1970: 1_800_000_000),
                 frameWidth: 1920, frameHeight: 1080, fingerprint: fingerprint)
    }

    func testWithheldHandheldAndUnidentifiedAreSkipped() {
        let withheld: Set<String> = ["bch_onl_sun_land_onl_03"]
        XCTAssertEqual(NetLabels.skip(video: "bch_onl_sun_land_onl_03", camera: "Tripod / corner", withheld: withheld, fingerprint: "f"), .withheld)
        XCTAssertEqual(NetLabels.skip(video: "grs_hnd_sun_land_self_01", camera: "Handheld / corner", withheld: withheld, fingerprint: "f"), .handheld)
        XCTAssertEqual(NetLabels.skip(video: "grs_hnd_sun_land_self_01", camera: "handheld", withheld: withheld, fingerprint: "f"), .handheld)
        XCTAssertEqual(NetLabels.skip(video: "x", camera: "Tripod / corner", withheld: withheld, fingerprint: nil), .unidentified)
        XCTAssertNil(NetLabels.skip(video: "bch_ele_sun_port_self_03", camera: "End line, elevated (stands/tripod 2m+)", withheld: withheld, fingerprint: "f"))
        XCTAssertNil(NetLabels.skip(video: "grs_extra_self_01", camera: "Extra", withheld: withheld, fingerprint: "f"))
        // Withheld wins over the camera and over a missing identity.
        XCTAssertEqual(NetLabels.skip(video: "x", camera: "Handheld / corner", withheld: ["x"], fingerprint: nil), .withheld)
    }

    func testFrameComesFromTheFirstRallyLongEnoughElseTheMiddle() {
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: [(30, 31), (40, 50), (60, 70)]), 45)
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: [(60, 70), (40, 50)]), 45)
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: []), 50)
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: [(30, 31)]), 50)
        // A mark past the video's end (a trimmed copy) is not used.
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: [(95, 110)]), 50)
    }

    func testYOLOLineIsTopDownCentreAndSize() {
        // Vision box: x 0.1–0.6, y 0.2–0.3 from the bottom → centre y from the top is 0.75.
        XCTAssertEqual(NetLabels.yoloLine(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1)), "0 0.350000 0.750000 0.500000 0.100000")
        // Clipped to the frame first.
        XCTAssertEqual(NetLabels.yoloLine(CGRect(x: -0.1, y: 0.9, width: 0.4, height: 0.3)), "0 0.150000 0.050000 0.300000 0.100000")
        XCTAssertEqual(NetLabels.yoloLine(CGRect(x: 1.2, y: 0.2, width: 0.5, height: 0.1)), "")
        XCTAssertEqual(NetLabels.yoloLine(.zero), "")
    }

    func testStoreRoundTripsAndFailsClosedOnABadFile() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NetLabelStore(projectDir: dir)
        XCTAssertEqual(try store.load(), [:])
        let label = Self.label(fingerprint: "fp-1", time: 12.5)
        try store.save(["bch_a": label])
        XCTAssertEqual(try store.load(), ["bch_a": label])
        try Data("{not json".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }

    func testExportPlanRefusesWithheldOtherRecordingsLabelsAndSkipsUnlabeled() {
        func src(_ v: String, _ camera: String = "Tripod / corner", fp: String? = "fp-a") -> NetDatasetExport.Source {
            NetDatasetExport.Source(video: v, clip: v, camera: camera, url: URL(fileURLWithPath: "/nonexistent/\(v).mp4"), fingerprint: fp)
        }
        let sources = [src("c_labeled"), src("a_withheld_but_labeled"), src("b_unlabeled"), src("d_handheld", "Handheld / corner"),
                       src("e_replaced_video", fp: "fp-new"), src("f_no_identity", fp: nil)]
        let labels = ["c_labeled": Self.label(), "a_withheld_but_labeled": Self.label(), "d_handheld": Self.label(),
                      "e_replaced_video": Self.label(fingerprint: "fp-old"), "f_no_identity": Self.label()]
        let plan = NetDatasetExport.plan(labels: labels, sources: sources, withheld: ["a_withheld_but_labeled"])
        XCTAssertEqual(plan.export.map(\.video), ["c_labeled"])
        XCTAssertEqual(plan.skipped, [.init(video: "a_withheld_but_labeled", reason: "withheld"),
                                      .init(video: "b_unlabeled", reason: "unlabeled"),
                                      .init(video: "d_handheld", reason: "handheld"),
                                      .init(video: "e_replaced_video", reason: "label is another recording's (fingerprint differs)"),
                                      .init(video: "f_no_identity", reason: "unidentified")])
    }

    // MARK: - The tab

    /// Footage that answers from a script and records every call; a frame
    /// decode waits until the test lets it through.
    private final class ScriptedFootage: NetLabelFootage, @unchecked Sendable {
        let lock = NSLock()
        private(set) var durationCalls: [String] = []
        private(set) var frameCalls: [(String, Double)] = []
        private(set) var proposalCalls = 0
        var gate: CheckedContinuation<Void, Never>?
        var holdFrames = false
        var waiting: (() -> Void)?

        func duration(of url: URL) async -> Double {
            lock.withLock { durationCalls.append(url.lastPathComponent) }
            return 100
        }

        func frame(of url: URL, at time: Double) async throws -> CGImage {
            lock.withLock { frameCalls.append((url.lastPathComponent, time)) }
            if holdFrames {
                await withCheckedContinuation { c in lock.withLock { gate = c }; waiting?() }
            }
            return try Self.image()
        }

        func proposal(on frame: CGImage) -> (rect: CGRect, confidence: Float)? {
            lock.withLock { proposalCalls += 1 }
            return (CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1), 0.9)
        }

        func release() { lock.withLock { gate?.resume(); gate = nil } }

        static func image() throws -> CGImage {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try XCTUnwrap(ctx.makeImage())
        }
    }

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netlabels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func item(_ video: String, skip: NetLabels.Skip? = nil, fingerprint: String? = "fp-a", in dir: URL) throws -> NetLabelsModel.Item {
        // A readable file stands in for the video; the scripted footage never reads it.
        let url = dir.appendingPathComponent("\(video).mp4")
        try Data("x".utf8).write(to: url)
        return NetLabelsModel.Item(video: video, clip: video, camera: "Tripod / corner", url: url, fingerprint: fingerprint,
                                   skip: skip, labeled: false, stale: false)
    }

    @MainActor
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @MainActor
    func testASkippedRecordingIsNeverOpened() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let model = NetLabelsModel(items: [try item("a_withheld", skip: .withheld, in: dir), try item("b_handheld", skip: .handheld, in: dir),
                                           try item("c_ok", in: dir)],
                                   labels: [:], store: NetLabelStore(projectDir: dir), footage: footage)
        model.select("a_withheld")
        await settle()
        model.step(seconds: 1)
        _ = model.confirm()
        await settle()
        XCTAssertEqual(model.selected, "a_withheld")
        XCTAssertTrue(footage.durationCalls.isEmpty, "a withheld recording's file was read")
        XCTAssertTrue(footage.frameCalls.isEmpty, "a withheld recording was decoded")
        XCTAssertEqual(footage.proposalCalls, 0, "a withheld recording was shown to the model")
        XCTAssertNil(model.frame)
        XCTAssertFalse(model.canConfirm)

        model.select("b_handheld")
        await settle()
        XCTAssertTrue(footage.frameCalls.isEmpty)

        // The ordinary recording is opened, decoded once and proposed on.
        model.select("c_ok")
        await settle()
        XCTAssertEqual(footage.durationCalls, ["c_ok.mp4"])
        XCTAssertEqual(footage.frameCalls.map(\.0), ["c_ok.mp4"])
        XCTAssertEqual(footage.proposalCalls, 1)
        XCTAssertNotNil(model.frame)
        XCTAssertTrue(model.canConfirm)
    }

    @MainActor
    func testConfirmSavesOnlyTheFrameOnScreenAtItsTime() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let store = NetLabelStore(projectDir: dir)
        let model = NetLabelsModel(items: [try item("c_ok", in: dir), try item("d_next", in: dir)], labels: [:], store: store, footage: footage)
        model.select("c_ok")
        await settle()
        XCTAssertEqual(model.frameTime, 50)   // no rally marks: the middle of 100 s
        XCTAssertTrue(model.canConfirm)

        // Step a second; while the new frame is still decoding, confirming is refused.
        footage.holdFrames = true
        let held = expectation(description: "decode held")
        footage.waiting = { held.fulfill() }
        model.step(seconds: 1)
        await fulfillment(of: [held], timeout: 2)
        XCTAssertEqual(model.time, 51)
        XCTAssertEqual(model.frameTime, 50, "the old frame is still what's on screen")
        XCTAssertTrue(model.loading)
        XCTAssertFalse(model.canConfirm)
        XCTAssertFalse(model.confirm())
        XCTAssertEqual(try store.load(), [:])

        // Once it lands, the label is for 51 s, with the recording's fingerprint.
        footage.holdFrames = false
        footage.release()
        await settle()
        XCTAssertEqual(model.frameTime, 51)
        XCTAssertTrue(model.canConfirm)
        XCTAssertTrue(model.confirm())
        let saved = try XCTUnwrap(try store.load()["c_ok"])
        XCTAssertEqual(saved.time, 51)
        XCTAssertEqual(saved.fingerprint, "fp-a")
        XCTAssertTrue(saved.proposed)
        XCTAssertEqual(saved.frameWidth, 64)
        XCTAssertEqual(model.selected, "d_next", "moves on to the next recording to label")
    }

    @MainActor
    func testALabelOfAnotherRecordingIsStaleNotLabeled() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let model = NetLabelsModel(items: [try item("c_ok", fingerprint: "fp-new", in: dir)],
                                   labels: ["c_ok": Self.label(fingerprint: "fp-old", time: 7)],
                                   store: NetLabelStore(projectDir: dir), footage: footage)
        let it = try XCTUnwrap(model.items.first)
        XCTAssertFalse(it.labeled)
        XCTAssertTrue(it.stale)
        XCTAssertEqual(model.labeledCount, 0)
        XCTAssertEqual(model.toLabelCount, 1)
        model.select("c_ok")
        await settle()
        XCTAssertNil(model.current)
        XCTAssertEqual(model.frameTime, 50, "the stale label's frame time is not used")
        XCTAssertEqual(footage.proposalCalls, 1, "treated as unlabeled: a proposal is offered")
    }
}
