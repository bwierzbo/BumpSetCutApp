//
//  PipelineGoldenTests.swift
//  BumpSetCutTests
//
//  The pipeline's whole answer on a real recording, kept as a file and compared on every later run: the
//  rallies, the counts, and every processed frame's evidence. A change that is meant to leave the pipeline's
//  behaviour alone (a refactor) is run against the file recorded before it. Each run's saved ball detections
//  are then decided again (D-044) and must give that run's answer to the line.
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
        func processor(for run: (name: String, net: NetGeometry, camera: CameraSetup?)) -> VideoProcessor {
            let processor = VideoProcessor()
            var config = ProcessorConfig()
            config.applyCamera(run.camera)
            processor.config = config
            processor.netSource = FixedNetSource(run.net)
            processor.collectFrameEvidence = true
            return processor
        }
        /// A run's whole answer: its rallies and numbers, the net rules it made, its serves and every frame's evidence.
        func answer(of processor: VideoProcessor, _ work: () async throws -> ProcessingMetadata) async throws -> [String] {
            var answer: [String] = []
            do {
                answer += Self.describe(try await work())
            } catch ProcessingError.noRalliesDetected {
                answer.append("no rallies")
            }
            answer.append("checks \(String(describing: processor.lastSpatialChecks))")
            answer += processor.serves.map { "serve \($0)" }
            return answer + processor.frameEvidence.map(Self.describe)
        }
        var lines: [String] = []
        var answers: [[String]] = []
        var logs: [BallDetectionLog] = []
        for run in runs {
            let processor = processor(for: run)
            let ran = try await answer(of: processor) { try await processor.analyzeVideo(video) }
            lines.append("=== \(run.name)")
            lines += ran
            answers.append(ran)
            // The run's detection log is what the stage was given: the same frames and boxes as the evidence, and
            // it reads back from its bytes unchanged. Its size on a real recording is printed for the record.
            let log = try XCTUnwrap(processor.detectionLog, run.name)
            XCTAssertEqual(log.frames.map { CMTimeGetSeconds($0.time) }, processor.frameEvidence.map(\.time), run.name)
            XCTAssertEqual(log.frames.map { $0.detections.map(\.bbox) }, processor.frameEvidence.map { $0.detections.map(\.bbox) }, run.name)
            XCTAssertEqual(log.frames.map { $0.detections.map(\.confidence) }, processor.frameEvidence.map { $0.detections.map(\.confidence) }, run.name)
            let bytes = try log.encoded()
            XCTAssertEqual(try BallDetectionLog(data: bytes), log, run.name)
            print(String(format: "PipelineGoldenTests: detection log for \"%@\": %d frames, %d detections, %d bytes = %.2f MB per hour of video",
                         run.name, log.frames.count, log.frames.reduce(0) { $0 + $1.detections.count }, bytes.count,
                         Double(bytes.count) / 1_048_576 / max(log.header.durationSec, 1) * 3600))
            logs.append(log)
        }

        // Deciding again from saved balls is the run without the finding: each run's log, decided under that run's
        // net and camera, gives that run's answer to the line — and so does the log of the run that had no net,
        // decided under each of the others' (what a net or a camera position corrected afterwards does).
        for (index, run) in runs.enumerated() {
            for (source, log) in [("its own", logs[index]), ("the no-net run's", logs[0])] {
                let again = processor(for: run)
                let decided = try await answer(of: again) { try await again.decideRalliesAgain(from: log, forVideoAt: video, videoId: UUID(), persist: false) }
                let first = zip(answers[index], decided).enumerated().first { $0.element.0 != $0.element.1 }
                XCTAssertTrue(decided == answers[index], "\"\(run.name)\" decided again from \(source) saved balls differs from the run (\(answers[index].count) lines, \(decided.count) again); "
                    + "first at \(first?.offset ?? -1): ran \"\(first?.element.0 ?? "")\", again \"\(first?.element.1 ?? "")\"")
            }
        }
        print("PipelineGoldenTests: \(runs.count * 2) decisions from saved balls matched their runs")
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
