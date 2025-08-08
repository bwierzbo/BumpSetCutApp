//
//  VideoProcessor.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import Foundation
import AVFoundation
import Vision
import CoreMedia
import UIKit

@Observable
final class VideoProcessor {

    // MARK: - UI observed
    var isProcessing = false
    var progress: Double = 0.0
    var processedURL: URL?

    // MARK: - Config + deps
    var config = ProcessorConfig()

    // After
    private let detector = YOLODetector()
    private var gate = BallisticsGate(config: ProcessorConfig())
    private var decider = RallyDecider(config: ProcessorConfig())
    private var segments = SegmentBuilder(config: ProcessorConfig())
    private let exporter = VideoExporter()

    // MARK: - Entry point
    func processVideo(_ url: URL) async throws -> URL {
        await MainActor.run { isProcessing = true; progress = 0 }

        // Recreate stage objects with current config (no lazy)
        self.gate = BallisticsGate(config: config)
        self.decider = RallyDecider(config: config)
        self.segments = SegmentBuilder(config: config)
        
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.exportFailed
        }

        let duration = try await asset.load(.duration)
        let fps = max(10, Int(try await track.load(.nominalFrameRate)))

        // Reader
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)

        // Reset state
        decider.reset()
        segments.reset()

        var frameCount = 0
        let totalFramesEstimate = Int(duration.seconds * Double(fps))

        reader.startReading()
        let tracker = KalmanBallTracker()

        while reader.status == .reading, let sbuf = output.copyNextSampleBuffer(),
              let pix = CMSampleBufferGetImageBuffer(sbuf) {

            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)

            // Detect → track
            let dets = detector.detect(in: pix, at: pts)
            tracker.update(with: dets)

            // Pick the freshest track (the one updated this frame if possible)
            let activeTrack: KalmanBallTracker.TrackedBall? = tracker.tracks
                .sorted { ($0.positions.last?.1 ?? .zero) > ($1.positions.last?.1 ?? .zero) }
                .first

            // Gate by physics
            let isProjectile = activeTrack.map { gate.isValidProjectile($0) } ?? false

            let isActive = decider.update(isBallActive: isProjectile, timestamp: pts)
            segments.observe(isActive: isActive, at: pts)

            // Progress (~once per second)
            frameCount += 1
            if frameCount % fps == 0 {
                let p = min(1.0, max(0.0, Double(frameCount) / Double(max(totalFramesEstimate, 1))))
                await MainActor.run { self.progress = p }
            }
        }

        let keep = segments.finalize(until: duration)
        guard !keep.isEmpty else {
            await MainActor.run { isProcessing = false }
            throw ProcessingError.exportFailed
        }

        let out = try await exporter.exportTrimmed(asset: asset, keepRanges: keep)

        await MainActor.run {
            processedURL = out
            isProcessing = false
            progress = 1
        }
        return out
    }
}
