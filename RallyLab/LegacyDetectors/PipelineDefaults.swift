//
//  PipelineDefaults.swift
//  RallyLab
//
//  What RallyLab on the Mac gives the shared pipeline, as it did before the detectors left
//  the apps that ship (D-042): the Ultralytics-derived ball detector for a configuration
//  that asks for one, and the old net detector's box, sampled across the video. Research
//  only. Kept so stored evaluations, baselines and exported evidence can be reproduced as
//  they were made. The BumpSetCut app and RallyLab on the iPhone have their own file of
//  this name, with neither.
//

import AVFoundation
import Vision

extension YOLODetector: SingleFrameBallDetector {}

enum PipelineDefaults {
    /// The configured ball model (the one already loaded, if it is that one), with how frames are fitted into it:
    /// models trained on letterboxed frames get every frame letterboxed; ball_v2_small keeps the config's choice.
    static func singleFrameBallDetector(for config: ProcessorConfig, reusing existing: (any SingleFrameBallDetector)?) -> (any SingleFrameBallDetector)? {
        let loaded = existing as? YOLODetector
        let detector = loaded?.modelName == config.ballModel.rawValue ? loaded! : YOLODetector(modelName: config.ballModel.rawValue)
        detector.minConfidence = VNConfidence(config.detectionConfidence)
        if config.ballModel.needsLetterbox {
            detector.useScaleFitLetterbox = true
            detector.adaptiveLetterbox = false
        } else {
            detector.useScaleFitLetterbox = config.useScaleFitLetterbox
            detector.adaptiveLetterbox = config.adaptiveLetterbox
        }
        detector.adaptiveWideRatio = config.adaptiveLetterboxWideRatio
        return detector
    }

    static func netSource() -> any NetGeometrySource { LegacyNetDetectorSource() }
}

/// The old net detector's box for a video: one median box from frames spread across it — the sampling RallyLab's
/// Net tab uses (N frames over the middle 90%, the highest-confidence box per frame, a component-wise median).
/// The model is loaded once and kept across videos.
final class LegacyNetDetectorSource: NetGeometrySource {
    static let method = "legacy_net_detector"
    private var netDetector: NetDetector?

    func netGeometry(forVideoAt url: URL, asset: AVAsset, durationSec: Double, config: ProcessorConfig) async -> NetGeometry {
        if netDetector == nil { netDetector = NetDetector() }
        guard durationSec > 0, let netDetector else { return .unavailable(reason: "the video has no length") }
        netDetector.minConfidence = config.netDetectionConfidence
        netDetector.useScaleFitLetterbox = config.netUseScaleFitLetterbox
        let gen = AVAssetImageGenerator(asset: asset)
        // The ball detector's frame space: raw, or upright when the rotation is applied.
        gen.appliesPreferredTrackTransform = config.applyVideoRotation
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)

        let count = max(2, config.netSampleFrameCount)
        var boxes: [CGRect] = []
        var confs: [Double] = []
        for i in 0..<count {
            // Spread across the middle 90% to skip black intro/outro frames.
            let frac = count == 1 ? 0.5 : 0.05 + 0.9 * Double(i) / Double(count - 1)
            let t = CMTime(seconds: frac * durationSec, preferredTimescale: 600)
            guard let cg = try? await gen.image(at: t).image else { continue }
            if let best = netDetector.detect(in: cg).first {
                boxes.append(best.rect)
                confs.append(Double(best.confidence))
            }
        }
        guard !boxes.isEmpty else { return .unavailable(reason: "the net detector found no net") }
        return .detected(DetectedNet(box: BallNetSampler.medianBox(boxes), confidence: confs.reduce(0, +) / Double(confs.count)),
                         method: Self.method)
    }
}
