//
//  ProcessingCheckpoint.swift
//  BumpSetCut
//
//  Resumable processing: a checkpoint written at rally-idle moments captures
//  everything the pipeline needs to continue a run from time T instead of
//  starting over — closed raw segments, the frozen net, evidence, per-frame
//  samples the post-loop rules consume, and the stat accumulators. Written
//  only when the rally decider is idle, so no tracker/FSM state crosses the
//  boundary: the resumed run starts its stateful stages fresh at T.
//
//  Diagnostic-only quality metrics (trajectory point breakdowns,
//  classification distribution) are NOT fully restored — restored trajectory
//  spans carry no points — so those metrics reflect the post-resume portion.
//  Everything user-visible (rally boundaries, per-rally confidence/quality,
//  serve-direction trend, evidence for the flywheel) survives the resume.
//

import CoreMedia
import CryptoKit
import Foundation

struct ProcessingCheckpoint: Codable {

    struct TimeRangeSec: Codable {
        let start: Double
        let end: Double
    }

    struct HeightSample: Codable {
        let t: Double
        let y: Double
    }

    struct SizeSample: Codable {
        let t: Double
        let area: Double
    }

    /// Compact physics entry: exactly the fields the per-segment metrics read.
    struct PhysicsSample: Codable {
        let t: Double
        let isValid: Bool
        let rSquared: Double
        let confidenceLevel: Double
    }

    /// Compact trajectory span: what per-segment average length needs.
    struct TrajectorySpan: Codable {
        let start: Double
        let end: Double
    }

    struct NetBox: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let confidence: Double

        init(_ net: DetectedNet) {
            x = Double(net.box.origin.x)
            y = Double(net.box.origin.y)
            width = Double(net.box.size.width)
            height = Double(net.box.size.height)
            confidence = net.confidence
        }

        var detectedNet: DetectedNet {
            DetectedNet(box: CGRect(x: x, y: y, width: width, height: height), confidence: confidence)
        }
    }

    struct Counters: Codable {
        var rawFrameIndex: Int
        var skippedFrames: Int
        var frameCount: Int
        var totalDetections: Int
        var detectionFrameCount: Int
        var trackingFrameCount: Int
        var rallyFrameCount: Int
        var physicsValidFrameCount: Int
        var confidenceSum: Double
        var rSquaredSum: Double
        var rSquaredCount: Int
    }

    let videoId: UUID
    /// Guards against resuming with a different pipeline configuration.
    let configHash: String
    /// Guards against resuming against a different source file.
    let videoDurationSec: Double
    let collectEvidence: Bool
    /// Where the resumed reader starts (a rally-idle timestamp).
    let resumeTime: Double
    let rawSegments: [TimeRangeSec]
    let ballHeights: [HeightSample]
    let ballSizes: [SizeSample]
    let evidence: [StoredFrameEvidence]
    let physics: [PhysicsSample]
    let trajectorySpans: [TrajectorySpan]
    let counters: Counters
    let net: NetBox?
    let savedAt: Date

    /// Stable hash over EVERY field of the processor configuration — a
    /// resumed run must use the exact config that produced the checkpoint.
    /// Reflection (not the Codable snapshot, which omits fields like
    /// detectionConfidence) so new tunables are covered automatically.
    static func hash(of config: ProcessorConfig) -> String {
        let description = Mirror(reflecting: config).children
            .map { "\($0.label ?? "?")=\($0.value)" }
            .sorted()
            .joined(separator: ";")
        let digest = SHA256.hash(data: Data(description.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this checkpoint can seed a run for the given inputs.
    func isValid(for videoId: UUID, configHash: String, durationSec: Double, collectEvidence: Bool) -> Bool {
        self.videoId == videoId
            && self.configHash == configHash
            && abs(self.videoDurationSec - durationSec) < 0.5
            && self.collectEvidence == collectEvidence
            && resumeTime > 1.0
            && resumeTime < durationSec - 1.0
    }
}

// MARK: - Isolation-free file I/O (the processing loop runs off the main actor)

extension ProcessingCheckpoint {

    static func load(from url: URL) -> ProcessingCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let checkpoint = try? JSONDecoder().decode(ProcessingCheckpoint.self, from: data) else {
            return nil
        }
        return checkpoint
    }

    func write(to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            print("⚠️ ProcessingCheckpoint: write failed — \(error.localizedDescription)")
        }
    }

    static func delete(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Evidence back-conversion

extension VideoProcessor.FrameEvidence {
    /// Rebuild in-memory evidence from its stored form on resume. Lossy
    /// fields (per-frame candidates, the net copy) restore empty/nil — the
    /// flywheel upload uses the stored form, which round-trips exactly.
    init(_ stored: StoredFrameEvidence) {
        self.init(
            time: stored.time,
            hasBall: stored.hasBall,
            isProjectile: stored.isProjectile,
            detections: stored.detections.map {
                VideoProcessor.BallDetection(
                    bbox: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height),
                    confidence: Float($0.confidence),
                    isOffCourt: false
                )
            },
            trackPoint: (stored.trackX != nil && stored.trackY != nil)
                ? CGPoint(x: stored.trackX!, y: stored.trackY!)
                : nil,
            rSquared: stored.rSquared,
            gravitySignature: stored.gravitySignature,
            movementType: stored.movementType.flatMap(MovementType.init(rawValue:)),
            rejectionReason: stored.rejectionReason,
            candidates: [],
            detectedNet: nil
        )
    }
}
