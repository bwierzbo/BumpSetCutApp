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
    var processedMetadata: ProcessingMetadata?

    // MARK: - Config + deps
    var config = ProcessorConfig()

    // After
    private let detector = YOLODetector()
    private var gate = BallisticsGate(config: ProcessorConfig())
    private var decider = RallyDecider(config: ProcessorConfig())
    private var segments = SegmentBuilder(config: ProcessorConfig())
    private let exporter = VideoExporter()
    private var metadataStore: MetadataStore?

    // Background execution protection
    private let backgroundGuard = BackgroundProcessingGuard()

    // Debug data collection
    var trajectoryDebugger: TrajectoryDebugger?
    private var metricsCollector: MetricsCollector?

    // MARK: - Entry point (now generates metadata instead of video files)
    func processVideo(_ url: URL, videoId: UUID) async throws -> ProcessingMetadata {
        // Delegate to metadata processing method
        return try await processVideoMetadata(url, videoId: videoId)
    }

    // MARK: - Legacy video export method (for backward compatibility if needed)
    func processVideoLegacy(_ url: URL) async throws -> URL {
        await MainActor.run {
            isProcessing = true; progress = 0
            backgroundGuard.begin {
                print("⚠️ BackgroundProcessingGuard: background time expiring during legacy processing")
            }
        }

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

            // Gate by physics + fallback to raw detection presence
            let gateResult = activeTrack.map { gate.validateProjectile($0) }
            let isProjectile = gateResult?.isValid ?? false
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
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
            throw ProcessingError.exportFailed
        }

        // Check for cancellation before export (which can take a long time)
        try Task.checkCancellation()
        let out = try await exporter.exportTrimmed(asset: asset, keepRanges: keep)

        await MainActor.run {
            processedURL = out
            isProcessing = false
            progress = 1
            backgroundGuard.end()
        }
        return out
    }

    // MARK: - Debug path (no cutting, full-length annotated video)
    func processVideoDebug(_ url: URL) async throws -> URL {
        await MainActor.run {
            isProcessing = true; progress = 0
            backgroundGuard.begin {
                print("⚠️ BackgroundProcessingGuard: background time expiring during debug processing")
            }
        }

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
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
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
                let gateResult = activeTrack.map { gate.validateProjectile($0) }
                let isProjectile = gateResult?.isValid ?? false
                let hasBall = !dets.isEmpty
                let inRally = decider.update(hasBall: hasBall, isProjectile: isProjectile, timestamp: pts)

                // Capture debug data if available
                if let debugger = trajectoryDebugger, let track = activeTrack {
                    let gr = gateResult ?? BallisticsGate.ValidationResult(
                        isValid: false, rSquared: 0, curvatureDirectionValid: false,
                        hasMotionEvidence: false, positionJumpsValid: true, confidenceLevel: 0)
                    let physicsResult = PhysicsValidationResult(
                        isValid: gr.isValid,
                        rSquared: gr.rSquared,
                        curvatureDirectionValid: gr.curvatureDirectionValid,
                        accelerationMagnitudeValid: gr.hasMotionEvidence,
                        velocityConsistencyValid: true,
                        positionJumpsValid: gr.positionJumpsValid,
                        confidenceLevel: gr.confidenceLevel
                    )

                    let movementClassifier = MovementClassifier()
                    let movementClassification = movementClassifier.classifyMovement(track)

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
            backgroundGuard.end()
        }
        return out
    }

    // MARK: - Metadata path (production mode with metadata generation)
    func processVideoMetadata(_ url: URL, videoId: UUID) async throws -> ProcessingMetadata {
        await MainActor.run {
            isProcessing = true; progress = 0; processedMetadata = nil
            backgroundGuard.begin {
                print("⚠️ BackgroundProcessingGuard: background time expiring during metadata processing")
            }
        }

        // Check analysis mode from settings
        let useThoroughAnalysis = await MainActor.run { AppSettings.shared.useThoroughAnalysis }
        print("📊 Analysis mode: \(useThoroughAnalysis ? "Thorough" : "Quick")")

        let startTime = Date()

        // Initialize metadata store on main actor
        self.metadataStore = await MainActor.run { MetadataStore() }

        // Recreate stage objects with current config (no lazy)
        self.gate = BallisticsGate(config: config)
        self.decider = RallyDecider(config: config)
        self.segments = SegmentBuilder(config: config)

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
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

        // Metadata collection variables
        var frameCount = 0
        var totalDetections = 0
        var detectionFrameCount = 0
        var trackingFrameCount = 0
        var rallyFrameCount = 0
        var physicsValidFrameCount = 0
        var confidenceSum = 0.0
        var rSquaredSum = 0.0
        var rSquaredCount = 0

        // Trajectory data collection with memory limits
        var trajectoryDataCollection: [ProcessingTrajectoryData] = []
        var classificationResults: [ProcessingClassificationResult] = []
        var physicsValidationData: [PhysicsValidationData] = []

        // Memory management constants from config
        let maxTrajectoryData = config.enableMemoryLimits ? config.maxTrajectoryDataEntries : 10000
        let maxClassificationResults = config.enableMemoryLimits ? config.maxClassificationEntries : 10000
        let maxPhysicsValidationData = config.enableMemoryLimits ? config.maxPhysicsValidationEntries : 10000

        let totalFramesEstimate = Int(duration.seconds * Double(fps))

        reader.startReading()
        let tracker = KalmanBallTracker(config: config)

        // Dynamic stride tracking
        var rawFrameIndex = 0
        var skippedFrames = 0

        while reader.status == .reading, let sbuf = output.copyNextSampleBuffer(),
              let pix = CMSampleBufferGetImageBuffer(sbuf) {

            // Check for cancellation before processing each frame
            try Task.checkCancellation()

            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
            rawFrameIndex += 1

            // Dynamic stride: only in thorough mode
            let shouldProcess: Bool
            if useThoroughAnalysis {
                let recommendedStride = tracker.recommendedStride(currentTime: pts)
                shouldProcess = (rawFrameIndex == 1) || (rawFrameIndex % recommendedStride == 0)
            } else {
                shouldProcess = true  // Quick mode: process every frame
            }

            // Skip detection/tracking on non-processed frames
            guard shouldProcess else {
                skippedFrames += 1
                CMSampleBufferInvalidate(sbuf)
                continue
            }

            // Detect → track
            let dets = detector.detect(in: pix, at: pts)
            tracker.update(with: dets)

            // Update detection statistics
            totalDetections += dets.count
            if !dets.isEmpty {
                detectionFrameCount += 1
            }

            // Pick the freshest track (the one updated this frame if possible)
            let activeTrack: KalmanBallTracker.TrackedBall? = tracker.tracks
                .sorted { ($0.positions.last?.1 ?? .zero) > ($1.positions.last?.1 ?? .zero) }
                .first

            // Gate by physics + fallback to raw detection presence
            let gateResult = activeTrack.map { gate.validateProjectile($0) }
            let isProjectile = gateResult?.isValid ?? false
            let hasBall = !dets.isEmpty
            let isActive = decider.update(hasBall: hasBall, isProjectile: isProjectile, timestamp: pts)
            segments.observe(isActive: isActive, at: pts)

            // Update statistics
            if !tracker.tracks.isEmpty {
                trackingFrameCount += 1
            }
            if isActive {
                rallyFrameCount += 1
            }
            if isProjectile {
                physicsValidFrameCount += 1
            }

            // Collect trajectory data only in thorough mode
            if useThoroughAnalysis, let track = activeTrack {
                // Calculate metrics for this track segment
                let (rSquared, velocity, acceleration) = calculateTrackMetrics(track)
                if rSquared > 0 {
                    rSquaredSum += rSquared
                    rSquaredCount += 1
                }

                // Create trajectory data for tracks with sufficient points
                if track.positions.count >= 2 {
                    // Convert all track positions to trajectory points
                    let trajectoryPoints = track.positions.map { position in
                        ProcessingTrajectoryPoint(
                            timestamp: position.1,
                            position: position.0,
                            velocity: velocity,
                            acceleration: acceleration,
                            confidence: calculateTrackConfidence(track)
                        )
                    }

                    let movementClassifier = MovementClassifier()
                    let classification = movementClassifier.classifyMovement(track)

                    let trackStartTime = track.positions.first?.1 ?? pts
                    let newTrajectory = ProcessingTrajectoryData(
                        id: UUID(),
                        startTime: CMTimeGetSeconds(trackStartTime),
                        endTime: CMTimeGetSeconds(pts),
                        points: trajectoryPoints,
                        rSquared: rSquared,
                        movementType: classification.movementType,
                        confidence: calculateTrackConfidence(track),
                        quality: classification.details.physicsScore
                    )
                    trajectoryDataCollection.append(newTrajectory)

                    // Memory management: enforce sliding window for trajectory data
                    if trajectoryDataCollection.count > maxTrajectoryData {
                        trajectoryDataCollection.removeFirst(trajectoryDataCollection.count - maxTrajectoryData)
                    }

                    // Store classification result
                    let classificationResult = ProcessingClassificationResult(
                        trajectoryId: newTrajectory.id,
                        timestamp: pts,
                        movementType: classification.movementType,
                        confidence: classification.confidence,
                        classificationDetails: classification.details
                    )
                    classificationResults.append(classificationResult)

                    // Memory management: enforce sliding window for classification results
                    if classificationResults.count > maxClassificationResults {
                        classificationResults.removeFirst(classificationResults.count - maxClassificationResults)
                    }

                    confidenceSum += calculateTrackConfidence(track)
                }

                // Store physics validation data from real gate results
                let gr = gateResult ?? BallisticsGate.ValidationResult(
                    isValid: false, rSquared: 0, curvatureDirectionValid: false,
                    hasMotionEvidence: false, positionJumpsValid: true, confidenceLevel: 0)
                let physicsData = PhysicsValidationData(
                    trajectoryId: trajectoryDataCollection.last?.id ?? UUID(),
                    timestamp: pts,
                    isValid: gr.isValid,
                    rSquared: gr.rSquared,
                    curvatureValid: gr.curvatureDirectionValid,
                    accelerationValid: gr.hasMotionEvidence,
                    velocityConsistent: true,
                    positionJumpsValid: gr.positionJumpsValid,
                    confidenceLevel: gr.confidenceLevel
                )
                physicsValidationData.append(physicsData)

                // Memory management: enforce sliding window for physics validation data
                if physicsValidationData.count > maxPhysicsValidationData {
                    physicsValidationData.removeFirst(physicsValidationData.count - maxPhysicsValidationData)
                }
            }

            // Progress (~once per second)
            frameCount += 1
            if frameCount % fps == 0 {
                let p = min(1.0, max(0.0, Double(frameCount) / Double(max(totalFramesEstimate, 1))))
                await MainActor.run { self.progress = p }
                print(String(format: "[metadata] t=%.2fs det=%d proj=%@ inRally=%@ tracks=%d",
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

        // Log processing statistics
        let processedFrames = rawFrameIndex - skippedFrames
        let skipRate = rawFrameIndex > 0 ? (Double(skippedFrames) / Double(rawFrameIndex)) * 100 : 0
        if useThoroughAnalysis {
            print("⚡ Thorough mode - Dynamic stride statistics:")
            print("   - Total frames: \(rawFrameIndex)")
            print("   - Processed frames: \(processedFrames)")
            print("   - Skipped frames: \(skippedFrames) (\(String(format: "%.1f", skipRate))%)")
        } else {
            print("🚀 Quick mode - Processed all \(rawFrameIndex) frames")
        }

        print("🔍 Metadata: Segment finalization results:")
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
            print("❌ No rally segments found for metadata generation")
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
            throw ProcessingError.exportFailed
        }

        // Check for cancellation before metadata generation
        try Task.checkCancellation()

        // Generate rally segments from keep ranges with real per-segment metrics
        let rallySegments = keep.enumerated().map { index, range in
            let rangeStart = CMTimeGetSeconds(range.start)
            let rangeEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(range))

            // Filter physics validation data within this segment's time range
            let segmentPhysics = physicsValidationData.filter {
                $0.timestamp >= rangeStart && $0.timestamp <= rangeEnd
            }

            // Compute real confidence: average confidenceLevel of physics entries in range
            let segmentConfidence: Double
            if segmentPhysics.isEmpty {
                segmentConfidence = 0.0
            } else {
                segmentConfidence = segmentPhysics.reduce(0.0) { $0 + $1.confidenceLevel } / Double(segmentPhysics.count)
            }

            // Compute real quality: average R-squared of valid physics entries in range
            let validPhysics = segmentPhysics.filter { $0.isValid && $0.rSquared > 0 }
            let segmentQuality: Double
            if validPhysics.isEmpty {
                segmentQuality = 0.0
            } else {
                segmentQuality = validPhysics.reduce(0.0) { $0 + $1.rSquared } / Double(validPhysics.count)
            }

            // Filter trajectories within this segment's time range
            let segmentTrajectories = trajectoryDataCollection.filter {
                $0.startTime < rangeEnd && $0.endTime > rangeStart
            }
            let avgTrajLen = segmentTrajectories.isEmpty ? 0.0 :
                segmentTrajectories.reduce(0.0) { $0 + $1.duration } / Double(segmentTrajectories.count)

            return RallySegment(
                startTime: range.start,
                endTime: CMTimeRangeGetEnd(range),
                confidence: segmentConfidence,
                quality: segmentQuality,
                detectionCount: segmentPhysics.count,
                averageTrajectoryLength: avgTrajLen
            )
        }

        // Generate processing statistics
        let processingStats = ProcessingStats(
            totalFrames: rawFrameIndex,
            processedFrames: processedFrames,
            detectionFrames: detectionFrameCount,
            trackingFrames: trackingFrameCount,
            rallyFrames: rallyFrameCount,
            physicsValidFrames: physicsValidFrameCount,
            totalDetections: totalDetections,
            validTrajectories: trajectoryDataCollection.count,
            averageDetectionsPerFrame: processedFrames > 0 ? Double(totalDetections) / Double(processedFrames) : 0,
            averageConfidence: detectionFrameCount > 0 ? confidenceSum / Double(detectionFrameCount) : 0,
            processingDuration: Date().timeIntervalSince(startTime),
            framesPerSecond: Double(fps)
        )

        // Generate quality metrics
        let qualityMetrics = QualityMetrics(
            overallQuality: calculateOverallQuality(stats: processingStats, rSquaredAvg: rSquaredCount > 0 ? rSquaredSum / Double(rSquaredCount) : 0),
            averageRSquared: rSquaredCount > 0 ? rSquaredSum / Double(rSquaredCount) : 0,
            trajectoryConsistency: calculateTrajectoryConsistency(trajectoryDataCollection),
            physicsValidationRate: frameCount > 0 ? Double(physicsValidFrameCount) / Double(frameCount) : 0,
            movementClassificationAccuracy: calculateClassificationAccuracy(classificationResults),
            confidenceDistribution: calculateConfidenceDistribution(classificationResults),
            qualityBreakdown: calculateQualityBreakdown(trajectoryDataCollection)
        )

        // Generate performance metrics
        let endTime = Date()
        let performanceMetrics = PerformanceData(
            processingStartTime: startTime,
            processingEndTime: endTime,
            averageFPS: processingStats.framesPerSecond,
            peakMemoryUsageMB: 0, // Could implement memory tracking
            averageMemoryUsageMB: 0,
            cpuUsagePercent: nil,
            processingOverheadPercent: calculateProcessingOverhead(processingDuration: endTime.timeIntervalSince(startTime), videoDuration: CMTimeGetSeconds(duration)),
            detectionLatencyMs: nil
        )

        // Create final metadata
        let metadata = ProcessingMetadata.createWithEnhancedData(
            for: videoId,
            with: config,
            rallySegments: rallySegments,
            stats: processingStats,
            quality: qualityMetrics,
            trajectories: trajectoryDataCollection,
            classifications: classificationResults,
            physics: physicsValidationData,
            performance: performanceMetrics
        )

        // Save metadata to store
        do {
            guard let metadataStore = metadataStore else {
                throw ProcessingError.exportFailed
            }
            try await metadataStore.saveMetadata(metadata)
            print("✅ Successfully saved metadata for video \(videoId)")
        } catch {
            print("❌ Failed to save metadata: \(error)")
            await MainActor.run { backgroundGuard.end() }
            throw error
        }

        await MainActor.run {
            processedMetadata = metadata
            isProcessing = false
            progress = 1
            backgroundGuard.end()
        }

        return metadata
    }

    // MARK: - Helper methods for metadata calculation

    private func calculateTrackMetrics(_ track: KalmanBallTracker.TrackedBall) -> (rSquared: Double, velocity: Double, acceleration: Double) {
        guard track.positions.count >= 3 else {
            return (0.0, 0.0, 0.0)
        }

        // Calculate velocity from last few points
        let recent = track.positions.suffix(3)
        var velocitySum = 0.0
        let accelerationSum = 0.0

        if recent.count >= 2 {
            let positions = Array(recent)
            for i in 1..<positions.count {
                let dt = CMTimeGetSeconds(positions[i].1) - CMTimeGetSeconds(positions[i-1].1)
                if dt > 0 {
                    let dx = positions[i].0.x - positions[i-1].0.x
                    let dy = positions[i].0.y - positions[i-1].0.y
                    let velocity = sqrt(dx*dx + dy*dy) / dt
                    velocitySum += Double(velocity)
                }
            }

            // Simple R² calculation based on trajectory linearity (simplified)
            let rSquared = calculateSimpleRSquared(positions: track.positions.map { $0.0 })
            return (rSquared, velocitySum / Double(recent.count - 1), accelerationSum)
        }

        return (0.0, 0.0, 0.0)
    }

    private func calculateTrackConfidence(_ track: KalmanBallTracker.TrackedBall) -> Double {
        // Calculate confidence based on track age, consistency, and displacement
        guard track.positions.count >= 2 else {
            return 0.3 // Low confidence for single-point tracks
        }

        // Age-based confidence (longer tracks are more reliable)
        let ageConfidence = min(1.0, Double(track.age) / 10.0)

        // Movement-based confidence (tracks that move are more likely to be balls)
        let movementConfidence = min(1.0, Double(track.netDisplacement) * 5.0)

        // Combine factors
        let baseConfidence = (ageConfidence + movementConfidence) / 2.0

        // Ensure reasonable bounds
        return max(0.1, min(0.95, baseConfidence))
    }

    private func calculateSimpleRSquared(positions: [CGPoint]) -> Double {
        guard positions.count >= 3 else { return 0.0 }

        // Calculate linear regression R²
        let n = Double(positions.count)
        let sumX = positions.reduce(0) { $0 + Double($1.x) }
        let sumY = positions.reduce(0) { $0 + Double($1.y) }
        let sumXY = positions.reduce(0) { $0 + Double($1.x * $1.y) }
        let sumXX = positions.reduce(0) { $0 + Double($1.x * $1.x) }
        let sumYY = positions.reduce(0) { $0 + Double($1.y * $1.y) }

        let numerator = n * sumXY - sumX * sumY
        let denominator = sqrt((n * sumXX - sumX * sumX) * (n * sumYY - sumY * sumY))

        guard denominator > 0 else { return 0.0 }
        let correlation = numerator / denominator
        return max(0.0, min(1.0, correlation * correlation))
    }

    private func calculateOverallQuality(stats: ProcessingStats, rSquaredAvg: Double) -> Double {
        let detectionQuality = stats.detectionRate
        let physicsQuality = stats.physicsValidFrames > 0 ? Double(stats.physicsValidFrames) / Double(stats.processedFrames) : 0
        let trajectoryQuality = rSquaredAvg
        let completenessQuality = stats.processingCompleteness

        return (detectionQuality + physicsQuality + trajectoryQuality + completenessQuality) / 4.0
    }

    private func calculateTrajectoryConsistency(_ trajectories: [ProcessingTrajectoryData]) -> Double {
        guard !trajectories.isEmpty else { return 0.0 }

        let avgRSquared = trajectories.reduce(0) { $0 + $1.rSquared } / Double(trajectories.count)
        return avgRSquared
    }

    private func calculateClassificationAccuracy(_ classifications: [ProcessingClassificationResult]) -> Double? {
        guard !classifications.isEmpty else { return nil }

        let avgConfidence = classifications.reduce(0) { $0 + $1.confidence } / Double(classifications.count)
        return avgConfidence
    }

    private func calculateConfidenceDistribution(_ classifications: [ProcessingClassificationResult]) -> ConfidenceDistribution {
        var high = 0
        var medium = 0
        var low = 0

        for classification in classifications {
            if classification.confidence >= 0.8 {
                high += 1
            } else if classification.confidence >= 0.5 {
                medium += 1
            } else {
                low += 1
            }
        }

        return ConfidenceDistribution(high: high, medium: medium, low: low)
    }

    private func calculateQualityBreakdown(_ trajectories: [ProcessingTrajectoryData]) -> QualityBreakdown {
        guard !trajectories.isEmpty else {
            return QualityBreakdown(
                velocityConsistency: 0,
                accelerationPattern: 0,
                smoothnessScore: 0,
                verticalMotionScore: 0,
                overallCoherence: 0
            )
        }

        // Calculate average metrics across all trajectories
        var totalVelocityConsistency = 0.0
        var totalAccelerationPattern = 0.0
        var totalSmoothness = 0.0
        var totalVerticalMotion = 0.0

        for trajectory in trajectories {
            // These would ideally come from the classification details or be calculated from trajectory points
            totalVelocityConsistency += 0.8 // Placeholder
            totalAccelerationPattern += trajectory.rSquared
            totalSmoothness += trajectory.quality
            totalVerticalMotion += 0.7 // Placeholder
        }

        let count = Double(trajectories.count)
        let velocityConsistency = totalVelocityConsistency / count
        let accelerationPattern = totalAccelerationPattern / count
        let smoothnessScore = totalSmoothness / count
        let verticalMotionScore = totalVerticalMotion / count
        let overallCoherence = (velocityConsistency + accelerationPattern + smoothnessScore + verticalMotionScore) / 4.0

        return QualityBreakdown(
            velocityConsistency: velocityConsistency,
            accelerationPattern: accelerationPattern,
            smoothnessScore: smoothnessScore,
            verticalMotionScore: verticalMotionScore,
            overallCoherence: overallCoherence
        )
    }

    private func calculateProcessingOverhead(processingDuration: TimeInterval, videoDuration: TimeInterval) -> Double {
        guard videoDuration > 0 else { return 0 }
        return (processingDuration / videoDuration - 1.0) * 100.0
    }
}
