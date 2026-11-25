//
//  ShippingBaselineTests.swift
//  BumpSetCutTests
//
//  The app as it ships (D-042): one ball model in the bundle, the multi-frame one; no
//  single-frame detector to fall back to; a run that can't find the ball refuses rather
//  than use another model; the net comes from a named source, and with none the rules
//  that need it are skipped and recorded as skipped.
//

import AVFoundation
import XCTest
@testable import BumpSetCut

final class ShippingBaselineTests: XCTestCase {
    private var dir: URL!
    private var video: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShippingBaselineTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        video = try TestVideoFactory.writeVideo(to: dir.appendingPathComponent("clip.mp4"), duration: 2, size: CGSize(width: 320, height: 180))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Runs the pipeline over the clip. The clip has no rally in it, which the pipeline reports by throwing;
    /// what these tests read is what the run was told of the net and did with it.
    private func run(_ processor: VideoProcessor) async throws {
        do { _ = try await processor.analyzeVideo(video) } catch ProcessingError.noRalliesDetected {}
    }

    /// A net source that answers what it is told to, and counts how often it is asked.
    private final class FixedNet: NetGeometrySource {
        let answer: NetGeometry
        private(set) var asked = 0
        init(_ answer: NetGeometry) { self.answer = answer }
        func netGeometry(forVideoAt url: URL, asset: AVAsset, durationSec: Double, config: ProcessorConfig) async -> NetGeometry {
            asked += 1
            return answer
        }
    }

    // MARK: The bundle

    func testTheOnlyModelInTheAppIsTheMultiFrameBallModel() throws {
        let compiled = (Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []).map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertEqual(compiled, ["ball_heat"])
        XCTAssertEqual(Bundle.main.urls(forResourcesWithExtension: "mlpackage", subdirectory: nil) ?? [], [])
        for name in BallModel.allCases.map(\.rawValue) + ["bestv2", "bestv3", "net"] {
            for ext in ["mlmodelc", "mlpackage", "mlmodel"] {
                XCTAssertNil(Bundle.main.url(forResource: name, withExtension: ext), "\(name).\(ext)")
            }
        }
    }

    // MARK: The ball finder

    func testProcessingFindsTheBallWithTheBundledMultiFrameModelAlone() {
        let config = ProcessorConfig()
        XCTAssertTrue(config.heatmapOnly)
        XCTAssertEqual(config.heatmapModel, ProcessorConfig.bundledHeatmapModel)
        XCTAssertNotNil(config.heatmapModel)
    }

    func testAStoredDebugChoiceCannotBringASingleFrameDetectorBack() {
        let defaults = UserDefaults.standard
        defaults.set("yolo", forKey: "debugBallFinder")
        defer { defaults.removeObject(forKey: "debugBallFinder") }
        XCTAssertTrue(ProcessorConfig().heatmapOnly)
        XCTAssertNotNil(ProcessorConfig().heatmapModel)
    }

    func testThisBuildHasNoSingleFrameDetector() {
        var config = ProcessorConfig()
        config.heatmapOnly = false
        XCTAssertNil(PipelineDefaults.singleFrameBallDetector(for: config, reusing: nil))
    }

    func testARunWithNoMultiFrameModelIsRefusedNotRunOnAnotherDetector() async throws {
        let processor = VideoProcessor()
        processor.config.heatmapModel = nil
        do {
            _ = try await processor.analyzeVideo(video)
            XCTFail("the run went ahead with no ball model")
        } catch ProcessingError.modelNotFound {
        }
        XCTAssertFalse(processor.isProcessing)
        XCTAssertNil(processor.loadedHeatmapModel)
    }

    func testAConfigurationAskingForASingleFrameDetectorIsRefused() async throws {
        let processor = VideoProcessor()
        processor.config.heatmapOnly = false
        do {
            _ = try await processor.analyzeVideo(video)
            XCTFail("the run went ahead on a detector this build does not have")
        } catch ProcessingError.modelNotFound {
        }
    }

    // MARK: The net

    func testWithNoNetTheNetRulesAreSkippedAndRecordedAsSkipped() async throws {
        let processor = VideoProcessor()
        try await run(processor)
        XCTAssertNotNil(processor.loadedHeatmapModel)
        let checks = try XCTUnwrap(processor.lastSpatialChecks)
        XCTAssertEqual(checks.netOrigin, NetGeometry.unavailable)
        XCTAssertEqual(checks.netUnavailableReason, "nothing in this build knows where the net is")
        XCTAssertEqual(checks.underNetRejection, .noNetGeometry)
        XCTAssertEqual(checks.offCourtRejection, .noNetGeometry)
        XCTAssertEqual(checks.aboveNetRequirement, .noNetGeometry)
        XCTAssertEqual(checks.skippedLine, "No net geometry (nothing in this build knows where the net is): the under-net, off-court, above-net rules were skipped.")
    }

