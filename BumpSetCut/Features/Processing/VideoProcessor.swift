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

@Observable
final class VideoProcessor {

    // MARK: - UI observed
    var isProcessing = false
    var progress: Double = 0.0
    var processedURL: URL?
    var processedMetadata: ProcessingMetadata?

    // MARK: - Config + deps
    var config = ProcessorConfig()

    /// Max seconds since a track's last real detection for it to still count as
    /// a live ball. Large enough to ride out brief occlusions (a few frames),
    /// small enough that a ball that has left the frame stops driving the rally.
    private let maxTrackStalenessSec: Double = 0.3

    /// Identity of the track currently driving the rally, for selection stickiness
    /// across frames. Reset per video.
    private var selectedTrackId: UUID?

    private var detector = YOLODetector()
    private var gate = BallisticsGate(config: ProcessorConfig())
    private var decider = RallyDecider(config: ProcessorConfig())
    private var segments = SegmentBuilder(config: ProcessorConfig())

    #if os(iOS)
    private let exporter = VideoExporter()
    #endif
    private var metadataStore: MetadataStore?

    // Background execution protection
    private let backgroundGuard = BackgroundProcessingGuard()

    /// Register a closure to be called if background time expires during processing.
    /// Typically used by the ViewModel to cancel the current processing Task.
    @MainActor
    func setBackgroundCancellationHandler(_ handler: @escaping @MainActor () -> Void) {
        backgroundGuard.setCancellationHandler(handler)
    }

    // Debug data collection
    var trajectoryDebugger: TrajectoryDebugger?
    private var metricsCollector: MetricsCollector?

    // MARK: - Frame evidence capture (for offline replay/evaluation tools)

    /// One processed frame's rally-evidence signals plus the raw visual data
    /// needed to draw a detection/trajectory overlay. Replaying the signal
    /// fields through RallyDecider/SegmentBuilder reproduces segmentation
    /// exactly for any post-detection config, without re-running detection.
    /// A kept volleyball detection: its Vision-normalized bbox plus the YOLO
    /// model confidence for that box.
    struct BallDetection {
        let bbox: CGRect
        let confidence: Float
    }

    /// One candidate trajectory considered for the rally this frame (multi-court).
    /// Lets RallyLab draw every candidate trail and show why one was selected.
    struct TrackCandidate {
        let id: UUID
        let point: CGPoint        // current normalized position (Vision coords)
        let score: Double         // selection score (quality + size/age tiebreaks)
        let isProjectile: Bool    // passed the gate this frame
        let isSelected: Bool      // the track driving the rally
        let ballSize: CGFloat     // detected ball's mean side length (normalized);
                                  // RallyLab draws the ROI as this × a display scale
    }

    struct FrameEvidence {
        let time: Double          // PTS in seconds
        let hasBall: Bool
        let isProjectile: Bool
        /// Kept volleyball detections this frame (Vision-normalized bboxes,
        /// origin bottom-left, [0,1]) with their model confidences. Empty when
        /// nothing was detected.
        let detections: [BallDetection]
        /// Center of the freshest active track this frame (normalized), or nil
        /// when no track was active. Successive points form the ball trail.
        let trackPoint: CGPoint?
        /// Physics-gate readouts for the active track this frame (nil when no
        /// track was validated). These are what distinguish a real arc from a
        /// carried/held ball: rSquared stays high even for a straight carry,
        /// so gravitySignature + movementType are the real discriminators.
        let rSquared: Double?
        let gravitySignature: Double?
        let movementType: MovementType?
        /// Why the gate did NOT accept this frame as a projectile (nil when it did).
        let rejectionReason: String?
        /// All candidate trajectories this frame (multi-court), for visualization.
        let candidates: [TrackCandidate]
    }

    /// Off by default: evidence costs memory proportional to frame count, so
    /// only evaluation tools (RallyLab) opt in.
    var collectFrameEvidence = false
    private(set) var frameEvidence: [FrameEvidence] = []
    private(set) var lastVideoDurationSec: Double = 0

    // MARK: - Entry point (now generates metadata instead of video files)
    func processVideo(_ url: URL, videoId: UUID) async throws -> ProcessingMetadata {
        // Delegate to metadata processing method
        return try await processVideoMetadata(url, videoId: videoId)
    }

