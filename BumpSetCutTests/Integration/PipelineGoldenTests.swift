//
//  PipelineGoldenTests.swift
//  BumpSetCutTests
//
//  The pipeline's whole answer on a real recording, kept as a file and compared on every later run: the
//  rallies, the counts, and every processed frame's evidence. A change that is meant to leave the pipeline's
//  behaviour alone (a refactor) is run against the file recorded before it.
//
//  The recording is local and not in git, so the test runs only when told where it is:
//    TEST_RUNNER_PIPELINE_GOLDEN_VIDEO=<video> TEST_RUNNER_PIPELINE_GOLDEN_FILE=<file> xcodebuild test …
//  With no file there yet, the run records one. A recording that differs is written beside it as <file>.actual.
//

import AVFoundation
import XCTest
@testable import BumpSetCut

final class PipelineGoldenTests: XCTestCase {
    func testTheRunsMatchTheOnesRecorded() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let videoPath = environment["PIPELINE_GOLDEN_VIDEO"], let goldenPath = environment["PIPELINE_GOLDEN_FILE"] else {
            throw XCTSkip("PIPELINE_GOLDEN_VIDEO and PIPELINE_GOLDEN_FILE name the recording and its golden file")
        }
        let video = URL(fileURLWithPath: videoPath), golden = URL(fileURLWithPath: goldenPath)

        // The net as marked on the acceptance recording; any box across the court exercises the rules.
        let net = DetectedNet(box: CGRect(x: 0.216, y: 0.457, width: 0.617, height: 0.108), confidence: 1)
        let corner = CameraSetup(position: CameraZone.corner.presetPosition, height: .raised)
        let runs: [(name: String, net: NetGeometry, camera: CameraSetup?)] = [
            ("no net", .unavailable(reason: "none for this run"), nil),
            ("confirmed net", .confirmed(net), nil),
            ("confirmed net, corner camera", .confirmed(net), corner)
        ]
        var lines: [String] = []
        for run in runs {
            let processor = VideoProcessor()
            var config = ProcessorConfig()
            config.applyCamera(run.camera)
            processor.config = config
            processor.netSource = FixedNetSource(run.net)
            processor.collectFrameEvidence = true
            lines.append("=== \(run.name)")
            do {
                lines += Self.describe(try await processor.analyzeVideo(video))
            } catch ProcessingError.noRalliesDetected {
                lines.append("no rallies")
            }
            lines.append("checks \(String(describing: processor.lastSpatialChecks))")
            lines += processor.serves.map { "serve \($0)" }
            lines += processor.frameEvidence.map(Self.describe)
        }
        let actual = lines.joined(separator: "\n") + "\n"

        guard let recorded = try? String(contentsOf: golden, encoding: .utf8) else {
            try actual.write(to: golden, atomically: true, encoding: .utf8)
            print("PipelineGoldenTests: recorded \(lines.count) lines to \(golden.path)")
            return
        }
        guard actual != recorded else { return }
        try actual.write(to: golden.appendingPathExtension("actual"), atomically: true, encoding: .utf8)
        let was = recorded.split(separator: "\n", omittingEmptySubsequences: false), now = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let first = zip(was, now).enumerated().first { $0.element.0 != $0.element.1 }
        XCTFail("The pipeline's answer changed (\(was.count) lines recorded, \(now.count) now). First difference at line \((first?.offset ?? min(was.count, now.count)) + 1): recorded \"\(first?.element.0 ?? "")\", now \"\(first?.element.1 ?? "")\"")
    }

    private static func n(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "-" }
    private static func n(_ value: CGFloat?) -> String { n(value.map(Double.init)) }
    private static func p(_ point: CGPoint?) -> String { point.map { "(\(n($0.x)),\(n($0.y)))" } ?? "-" }

    private static func describe(_ metadata: ProcessingMetadata) -> [String] {
        let s = metadata.processingStats, q = metadata.qualityMetrics
        return metadata.rallySegments.map {
            "rally \(n($0.startTime))…\(n($0.endTime)) confidence \(n($0.confidence)) quality \(n($0.quality)) detections \($0.detectionCount) "
                + "trajectory \(n($0.averageTrajectoryLength)) sizeTrend \(n($0.ballSizeTrend)) serveX \(n($0.serveBallX)) manual \($0.isManual)"
        } + [
            "stats frames \(s.totalFrames) processed \(s.processedFrames) detection \(s.detectionFrames) tracking \(s.trackingFrames) rally \(s.rallyFrames) "
                + "physics \(s.physicsValidFrames) detections \(s.totalDetections) trajectories \(s.validTrajectories) "
                + "perFrame \(n(s.averageDetectionsPerFrame)) confidence \(n(s.averageConfidence)) fps \(n(s.framesPerSecond))",
            "quality overall \(n(q.overallQuality)) r2 \(n(q.averageRSquared)) consistency \(n(q.trajectoryConsistency)) physicsRate \(n(q.physicsValidationRate)) "
                + "classification \(n(q.movementClassificationAccuracy)) distribution \(q.confidenceDistribution.high)/\(q.confidenceDistribution.medium)/\(q.confidenceDistribution.low)",
            "kept trajectories \(metadata.trajectoryData?.count ?? -1) classifications \(metadata.classificationResults?.count ?? -1) physics \(metadata.physicsValidation?.count ?? -1) "
                + "netCenterX \(n(metadata.netCenterX))",
            "physics " + (metadata.physicsValidation ?? []).map { "\(n($0.timestamp)):\($0.isValid ? 1 : 0):\(n($0.rSquared)):\(n($0.confidenceLevel))" }.joined(separator: " ")
        ]
    }

    private static func describe(_ e: VideoProcessor.FrameEvidence) -> String {
        let detections = e.detections.map {
            "[\(n($0.bbox.minX)),\(n($0.bbox.minY)),\(n($0.bbox.width)),\(n($0.bbox.height)) c\(n(Double($0.confidence))) off\($0.isOffCourt ? 1 : 0) heat\($0.fromHeatmap ? 1 : 0)]"
        }.joined()
        let candidates = e.candidates.map {
            "{\(p($0.point)) s\(n($0.score)) proj\($0.isProjectile ? 1 : 0) sel\($0.isSelected ? 1 : 0) ex\($0.isCourtExcluded ? 1 : 0) size\(n($0.ballSize)) roi\(n($0.roiRadius)) "
                + "r2 \(n($0.rSquared)) g \(n($0.gravitySignature)) \($0.movementType?.rawValue ?? "-") \($0.rejectionReason ?? "-")}"
        }.joined()
        return "frame \(n(e.time)) ball\(e.hasBall ? 1 : 0) proj\(e.isProjectile ? 1 : 0) dets\(detections) track \(p(e.trackPoint)) r2 \(n(e.rSquared)) g \(n(e.gravitySignature)) "
            + "\(e.movementType?.rawValue ?? "-") \(e.rejectionReason ?? "-") net \(e.detectedNet.map { "\($0.box)" } ?? "-") upright\(e.upright ? 1 : 0) "
            + "gate \(e.gate.map { "\($0.isValid ? 1 : 0):\(n($0.rSquared)):\(n($0.confidenceLevel))" } ?? "-") cands\(candidates)"
    }
}
