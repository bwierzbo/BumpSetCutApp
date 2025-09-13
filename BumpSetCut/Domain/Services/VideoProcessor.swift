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
    
    // Debug data collection
    var trajectoryDebugger: TrajectoryDebugger?
    private var metricsCollector: MetricsCollector?

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
        // Process every frame in production path

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
              
            // Check for cancellation before processing each frame
            try Task.checkCancellation()

            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)

            // Detect → track
            let dets = detector.detect(in: pix, at: pts)
            tracker.update(with: dets)

            // Pick the freshest track (the one updated this frame if possible)
            let activeTrack: KalmanBallTracker.TrackedBall? = tracker.tracks
                .sorted { ($0.positions.last?.1 ?? .zero) > ($1.positions.last?.1 ?? .zero) }
                .first

            // Gate by physics + fallback to raw detection presence (debug-friendly)
            let isProjectile = activeTrack.map { gate.isValidProjectile($0) } ?? false
            let hasBall = !dets.isEmpty
            let isActive = decider.update(hasBall: hasBall, isProjectile: isProjectile, timestamp: pts)
            segments.observe(isActive: isActive, at: pts)

            // Progress (~once per second)
            frameCount += 1
            if frameCount % fps == 0 {
                let p = min(1.0, max(0.0, Double(frameCount) / Double(max(totalFramesEstimate, 1))))
                await MainActor.run { self.progress = p }
                print(String(format: "[proc] t=%.2fs det=%d proj=%@ inRally=%@ tracks=%d",
                             CMTimeGetSeconds(pts),
                             dets.count,
                             isProjectile ? "Y" : "N",
                             isActive ? "Y" : "N",
                             tracker.tracks.count))
            }
            
            // Clean up sample buffer to prevent memory accumulation for large videos
            CMSampleBufferInvalidate(sbuf)
        }

        // Check if reader finished successfully or encountered an error
        if reader.status == .failed {
            if let error = reader.error {
                throw error
            } else {
                throw ProcessingError.exportFailed
            }
        }

        let keep = segments.finalize(until: duration)
        
        // Add detailed debugging information
        print("🔍 Debug: Segment finalization results:")
        print("   - Total keep ranges: \(keep.count)")
        print("   - Video duration: \(CMTimeGetSeconds(duration))s")
        if !keep.isEmpty {
            for (i, range) in keep.enumerated() {
                let startTime = CMTimeGetSeconds(range.start)
                let endTime = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                print("   - Range \(i): \(String(format: "%.2f", startTime))s - \(String(format: "%.2f", endTime))s (\(String(format: "%.2f", endTime - startTime))s)")
            }
        }
        
        guard !keep.isEmpty else {
            print("❌ No keep ranges. Detections may be too sparse or gating too strict. Check labels and thresholds.")
            print("💡 Possible causes:")
            print("   - Enhanced physics validation too strict")
            print("   - No ball detections found")
            print("   - Rally detection thresholds too high")
            print("   - Processing configuration issues")
            await MainActor.run { isProcessing = false }
            throw ProcessingError.exportFailed
        }

        // Check for cancellation before export (which can take a long time)
        try Task.checkCancellation()
        let out = try await exporter.exportTrimmed(asset: asset, keepRanges: keep)

        await MainActor.run {
            processedURL = out
            isProcessing = false
            progress = 1
        }
        return out
    }

    // MARK: - Debug path (no cutting, full-length annotated video)
    func processVideoDebug(_ url: URL) async throws -> URL {
        await MainActor.run { isProcessing = true; progress = 0 }

        // Initialize debug session
        await MainActor.run {
            metricsCollector = MetricsCollector(config: MetricsCollector.MetricsConfig.default)
        }
        trajectoryDebugger = TrajectoryDebugger(metricsCollector: metricsCollector!)
        trajectoryDebugger?.isEnabled = true
        trajectoryDebugger?.isRecording = true
        trajectoryDebugger?.startDebugSession(name: "Video Processing Session")

        // Recreate stage objects with current config
        self.gate = BallisticsGate(config: config)
        self.decider = RallyDecider(config: config)
        decider.reset()

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            await MainActor.run { isProcessing = false }
            throw ProcessingError.exportFailed
        }

        let duration = try await asset.load(.duration)
        let fps = max(10, Int(try await track.load(.nominalFrameRate)))
        // Process every Nth frame to reduce load
        let stride = 3
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        // Reuse last overlay on skipped frames
        var lastDets: [DetectionResult] = []
        var lastActiveTrack: KalmanBallTracker.TrackedBall? = nil
        var lastIsProjectile = false
        var lastInRally = false

        // Reader
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)

        // Annotator (writes full-length MP4 with overlays)
        let annotator = try DebugAnnotator(size: naturalSize, transform: preferredTransform)

        // Tracking
        let tracker = KalmanBallTracker()

        var frameCount = 0
        // We will write every frame in debug output
        let totalFramesEstimate = Int(duration.seconds * Double(fps))
        var rawFrameIndex = 0

        reader.startReading()
        while reader.status == .reading, let sbuf = output.copyNextSampleBuffer(),
              let pix = CMSampleBufferGetImageBuffer(sbuf) {
              
            // Check for cancellation before processing each frame
            try Task.checkCancellation()

            rawFrameIndex += 1
            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)

            // Decide whether to run the heavy path this frame
            let shouldProcess = (rawFrameIndex == 1) || (rawFrameIndex % stride == 0)
            if shouldProcess {
                // Detect → track
                let dets = detector.detect(in: pix, at: pts)
                tracker.update(with: dets)

                // Pick the freshest track
                let activeTrack: KalmanBallTracker.TrackedBall? = tracker.tracks
                    .sorted { ($0.positions.last?.1 ?? .zero) > ($1.positions.last?.1 ?? .zero) }
                    .first

                // Gate by physics + raw detection presence (debug-friendly)
                let isProjectile = activeTrack.map { gate.isValidProjectile($0) } ?? false
                let hasBall = !dets.isEmpty
                let inRally = decider.update(hasBall: hasBall, isProjectile: isProjectile, timestamp: pts)

                // Capture debug data if available
                if let debugger = trajectoryDebugger, let track = activeTrack {
                    // Create physics validation result with proper parameters
                    let physicsResult = PhysicsValidationResult(
                        isValid: isProjectile,
                        rSquared: 0.95, // Default value, could be extracted from gate
                        curvatureDirectionValid: true,
                        accelerationMagnitudeValid: true,
                        velocityConsistencyValid: true,
                        positionJumpsValid: true,
                        confidenceLevel: 0.9
                    )
                    
                    // Create movement classification
                    let movementClassifier = MovementClassifier()
                    let movementClassification = movementClassifier.classifyMovement(track)
                    
                    // Calculate quality metrics
                    let trajectoryQualityScore = TrajectoryQualityScore()
                    let qualityMetrics = trajectoryQualityScore.calculateQuality(for: track)
                    
                    debugger.analyzeTrajectory(
                        track,
                        physicsResult: physicsResult,
                        classificationResult: movementClassification,
                        qualityScore: qualityMetrics
                    )
                }

                // Cache for skipped frames
                lastDets = dets
                lastActiveTrack = activeTrack
                lastIsProjectile = isProjectile
                lastInRally = inRally
            }

            // Append annotated frame using the latest available overlay state
            try annotator.append(sampleBuffer: sbuf,
                                 overlay: .init(detections: lastDets,
                                                track: lastActiveTrack,
                                                isProjectile: lastIsProjectile,
                                                inRally: lastInRally,
                                                time: pts))

            // Progress (~once per second)
            frameCount += 1
            if frameCount % fps == 0 {
                let p = min(1.0, max(0.0, Double(frameCount) / Double(max(totalFramesEstimate, 1))))
                await MainActor.run { self.progress = p }
                print(String(format: "[debug] t=%.2fs det=%d proj=%@ rally=%@ tracks=%d",
                             CMTimeGetSeconds(pts),
                             lastDets.count,
                             lastIsProjectile ? "Y" : "N",
                             lastInRally ? "Y" : "N",
                             tracker.tracks.count))
            }
        }

        // Check for cancellation before finishing (which can take time)
        try Task.checkCancellation()
        let out = try await annotator.finish()
        
        // Stop debug session
        trajectoryDebugger?.stopDebugSession()
        
        await MainActor.run {
            processedURL = out
            isProcessing = false
            progress = 1
        }
        return out
    }
}
