//
//  RallyDecisionStage.swift
//  BumpSetCut
//
//  What the pipeline does with a processed frame's ball detections, whoever found them: the off-court
//  filter, the tracker, the physics gate and trajectory selection, the serve watch, the rally decision and
//  the segments, then, when the frames are over, the above-net rule and each kept rally's numbers. The net
//  and the camera position act here and nowhere else, so a run that finds the ball (VideoProcessor) and one
//  that reads the balls an earlier run found go through the same code. Compiled into RallyLab too.
//

import AVFoundation
import CoreGraphics
import Foundation

final class RallyDecisionStage {
    typealias FrameEvidence = VideoProcessor.FrameEvidence
    typealias BallDetection = VideoProcessor.BallDetection
    typealias TrackCandidate = VideoProcessor.TrackCandidate

    /// What was decided on one frame; handed back to `record` for the run's counts.
    struct FrameDecision {
        let time: CMTime
        let hasBall: Bool
        let isProjectile: Bool
        /// A rally is on at this frame.
        let isActive: Bool
        fileprivate let track: KalmanBallTracker.TrackedBall?
        fileprivate let gate: BallisticsGate.ValidationResult?
    }

    /// The frames are over: the rallies kept, padded as they are cut, with their numbers and serves.
    struct Outcome {
        let keep: [CMTimeRange]
        let rallies: [RallySegment]
        /// Each kept rally's serve; empty unless evidence is collected.
        let serves: [ServeDetector.Serve]
    }

    private let config: ProcessorConfig
    /// The run's net: one box for the whole video, nil when there is none (the rules that need it are skipped).
    private let net: DetectedNet?
    private let collectEvidence: Bool
    private let eventLog: ProcessingEventLog
    private let debugger: TrajectoryDebugger?

    private var gate: BallisticsGate
    private var decider: RallyDecider
    /// Serves as they fly, for the decider's serve-primed start.
    private var serveWatch = ServeWatch()
    private var segments: SegmentBuilder
    private let tracker: KalmanBallTracker
    // Reuse stateless classifier across frames to avoid per-frame allocation
    private let movementClassifier = MovementClassifier()

    /// Max seconds since a track's last real detection for it to still count as
    /// a live ball. Large enough to ride out brief occlusions (a few frames),
    /// small enough that a ball that has left the frame stops driving the rally.
    private let maxTrackStalenessSec: Double = 0.3

    /// Identity of the track currently driving the rally, for selection stickiness
    /// across frames.
    private var selectedTrackId: UUID?
    // Consecutive processed frames the selected track has failed the gate while
    // still fresh — the lock is held through short blips (every ball contact
    // breaks the parabola fit for a few frames).
    private var selectedDropCount = 0
    private var previousRallyActive = false

    private(set) var frameEvidence: [FrameEvidence] = []
    /// The serves rallies started on, as the decider took them.
    private var startedServes: [ServeDetector.Serve] = []

    // Per-frame ball heights (Vision y), for the above-net multi-contact rule.
    private(set) var ballHeights: [(t: Double, y: CGFloat)]
    // Selected-track ball bbox areas for the per-rally serve-direction trend —
    // tracker.tracks is pruned as tracks go stale, so it can't be read after the loop.
    // Ball size (and horizontal position, for side-on serve detection) at
    // each tracked sample.
    private(set) var ballSizes: [(t: Double, area: Double, x: Double?)]

    // Metadata collection (seeded from the checkpoint on resume)
    private(set) var frameCount: Int
    private(set) var totalDetections: Int
    private(set) var detectionFrameCount: Int
    private(set) var trackingFrameCount: Int
    private(set) var rallyFrameCount: Int
    private(set) var physicsValidFrameCount: Int
    private(set) var confidenceSum: Double
    private(set) var rSquaredSum: Double
    private(set) var rSquaredCount: Int
    private(set) var trajectoryDataCollection: [ProcessingTrajectoryData]
    private(set) var classificationResults: [ProcessingClassificationResult] = []
    private(set) var physicsValidationData: [PhysicsValidationData]

    // Memory management constants from config
    private let maxTrajectoryData: Int
    private let maxClassificationResults: Int
    private let maxPhysicsValidationData: Int

    /// The raw rally spans closed so far (what a resume checkpoint keeps).
    var closedRawRanges: [CMTimeRange] { segments.closedRawRanges }
    var trackCount: Int { tracker.tracks.count }

