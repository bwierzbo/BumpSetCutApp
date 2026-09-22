//
//  VideoExporterFramingTests.swift
//  BumpSetCutTests
//
//  What you framed is what you get: a ShareCrop describes the screen (SwiftUI
//  space, +Y down, clockwise rotation) and the exporter works in the
//  composition's space. These tests render real frames and compare pixels,
//  so the sign conventions are pinned by evidence rather than by comment.
//

import XCTest
import AVFoundation
@testable import BumpSetCut

final class VideoExporterFramingTests: XCTestCase {

    private let size = CGSize(width: 320, height: 240)
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoExporterFramingTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private struct RGB: Equatable, CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var description: String { "(\(r),\(g),\(b))" }
        /// H.264 chroma subsampling smears edges; compare loosely.
        func isClose(to other: RGB) -> Bool {
            abs(r - other.r) < 60 && abs(g - other.g) < 60 && abs(b - other.b) < 60
        }
    }

    /// Four flat colour quadrants — every region of the frame is identifiable.
    private func makeQuadrantClip() throws -> URL {
        try TestVideoFactory.writeVideo(
            to: tempDirectory.appendingPathComponent("quadrants.mp4"),
            duration: 0.5, size: size, fps: 30
        ) { ctx, size, _ in
            let w = size.width / 2, h = size.height / 2
            // CG y = 0 is the bottom of the frame.
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))   // bottom-left
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))   // bottom-right
            ctx.fill(CGRect(x: w, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))   // top-left
            ctx.fill(CGRect(x: 0, y: h, width: w, height: h))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1))   // top-right
            ctx.fill(CGRect(x: w, y: h, width: w, height: h))
        }
    }

    /// Colour at a normalized point of the first frame, x from the left and
    /// y from the top — the same convention for source and export.
    private func sample(_ url: URL, at point: CGPoint) async throws -> RGB {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let (image, _) = try await generator.image(at: CMTime(value: 1, timescale: 10))

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Drawn upright, so memory row 0 is the top of the picture.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = Int(point.x * CGFloat(width)), y = Int(point.y * CGFloat(height))
        let i = (y * width + x) * 4
        return RGB(r: Int(pixels[i]), g: Int(pixels[i + 1]), b: Int(pixels[i + 2]))
    }

    private func export(_ source: URL, crop: ShareCrop) async throws -> URL {
        let url = try await VideoExporter().exportStitchedClips(
            [.init(url: source, timeRange: nil, crop: crop)]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertSameColour(_ exported: URL, at outPoint: CGPoint,
                                  as source: URL, at srcPoint: CGPoint,
                                  _ message: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let expected = try await sample(source, at: srcPoint)
        let actual = try await sample(exported, at: outPoint)
        XCTAssertTrue(actual.isClose(to: expected),
                      "\(message): expected \(expected) (source \(srcPoint)) but exported \(outPoint) is \(actual)",
                      file: file, line: line)
    }

    // MARK: - Sanity

    func testFixtureSamplesDistinctQuadrants() async throws {
        let source = try makeQuadrantClip()
        let tl = try await sample(source, at: CGPoint(x: 0.25, y: 0.25))
        let tr = try await sample(source, at: CGPoint(x: 0.75, y: 0.25))
        let bl = try await sample(source, at: CGPoint(x: 0.25, y: 0.75))
        let br = try await sample(source, at: CGPoint(x: 0.75, y: 0.75))
        XCTAssertFalse(tl.isClose(to: tr)); XCTAssertFalse(tl.isClose(to: bl)); XCTAssertFalse(tl.isClose(to: br))
        XCTAssertFalse(tr.isClose(to: bl)); XCTAssertFalse(tr.isClose(to: br)); XCTAssertFalse(bl.isClose(to: br))
    }

    // MARK: - Pan

    /// On screen, dragging the video down (+Y offset) brings what was above
    /// the center into view. Zoom 2 with a quarter-height pan: the output
    /// center shows the source point one eighth above center.
    func testPanDownShowsContentFromAboveCenter() async throws {
        let source = try makeQuadrantClip()
        let exported = try await export(source, crop: ShareCrop(zoom: 2, offsetXNorm: 0, offsetYNorm: 0.25))
        try await assertSameColour(exported, at: CGPoint(x: 0.25, y: 0.5), as: source, at: CGPoint(x: 0.375, y: 0.375), "pan down, left")
        try await assertSameColour(exported, at: CGPoint(x: 0.75, y: 0.5), as: source, at: CGPoint(x: 0.625, y: 0.375), "pan down, right")
    }

    func testPanUpShowsContentFromBelowCenter() async throws {
        let source = try makeQuadrantClip()
        let exported = try await export(source, crop: ShareCrop(zoom: 2, offsetXNorm: 0, offsetYNorm: -0.25))
        try await assertSameColour(exported, at: CGPoint(x: 0.25, y: 0.5), as: source, at: CGPoint(x: 0.375, y: 0.625), "pan up, left")
        try await assertSameColour(exported, at: CGPoint(x: 0.75, y: 0.5), as: source, at: CGPoint(x: 0.625, y: 0.625), "pan up, right")
    }

    func testPanRightShowsContentFromLeftOfCenter() async throws {
        let source = try makeQuadrantClip()
        let exported = try await export(source, crop: ShareCrop(zoom: 2, offsetXNorm: 0.25, offsetYNorm: 0))
        try await assertSameColour(exported, at: CGPoint(x: 0.5, y: 0.25), as: source, at: CGPoint(x: 0.375, y: 0.375), "pan right, top")
        try await assertSameColour(exported, at: CGPoint(x: 0.5, y: 0.75), as: source, at: CGPoint(x: 0.375, y: 0.625), "pan right, bottom")
    }

    // MARK: - Rotation

    /// `.rotationEffect(.degrees(90))` turns the picture clockwise: what was
    /// at the top ends up on the right. With the cover scale for 4:3 (4/3)
    /// a source point at (0.5, 0.2) — 0.3H above center — lands 0.3H·(4/3)
    /// right of center = 0.4H = 96pt → x = 160 + 96 = 256 → 0.8W.
    func testClockwiseRotationMovesTopToRight() async throws {
        let source = try makeQuadrantClip()
        let exported = try await export(source, crop: ShareCrop(zoom: 1, offsetXNorm: 0, offsetYNorm: 0, rotation: 90))
        // Top-left quadrant → top-right of the output; bottom-left → top-left.
        try await assertSameColour(exported, at: CGPoint(x: 0.8, y: 0.3), as: source, at: CGPoint(x: 0.3, y: 0.2), "top-left quadrant rotates to the top-right")
        try await assertSameColour(exported, at: CGPoint(x: 0.2, y: 0.3), as: source, at: CGPoint(x: 0.3, y: 0.8), "bottom-left quadrant rotates to the top-left")
    }

    func testIdentityCropIsNotFraming() {
        XCTAssertNil(ShareCrop(adjustment: nil))
        XCTAssertNil(ShareCrop(adjustment: RallyTrimAdjustment(before: 1, after: 1)))
        XCTAssertNotNil(ShareCrop(adjustment: RallyTrimAdjustment(before: 0, after: 0, rotation: 5)))
        XCTAssertNotNil(ShareCrop(adjustment: RallyTrimAdjustment(before: 0, after: 0, zoom: 1.5)))
        XCTAssertFalse(VideoExporter.StitchClip(url: URL(fileURLWithPath: "/x")).hasFraming)
    }
}
