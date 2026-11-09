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
        XCTAssertEqual(RTMPlayerDetector.floats(a), [0.5, -1.25, 2])
        let b = try MLMultiArray(shape: [2], dataType: .float32)
        b[0] = 1.5; b[1] = 3
        XCTAssertEqual(RTMPlayerDetector.floats(b), [1.5, 3])
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
}
