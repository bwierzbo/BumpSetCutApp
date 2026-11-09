//
//  PlayerDetectorsTests.swift
//  RallyLabTests
//
//  The detector layer of the player-feasibility research without any model: NMS
//  (IoU, and containment only between tiles), the tile grid, tile → frame mapping
//  and the cross-tile merge with a scripted detector, the fp16 reader used on Core
//  ML outputs, and the COCO-17 → Vision-slot mapping (neck and root stay null).
//

import CoreML
import XCTest
@testable import RallyLab

final class PlayerDetectorsTests: XCTestCase {
    typealias Box = PlayerFeatures.Box

    private func person(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ conf: Double) -> PlayerDetections.Person {
        .init(box: Box(x: x, y: y, w: w, h: h), conf: conf, pose: nil)
    }

    func testSuppressionByIoUAndContainmentOnlyAcrossSources() {
        let a = person(0.1, 0.1, 0.2, 0.4, 0.9), b = person(0.11, 0.1, 0.2, 0.4, 0.8), inner = person(0.12, 0.2, 0.08, 0.2, 0.7)
        XCTAssertEqual(PlayerDetections.suppress([a, b, inner], iou: 0.6), [0, 2], "b overlaps a; the small box inside a is a different person within one source")
        XCTAssertEqual(PlayerDetections.suppress([a, b, inner], iou: 0.6, containment: 0.8, fromOtherSource: { $0 == 2 || $1 == 2 }), [0],
                       "the same small box from another tile is a cut-off copy of a")
        XCTAssertEqual(PlayerDetections.suppress([inner, a], iou: 0.6, containment: 0.8, fromOtherSource: { _, _ in true }), [1],
                       "the higher score wins whatever the input order")
    }

    func testTilesCoverTheFrameWithOverlap() {
        let t = PlayerTiling(cols: 3, rows: 2, overlap: 0.2).tiles(width: 960, height: 540)
        XCTAssertEqual(t.count, 6)
        XCTAssertEqual(t.map(\.minX).min(), 0)
        XCTAssertEqual(t.map(\.maxX).max(), 960)
        XCTAssertEqual(t.map(\.maxY).max(), 540)
        let row = t.filter { $0.minY == 0 }.sorted { $0.minX < $1.minX }
        XCTAssertGreaterThan(row[0].maxX, row[1].minX, "neighbours overlap")
        XCTAssertEqual(PlayerTiling().tiles(width: 960, height: 540), [CGRect(x: 0, y: 0, width: 960, height: 540)])
    }

    /// A detector that sees one person in the middle of whatever it is given, and records the sizes it was given.
    private final class Scripted: PlayerDetector, @unchecked Sendable {
        var sizes: [CGSize] = []
        var described: [String: String] { ["name": "scripted"] }
        func detect(_ image: CGImage) -> PlayerDetections {
            sizes.append(CGSize(width: image.width, height: image.height))
            var d = PlayerDetections()
            d.persons = [.init(box: Box(x: 0.45, y: 0.4, w: 0.1, h: 0.2), conf: Double(image.width) / 1000,
                               pose: PlayerFeatures.Pose(conf: 1, joints: [PlayerFeatures.Joint(x: 0.5, y: 0.5, c: 1)] + Array(repeating: nil, count: 18)))]
            return d
        }
    }