    func testAConfirmedNetIsWhatTheRulesRunOn() async throws {
        let processor = VideoProcessor()
        processor.collectFrameEvidence = true
        let box = CGRect(x: 0.24, y: 0.49, width: 0.52, height: 0.12)
        let source = FixedNet(.confirmed(DetectedNet(box: box, confidence: 1)))
        processor.netSource = source
        try await run(processor)
        XCTAssertEqual(source.asked, 1)
        let checks = try XCTUnwrap(processor.lastSpatialChecks)
        XCTAssertEqual(checks.netOrigin, NetGeometry.personConfirmed)
        XCTAssertNil(checks.netUnavailableReason)
        XCTAssertEqual([checks.underNetRejection, checks.offCourtRejection, checks.aboveNetRequirement], [.ran, .ran, .ran])
        XCTAssertNil(checks.skippedLine)
        XCTAssertFalse(processor.frameEvidence.isEmpty)
        XCTAssertTrue(processor.frameEvidence.allSatisfy { $0.detectedNet?.box == box })
    }

    func testRulesTurnedOffAreRecordedAsOffAndTheNetIsNotAskedFor() async throws {
        let processor = VideoProcessor()
        processor.config.enableUnderNetRejection = false
        processor.config.enableOffCourtRejection = false
        processor.config.enableAboveNetRequirement = false
        let source = FixedNet(.confirmed(DetectedNet(box: CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.1), confidence: 1)))
        processor.netSource = source
        try await run(processor)
        let checks = try XCTUnwrap(processor.lastSpatialChecks)
        XCTAssertEqual(source.asked, 0)
        XCTAssertEqual([checks.underNetRejection, checks.offCourtRejection, checks.aboveNetRequirement], [.off, .off, .off])
        XCTAssertNil(checks.skippedLine)
    }

    func testOneRuleOnWithoutANetIsNamedAlone() {
        var config = ProcessorConfig()
        config.enableOffCourtRejection = false
        config.enableAboveNetRequirement = false
        let checks = SpatialChecks(config: config, net: .unavailable(reason: "the net is not confirmed"))
        XCTAssertEqual(checks.skippedLine, "No net geometry (the net is not confirmed): the under-net rule was skipped.")
        XCTAssertEqual(checks.offCourtRejection, .off)
    }

    func testTheNetsOriginIsKeptAndReadBack() throws {
        let net = DetectedNet(box: CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.1), confidence: 0.8)
        XCTAssertEqual(NetGeometry(net: net, origin: NetGeometry.personConfirmed).origin, NetGeometry.personConfirmed)
        XCTAssertEqual(NetGeometry(net: net, origin: "some_method_v1").origin, "some_method_v1")
        XCTAssertNil(NetGeometry.unavailable(reason: "x").net)
        let checks = SpatialChecks(config: ProcessorConfig(), net: .detected(net, method: "some_method_v1"))
        let decoded = try JSONDecoder().decode(SpatialChecks.self, from: JSONEncoder().encode(checks))
        XCTAssertEqual(decoded, checks)
        XCTAssertEqual(decoded.netOrigin, "some_method_v1")
        XCTAssertEqual(SpatialChecks.State.noNetGeometry.rawValue, "no_net_geometry")
        // A checkpoint written before the origin was recorded still gives its net.
        let old = try JSONDecoder().decode(ProcessingCheckpoint.NetBox.self, from: Data(#"{"x":0.2,"y":0.5,"width":0.6,"height":0.1,"confidence":0.8}"#.utf8))
        XCTAssertNil(old.origin)
        XCTAssertEqual(old.detectedNet.box, net.box)
    }

    // MARK: The debug video

    func testTheDebugVideoIsDrawnFromThePipelinesOwnRun() async throws {
        let processor = VideoProcessor()
        let out = try await processor.processVideoDebug(video)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertNotNil(processor.loadedHeatmapModel, "the debug run is the multi-frame pipeline")
        XCTAssertFalse(processor.isProcessing)
        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        let rate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(seconds, 2, accuracy: 0.2)
        XCTAssertGreaterThan(rate, 20)
        XCTAssertNotNil(processor.trajectoryDebugger)
    }
}
