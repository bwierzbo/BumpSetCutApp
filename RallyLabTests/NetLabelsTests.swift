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

    /// A label with corners spanning `box`; `boxOnly` makes one from before corners existed.
    private static func label(fingerprint: String = "fp-a", time: Double = 1, boxOnly: Bool = false) -> NetLabel {
        NetLabel(time: time, box: box, corners: boxOnly ? nil : NetQuad(rect: box.rect), proposed: false, adjusted: false,
                 reviewedAt: Date(timeIntervalSince1970: 1_800_000_000), frameWidth: 1920, frameHeight: 1080, fingerprint: fingerprint)
    }

    func testCornersSpanABoxAndMoveOneAtATimeOrTogether() {
        let q = NetQuad(rect: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1))
        // Vision: the top is the larger y.
        XCTAssertEqual(q.topLeft, .init(x: 0.2, y: 0.5)); XCTAssertEqual(q.topRight, .init(x: 0.8, y: 0.5))
        XCTAssertEqual(q.bottomRight, .init(x: 0.8, y: 0.4)); XCTAssertEqual(q.bottomLeft, .init(x: 0.2, y: 0.4))
        func near(_ a: CGRect, _ b: CGRect, line: UInt = #line) {
            for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] { XCTAssertEqual(x, y, accuracy: 1e-9, line: line) }
        }
        func near(_ a: NetQuad.Point, _ b: NetQuad.Point, line: UInt = #line) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9, line: line); XCTAssertEqual(a.y, b.y, accuracy: 1e-9, line: line)
        }
        near(q.bounds, CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1))
        XCTAssertTrue(q.isUsable)
        // A perspective net: the right tape end lower than the left. The box grows to contain it.
        let tilted = q.moving(corner: 1, to: CGPoint(x: 0.85, y: 0.45)).moving(corner: 2, to: CGPoint(x: 0.85, y: 0.36))
        XCTAssertEqual(tilted.topRight, .init(x: 0.85, y: 0.45))
        XCTAssertEqual(tilted.topLeft, q.topLeft, "the other corners stay")
        near(tilted.bounds, CGRect(x: 0.2, y: 0.36, width: 0.65, height: 0.14))
        XCTAssertEqual(NetLabels.yoloLine(tilted.bounds), "0 0.525000 0.570000 0.650000 0.140000")
        // A corner dragged out of the frame stops at its edge.
        XCTAssertEqual(q.moving(corner: 0, to: CGPoint(x: -0.3, y: 1.4)).topLeft, .init(x: 0, y: 1))
        // The whole net moved: every corner by the same amount, no further than the frame allows.
        let moved = tilted.offset(dx: 0.1, dy: -0.1)
        near(moved.topLeft, .init(x: 0.3, y: 0.4)); near(moved.bottomRight, .init(x: 0.95, y: 0.26))
        XCTAssertEqual(tilted.offset(dx: 0.5, dy: 0).bounds.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(tilted.offset(dx: 0.5, dy: 0).topLeft.x, 0.35, accuracy: 1e-9)
        XCTAssertFalse(NetQuad(rect: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0)).isUsable)
        // Collapsed onto a diagonal: a bounding box with width and height, but no area.
        let diagonal = NetQuad(topLeft: .init(x: 0.2, y: 0.2), topRight: .init(x: 0.8, y: 0.8), bottomRight: .init(x: 0.7, y: 0.7), bottomLeft: .init(x: 0.3, y: 0.3))
        XCTAssertEqual(diagonal.area, 0, accuracy: 1e-12)
        XCTAssertFalse(diagonal.isUsable)
        XCTAssertEqual(q.area, 0.06, accuracy: 1e-12, "a rectangle's area")
        XCTAssertGreaterThan(tilted.area, 0.05)
        // Winding does not matter: the same corners the other way round have the same area.
        let reversed = NetQuad(topLeft: q.topRight, topRight: q.topLeft, bottomRight: q.bottomLeft, bottomLeft: q.bottomRight)
        XCTAssertEqual(reversed.area, q.area, accuracy: 1e-12)
    }

    /// A label written before corners existed (a box) still decodes, with no corners;
    /// one with corners round-trips through the file with them.
    func testALabelFromBeforeCornersDecodesAsBoxOnly() throws {
        let old = """
        {"bch_a": {"adjusted": true, "box": {"confidence": 1, "h": 0.1, "w": 0.6, "x": 0.2, "y": 0.4}, "fingerprint": "fp-a",
                   "frameHeight": 1080, "frameWidth": 1920, "proposed": true, "reviewedAt": "2026-10-31T03:56:38Z", "time": 10.5}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let labels = try decoder.decode([String: NetLabel].self, from: Data(old.utf8))
        let label = try XCTUnwrap(labels["bch_a"])
        XCTAssertNil(label.corners)
        XCTAssertEqual(label.box.rect, CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1))
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NetLabelStore(projectDir: dir)
        try store.save(["bch_a": label, "bch_b": Self.label(time: 3)])
        let back = try store.load()
        XCTAssertEqual(back["bch_a"], label)
        XCTAssertEqual(back["bch_b"]?.corners, NetQuad(rect: Self.box.rect))
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"topLeft\""), "corners are on file by name")
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

    /// The tab's identities and withheld set come from the split manifest, not from the video
    /// files; the manifest counts only while its hashes are the project's files'.
    func testInventoryComesFromTheSplitManifestAndRefusesAStaleOne() throws {
        func row(_ video: String, split: String, reservedAs: String? = nil, noFingerprint: Bool = false, aliasGroup: String? = nil) -> String {
            let fingerprint: String? = noFingerprint ? nil : "fp-\(video)"
            return """
            {"video":"\(video)","sourceId":{"origin":"unknown"},"sessionId":{"origin":"unknown"},"venueId":{"origin":"unknown"},
             "datasetSplit":"train","split":"\(split)",\(reservedAs.map { "\"reservedAs\":\"\($0)\"," } ?? "")
             \(aliasGroup.map { "\"aliasGroup\":\"\($0)\"," } ?? "")
             \(fingerprint.map { "\"fingerprint\":\"\($0)\"," } ?? "")"ralliesMarked":true,"frames":1,"reviewedFrames":1,
             "addedAt":"2026-10-30T00:00:00Z","exposure":[]}
            """
        }
        func manifest(projectJson: String, validationJson: String?) throws -> DatasetSplitManifest {
            // `w_legacy` is a legacy holdout by name only (the manifest sets no reservedAs for its aliases);
            // `legacy_alias` shares its alias group and is withheld through it; `ok` has a group of its own.
            let rows = [row("ok", split: "train", aliasGroup: "ok"), row("tuned", split: "tune"),
                        row("w_listed", split: "lineage_holdout", reservedAs: "listed"), row("w_alias", split: "train", reservedAs: "alias"),
                        row("w_legacy", split: "legacy_holdout", aliasGroup: "legacy_alias"),
                        row("legacy_alias", split: "train", aliasGroup: "legacy_alias"),
                        row("w_final", split: "final_test"), row("w_candidate", split: "final_test_candidate"),
                        row("nofp", split: "train", noFingerprint: true)]
            let json = """
            {"schemaVersion":1,"project":"Fixture","createdAt":"2026-10-30T00:00:00Z","generator":"test",
             "hashes":{"projectJson":"\(projectJson)"\(validationJson.map { ",\"validationJson\":\"\($0)\"" } ?? "")},
             "splitDefinitions":{},"videos":[\(rows.joined(separator: ","))]}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DatasetSplitManifest.self, from: Data(json.utf8))
        }
        let m = try manifest(projectJson: "p1", validationJson: "v1")
        let listed: Set<String> = ["w_listed", "w_legacy", "w_final", "w_candidate"]
        let inventory = try NetInventory.inventory(m, projectJSONHash: "p1", validationJSONHash: "v1", listed: listed)
        XCTAssertEqual(inventory.withheld, ["w_listed", "w_alias", "w_legacy", "legacy_alias", "w_final", "w_candidate"],
                       "the legacy holdout's unlisted alias is withheld through its alias group, as lineageWithheldNames withholds it")
        XCTAssertEqual(inventory.fingerprint, ["ok": "fp-ok", "tuned": "fp-tuned", "w_listed": "fp-w_listed", "w_alias": "fp-w_alias",
                                               "w_legacy": "fp-w_legacy", "legacy_alias": "fp-legacy_alias", "w_final": "fp-w_final",
                                               "w_candidate": "fp-w_candidate"])
        XCTAssertNil(inventory.fingerprint["nofp"], "no fingerprint on record: unidentified")
        XCTAssertThrowsError(try NetInventory.inventory(m, projectJSONHash: "p2", validationJSONHash: "v1", listed: listed)) {
            XCTAssertEqual($0 as? NetInventoryError, .stale("project.json"))
        }
        XCTAssertThrowsError(try NetInventory.inventory(m, projectJSONHash: "p1", validationJSONHash: "v2", listed: listed)) {
            XCTAssertEqual($0 as? NetInventoryError, .stale("pipeline_tuning/validation.json"))
        }
        XCTAssertThrowsError(try NetInventory.inventory(m, projectJSONHash: nil, validationJSONHash: "v1", listed: listed))
        // A withheld name with no manifest row (a legacy holdout without a dataset session): nothing
        // could seed its alias group, so the tab is blocked rather than labeling its aliases.
        XCTAssertThrowsError(try NetInventory.inventory(m, projectJSONHash: "p1", validationJSONHash: "v1", listed: listed.union(["ghost"]))) {
            XCTAssertEqual($0 as? NetInventoryError, .noRow("ghost"))
        }
        XCTAssertEqual(try NetInventory.inventory(try manifest(projectJson: "p1", validationJson: nil), projectJSONHash: "p1", validationJSONHash: nil, listed: []).withheld.count, 6,
                       "no validation.json then and none now: the manifest still counts")

        // From a project folder: the hashes are of the files as they are now.
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        let project = dir.appendingPathComponent("project.json"), validation = dir.appendingPathComponent("pipeline_tuning/validation.json")
        try Data("project".utf8).write(to: project)
        let validationJSON = """
        {"tune":["tuned"],"holdout":["w_legacy"],"lineageHoldout":["w_listed"],"finalTest":["w_final"],"finalTestCandidates":["w_candidate"]}
        """
        try Data(validationJSON.utf8).write(to: validation)
        XCTAssertThrowsError(try NetInventory.load(projectDir: dir)) { XCTAssertEqual($0 as? NetInventoryError, .noManifest(NetInventory.manifestURL(in: dir))) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let current = try manifest(projectJson: try XCTUnwrap(DatasetSplitManifest.sha256(of: project)),
                                   validationJson: try XCTUnwrap(DatasetSplitManifest.sha256(of: validation)))
        try encoder.encode(current).write(to: NetInventory.manifestURL(in: dir))
        XCTAssertEqual(try NetInventory.load(projectDir: dir).withheld.count, 6)
        // validation.json names a holdout the manifest has no row for → blocked (the hash is of the file as written).
        let withGhost = validationJSON.replacingOccurrences(of: "\"holdout\":[\"w_legacy\"]", with: "\"holdout\":[\"w_legacy\",\"ghost\"]")
        try Data(withGhost.utf8).write(to: validation)
        try encoder.encode(try manifest(projectJson: try XCTUnwrap(DatasetSplitManifest.sha256(of: project)),
                                        validationJson: try XCTUnwrap(DatasetSplitManifest.sha256(of: validation)))).write(to: NetInventory.manifestURL(in: dir))
        XCTAssertThrowsError(try NetInventory.load(projectDir: dir)) { XCTAssertEqual($0 as? NetInventoryError, .noRow("ghost")) }
        try Data(validationJSON.utf8).write(to: validation)
        try encoder.encode(current).write(to: NetInventory.manifestURL(in: dir))
        try Data("project changed".utf8).write(to: project)
        XCTAssertThrowsError(try NetInventory.load(projectDir: dir)) { XCTAssertEqual($0 as? NetInventoryError, .stale("project.json")) }
        try Data("project".utf8).write(to: project)
        // A validation.json that is there but can't be read (here: a folder at its path) is not "none",
        // even against a manifest written when there was none: the reservations are unknown.
        let noValidation = try manifest(projectJson: try XCTUnwrap(DatasetSplitManifest.sha256(of: project)), validationJson: nil)
        try encoder.encode(noValidation).write(to: NetInventory.manifestURL(in: dir))
        try FileManager.default.removeItem(at: validation)
        XCTAssertEqual(try NetInventory.load(projectDir: dir).withheld.count, 6, "no validation.json then and none now")
        try FileManager.default.createDirectory(at: validation, withIntermediateDirectories: false)
        func unreadable(_ error: Error) -> String? {
            if case .unreadable(let url)? = error as? NetInventoryError { return url.path }
            return nil
        }
        XCTAssertThrowsError(try NetInventory.load(projectDir: dir)) { XCTAssertEqual(unreadable($0), validation.path) }
        try FileManager.default.removeItem(at: project)
        XCTAssertThrowsError(try NetInventory.load(projectDir: dir)) { XCTAssertEqual(unreadable($0), project.path) }
    }

    func testExportPlanRefusesWithheldOtherRecordingsLabelsAndSkipsUnlabeled() {
        func src(_ v: String, _ camera: String = "Tripod / corner", fp: String? = "fp-a") -> NetDatasetExport.Source {
            NetDatasetExport.Source(video: v, clip: v, camera: camera, url: URL(fileURLWithPath: "/nonexistent/\(v).mp4"), fingerprint: fp)
        }
        let sources = [src("c_labeled"), src("a_withheld_but_labeled"), src("b_unlabeled"), src("d_handheld", "Handheld / corner"),
                       src("e_replaced_video", fp: "fp-new"), src("f_no_identity", fp: nil), src("g_box_only")]
        let labels = ["c_labeled": Self.label(), "a_withheld_but_labeled": Self.label(), "d_handheld": Self.label(),
                      "e_replaced_video": Self.label(fingerprint: "fp-old"), "f_no_identity": Self.label(),
                      "g_box_only": Self.label(boxOnly: true)]
        let plan = NetDatasetExport.plan(labels: labels, sources: sources, withheld: ["a_withheld_but_labeled"])
        XCTAssertEqual(plan.export.map(\.video), ["c_labeled"])
        XCTAssertEqual(plan.skipped, [.init(video: "a_withheld_but_labeled", reason: "withheld"),
                                      .init(video: "b_unlabeled", reason: "unlabeled"),
                                      .init(video: "d_handheld", reason: "handheld"),
                                      .init(video: "e_replaced_video", reason: "label is another recording's (fingerprint differs)"),
                                      .init(video: "f_no_identity", reason: "unidentified"),
                                      .init(video: "g_box_only", reason: NetDatasetExport.cornersNotMarked)])
    }

    // MARK: - The tab

    /// Footage that answers from a script and records every call; a frame
    /// decode waits until the test lets it through.
    private final class ScriptedFootage: NetLabelFootage, @unchecked Sendable {
        let lock = NSLock()
        private(set) var readableCalls: [String] = []
        private(set) var durationCalls: [String] = []
        private(set) var frameCalls: [(String, Double)] = []
        private(set) var proposalCalls = 0
        /// Every call in order, so a test can see the ledger row land before the model runs.
        private(set) var events: [String] = []
        var modelAvailable = true
        /// Held reads, oldest first; `release()` lets them all go, `releaseFirst()` the oldest.
        var gates: [CheckedContinuation<Void, Never>] = []
        var holdFrames = false
        /// Hold the readability check (the share's stat) until `release()`: the tab must stay responsive meanwhile.
        var holdReadable = false
        var waiting: (() -> Void)?

        func isReadable(_ url: URL) async -> Bool {
            lock.withLock { readableCalls.append(url.lastPathComponent) }
            if holdReadable {
                await withCheckedContinuation { c in lock.withLock { gates.append(c) }; waiting?() }
            }
            return true
        }

        func rallyMarks(for url: URL) async -> [(start: Double, end: Double)] { [] }

        func duration(of url: URL) async -> Double {
            lock.withLock { durationCalls.append(url.lastPathComponent) }
            return 100
        }

        func frame(of url: URL, at time: Double) async throws -> CGImage {
            lock.withLock { frameCalls.append((url.lastPathComponent, time)) }
            if holdFrames {
                await withCheckedContinuation { c in lock.withLock { gates.append(c) }; waiting?() }
            }
            return try Self.image()
        }

        func proposal(on frame: CGImage) -> (rect: CGRect, confidence: Float)? {
            lock.withLock { proposalCalls += 1; events.append("proposal") }
            return (CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1), 0.9)
        }

        func noteExposure(_ video: String) { lock.withLock { events.append("exposure \(video)") } }

        func release() { lock.withLock { gates.forEach { $0.resume() }; gates = [] } }
        func releaseFirst() { lock.withLock { if !gates.isEmpty { gates.removeFirst().resume() } } }

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
        var recorded: [String] = []
        let model = NetLabelsModel(items: [try item("a_withheld", skip: .withheld, in: dir), try item("b_handheld", skip: .handheld, in: dir),
                                           try item("c_ok", in: dir)],
                                   labels: [:], store: NetLabelStore(projectDir: dir), footage: footage) { v, _ in recorded.append(v) }
        model.select("a_withheld")
        await settle()
        model.step(seconds: 1)
        _ = model.confirm()
        await settle()
        XCTAssertEqual(model.selected, "a_withheld")
        XCTAssertTrue(footage.durationCalls.isEmpty, "a withheld recording's file was read")
        XCTAssertTrue(footage.frameCalls.isEmpty, "a withheld recording was decoded")
        XCTAssertEqual(footage.proposalCalls, 0, "a withheld recording was shown to the model")
        XCTAssertTrue(recorded.isEmpty, "no exposure row for a recording that was never opened")
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
        XCTAssertEqual(recorded, ["c_ok"])
        XCTAssertNotNil(model.frame)
        XCTAssertTrue(model.canConfirm)
    }

    /// The share can take seconds per file, or block for the SMB timeout when it has
    /// dropped: the readability check runs off the main actor, and while it is pending
    /// the tab still answers — another recording can be picked and the first load is dropped.
    @MainActor
    func testTheTabStaysResponsiveWhileTheFileIsChecked() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        footage.holdReadable = true
        let model = NetLabelsModel(items: [try item("c_ok", in: dir), try item("d_next", in: dir)],
                                   labels: [:], store: NetLabelStore(projectDir: dir), footage: footage) { _, _ in }
        model.select("c_ok")
        await settle()
        XCTAssertEqual(footage.readableCalls, ["c_ok.mp4"])
        XCTAssertTrue(model.loading, "the check is pending")
        XCTAssertTrue(footage.durationCalls.isEmpty, "nothing further is read until the file is known readable")
        // The main actor is free: the model answers and another recording can be picked.
        XCTAssertEqual(model.selected, "c_ok")
        footage.holdReadable = false
        model.select("d_next")
        await settle()
        XCTAssertEqual(model.selected, "d_next")
        XCTAssertEqual(footage.readableCalls, ["c_ok.mp4", "d_next.mp4"])
        XCTAssertEqual(footage.durationCalls, ["d_next.mp4"])
        footage.release()   // c_ok's check comes back late: it was superseded and changes nothing
        await settle()
        XCTAssertEqual(footage.durationCalls, ["d_next.mp4"])
        XCTAssertEqual(footage.frameCalls.map(\.0), ["d_next.mp4"])
        XCTAssertEqual(model.selected, "d_next")
        XCTAssertNotNil(model.frame)
    }

    @MainActor
    func testConfirmSavesOnlyTheFrameOnScreenAtItsTime() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let store = NetLabelStore(projectDir: dir)
        let model = NetLabelsModel(items: [try item("c_ok", in: dir), try item("d_next", in: dir)], labels: [:], store: store, footage: footage) { _, _ in }
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
        XCTAssertEqual(saved.corners, NetQuad(rect: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)), "the proposal's corners")
        XCTAssertEqual(saved.box.rect, saved.corners?.bounds)
        XCTAssertEqual(model.selected, "d_next", "moves on to the next recording to label")
    }

    /// A label from before corners existed is still to label: its box seeds the corners (no
    /// proposal, no ledger row), the person drags them, and the saved label carries them.
    @MainActor
    func testABoxOnlyLabelSeedsTheCornersAndIsStillToLabel() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let store = NetLabelStore(projectDir: dir)
        var recorded: [String] = []
        let model = NetLabelsModel(items: [try item("c_ok", in: dir)], labels: ["c_ok": Self.label(time: 7, boxOnly: true)],
                                   store: store, footage: footage) { v, _ in recorded.append(v) }
        let it = try XCTUnwrap(model.items.first)
        XCTAssertTrue(it.boxOnly); XCTAssertFalse(it.labeled); XCTAssertFalse(it.stale)
        XCTAssertEqual(model.toLabelCount, 1)
        XCTAssertTrue(model.status.contains("1 box-only"), model.status)
        model.select("c_ok")
        await settle()
        XCTAssertEqual(model.frameTime, 7, "the box label's frame")
        XCTAssertEqual(model.quad, NetQuad(rect: Self.box.rect), "its box seeds the corners")
        XCTAssertEqual(footage.proposalCalls, 0); XCTAssertTrue(recorded.isEmpty)
        XCTAssertNil(model.current)
        XCTAssertTrue(model.status.contains("drag the four corners"), model.status)
        let placed = try XCTUnwrap(model.quad).moving(corner: 1, to: CGPoint(x: 0.82, y: 0.47))
        model.setQuad(placed)
        XCTAssertTrue(model.adjusted)
        XCTAssertTrue(model.confirm())
        let saved = try XCTUnwrap(try store.load()["c_ok"])
        XCTAssertEqual(saved.corners, placed)
        XCTAssertEqual(saved.box.rect, placed.bounds)
        XCTAssertTrue(saved.adjusted)
        XCTAssertTrue(try XCTUnwrap(model.items.first).labeled)
        XCTAssertEqual(model.toLabelCount, 0)
    }

    /// The share takes seconds per frame: the next recordings' frames are read in the
    /// background while one is being labeled, never a skipped or labeled one, and a
    /// recording read ahead opens at once without touching its file again.
    @MainActor
    func testFramesAreReadAheadOfTheSelection() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let model = NetLabelsModel(items: [try item("c_ok", in: dir), try item("d_next", in: dir), try item("e_withheld", skip: .withheld, in: dir),
                                           try item("f_labeled", in: dir), try item("g_later", in: dir)],
                                   labels: ["f_labeled": Self.label()], store: NetLabelStore(projectDir: dir), footage: footage,
                                   prefetchAhead: 2) { _, _ in }
        await settle()
        // Nothing selected: reading starts at the top of the list, two ahead.
        XCTAssertEqual(footage.frameCalls.map(\.0), ["c_ok.mp4", "d_next.mp4"])
        XCTAssertEqual(Set(model.prefetched.keys), ["c_ok", "d_next"])
        XCTAssertEqual(footage.proposalCalls, 0, "reading ahead runs no model")
        model.select("c_ok")
        await settle()
        XCTAssertNotNil(model.frame)
        XCTAssertEqual(model.frameTime, 50)
        XCTAssertEqual(model.duration, 100)
        XCTAssertEqual(footage.proposalCalls, 1, "the proposal is made when the recording is shown")
        XCTAssertEqual(footage.frameCalls.map(\.0), ["c_ok.mp4", "d_next.mp4", "g_later.mp4"], "the window moves on past the selection")
        XCTAssertFalse(footage.frameCalls.contains { $0.0 == "e_withheld.mp4" || $0.0 == "f_labeled.mp4" })
        XCTAssertTrue(model.confirm())
        await settle()
        XCTAssertEqual(model.selected, "d_next")
        XCTAssertNotNil(model.frame, "read ahead: on screen without a decode")
        XCTAssertEqual(footage.frameCalls.map(\.0), ["c_ok.mp4", "d_next.mp4", "g_later.mp4"])
        XCTAssertNil(model.prefetched["c_ok"], "labeled: no longer kept")
    }

    /// The share is slow, so the recording on screen reads first: picking one that was not
    /// read ahead stops the read-ahead after the file it is on (that frame is kept), its own
    /// reads run alone, and the read-ahead goes on once its frame is up.
    @MainActor
    func testTheSelectionReadsBeforeTheReadAhead() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        footage.holdFrames = true
        let model = NetLabelsModel(items: [try item("c_ok", in: dir), try item("d_next", in: dir), try item("g_later", in: dir)],
                                   labels: [:], store: NetLabelStore(projectDir: dir), footage: footage, prefetchAhead: 2) { _, _ in }
        await settle()
        XCTAssertEqual(footage.frameCalls.map(\.0), ["c_ok.mp4"], "the read-ahead is on the first recording's frame")
        XCTAssertEqual(model.prefetching, "c_ok")
        model.select("g_later")   // not read ahead: its own reads come first
        await settle()
        XCTAssertTrue(model.loading)
        XCTAssertEqual(footage.durationCalls, ["c_ok.mp4", "g_later.mp4"])
        XCTAssertEqual(footage.frameCalls.map(\.0), ["c_ok.mp4", "g_later.mp4"], "no further read-ahead while the selection reads")
        footage.releaseFirst()   // c_ok's frame lands
        await settle()
        XCTAssertNotNil(model.prefetched["c_ok"], "a frame that was already being read is kept")
        XCTAssertNil(model.prefetching)
        XCTAssertTrue(model.loading)
        XCTAssertEqual(footage.frameCalls.map(\.0), ["c_ok.mp4", "g_later.mp4"], "d_next waits for the selection's frame")
        footage.releaseFirst()   // g_later's frame lands
        await settle()
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.frameTime, 50)
        XCTAssertEqual(footage.frameCalls.map(\.0), ["c_ok.mp4", "g_later.mp4", "d_next.mp4"], "then the read-ahead goes on")
        XCTAssertEqual(model.prefetching, "d_next")
        // Stepping a frame is a read of the selection too: the read-ahead waits for it.
        model.step(seconds: 1)
        await settle()
        XCTAssertEqual(footage.frameCalls.map(\.0), ["c_ok.mp4", "g_later.mp4", "d_next.mp4", "g_later.mp4"])
        footage.release()   // d_next's frame, then the step's
        await settle()
        XCTAssertEqual(model.frameTime, 51)
        XCTAssertEqual(Set(model.prefetched.keys), ["c_ok", "d_next"])
        XCTAssertEqual(footage.frameCalls.count, 4, "nothing read twice")
    }

    /// The project is switched while a read-ahead frame is decoding, and the new project has a
    /// recording of the same name (another file, another fingerprint): the old frame lands
    /// nowhere, and the new recording is read for itself (Codex finding on #118).
    @MainActor
    func testAFrameReadForTheOldProjectNeverReachesTheNewOne() async throws {
        let dir = try Self.tempDir()
        let dir2 = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: dir2) }
        let footage = ScriptedFootage()
        footage.holdFrames = true
        let model = NetLabelsModel(items: [try item("c_ok", in: dir)], labels: [:], store: NetLabelStore(projectDir: dir),
                                   footage: footage, prefetchAhead: 1) { _, _ in }
        await settle()
        XCTAssertEqual(footage.frameCalls.map(\.0), ["c_ok.mp4"], "the old project's read-ahead is on its frame")
        model.install(items: [try item("c_ok", fingerprint: "fp-b", in: dir2)], labels: [:], store: NetLabelStore(projectDir: dir2))
        await settle()
        XCTAssertTrue(model.prefetched.isEmpty)
        XCTAssertEqual(footage.frameCalls.count, 1, "one read at a time: the new read-ahead waits for the old file")
        footage.releaseFirst()   // the old project's frame lands
        await settle()
        XCTAssertTrue(model.prefetched.isEmpty, "a frame of the old project is not kept under the new recording's name")
        XCTAssertEqual(footage.frameCalls.count, 2, "the new project's recording is read for itself")
        XCTAssertEqual(model.prefetching, "c_ok")
        footage.releaseFirst()
        await settle()
        XCTAssertNotNil(model.prefetched["c_ok"])
        model.select("c_ok")
        await settle()
        XCTAssertEqual(footage.frameCalls.count, 2, "read ahead: opens from memory")
        XCTAssertTrue(model.confirm())
        XCTAssertEqual(try NetLabelStore(projectDir: dir2).load()["c_ok"]?.fingerprint, "fp-b")
        XCTAssertEqual(try NetLabelStore(projectDir: dir).load(), [:], "nothing written to the old project")
    }

    /// A recording read ahead, picked and then superseded before its load ran — by a skipped
    /// recording, which starts no load of its own — shows nothing and makes no proposal.
    @MainActor
    func testAPrefetchedLoadSupersededBeforeItRunsChangesNothing() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        var recorded: [String] = []
        let model = NetLabelsModel(items: [try item("c_ok", in: dir), try item("e_withheld", skip: .withheld, in: dir)],
                                   labels: [:], store: NetLabelStore(projectDir: dir), footage: footage, prefetchAhead: 1) { v, _ in recorded.append(v) }
        await settle()
        XCTAssertNotNil(model.prefetched["c_ok"])
        model.select("c_ok")
        model.select("e_withheld")   // before c_ok's load task has run
        await settle()
        XCTAssertEqual(model.selected, "e_withheld")
        XCTAssertNil(model.frame, "the superseded load published nothing")
        XCTAssertNil(model.quad)
        XCTAssertEqual(footage.proposalCalls, 0)
        XCTAssertTrue(recorded.isEmpty, "no ledger row for a recording that was never shown")
        XCTAssertFalse(model.canConfirm)
    }

    @MainActor
    func testALabelOfAnotherRecordingIsStaleNotLabeled() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let model = NetLabelsModel(items: [try item("c_ok", fingerprint: "fp-new", in: dir)],
                                   labels: ["c_ok": Self.label(fingerprint: "fp-old", time: 7)],
                                   store: NetLabelStore(projectDir: dir), footage: footage) { _, _ in }
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

    // MARK: - The proposal's exposure

    @MainActor
    func testAProposalIsInTheLedgerBeforeTheModelRunsAndStaysWhenThePersonLeaves() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        let footage = ScriptedFootage()
        // The real ledger, in a project folder of the test's own.
        let real = NetProposalExposure.recorder(projectDir: dir)
        let model = NetLabelsModel(items: [try item("c_ok", in: dir), try item("d_next", in: dir)], labels: [:],
                                   store: NetLabelStore(projectDir: dir), footage: footage) { v, t in
            footage.noteExposure(v)
            try real(v, t)
        }
        model.select("c_ok")
        await settle()
        XCTAssertEqual(footage.events, ["exposure c_ok", "proposal"], "the row is written before the model runs")
        XCTAssertNotNil(model.proposal)

        // Leave without confirming or exporting: the row is on file.
        model.select("d_next")
        await settle()
        XCTAssertEqual(try NetLabelStore(projectDir: dir).load(), [:])
        let rows = try ExposureLog.readStrict(in: dir)
        XCTAssertEqual(rows.map(\.video), ["c_ok", "d_next"])
        XCTAssertEqual(Set(rows.map(\.kind)), [.netProposal])
        XCTAssertEqual(Set(rows.map(\.ref)), [NetProposalExposure.ref])
        XCTAssertTrue(rows.allSatisfy { $0.note?.contains("proposed a net box") == true })
        // Rows survive a round trip through the file with their kind spelled out.
        let text = try String(contentsOf: ExposureLog.url(in: dir), encoding: .utf8)
        XCTAssertTrue(text.contains("\"net_proposal\""))
    }

    @MainActor
    func testNoProposalWhenTheLedgerCannotBeWritten() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        struct Unwritable: LocalizedError { var errorDescription: String? { "disk full" } }
        let model = NetLabelsModel(items: [try item("c_ok", in: dir)], labels: [:], store: NetLabelStore(projectDir: dir), footage: footage) { v, _ in
            footage.noteExposure(v)
            throw Unwritable()
        }
        model.select("c_ok")
        await settle()
        XCTAssertEqual(footage.events, ["exposure c_ok"], "the model never ran")
        XCTAssertEqual(footage.proposalCalls, 0)
        XCTAssertNil(model.proposal)
        XCTAssertNil(model.box)
        XCTAssertTrue(model.status.contains("could not be recorded"), model.status)
        XCTAssertTrue(model.status.contains("disk full"), model.status)
        // The frame is still there to draw on by hand, and a hand-drawn box can be confirmed.
        XCTAssertNotNil(model.frame)
        model.setBox(CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1))
        XCTAssertTrue(model.canConfirm)
    }

    @MainActor
    func testNoLedgerRowWhenThereIsNoModelToRun() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        footage.modelAvailable = false
        var recorded: [String] = []
        let model = NetLabelsModel(items: [try item("c_ok", in: dir)], labels: [:], store: NetLabelStore(projectDir: dir), footage: footage) { v, _ in recorded.append(v) }
        model.select("c_ok")
        await settle()
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertEqual(footage.proposalCalls, 0)
        XCTAssertNotNil(model.frame)
    }
}