    /// A run's stage, before its first frame. `restored` is the checkpoint a resumed run starts from:
    /// checkpoints are written at rally-idle, so the tracker and the decider start fresh at the resume point,
    /// and what was closed and counted before it is put back.
    init(config: ProcessorConfig, net: DetectedNet?, collectEvidence: Bool, eventLog: ProcessingEventLog,
         debugger: TrajectoryDebugger?, restored: ProcessingCheckpoint?) {
        self.config = config
        self.net = net
        self.collectEvidence = collectEvidence
        self.eventLog = eventLog
        self.debugger = debugger
        gate = BallisticsGate(config: config)
        decider = RallyDecider(config: config)
        segments = SegmentBuilder(config: config)
        tracker = KalmanBallTracker(config: config)
        frameCount = restored?.counters.frameCount ?? 0
        totalDetections = restored?.counters.totalDetections ?? 0
        detectionFrameCount = restored?.counters.detectionFrameCount ?? 0
        trackingFrameCount = restored?.counters.trackingFrameCount ?? 0
        rallyFrameCount = restored?.counters.rallyFrameCount ?? 0
        physicsValidFrameCount = restored?.counters.physicsValidFrameCount ?? 0
        confidenceSum = restored?.counters.confidenceSum ?? 0.0
        rSquaredSum = restored?.counters.rSquaredSum ?? 0.0
        rSquaredCount = restored?.counters.rSquaredCount ?? 0

        // Trajectory data collection with memory limits. Resume restores the
        // fields the per-segment metrics read (spans, physics readouts) —
        // trajectory POINTS are not checkpointed, so the diagnostic quality
        // breakdown reflects the post-resume portion.
        trajectoryDataCollection = (restored?.trajectorySpans ?? []).map {
            ProcessingTrajectoryData(
                id: UUID(), startTime: $0.start, endTime: $0.end, points: [],
                rSquared: 0, movementType: nil, confidence: 0, quality: 0
            )
        }
        physicsValidationData = (restored?.physics ?? []).map {
            PhysicsValidationData(
                trajectoryId: UUID(),
                timestamp: CMTime(seconds: $0.t, preferredTimescale: 600),
                isValid: $0.isValid, rSquared: $0.rSquared,
                curvatureValid: $0.isValid, accelerationValid: $0.isValid,
                velocityConsistent: true, positionJumpsValid: true,
                confidenceLevel: $0.confidenceLevel
            )
        }
        if collectEvidence, let restoredEvidence = restored?.evidence {
            frameEvidence = restoredEvidence.map(FrameEvidence.init)
        }
        ballHeights = (restored?.ballHeights ?? []).map { ($0.t, CGFloat($0.y)) }
        ballSizes = (restored?.ballSizes ?? []).map { ($0.t, $0.area, $0.x) }
        maxTrajectoryData = config.enableMemoryLimits ? config.maxTrajectoryDataEntries : 10000
        maxClassificationResults = config.enableMemoryLimits ? config.maxClassificationEntries : 10000
        maxPhysicsValidationData = config.enableMemoryLimits ? config.maxPhysicsValidationEntries : 10000

        if let restored {
            for range in restored.rawSegments {
                segments.appendRaw(
                    start: CMTime(seconds: range.start, preferredTimescale: 600),
                    end: CMTime(seconds: range.end, preferredTimescale: 600)
                )
            }
        }
        // The run's net, from before its first frame, for the under-net rule.
        gate.net = net
    }

    /// How many decoded frames to step by now: denser while a ball is tracked, sparser when idle.
    func recommendedStride(currentTime: CMTime) -> Int { tracker.recommendedStride(currentTime: currentTime) }