    private func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testTiledDetectionsComeBackInFrameCoordinates() {
        let det = Scripted()
        let d = PlayerTiling(cols: 2, rows: 1, overlap: 0).detect(image(1000, 500), with: det)
        XCTAssertEqual(det.sizes, [CGSize(width: 500, height: 500), CGSize(width: 500, height: 500)])
        XCTAssertEqual(d.persons.count, 2)
        let xs = d.persons.map(\.box.x).sorted()
        XCTAssertEqual(xs[0], 0.225, accuracy: 1e-9, "left tile: 0.45 of 500 px")
        XCTAssertEqual(xs[1], 0.725, accuracy: 1e-9, "right tile: 500 + 0.45 of 500 px")
        XCTAssertEqual(d.persons[0].box.y, 0.4, accuracy: 1e-9)
        XCTAssertEqual(d.persons[0].box.w, 0.05, accuracy: 1e-9)
        let j = d.persons.first { $0.box.x > 0.5 }!.pose!.joints[0]!
        XCTAssertEqual(j.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(j.y, 0.5, accuracy: 1e-9)
    }

    func testOneTileIsTheWholeFrameUnchanged() {
        let det = Scripted()
        let d = PlayerTiling().detect(image(640, 360), with: det)
        XCTAssertEqual(det.sizes, [CGSize(width: 640, height: 360)])
        XCTAssertEqual(d.persons.first?.box.x, 0.45)
    }

    func testFloat16OutputsAreRead() throws {
        let a = try MLMultiArray(shape: [3], dataType: .float16)
        a[0] = 0.5; a[1] = -1.25; a[2] = 2
        XCTAssertEqual(PlayerCoreML.floats(a), [0.5, -1.25, 2])
        let b = try MLMultiArray(shape: [2], dataType: .float32)
        b[0] = 1.5; b[1] = 3
        XCTAssertEqual(PlayerCoreML.floats(b), [1.5, 3])
    }

    /// Core ML pads rows: the detector's boxes arrive [1, 8400, 4] with strides [268800, 32, 1] (seen 2026-11-08). Reading the
    /// buffer as packed scrambled every box; the reader must follow the strides.
    func testPaddedOutputsAreReadByTheirStrides() throws {
        let f32: [Float] = [1, 2, -9, -9, 3, 4, -9, -9]
        let p32 = UnsafeMutablePointer<Float>.allocate(capacity: f32.count)
        p32.initialize(from: f32, count: f32.count)
        let a = try MLMultiArray(dataPointer: p32, shape: [2, 2], dataType: .float32, strides: [4, 1], deallocator: { $0.deallocate() })
        XCTAssertEqual(PlayerCoreML.floats(a), [1, 2, 3, 4])
        // Half floats by bit pattern: 0.5 = 0x3800, 1 = 0x3C00, 2 = 0x4000, -1 = 0xBC00; padding 0x7BFF (65504).
        let f16: [UInt16] = [0x3800, 0x3C00, 0x7BFF, 0x4000, 0xBC00, 0x7BFF]
        let p16 = UnsafeMutablePointer<UInt16>.allocate(capacity: f16.count)
        p16.initialize(from: f16, count: f16.count)
        let b = try MLMultiArray(dataPointer: p16, shape: [1, 2, 2], dataType: .float16, strides: [6, 3, 1], deallocator: { $0.deallocate() })
        XCTAssertEqual(PlayerCoreML.floats(b), [0.5, 1, 2, -1])
    }

    func testCocoKeypointsFillVisionSlotsLeavingNeckAndRootNull() {
        let slots = RTMPlayerDetector.cocoToSlot
        XCTAssertEqual(slots.count, 17)
        XCTAssertEqual(Set(slots).count, 17)
        XCTAssertFalse(slots.contains(PlayerFeatures.joint("neck")))
        XCTAssertFalse(slots.contains(PlayerFeatures.joint("root")))
        XCTAssertEqual(slots[5], PlayerFeatures.joint("left_shoulder"))
        XCTAssertEqual(slots[16], PlayerFeatures.joint("right_ankle"))
    }

    func testRFDETRRefusesAMissingPackageAndNamesItsConverter() async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("rfdetr-missing-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try await RFDETRPlayerDetector(models: empty, size: .small, minScore: 0.3)
            XCTFail("no package, no detector")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rfdetr_small_person.mlpackage"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("convert_rfdetr_coreml.py"), error.localizedDescription)
        }
    }

    /// The fixture's expected numbers come from rfdetr 1.12's own PostProcess._apply_keypoint_trace_fusion (torch) and
    /// the converter's NumPy port, which agree: fused score 0.6921796202659607.
    func testRFDETRKeypointDecodeMatchesRFDETRsFusedScoreAndJoints() {
        let boxes: [Float] = [0.5, 0.5, 0.2, 0.4, 0.2, 0.2, 0.1, 0.1]
        let logits: [Float] = [-5, 2.0, -5, -3.0]
        var keypoints = [Float](repeating: 0, count: 2 * 34 * 8)
        for j in 0..<17 {
            let base = 0 * 34 * 8 + (17 + j) * 8
            let row: [Float] = [0.4 + 0.01 * Float(j), 0.3 + 0.02 * Float(j), j % 2 == 0 ? 1 : -1, 0, 3.0, 0.5, 2.5, 0]
            for d in 0..<8 { keypoints[base + d] = row[d] }
        }
        let people = RFDETRPlayerDetector.decode(boxes: boxes, logits: logits, keypoints: keypoints, minScore: 0.3)
        XCTAssertEqual(people.count, 1, "the second query's fused score is far below 0.3")
        let p = people[0]
        XCTAssertEqual(p.conf, 0.6921796202659607, accuracy: 1e-5)
        XCTAssertEqual(p.box.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(p.box.y, 1 - 0.7, accuracy: 1e-6, "Vision-normalised: origin bottom-left")
        XCTAssertEqual(p.box.h, 0.4, accuracy: 1e-6)
        let nose = p.pose?.joints[PlayerFeatures.joint("nose")], leftEye = p.pose?.joints[PlayerFeatures.joint("left_eye")]
        XCTAssertEqual(nose??.x ?? -1, 0.4, accuracy: 1e-6)
        XCTAssertEqual(nose??.y ?? -1, 1 - 0.3, accuracy: 1e-6)
        XCTAssertEqual(nose??.c ?? -1, 0.7310585975646973, accuracy: 1e-6)
        XCTAssertEqual(leftEye??.c ?? -1, 0.2689414322376251, accuracy: 1e-6)
        XCTAssertNil(p.pose?.joints[PlayerFeatures.joint("neck")] ?? nil, "COCO-17 has no neck")
    }

    func testRFDETRDetectionDecodeUsesThePersonSlotWithoutFusion() {
        // Two queries, 3 slots; slot 1 is the person.
        let boxes: [Float] = [0.5, 0.5, 0.2, 0.4, 0.2, 0.2, 0.1, 0.1]
        let logits: [Float] = [9, 0.0, -9, -9, 2.0, 9]
        let people = RFDETRPlayerDetector.decode(boxes: boxes, logits: logits, keypoints: [], minScore: 0.3)
        XCTAssertEqual(people.map(\.conf), [1 / (1 + exp(-2.0)), 0.5])
        XCTAssertNil(people[0].pose)
    }
}
