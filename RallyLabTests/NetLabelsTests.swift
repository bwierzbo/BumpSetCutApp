//
//  NetLabelsTests.swift
//  RallyLabTests
//
//  The net labels' rules: which recordings are skipped, where the frame is
//  taken, how a box becomes a YOLO line, the store failing closed, and the
//  export plan refusing withheld recordings whatever the labels say.
//

import CoreGraphics
import XCTest
@testable import RallyLab

final class NetLabelsTests: XCTestCase {

    func testWithheldAndHandheldAreSkipped() {
        let withheld: Set<String> = ["bch_onl_sun_land_onl_03"]
        XCTAssertEqual(NetLabels.skip(video: "bch_onl_sun_land_onl_03", camera: "Tripod / corner", withheld: withheld), .withheld)
        XCTAssertEqual(NetLabels.skip(video: "grs_hnd_sun_land_self_01", camera: "Handheld / corner", withheld: withheld), .handheld)
        XCTAssertEqual(NetLabels.skip(video: "grs_hnd_sun_land_self_01", camera: "handheld", withheld: withheld), .handheld)
        XCTAssertNil(NetLabels.skip(video: "bch_ele_sun_port_self_03", camera: "End line, elevated (stands/tripod 2m+)", withheld: withheld))
        XCTAssertNil(NetLabels.skip(video: "grs_extra_self_01", camera: "Extra", withheld: withheld))
        // Withheld wins over the camera: a withheld handheld recording is reported as withheld.
        XCTAssertEqual(NetLabels.skip(video: "x", camera: "Handheld / corner", withheld: ["x"]), .withheld)
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netlabels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NetLabelStore(projectDir: dir)
        XCTAssertEqual(try store.load(), [:])
        let label = NetLabel(time: 12.5, box: TrackCandidate(rect: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1), confidence: 1),
                             proposed: true, adjusted: false, reviewedAt: Date(timeIntervalSince1970: 1_800_000_000),
                             frameWidth: 1920, frameHeight: 1080)
        try store.save(["bch_a": label])
        XCTAssertEqual(try store.load(), ["bch_a": label])
        try Data("{not json".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }

    func testExportPlanRefusesWithheldAndSkipsUnlabeled() {
        let box = TrackCandidate(rect: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1), confidence: 1)
        let label = NetLabel(time: 1, box: box, proposed: false, adjusted: false, reviewedAt: Date(), frameWidth: 1920, frameHeight: 1080)
        func src(_ v: String, _ camera: String = "Tripod / corner") -> NetDatasetExport.Source {
            NetDatasetExport.Source(video: v, clip: v, camera: camera, url: URL(fileURLWithPath: "/nonexistent/\(v).mp4"))
        }
        let sources = [src("c_labeled"), src("a_withheld_but_labeled"), src("b_unlabeled"), src("d_handheld", "Handheld / corner")]
        let labels = ["c_labeled": label, "a_withheld_but_labeled": label, "d_handheld": label]
        let plan = NetDatasetExport.plan(labels: labels, sources: sources, withheld: ["a_withheld_but_labeled"])
        XCTAssertEqual(plan.export.map(\.video), ["c_labeled"])
        XCTAssertEqual(plan.skipped, [.init(video: "a_withheld_but_labeled", reason: "withheld"),
                                      .init(video: "b_unlabeled", reason: "unlabeled"),
                                      .init(video: "d_handheld", reason: "handheld")])
    }
}