    /// Tracks, gates and decides one processed frame, and keeps its evidence. `dets` are the frame's balls,
    /// the first `singleFrameCount` of them from a single-frame detector and the rest from the multi-frame model.
    func decide(_ dets: [DetectionResult], singleFrameCount: Int, at pts: CMTime) -> FrameDecision {
        // Off-court rejection: drop detections laterally beyond the net posts
        // (an adjacent court's ball) BEFORE tracking, so they can't form a track
        // or get pulled into the rally trajectory. `courtDets` feeds the tracker;
        // `dets` is kept whole for the overlay (off-court ones flagged below).
        let courtBoundsX: ClosedRange<CGFloat>? = (config.enableOffCourtRejection ? net : nil)
            .map { (($0.box.minX - config.offCourtMarginX)...($0.box.maxX + config.offCourtMarginX)) }
        let courtDets: [DetectionResult]
        if let b = courtBoundsX {
            courtDets = dets.filter { b.contains($0.bbox.midX) }
        } else {
            courtDets = dets
        }
        tracker.update(with: courtDets, at: pts)

        // Update detection statistics (court-eligible detections only)
        totalDetections += courtDets.count
        if !courtDets.isEmpty {
            detectionFrameCount += 1
        }

        // Multi-court selection: validate all fresh tracks and pick the best
        // rally trajectory (quality-first, sticky), instead of the freshest —
        // so a ball on another court can't hijack the rally.
        let selection = bestTrack(now: pts, tracker: tracker)
        let activeTrack = selection.track
        let gateResult = selection.gate
        let isProjectile = gateResult?.isValid ?? false
        let hasBall = !courtDets.isEmpty
        // A debug session records the selected track with its verdict, classification and quality.
        if let debugger = debugger, let track = activeTrack {
            let verdict = gateResult ?? BallisticsGate.ValidationResult(
                isValid: false, rSquared: 0, curvatureDirectionValid: false,
                hasMotionEvidence: false, positionJumpsValid: true, confidenceLevel: 0)
            debugger.analyzeTrajectory(
                track,
                physicsResult: PhysicsValidationResult(
                    isValid: verdict.isValid,
                    rSquared: verdict.rSquared,
                    curvatureDirectionValid: verdict.curvatureDirectionValid,
                    accelerationMagnitudeValid: verdict.hasMotionEvidence,
                    velocityConsistencyValid: true,
                    positionJumpsValid: verdict.positionJumpsValid,
                    confidenceLevel: verdict.confidenceLevel
                ),
                classificationResult: MovementClassifier().classifyMovement(track),
                qualityScore: TrajectoryQualityScore().calculateQuality(for: track)
            )
        }
        // Ball height (Vision y, 1.0 = top) for sky-ball grace: the selected
        // tracked ball, or the highest court-eligible detection this frame.
        let ballY = activeTrack?.positions.last?.0.y ?? courtDets.map { $0.bbox.midY }.max()
        if let ballY { ballHeights.append((CMTimeGetSeconds(pts), ballY)) }
        if let sized = activeTrack?.positionsWithSize.last,
           sized.bboxSize.width > 0, sized.bboxSize.height > 0 {
            let sizeT = CMTimeGetSeconds(sized.time)
            if ballSizes.last?.t != sizeT {
                ballSizes.append((sizeT, Double(sized.bboxSize.width * sized.bboxSize.height), Double(sized.center.x)))
            }
        }
        for serve in serveWatch.add(.init(t: CMTimeGetSeconds(pts), balls: courtDets.map(\.bbox))) { decider.noteServe(serve) }
        let isActive = decider.update(hasBall: hasBall, isProjectile: isProjectile, timestamp: pts, ballY: ballY)
        segments.observe(isActive: isActive, at: pts, rallyStart: decider.rallyStart)
        if let serve = decider.rallyServe, startedServes.last?.contact != serve.contact { startedServes.append(serve) }

        if collectEvidence {
            let trailPoint = config.useSmoothedTrack
                ? activeTrack?.smoothedPositions.last?.0
                : activeTrack?.positions.last?.0
            frameEvidence.append(FrameEvidence(
                time: CMTimeGetSeconds(pts),
                hasBall: hasBall,
                isProjectile: isProjectile,
                detections: dets.enumerated().map { i, det in
                    BallDetection(bbox: det.bbox, confidence: det.confidence,
                                  isOffCourt: courtBoundsX.map { !$0.contains(det.bbox.midX) } ?? false,
                                  fromHeatmap: i >= singleFrameCount)
                },
                trackPoint: trailPoint,
                rSquared: gateResult?.rSquared,
                gravitySignature: gateResult?.gravitySignature,
                movementType: gateResult?.movementType,
                rejectionReason: gateResult?.rejectionReason,
                candidates: selection.candidates,
                detectedNet: net,
                upright: config.applyVideoRotation,
                gate: gateResult
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
        return FrameDecision(time: pts, hasBall: hasBall, isProjectile: isProjectile, isActive: isActive, track: activeTrack, gate: gateResult)
    }

    /// Counts a decided frame and keeps its trajectory, classification and physics for the metadata. Apart from
    /// `decide` because a resume checkpoint is written between the two.
    func record(_ decision: FrameDecision) {
        let pts = decision.time, activeTrack = decision.track, gateResult = decision.gate
        let isActive = decision.isActive, isProjectile = decision.isProjectile
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
            let (rSquared, velocity, acceleration) = ProcessingQualityMetrics.calculateTrackMetrics(track)
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
                        confidence: ProcessingQualityMetrics.calculateTrackConfidence(track)
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
                    confidence: ProcessingQualityMetrics.calculateTrackConfidence(track),
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

                confidenceSum += ProcessingQualityMetrics.calculateTrackConfidence(track)
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
        frameCount += 1
    }

    /// After the last frame: closes the segments, applies the above-net rule and gives each kept rally its numbers.
    func finish(until duration: CMTime) -> Outcome {
        var serves: [ServeDetector.Serve] = []
        let built = segments.finalizeWithRaw(until: duration)
        var kept = built

        // Above-net rule: drop a multi-contact rally that never sends the ball above
        // this net's top edge (a background/other-court rally). Single arcs exempt.
        // Sample heights over the RAW rally span — preroll/postroll padding contains
        // serve-toss/aftermath motion that reads as an extra arc and would revoke the
        // single-trajectory exemption (RallyLab tunes this rule on raw boundaries).
        if config.enableAboveNetRequirement, let net = net {
            let netTopY = net.box.maxY - config.aboveNetMarginY
            let before = kept.count
            kept = built.filter { seg in
                let s = CMTimeGetSeconds(seg.raw.start)
                let e = CMTimeGetSeconds(CMTimeRangeGetEnd(seg.raw))
                let ys = ballHeights.filter { $0.t >= s && $0.t <= e }.map { $0.y }
                return NetClearanceRule.rallyClearsNetTop(ySamples: ys, netTopY: netTopY,
                                              arcProminence: config.aboveNetArcProminence)
            }
            if kept.count != before {
                eventLog.log(.segmentFinalized,
                             detail: "aboveNetRule dropped \(before - kept.count) multi-contact rally(s) that never cleared the net top")
            }
        }
        let keep = kept.map { $0.padded }
        if collectEvidence {
            let frames = ServeDetector.Frame.from(frameEvidence)
            serves = kept.compactMap { seg in
                let raw = Interval(start: CMTimeGetSeconds(seg.raw.start), end: CMTimeGetSeconds(CMTimeRangeGetEnd(seg.raw)))
                return startedServes.first { $0.startsRally(raw) } ?? ServeDetector().serve(in: frames, rallyStart: raw.start)
            }
        }

        eventLog.log(.segmentFinalized, detail: "keepRanges=\(keep.count), videoDuration=\(String(format: "%.2f", CMTimeGetSeconds(duration)))s")

        // Generate rally segments from keep ranges with real per-segment metrics
        let rallies = keep.enumerated().map { index, range in
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
            // Sampled during the frame loop (ballSizes) — tracker.tracks prunes stale
            // tracks, so reading it here yielded nil for every rally but the last.
            let maxInitialSamples = 10
            let openingSamples = Array(
                ballSizes.lazy
                    .filter { $0.t >= rangeStart && $0.t <= rangeEnd }
                    .prefix(maxInitialSamples)
            )
            let trendPoints = openingSamples.map { (time: $0.t - rangeStart, area: $0.area) }
            // Where the ball is across the frame as the rally opens: the serve's
            // side of the net when the camera is side-on.
            let openingXs = openingSamples.compactMap(\.x)
            let serveBallX: Double? = openingXs.count >= 3
                ? openingXs.reduce(0, +) / Double(openingXs.count) : nil
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
                ballSizeTrend: ballSizeTrend,
                serveBallX: serveBallX
            )
        }
        return Outcome(keep: keep, rallies: rallies, serves: serves)
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
        guard !fresh.isEmpty else {
            selectedTrackId = nil
            selectedDropCount = 0
            return (nil, nil, [])
        }

        // Validate every fresh track once. `size` is the ball's mean bbox side
        // length (√area) — RallyLab scales it into the drawn ROI radius.
        let evaluated: [(track: KalmanBallTracker.TrackedBall, gate: BallisticsGate.ValidationResult, size: CGFloat)] =
            fresh.map { ($0, gate.validateProjectile($0), sqrt(max(0, $0.meanBboxArea()))) }

        func currentPoint(_ t: KalmanBallTracker.TrackedBall) -> CGPoint? {
            config.useSmoothedTrack ? t.smoothedPositions.last?.0 : t.positions.last?.0
        }

        // Score only VALID candidates (quality-first + size/age tiebreakers).
        var valid = evaluated.filter { $0.gate.isValid }
        // Physics-valid tracks before the multi-court gate; anything dropped below
        // is a "non-court" ball (far/other court), flagged for RallyLab.
        let physicsValidIds = Set(valid.map { $0.track.id })

        // Hard size gate: drop fresh balls much smaller than the biggest one — a
        // far / other-court ball. The biggest always survives (ratio 1.0).
        if config.multiCourtSizeGateEnabled, config.multiCourtMinSizeRatio > 0,
           let maxSize = valid.map({ $0.size }).max(), maxSize > 0 {
            let minSize = maxSize * CGFloat(config.multiCourtMinSizeRatio)
            valid = valid.filter { $0.size >= minSize }
        }

        // Absolute size floor: drop any ball smaller than this regardless of the
        // other balls present — a back/other-FIELD ball is physically small in
        // frame. Catches the case the relative gate can't: when the far ball is the
        // only fresh one (this court's ball already left), so it's the "biggest".
        if config.multiCourtMinBallSize > 0 {
            valid = valid.filter { $0.size >= config.multiCourtMinBallSize }
        }

        // Spatial lock: once a rally is locked to a court, drop candidates far from
        // the currently-selected ball — keeps the rally on one court. Anchors on the
        // selected track's latest point even while it transiently fails the gate
        // (contacts break the fit), so a far ball can't hijack during the blip.
        // Releases when that ball disappears (selected track no longer fresh).
        if config.multiCourtSpatialLockEnabled,
           let selPt = evaluated.first(where: { $0.track.id == selectedTrackId }).flatMap({ currentPoint($0.track) }) {
            valid = valid.filter { e in
                guard let pt = currentPoint(e.track) else { return false }
                return hypot(pt.x - selPt.x, pt.y - selPt.y) <= config.multiCourtMaxLateralDistance
            }
        }
        // Physics-valid balls the multi-court gate dropped = non-court balls.
        let nonCourtIds = physicsValidIds.subtracting(valid.map { $0.track.id })
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

        if let selected {
            selectedTrackId = selected.track.id
            selectedDropCount = 0
        } else if selectedTrackId != nil, fresh.contains(where: { $0.id == selectedTrackId }) {
            // Selected track is still fresh but gate-invalid this frame — hold the
            // lock/stickiness through the same blip grace RallyDecider allows,
            // instead of releasing at the first failed fit.
            selectedDropCount += 1
            if selectedDropCount > config.projDropGracePeriod {
                selectedTrackId = nil
                selectedDropCount = 0
            }
        } else {
            selectedTrackId = nil
            selectedDropCount = 0
        }

        // Candidates for visualization: every fresh track (valid or not).
        let scoreById = Dictionary(scored.map { ($0.e.track.id, $0.score) }, uniquingKeysWith: { a, _ in a })
        let candidates: [TrackCandidate] = evaluated.compactMap { e in
            guard let pt = currentPoint(e.track) else { return nil }
            // A court-excluded candidate passed physics but was dropped by the
            // multi-court gate; surface that as its reason (the gate itself has none).
            let reason = nonCourtIds.contains(e.track.id)
                ? (e.size < config.multiCourtMinBallSize ? "non-court (too small)" : "non-court (size/lateral)")
                : e.gate.rejectionReason
            return TrackCandidate(
                id: e.track.id,
                point: pt,
                score: scoreById[e.track.id] ?? 0,
                isProjectile: e.gate.isValid,
                isSelected: e.track.id == selectedTrackId,
                isCourtExcluded: nonCourtIds.contains(e.track.id),
                ballSize: e.size,
                roiRadius: e.track.roiRadius(config: config),
                rSquared: e.gate.rSquared,
                gravitySignature: e.gate.gravitySignature,
                movementType: e.gate.movementType,
                rejectionReason: reason
            )
        }
        return (selected?.track, selected?.gate, candidates)
    }
}