    #if os(iOS)
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
        selectedTrackId = nil

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
            throw ProcessingError.noVideoTrack
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
        var lastGateResult: BallisticsGate.ValidationResult? = nil

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
        // Reuse stateless classifiers across frames to avoid per-frame allocation
        let movementClassifier = MovementClassifier()
        let trajectoryQualityScore = TrajectoryQualityScore()

        var frameCount = 0
        // We will write every frame in debug output
        let totalFramesEstimate = Int(duration.seconds * Double(fps))
        var rawFrameIndex = 0

        reader.startReading()
        defer { reader.cancelReading() }
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
                tracker.update(with: dets, at: pts)

                // Best rally trajectory across courts (quality-first, sticky).
                let selection = bestTrack(now: pts, tracker: tracker)
                let activeTrack = selection.track
                let gateResult = selection.gate
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

                    let movementClassification = movementClassifier.classifyMovement(track)
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
                lastGateResult = gateResult
            }

            // Append annotated frame using the latest available overlay state
            try annotator.append(sampleBuffer: sbuf,
                                 overlay: .init(detections: lastDets,
                                                track: lastActiveTrack,
                                                isProjectile: lastIsProjectile,
                                                inRally: lastInRally,
                                                time: pts,
                                                validation: lastGateResult))

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
    #endif

    // MARK: - Metadata path (production mode with metadata generation)
    func processVideoMetadata(_ url: URL, videoId: UUID) async throws -> ProcessingMetadata {
        await MainActor.run {
            isProcessing = true; progress = 0; processedMetadata = nil
            backgroundGuard.begin {
                print("⚠️ BackgroundProcessingGuard: background time expiring — cancelling processing")
            }
        }

        frameEvidence.removeAll()
        lastVideoDurationSec = 0

        let startTime = Date()
        let eventLog = ProcessingEventLog()
        eventLog.log(.processingStarted, detail: "videoId=\(videoId)")

        // Initialize metadata store on main actor
        self.metadataStore = await MainActor.run { MetadataStore() }

        let asset = AVURLAsset(url: url)

        // Recreate stage objects with current config
        self.gate = BallisticsGate(config: config)
        self.decider = RallyDecider(config: config)
        self.segments = SegmentBuilder(config: config)
        detector.minConfidence = VNConfidence(config.detectionConfidence)
        detector.useScaleFitLetterbox = config.useScaleFitLetterbox

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
            throw ProcessingError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let fps = max(10, Int(try await track.load(.nominalFrameRate)))
        lastVideoDurationSec = CMTimeGetSeconds(duration)

        // Reader
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)

        // Reset state
        decider.reset()
        segments.reset()
        selectedTrackId = nil

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
        defer { reader.cancelReading() }
        eventLog.log(.frameLoopStarted, detail: "fps=\(fps), totalFramesEstimate=\(totalFramesEstimate)")
        let tracker = KalmanBallTracker(config: config)
        // Reuse stateless classifier across frames to avoid per-frame allocation
        let movementClassifier = MovementClassifier()

        // Dynamic stride tracking
        var rawFrameIndex = 0
        var skippedFrames = 0
        var previousRallyActive = false

        while reader.status == .reading, let sbuf = output.copyNextSampleBuffer(),
              let pix = CMSampleBufferGetImageBuffer(sbuf) {

            // Check for cancellation before processing each frame
            try Task.checkCancellation()

            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
            rawFrameIndex += 1

            // Single processing path: a dynamic stride skips frames (denser
            // while tracking a ball, sparser when idle) so we never run
            // detection on every frame.
            let recommendedStride = tracker.recommendedStride(currentTime: pts)
            let shouldProcess = (rawFrameIndex == 1) || (rawFrameIndex % recommendedStride == 0)

            // Skip detection/tracking on non-processed frames
            guard shouldProcess else {
                skippedFrames += 1
                CMSampleBufferInvalidate(sbuf)
                continue
            }

            // Detect → track
            let dets = detector.detect(in: pix, at: pts)
            tracker.update(with: dets, at: pts)

            // Update detection statistics
            totalDetections += dets.count
            if !dets.isEmpty {
                detectionFrameCount += 1
            }

            // Multi-court selection: validate all fresh tracks and pick the best
            // rally trajectory (quality-first, sticky), instead of the freshest —
            // so a ball on another court can't hijack the rally.
            let selection = bestTrack(now: pts, tracker: tracker)
            let activeTrack = selection.track
            let gateResult = selection.gate
            let isProjectile = gateResult?.isValid ?? false
            let hasBall = !dets.isEmpty
            // Ball height (Vision y, 1.0 = top) for sky-ball grace: the selected
            // tracked ball, or the highest detection this frame.
            let ballY = activeTrack?.positions.last?.0.y ?? dets.map { $0.bbox.midY }.max()
            let isActive = decider.update(hasBall: hasBall, isProjectile: isProjectile, timestamp: pts, ballY: ballY)
            segments.observe(isActive: isActive, at: pts)

            if collectFrameEvidence {
                let trailPoint = config.useSmoothedTrack
                    ? activeTrack?.smoothedPositions.last?.0
                    : activeTrack?.positions.last?.0
                frameEvidence.append(FrameEvidence(
                    time: CMTimeGetSeconds(pts),
                    hasBall: hasBall,
                    isProjectile: isProjectile,
                    detections: dets.map { BallDetection(bbox: $0.bbox, confidence: $0.confidence) },
                    trackPoint: trailPoint,
                    rSquared: gateResult?.rSquared,
                    gravitySignature: gateResult?.gravitySignature,
                    movementType: gateResult?.movementType,
                    rejectionReason: gateResult?.rejectionReason,
                    candidates: selection.candidates
                ))
            }

            // Log rally state transitions, including gate physics metrics so field
            // false-positives (rolling/carried balls) can be diagnosed from the event log.
            if isActive && !previousRallyActive {
                var detail = "hasBall=\(hasBall), isProjectile=\(isProjectile)"
                if let gr = gateResult {
                    detail += String(format: ", r2=%.2f", gr.rSquared)
                    if let sig = gr.gravitySignature {
                        detail += String(format: ", gravSig=%.2f", sig)
                    }
                    if let type = gr.movementType {
                        detail += ", class=\(type.rawValue)"
                    }
                }
                eventLog.log(.rallyStarted, at: pts, detail: detail)
            } else if !isActive && previousRallyActive {
                eventLog.log(.rallyEnded, at: pts, detail: "hasBall=\(hasBall), isProjectile=\(isProjectile)")
            }
            previousRallyActive = isActive

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

            // Collect trajectory/classification/physics data for metadata.
            if let track = activeTrack {
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
            eventLog.log(.processingFailed, detail: "AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")")
            throw ProcessingError.assetReaderFailed(reader.error)
        }

        let keep = segments.finalize(until: duration)
        eventLog.log(.segmentFinalized, detail: "keepRanges=\(keep.count), videoDuration=\(String(format: "%.2f", CMTimeGetSeconds(duration)))s")

        // Log processing statistics
        let processedFrames = rawFrameIndex - skippedFrames
        let skipRate = rawFrameIndex > 0 ? (Double(skippedFrames) / Double(rawFrameIndex)) * 100 : 0
        print("⚡ Dynamic stride statistics:")
        print("   - Total frames: \(rawFrameIndex)")
        print("   - Processed frames: \(processedFrames)")
        print("   - Skipped frames: \(skippedFrames) (\(String(format: "%.1f", skipRate))%)")

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
            eventLog.log(.processingFailed, detail: "noRalliesDetected")
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
            throw ProcessingError.noRalliesDetected
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

            // Compute ball size trend from the first detections of this rally.
            // The serve is the opening action, so the initial ball trajectory
            // tells us direction: growing bbox = approaching (far served),
            // shrinking bbox = receding (near served).
            let maxInitialSamples = 10
            var trendPoints: [(time: Double, area: Double)] = []
            for track in tracker.tracks {
                for pos in track.positionsWithSize {
                    let t = CMTimeGetSeconds(pos.time)
                    if t >= rangeStart && t <= rangeEnd && pos.bboxSize.width > 0 && pos.bboxSize.height > 0 {
                        trendPoints.append((time: t - rangeStart, area: Double(pos.bboxSize.width * pos.bboxSize.height)))
                    }
                }
            }
            trendPoints.sort { $0.time < $1.time }
            trendPoints = Array(trendPoints.prefix(maxInitialSamples))
            let ballSizeTrend: Double? = {
                guard trendPoints.count >= 3 else { return nil }
                let n = Double(trendPoints.count)
                let sumX = trendPoints.reduce(0.0) { $0 + $1.time }
                let sumY = trendPoints.reduce(0.0) { $0 + $1.area }
                let sumXY = trendPoints.reduce(0.0) { $0 + $1.time * $1.area }
                let sumX2 = trendPoints.reduce(0.0) { $0 + $1.time * $1.time }
                let denom = n * sumX2 - sumX * sumX
                guard abs(denom) > 1e-12 else { return nil }
                return (n * sumXY - sumX * sumY) / denom
            }()

            return RallySegment(
                startTime: range.start,
                endTime: CMTimeRangeGetEnd(range),
                confidence: segmentConfidence,
                quality: segmentQuality,
                detectionCount: segmentPhysics.count,
                averageTrajectoryLength: avgTrajLen,
                ballSizeTrend: ballSizeTrend
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
        eventLog.log(.processingCompleted, detail: "rallies=\(rallySegments.count), duration=\(String(format: "%.1f", endTime.timeIntervalSince(startTime)))s")
        let metadata = ProcessingMetadata.createWithEnhancedData(
            for: videoId,
            with: config,
            rallySegments: rallySegments,
            stats: processingStats,
            quality: qualityMetrics,
            trajectories: trajectoryDataCollection,
            classifications: classificationResults,
            physics: physicsValidationData,
            performance: performanceMetrics,
            eventLog: eventLog.allEvents
        )

        // Save metadata to store
        do {
            guard let metadataStore = metadataStore else {
                throw ProcessingError.metadataStoreUnavailable
            }
            try await metadataStore.saveMetadata(metadata)
            print("✅ Successfully saved metadata for video \(videoId)")
        } catch {
            print("❌ Failed to save metadata: \(error)")
            await MainActor.run { backgroundGuard.end() }
            throw error // eventLog already embedded in metadata at this point
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

    /// Returns the track only when its most recent detection is within
    /// `maxTrackStalenessSec` of `now`; otherwise nil. Rejects stale ghost
    /// tracks whose frozen arc would otherwise keep validating as a projectile.
    private func freshTrack(_ track: KalmanBallTracker.TrackedBall?, now: CMTime) -> KalmanBallTracker.TrackedBall? {
        guard let track, let lastTime = track.positions.last?.1 else { return nil }
        let staleness = CMTimeGetSeconds(CMTimeSubtract(now, lastTime))
        return staleness <= maxTrackStalenessSec ? track : nil
    }

    /// Multi-court trajectory selection. Validates every fresh track, scores the
    /// valid ones (quality-first, with small ball-size + age tiebreakers), and
    /// picks the best — sticking with the currently-selected trajectory unless
    /// another beats it by `trajectorySelectionStickiness`. Returns the selected
    /// track + its gate result, plus all candidates (for RallyLab visualization).
    /// Runs the gate once per fresh track (typically 2–4); heavier only if many
    /// balls are on screen at once.
    private func bestTrack(now: CMTime, tracker: KalmanBallTracker)
        -> (track: KalmanBallTracker.TrackedBall?, gate: BallisticsGate.ValidationResult?, candidates: [TrackCandidate]) {

        let fresh = tracker.tracks.filter { t in
            guard let last = t.positions.last?.1 else { return false }
            return CMTimeGetSeconds(CMTimeSubtract(now, last)) <= maxTrackStalenessSec
        }
        guard !fresh.isEmpty else { selectedTrackId = nil; return (nil, nil, []) }

        // Validate every fresh track once. `size` is the ball's mean bbox side
        // length (√area) — RallyLab scales it into the drawn ROI radius.
        let evaluated: [(track: KalmanBallTracker.TrackedBall, gate: BallisticsGate.ValidationResult, size: CGFloat)] =
            fresh.map { ($0, gate.validateProjectile($0), sqrt(max(0, $0.meanBboxArea()))) }

        // Score only VALID candidates (quality-first + size/age tiebreakers).
        let valid = evaluated.filter { $0.gate.isValid }
        let maxArea = valid.map { $0.track.meanBboxArea() }.max() ?? 0
        let ageRef = 12.0
        func score(_ e: (track: KalmanBallTracker.TrackedBall, gate: BallisticsGate.ValidationResult, size: CGFloat)) -> Double {
            let quality = 0.5 * e.gate.confidenceLevel + 0.5 * (e.gate.gravitySignature ?? 0)
            let sizeScore = maxArea > 0 ? Double(e.track.meanBboxArea() / maxArea) : 0
            let ageScore = min(1.0, Double(e.track.age) / ageRef)
            return quality + config.trajectorySizeTiebreak * sizeScore + 0.05 * ageScore
        }
        let scored = valid.map { (e: $0, score: score($0)) }

        // Select best, with stickiness toward the currently-selected track.
        var selected: (track: KalmanBallTracker.TrackedBall, gate: BallisticsGate.ValidationResult)?
        if let best = scored.max(by: { $0.score < $1.score }) {
            if let stuck = scored.first(where: { $0.e.track.id == selectedTrackId }),
               stuck.score >= best.score - config.trajectorySelectionStickiness {
                selected = (stuck.e.track, stuck.e.gate)
            } else {
                selected = (best.e.track, best.e.gate)
            }
        }
        selectedTrackId = selected?.track.id

        // Candidates for visualization: every fresh track (valid or not).
        let scoreById = Dictionary(scored.map { ($0.e.track.id, $0.score) }, uniquingKeysWith: { a, _ in a })
        let candidates: [TrackCandidate] = evaluated.compactMap { e in
            let pt = config.useSmoothedTrack ? e.track.smoothedPositions.last?.0 : e.track.positions.last?.0
            guard let pt else { return nil }
            return TrackCandidate(
                id: e.track.id,
                point: pt,
                score: scoreById[e.track.id] ?? 0,
                isProjectile: e.gate.isValid,
                isSelected: e.track.id == selectedTrackId,
                ballSize: e.size
            )
        }
        return (selected?.track, selected?.gate, candidates)
    }

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
            totalVelocityConsistency += velocityConsistencyScore(for: trajectory.points)
            totalAccelerationPattern += trajectory.rSquared
            totalSmoothness += trajectory.quality
            totalVerticalMotion += verticalMotionScore(for: trajectory.points)
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

    /// 0–1 (higher = more consistent). Coefficient of variation of point velocities,
    /// inverted and clamped so callers can average it directly into a coherence score.
    private func velocityConsistencyScore(for points: [ProcessingTrajectoryPoint]) -> Double {
        let velocities = points.map(\.velocity).filter { $0.isFinite && $0 > 0 }
        guard velocities.count >= 2 else { return 0 }
        let mean = velocities.reduce(0, +) / Double(velocities.count)
        guard mean > 0 else { return 0 }
        let variance = velocities.map { pow($0 - mean, 2) }.reduce(0, +) / Double(velocities.count)
        let cv = sqrt(variance) / mean
        return max(0, min(1, 1 - cv))
    }

    /// 0–1 (higher = more vertical motion). Ratio of summed |dy| to total path length —
    /// rallies are vertical (set, spike, dig) so a high score means a plausible ball path.
    private func verticalMotionScore(for points: [ProcessingTrajectoryPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var verticalDistance = 0.0
        var totalDistance = 0.0
        for i in 1..<points.count {
            let dx = Double(points[i].position.x - points[i - 1].position.x)
            let dy = Double(points[i].position.y - points[i - 1].position.y)
            verticalDistance += abs(dy)
            totalDistance += sqrt(dx * dx + dy * dy)
        }
        guard totalDistance > 0 else { return 0 }
        return min(1, verticalDistance / totalDistance)
    }

    private func calculateProcessingOverhead(processingDuration: TimeInterval, videoDuration: TimeInterval) -> Double {
        guard videoDuration > 0 else { return 0 }
        return (processingDuration / videoDuration - 1.0) * 100.0
    }
}
