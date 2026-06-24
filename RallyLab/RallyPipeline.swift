//
//  RallyPipeline.swift
//  RallyLab
//
//  Pluggable rally-detection pipelines for side-by-side comparison. A pipeline is
//  anything that turns a video + config into predicted rally intervals; the labels,
//  scorer, and overlay stay shared so different approaches are comparable.
//
//  To add an experimental pipeline: conform a type to `RallyPipeline` (or build a
//  `StandardPipeline` variant with a config transform) and add it to
//  `PipelineRegistry.all`. It then appears in the Compare tab's pickers.
//

import Foundation

/// The output of running a pipeline over a video: the raw (unpadded) decided rally
/// boundaries — what the scorer compares to hand labels — plus the padded export ranges.
struct PipelineResult {
    let rawPredictions: [Interval]
    let paddedPredictions: [Interval]
}

/// A rally-detection pipeline RallyLab can run and score.
protocol RallyPipeline {
    var id: String { get }
    var name: String { get }
    var detail: String { get }
    /// Produce predicted rally intervals. `baseConfig` is RallyLab's current tunable
    /// config; pipelines may override fields. Heavy detection work belongs here.
    func run(url: URL, duration: Double, baseConfig: ProcessorConfig, minRallySec: Double) async throws -> PipelineResult
}

/// The production pipeline (YOLO → Kalman → ballistics gate → decider → segments),
/// parameterized by a config transform so config-only variants are one-liners.
struct StandardPipeline: RallyPipeline {
    let id: String
    let name: String
    let detail: String
    /// Applied to RallyLab's base config before running — lets variants flip flags.
    let configure: (ProcessorConfig) -> ProcessorConfig

    func run(url: URL, duration: Double, baseConfig: ProcessorConfig, minRallySec: Double) async throws -> PipelineResult {
        let cfg = configure(baseConfig)
        let processor = VideoProcessor()
        processor.config = cfg
        processor.collectFrameEvidence = true
        do {
            _ = try await processor.processVideo(url, videoId: UUID())
        } catch ProcessingError.noRalliesDetected {
            // Zero predicted segments is a legitimate outcome; evidence was still captured.
        }
        let evidence = processor.frameEvidence
        let dur = processor.lastVideoDurationSec > 0 ? processor.lastVideoDurationSec : duration
        let raw = EvidenceReplayer.decidedRanges(evidence: evidence, duration: dur, config: cfg,
                                                 minRallySec: minRallySec, padded: false)
        let padded = EvidenceReplayer.decidedRanges(evidence: evidence, duration: dur, config: cfg,
                                                    minRallySec: minRallySec, padded: true)
        return PipelineResult(rawPredictions: raw, paddedPredictions: padded)
    }
}

/// Phase 1 deterministic FSM pipeline: ball + net + court geometry → finite state
/// machine, no ML scoring. Runs its own dense detection pass + the engine.
struct DeterministicPipeline: RallyPipeline {
    let id = "deterministic"
    let name = "Deterministic FSM (Phase 1)"
    let detail = "Ball + net + court geometry → finite state machine. No ML scoring."

    func run(url: URL, duration: Double, baseConfig: ProcessorConfig, minRallySec: Double) async throws -> PipelineResult {
        let (samples, net) = try await BallNetSampler.sample(url: url)
        guard let net else { return PipelineResult(rawPredictions: [], paddedPredictions: []) }
        let result = DeterministicRallyEngine(config: EngineConfig()).run(samples: samples, net: net)
        let intervals = result.rallies.map { Interval(start: $0.startTime, end: $0.endTime) }
        return PipelineResult(rawPredictions: intervals, paddedPredictions: intervals)
    }
}

/// The pipelines available in the Compare tab. Add experimental ones here.
enum PipelineRegistry {
    static let all: [RallyPipeline] = [
        StandardPipeline(
            id: "standard",
            name: "Standard",
            detail: "Current pipeline as-is (your live tunables).",
            configure: { $0 }
        ),
        StandardPipeline(
            id: "scoregate",
            name: "Standard + score gate",
            detail: "Standard, then drop rallies below the rally-score threshold.",
            configure: { var c = $0; c.enableRallyScoreGate = true; return c }
        ),
        DeterministicPipeline(),
    ]

    static func pipeline(id: String) -> RallyPipeline? {
        all.first { $0.id == id }
    }
}
