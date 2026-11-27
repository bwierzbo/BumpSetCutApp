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
import os

/// Concurrency rule (why @unchecked Sendable holds): one `process*` call in
/// flight per instance; the UI fields below are written only on the main
/// actor; `requestCheckpoint()` is the only cross-thread entry point and is
/// lock-protected. Callers read results (`frameEvidence`, …) after the call
/// returns, from the instance they started it on.
@Observable
final class VideoProcessor: @unchecked Sendable {

    // MARK: - UI observed
    // (Only these four are observed; everything below is per-run state marked
    // @ObservationIgnored, so the frame loop's mutations skip the registrar.)
    var isProcessing = false
    var progress: Double = 0.0
    var processedURL: URL?
    var processedMetadata: ProcessingMetadata?

    // MARK: - Config + deps
    @ObservationIgnored var config = ProcessorConfig()

    /// A detector that reads one frame at a time, for a configuration that asks for one in a build that
    /// has one (PipelineDefaults): research builds only. The apps that ship find the ball with the
    /// multi-frame model alone, and this stays nil.
    @ObservationIgnored private var detector: (any SingleFrameBallDetector)?
    /// The last run's tracking, rules and rally decision (RallyDecisionStage); nil before the first run.
    @ObservationIgnored private var stage: RallyDecisionStage?

    /// Where a run's net comes from (for the under-net, off-court and above-net rules): the build's own
    /// source unless the caller names one — the app names the video's confirmed calibration.
    @ObservationIgnored var netSource: any NetGeometrySource = PipelineDefaults.netSource()
    /// What the run was told of the net, asked once before the first frame. Reset per video.
    @ObservationIgnored private var netGeometry: NetGeometry = .unavailable(reason: "no net-dependent rule is on")
    /// The run's net: one box for the whole video, nil when there is none — the rules that need it are then
    /// skipped and the metadata says so (SpatialChecks).
    @ObservationIgnored private var detectedNet: DetectedNet?
    /// Which net rules the last run made and on what net: in its metadata too, and here for a run that
    /// ended with no rally and so no metadata.
    @ObservationIgnored private(set) var lastSpatialChecks: SpatialChecks?

    @ObservationIgnored private var metadataStore: MetadataStore?

    // Background execution protection
    private let backgroundGuard = BackgroundProcessingGuard()

    /// Register a closure to be called if background time expires during processing.
    /// Typically used by the ViewModel to cancel the current processing Task.
    @MainActor
    func setBackgroundCancellationHandler(_ handler: @escaping @MainActor () -> Void) {
        backgroundGuard.setCancellationHandler(handler)
    }

    // Debug data collection
    @ObservationIgnored var trajectoryDebugger: TrajectoryDebugger?

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
        /// Dropped before tracking because it sits laterally beyond the net posts
        /// (an adjacent court's ball). Drawn dimmed in RallyLab.
        let isOffCourt: Bool
        /// Found by the multi-frame model where YOLO had nothing; `confidence`
        /// is then the heatmap's peak value.
        var fromHeatmap: Bool = false
    }

    /// One candidate trajectory considered for the rally this frame (multi-court).
    /// Lets RallyLab draw every candidate trail and show why one was selected.
    struct TrackCandidate {
        let id: UUID
        let point: CGPoint        // current normalized position (Vision coords)
        let score: Double         // selection score (quality + size/age tiebreaks)
        let isProjectile: Bool    // passed the gate this frame
        let isSelected: Bool      // the track driving the rally
        let isCourtExcluded: Bool // physics-valid but dropped by the multi-court
                                  // gate (too small = far court, or too far from the
                                  // locked court) — i.e. a "non-court" ball
        let ballSize: CGFloat     // detected ball's mean side length (normalized);
                                  // used for size-trend / serve-signature analysis
        let roiRadius: CGFloat    // the track's actual association ROI radius
                                  // (normalized) — RallyLab draws this exactly, so
                                  // the drawn circle IS the real association gate
        // This candidate's OWN gate verdict, so RallyLab can explain why ANY
        // trajectory isn't a rally — not just the one that was selected.
        let rSquared: Double?
        let gravitySignature: Double?
        let movementType: MovementType?
        let rejectionReason: String?
    }

    /// Where a run's time goes, stage by stage, printed once at the end as
    /// one "⏱ [timing]" line — how a model is judged on the iPhone, where
    /// decoding and the Neural Engine behave nothing like on a Mac.
    struct StageTiming {
        var decode = 0.0, net = 0.0, grey = 0.0, multiFrame = 0.0, yolo = 0.0, rules = 0.0
        var greyFrames = 0, windows = 0, yoloFrames = 0, handled = 0

        /// Seconds `work` took, added to `stage`.
        static func time<T>(_ stage: inout Double, _ work: () throws -> T) rethrows -> T {
            let start = CFAbsoluteTimeGetCurrent()
            defer { stage += CFAbsoluteTimeGetCurrent() - start }
            return try work()
        }

        func line(video: Double, frames: Int, total: Double, model: String,
                  thermal: (ProcessInfo.ThermalState, ProcessInfo.ThermalState)) -> String {
            func ms(_ t: Double, _ n: Int) -> String { n > 0 ? String(format: "%.1f ms each", t / Double(n) * 1000) : "none" }
            func name(_ s: ProcessInfo.ThermalState) -> String {
                switch s {
                case .nominal: return "nominal"
                case .fair: return "fair"
                case .serious: return "serious"
                case .critical: return "critical"
                @unknown default: return "unknown"
                }
            }
            return String(format: "⏱ [timing] %@ · %.1f s of video (%d frames) in %.1f s = %.2f× real time", model, video, frames, total,
                          total / max(video, 0.001))
                + String(format: " · decode %.1f s · net %.1f s", decode, net)
                + String(format: " · grey %.1f s (%@)", grey, ms(grey, greyFrames))
                + String(format: " · multi-frame %.1f s (%d windows, %@)", multiFrame, windows, ms(multiFrame, windows))
                + String(format: " · YOLO %.1f s (%d frames, %@)", yolo, yoloFrames, ms(yolo, yoloFrames))
                + String(format: " · tracking+rules %.1f s (%d frames)", rules, handled)
                + " · thermal \(name(thermal.0))→\(name(thermal.1))"
        }
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
        /// The fixed per-video net once sampled (nil until frozen / if none found).
        /// Lets RallyLab draw the net band and the off-court boundary lines.
        let detectedNet: DetectedNet?
        /// Coordinates are in the upright frame (the video's rotation flag was
        /// applied — `applyVideoRotation`); false means stored-frame space, which
        /// differs only for rotated (e.g. portrait phone) video.
        var upright = false
        /// The gate's whole verdict on the selected track this frame (nil when none
        /// was validated): what a debug drawing shows, as the gate gave it.
        var gate: BallisticsGate.ValidationResult? = nil
    }

    /// Off by default: evidence costs memory proportional to frame count, so
    /// only evaluation tools (RallyLab) opt in.
    @ObservationIgnored var collectFrameEvidence = false
    var frameEvidence: [FrameEvidence] { stage?.frameEvidence ?? [] }
    /// Each kept rally's serve: the one it started on (the decider's
    /// serve-primed start), else ServeDetector's search of the evidence —
    /// so only when it's collected. For the debug video; not used to cut.
    @ObservationIgnored private(set) var serves: [ServeDetector.Serve] = []
    @ObservationIgnored private(set) var lastVideoDurationSec: Double = 0

    /// Set when background time is about to run out: the frame loop writes a
    /// resume checkpoint at the next rally-idle frame. Set from the main
    /// thread, taken by the frame loop on its own — hence the lock.
    @ObservationIgnored private let urgentCheckpoint = OSAllocatedUnfairLock(initialState: false)

    /// Ask the frame loop to checkpoint as soon as it's safe (rally-idle).
    func requestCheckpoint() {
        urgentCheckpoint.withLock { $0 = true }
    }

    /// BGRA frames for detection; with `standardColor`, converted to SDR
    /// BT.709 (tone-mapping HDR) as AVAssetImageGenerator — and so training —
    /// sees them.
    static func readerSettings(standardColor: Bool) -> [String: Any] {
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if standardColor {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
        return settings
    }

    /// The multi-frame model (config.heatmapModel), run on overlapping
    /// windows of the frames it's fed.
    @ObservationIgnored private var heatDetector: HeatmapBallDetector?
    @ObservationIgnored private var heatModelURL: URL?
    /// The loaded multi-frame model's own threshold, for when the config doesn't override it.
    @ObservationIgnored private var heatModelThreshold: Float?
    @ObservationIgnored private var heatWindows: HeatmapWindows?
    @ObservationIgnored private var heatLastTime: Double?

    /// The multi-frame model the last run actually loaded, nil when it had none (no model configured, or the
    /// configured one failed to load) — so a caller that names the detector its evidence came from can check it did.
    var loadedHeatmapModel: URL? { heatDetector == nil ? nil : heatModelURL }

    /// Load the configured multi-frame model, if it changed.
    private func prepareHeatmap() {
        defer { heatWindows = heatDetector.map { HeatmapWindows(detector: $0, hop: config.heatmapHop) } }
        heatLastTime = nil
        if config.heatmapModel != heatModelURL {
            heatModelURL = config.heatmapModel
            #if os(iOS)
            heatDetector = config.heatmapModel.flatMap { HeatmapBallDetector(modelURL: $0, computeUnits: .cpuAndNeuralEngine) }
            #else
            heatDetector = config.heatmapModel.flatMap { HeatmapBallDetector(modelURL: $0) }
            #endif
            heatModelThreshold = heatDetector?.threshold
        }
        if let own = heatModelThreshold { heatDetector?.threshold = config.heatmapThreshold.map(Float.init) ?? own }
    }

    /// The frame as the multi-frame model takes it, if it takes this one:
    /// frames about 1/30 s apart whatever the video's rate (as it was
    /// trained). Asked of every decoded frame, skipped ones included.
    private func heatmapFrame(_ pix: CVPixelBuffer, at seconds: Double) -> HeatmapBallDetector.Frame? {
        guard let heat = heatDetector else { return nil }
        if let last = heatLastTime, seconds - last < 1.0 / 30 - 0.004 { return nil }
        guard let frame = heat.frame(pix) else { return nil }
        heatLastTime = seconds
        return frame
    }

    /// The multi-frame model's balls YOLO didn't already find (a peak near a
    /// YOLO box is the same ball). The model reads frames as stored (as it
    /// was trained); its boxes are turned into the `orientation` space YOLO's
    /// are in.
    private func heatmapOnlyDetections(_ peaks: [HeatmapBallDetector.Peak], beside dets: [DetectionResult], at pts: CMTime,
                                       orientation: CGImagePropertyOrientation) -> [DetectionResult] {
        peaks.compactMap { peak in
            let rect = VideoFrameGeometry.upright(peak.rect, from: orientation)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let known = dets.contains { d in
                hypot(d.bbox.midX - c.x, (d.bbox.midY - c.y) * 9 / 16) < max(d.bbox.width, 0.012)
            }
            return known ? nil : DetectionResult(bbox: rect, confidence: peak.confidence, timestamp: pts)
        }
    }

    /// Loads what finds the ball for this configuration, or refuses the run. With `heatmapOnly` that is
    /// the multi-frame model, and a model that isn't there or won't load is an error — never a reason to run
    /// another detector. Otherwise it is the build's single-frame detector, and a build without one refuses.
    private func prepareDetectors() throws {
        prepareHeatmap()
        if config.heatmapOnly {
            guard heatDetector != nil else { throw ProcessingError.modelNotFound }
        } else {
            detector = PipelineDefaults.singleFrameBallDetector(for: config, reusing: detector)
            guard detector != nil else { throw ProcessingError.modelNotFound }
        }
    }

    func processVideo(_ url: URL, videoId: UUID) async throws -> ProcessingMetadata {
        // Delegate to metadata processing method
        return try await processVideoMetadata(url, videoId: videoId)
    }

    /// Run the pipeline on a video and return what it found, keeping nothing on disk: no metadata
    /// file and no resume checkpoint. For analysis runs on videos that are not in the library
    /// (RallyLab's scoring, tuning, export and labeling runs): a file saved under an ID nothing
    /// remembers is never read again and never removed.
    func analyzeVideo(_ url: URL) async throws -> ProcessingMetadata {
        try await processVideoMetadata(url, videoId: UUID(), persist: false)
    }

    #if os(iOS)
    // MARK: - Debug path (no cutting, full-length annotated video)
    /// The whole video with what the pipeline saw drawn over it. The run is the pipeline itself — the
    /// detector, tracker, rules and decision of processVideo, with nothing kept on disk — and the drawing
    /// is made from its evidence in a second pass over the frames.
    func processVideoDebug(_ url: URL) async throws -> URL {
        let debugger = TrajectoryDebugger()
        debugger.isEnabled = true
        debugger.isRecording = true
        debugger.startDebugSession(name: "Video Processing Session")
        trajectoryDebugger = debugger
        let collecting = collectFrameEvidence
        collectFrameEvidence = true
        defer {
            collectFrameEvidence = collecting
            debugger.stopDebugSession()
        }
        // A video the pipeline found no rally in is still drawn: what it saw is why.
        let rallies: [ClosedRange<Double>]
        do {
            rallies = try await processVideoMetadata(url, videoId: UUID(), persist: false).rallySegments.map { $0.startTime...$0.endTime }
        } catch ProcessingError.noRalliesDetected {
            rallies = []
        }
        let evidence = frameEvidence

        await MainActor.run {
            isProcessing = true; progress = 0
            backgroundGuard.begin {
                print("⚠️ BackgroundProcessingGuard: background time expiring during debug processing")
            }
        }
        do {
            let out = try await annotate(url, evidence: evidence, rallies: rallies)
            await MainActor.run {
                processedURL = out
                isProcessing = false
                progress = 1
                backgroundGuard.end()
            }
            return out
        } catch {
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
            throw error
        }
    }

    /// Every frame of the video with the newest evidence at or before it drawn over it: the balls found, the
    /// selected track's last second, the gate's verdict and whether the frame is inside a kept rally.
    private func annotate(_ url: URL, evidence: [FrameEvidence], rallies: [ClosedRange<Double>]) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProcessingError.noVideoTrack }
        let duration = try await asset.load(.duration)
        let fps = max(10, Int(try await track.load(.nominalFrameRate)))
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        // The evidence's frame space: upright when the rotation is applied.
        let frameOrientation: CGImagePropertyOrientation = config.applyVideoRotation
            ? VideoFrameGeometry.orientation(for: preferredTransform)
            : .up
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.readerSettings(standardColor: config.standardColorFrames))
        reader.add(output)
        let annotator = try DebugAnnotator(size: naturalSize, transform: preferredTransform, orientation: frameOrientation)

        // Evidence older than this is not drawn on a frame: the pipeline had nothing to say of it.
        let freshFor = 1.0 / 3
        var next = 0
        var trail: [(time: Double, point: CGPoint)] = []
        var frameCount = 0
        let totalFramesEstimate = Int(duration.seconds * Double(fps))

        reader.startReading()
        defer { reader.cancelReading() }
        while reader.status == .reading, let sbuf = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
            let now = CMTimeGetSeconds(pts)
            while next < evidence.count, evidence[next].time <= now + 1e-6 {
                if let point = evidence[next].trackPoint { trail.append((evidence[next].time, point)) }
                next += 1
            }
            trail.removeAll { now - $0.time > 1 }
            let seen = next > 0 && now - evidence[next - 1].time <= freshFor ? evidence[next - 1] : nil
            try annotator.append(sampleBuffer: sbuf,
                                 overlay: .init(detections: seen?.detections.map { DetectionResult(bbox: $0.bbox, confidence: $0.confidence, timestamp: pts) } ?? [],
                                                trail: seen?.trackPoint == nil ? [] : trail.map(\.point),
                                                isProjectile: seen?.isProjectile ?? false,
                                                inRally: rallies.contains { $0.contains(now) },
                                                time: pts,
                                                validation: seen?.gate))
            frameCount += 1
            if frameCount % fps == 0 {
                let p = min(1.0, max(0.0, Double(frameCount) / Double(max(totalFramesEstimate, 1))))
                await MainActor.run { self.progress = p }
            }
        }
        if reader.status == .failed { throw ProcessingError.assetReaderFailed(reader.error) }
        try Task.checkCancellation()
        return try await annotator.finish()
    }
    #endif

    // MARK: - Metadata path (production mode with metadata generation)
    /// `persist: false` (analyzeVideo) leaves the metadata store unset for the run, so nothing below
    /// reads or writes a checkpoint, looks for earlier manual segments, or saves the result.
    func processVideoMetadata(_ url: URL, videoId: UUID, persist: Bool = true) async throws -> ProcessingMetadata {
        await MainActor.run {
            isProcessing = true; progress = 0; processedMetadata = nil
            backgroundGuard.begin {
                print("⚠️ BackgroundProcessingGuard: background time expiring — cancelling processing")
            }
        }

        stage = nil
        serves.removeAll()
        lastVideoDurationSec = 0

        let startTime = Date()
        var timing = StageTiming()
        let thermalAtStart = ProcessInfo.processInfo.thermalState
        let eventLog = ProcessingEventLog()
        eventLog.log(.processingStarted, detail: "videoId=\(videoId)")

        // Initialize metadata store on main actor
        self.metadataStore = persist ? await MainActor.run { MetadataStore.shared } : nil

        let asset = AVURLAsset(url: url)

        do { try prepareDetectors() } catch {
            eventLog.log(.processingFailed, detail: "no ball detector for this configuration (heatmapOnly=\(config.heatmapOnly))")
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
            throw error
        }

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
            throw ProcessingError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let fps = max(10, Int(try await track.load(.nominalFrameRate)))
        lastVideoDurationSec = CMTimeGetSeconds(duration)
        let frameOrientation: CGImagePropertyOrientation = config.applyVideoRotation
            ? VideoFrameGeometry.orientation(for: (try? await track.load(.preferredTransform)) ?? .identity)
            : .up

        // Resumable processing: a checkpoint from an interrupted run (same
        // video, same config) lets this run start at its rally-idle resume
        // point instead of frame zero.
        let checkpointURL = await MainActor.run { [metadataStore] in
            metadataStore?.processingCheckpointFileURL(for: videoId)
        }
        let configHash = ProcessingCheckpoint.hash(of: config)
        urgentCheckpoint.withLock { $0 = false }

        // The net, asked of the run's source once, before anything else of the
        // run is decided: one box for the whole video, or none — and then the
        // rules that need it are skipped, never answered as if the ball were in
        // the court or above the net. Asked on a resume too: what a checkpoint
        // holds was decided against the net it was written with.
        detectedNet = nil
        netGeometry = .unavailable(reason: "no net-dependent rule is on")
        if config.enableUnderNetRejection || config.enableOffCourtRejection || config.enableAboveNetRequirement {
            let netStart = CFAbsoluteTimeGetCurrent()
            netGeometry = await netSource.netGeometry(forVideoAt: url, asset: asset, durationSec: lastVideoDurationSec, config: config)
            timing.net = CFAbsoluteTimeGetCurrent() - netStart
            detectedNet = netGeometry.net
        }

        var restored: ProcessingCheckpoint?
        if let checkpointURL, let candidate = ProcessingCheckpoint.load(from: checkpointURL) {
            if candidate.isValid(for: videoId, configHash: configHash,
                                 durationSec: lastVideoDurationSec,
                                 collectEvidence: collectFrameEvidence),
               candidate.wasWritten(with: detectedNet, origin: netGeometry.origin) {
                restored = candidate
                eventLog.log(.processingStarted,
                             detail: String(format: "resuming from checkpoint at %.1fs", candidate.resumeTime))
            } else {
                // Different config, source or net (a calibration confirmed, corrected or withdrawn since) —
                // a stale checkpoint must not leak in: the run starts from the first frame.
                ProcessingCheckpoint.delete(at: checkpointURL)
            }
        }

        // Reader (resumes mid-video when a checkpoint seeded this run)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.readerSettings(standardColor: config.standardColorFrames))
        reader.add(output)
        if let restored {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: restored.resumeTime, preferredTimescale: 600),
                end: duration
            )
            await MainActor.run { self.progress = restored.resumeTime / max(lastVideoDurationSec, 0.1) }
        }

        // Everything from the frame's balls on: tracking, the rules and the rally decision. Checkpoints are
        // written at rally-idle, so a resumed run's stage starts fresh at the resume point with what was closed
        // and counted before it put back.
        let stage = RallyDecisionStage(config: config, net: detectedNet, collectEvidence: collectFrameEvidence, eventLog: eventLog,
                                       debugger: trajectoryDebugger, restored: restored)
        self.stage = stage
        let spatialChecks = SpatialChecks(config: config, net: netGeometry)
        lastSpatialChecks = spatialChecks
        if let line = spatialChecks.skippedLine { print("ℹ️ \(line)") }

        let totalFramesEstimate = Int(duration.seconds * Double(fps))

        reader.startReading()
        defer { reader.cancelReading() }
        eventLog.log(.frameLoopStarted, detail: "fps=\(fps), totalFramesEstimate=\(totalFramesEstimate)")

        // Dynamic stride tracking
        var rawFrameIndex = restored?.counters.rawFrameIndex ?? 0
        var skippedFrames = restored?.counters.skippedFrames ?? 0

        // Checkpoint cadence: at rally-idle, every ~30s of video, plus
        // immediately when background expiry requests one.
        var lastCheckpointTime = restored?.resumeTime ?? 0
        let writeCheckpoint: (_ nowSec: Double, _ rawFrameIndex: Int, _ skippedFrames: Int) -> Void = {
            [weak self] nowSec, rawFrameIndex, skippedFrames in
            guard let self, let checkpointURL else { return }
            ProcessingCheckpoint(
                videoId: videoId,
                configHash: configHash,
                videoDurationSec: self.lastVideoDurationSec,
                collectEvidence: self.collectFrameEvidence,
                resumeTime: nowSec,
                rawSegments: stage.closedRawRanges.map {
                    .init(start: CMTimeGetSeconds($0.start), end: CMTimeGetSeconds(CMTimeRangeGetEnd($0)))
                },
                ballHeights: stage.ballHeights.map { .init(t: $0.t, y: Double($0.y)) },
                ballSizes: stage.ballSizes.map { .init(t: $0.t, area: $0.area, x: $0.x) },
                evidence: self.collectFrameEvidence ? stage.frameEvidence.map(StoredFrameEvidence.init) : [],
                physics: stage.physicsValidationData.map {
                    .init(t: $0.timestamp, isValid: $0.isValid, rSquared: $0.rSquared, confidenceLevel: $0.confidenceLevel)
                },
                trajectorySpans: stage.trajectoryDataCollection.map { .init(start: $0.startTime, end: $0.endTime) },
                counters: .init(
                    rawFrameIndex: rawFrameIndex, skippedFrames: skippedFrames, frameCount: stage.frameCount,
                    totalDetections: stage.totalDetections, detectionFrameCount: stage.detectionFrameCount,
                    trackingFrameCount: stage.trackingFrameCount, rallyFrameCount: stage.rallyFrameCount,
                    physicsValidFrameCount: stage.physicsValidFrameCount, confidenceSum: stage.confidenceSum,
                    rSquaredSum: stage.rSquaredSum, rSquaredCount: stage.rSquaredCount
                ),
                net: self.detectedNet.map { ProcessingCheckpoint.NetBox($0, origin: self.netGeometry.origin) },
                savedAt: Date()
            ).write(to: checkpointURL)
        }

        // The multi-frame model finds the ball by itself; YOLO doesn't run.
        let heatAlone = config.heatmapOnly && heatDetector != nil

        // A processed frame, detected by YOLO, waiting for the multi-frame
        // model: its answer comes a few fed frames later, from the window
        // that has the frame near its middle. Without that model nothing
        // waits. The counters are the decoder's at this frame, for a
        // checkpoint written as it's handled.
        struct PendingFrame {
            let pts: CMTime
            let rawFrameIndex: Int
            let skippedFrames: Int
            let yoloDets: [DetectionResult]
            /// Its index among the frames fed to the multi-frame model.
            let heatIndex: Int?
        }
        var pending: [PendingFrame] = []
        var heatPeaks: [Int: [HeatmapBallDetector.Peak]] = [:]
        func keepHeatPeaks(_ answers: [[HeatmapBallDetector.Peak]], answeredThrough end: Int) {
            for (k, peaks) in answers.enumerated() {
                let index = end - answers.count + k
                if pending.contains(where: { $0.heatIndex == index }) { heatPeaks[index] = peaks }
            }
        }

        // Track, gate, decide and record one processed frame.
        func handle(_ frame: PendingFrame) async throws {
            let pts = frame.pts
            let yoloDets = frame.yoloDets
            let heatDets = frame.heatIndex
                .flatMap { heatPeaks.removeValue(forKey: $0) }
                .map { heatmapOnlyDetections($0, beside: yoloDets, at: pts, orientation: frameOrientation) } ?? []
            let dets = yoloDets + heatDets
            let decision = stage.decide(dets, singleFrameCount: yoloDets.count, at: pts)

            // Resume checkpoint: written only at rally-idle so no FSM/tracker
            // state spans the boundary. Periodic (~30s of video) plus an
            // immediate write when background expiry asked for one.
            if !decision.isActive {
                let nowSec = CMTimeGetSeconds(pts)
                // Taken and cleared in one step, so a request arriving
                // mid-write isn't lost.
                let urgent = urgentCheckpoint.withLock { requested in
                    defer { requested = false }
                    return requested
                }
                if urgent || nowSec - lastCheckpointTime >= 30 {
                    writeCheckpoint(nowSec, frame.rawFrameIndex, frame.skippedFrames)
                    lastCheckpointTime = nowSec
                }
            }

            stage.record(decision)

            // Progress (~once per second). Use rawFrameIndex — frameCount only counts
            // stride-processed frames, which made the bar plateau at the skip rate.
            if frame.rawFrameIndex % fps == 0 {
                let p = min(1.0, max(0.0, Double(frame.rawFrameIndex) / Double(max(totalFramesEstimate, 1))))
                await MainActor.run { self.progress = p }
                print(String(format: "[metadata] t=%.2fs det=%d proj=%@ inRally=%@ tracks=%d",
                             CMTimeGetSeconds(pts),
                             dets.count,
                             decision.isProjectile ? "Y" : "N",
                             decision.isActive ? "Y" : "N",
                             stage.trackCount))
            }
        }

        // Run a processed frame through tracking and the rules, timed.
        func handleTimed(_ frame: PendingFrame) async throws {
            let start = CFAbsoluteTimeGetCurrent()
            try await handle(frame)
            timing.rules += CFAbsoluteTimeGetCurrent() - start
            timing.handled += 1
        }
        // The multi-frame model's answers, kept for the frames waiting on them.
        func keepTimed(_ answers: [[HeatmapBallDetector.Peak]]) {
            guard let windows = heatWindows, !answers.isEmpty else { return }
            timing.windows += 1
            keepHeatPeaks(answers, answeredThrough: windows.answered)
        }

        while reader.status == .reading,
              let sbuf = StageTiming.time(&timing.decode, { output.copyNextSampleBuffer() }),
              let pix = CMSampleBufferGetImageBuffer(sbuf) {

            // Check for cancellation before processing each frame
            try Task.checkCancellation()

            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
            rawFrameIndex += 1
            let heatFrame = heatDetector == nil ? nil : StageTiming.time(&timing.grey) { heatmapFrame(pix, at: CMTimeGetSeconds(pts)) }
            if heatFrame != nil { timing.greyFrames += 1 }
            let heatIndex = heatFrame != nil ? heatWindows?.pushed : nil

            // Single processing path: a dynamic stride skips frames (denser
            // while tracking a ball, sparser when idle) so we never run
            // detection on every frame. The tracker is a few frames behind
            // the decoder while the multi-frame model's answers are awaited.
            let recommendedStride = stage.recommendedStride(currentTime: pts)
            // The multi-frame model alone runs on exactly the frames it's fed
            // (~30/s): a processed frame it hadn't seen would read as "no ball".
            let shouldProcess = heatAlone
                ? heatIndex != nil
                : (rawFrameIndex == 1) || (rawFrameIndex % recommendedStride == 0)

            if shouldProcess {
                // Detect: YOLO now; the multi-frame model's balls YOLO missed
                // (or, with config.heatmapOnly, all of them) when its window comes.
                let yoloDets = heatAlone ? [] : StageTiming.time(&timing.yolo) {
                    detector?.detect(in: pix, at: pts, orientation: frameOrientation) ?? []
                }
                if !heatAlone { timing.yoloFrames += 1 }
                pending.append(PendingFrame(pts: pts, rawFrameIndex: rawFrameIndex, skippedFrames: skippedFrames,
                                            yoloDets: yoloDets, heatIndex: heatIndex))
            } else {
                skippedFrames += 1
                // Keep progress advancing through skipped frames (~once per second)
                if rawFrameIndex % fps == 0 {
                    let p = min(1.0, Double(rawFrameIndex) / Double(max(totalFramesEstimate, 1)))
                    await MainActor.run { self.progress = p }
                }
            }
            if let heatFrame, let answers = StageTiming.time(&timing.multiFrame, { heatWindows?.push(heatFrame) }) {
                keepTimed(answers)
            }

            // Clean up sample buffer to prevent memory accumulation for large videos
            CMSampleBufferInvalidate(sbuf)

            while let next = pending.first, next.heatIndex.map({ $0 < (heatWindows?.answered ?? 0) }) ?? true {
                pending.removeFirst()
                try await handleTimed(next)
            }
        }

        // Check if reader finished successfully or encountered an error
        if reader.status == .failed {
            eventLog.log(.processingFailed, detail: "AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")")
            throw ProcessingError.assetReaderFailed(reader.error)
        }

        // The video's last frames: the multi-frame model answers them from
        // its last window.
        if let answers = StageTiming.time(&timing.multiFrame, { heatWindows?.finish() }) {
            keepTimed(answers)
        }
        for frame in pending {
            try Task.checkCancellation()
            try await handleTimed(frame)
        }
        pending.removeAll()

        let outcome = stage.finish(until: duration)
        let keep = outcome.keep
        serves = outcome.serves

        // Log processing statistics
        let processedFrames = rawFrameIndex - skippedFrames
        let finder = heatDetector == nil ? config.ballModel.rawValue
            : "\(heatAlone ? "multi-frame only" : "\(config.ballModel.rawValue) + multi-frame") (\(heatModelURL?.deletingPathExtension().lastPathComponent ?? "?"))"
        print(timing.line(video: lastVideoDurationSec - (restored?.resumeTime ?? 0), frames: rawFrameIndex - (restored?.counters.rawFrameIndex ?? 0),
                          total: Date().timeIntervalSince(startTime), model: finder,
                          thermal: (thermalAtStart, ProcessInfo.processInfo.thermalState)))
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
            // A completed run has nothing to resume — even a no-rally one.
            if let checkpointURL { ProcessingCheckpoint.delete(at: checkpointURL) }
            await MainActor.run { isProcessing = false; backgroundGuard.end() }
            throw ProcessingError.noRalliesDetected
        }

        // Check for cancellation before metadata generation
        try Task.checkCancellation()

        let rallySegments = outcome.rallies

        // Generate processing statistics
        let processingStats = ProcessingStats(
            totalFrames: rawFrameIndex,
            processedFrames: processedFrames,
            detectionFrames: stage.detectionFrameCount,
            trackingFrames: stage.trackingFrameCount,
            rallyFrames: stage.rallyFrameCount,
            physicsValidFrames: stage.physicsValidFrameCount,
            totalDetections: stage.totalDetections,
            validTrajectories: stage.trajectoryDataCollection.count,
            averageDetectionsPerFrame: processedFrames > 0 ? Double(stage.totalDetections) / Double(processedFrames) : 0,
            averageConfidence: stage.detectionFrameCount > 0 ? stage.confidenceSum / Double(stage.detectionFrameCount) : 0,
            processingDuration: Date().timeIntervalSince(startTime),
            framesPerSecond: Double(fps)
        )

        // Generate quality metrics
        let qualityMetrics = QualityMetrics(
            overallQuality: ProcessingQualityMetrics.calculateOverallQuality(stats: processingStats, rSquaredAvg: stage.rSquaredCount > 0 ? stage.rSquaredSum / Double(stage.rSquaredCount) : 0),
            averageRSquared: stage.rSquaredCount > 0 ? stage.rSquaredSum / Double(stage.rSquaredCount) : 0,
            trajectoryConsistency: ProcessingQualityMetrics.calculateTrajectoryConsistency(stage.trajectoryDataCollection),
            physicsValidationRate: stage.frameCount > 0 ? Double(stage.physicsValidFrameCount) / Double(stage.frameCount) : 0,
            movementClassificationAccuracy: ProcessingQualityMetrics.calculateClassificationAccuracy(stage.classificationResults),
            confidenceDistribution: ProcessingQualityMetrics.calculateConfidenceDistribution(stage.classificationResults),
            qualityBreakdown: ProcessingQualityMetrics.calculateQualityBreakdown(stage.trajectoryDataCollection)
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
            processingOverheadPercent: ProcessingQualityMetrics.calculateProcessingOverhead(processingDuration: endTime.timeIntervalSince(startTime), videoDuration: CMTimeGetSeconds(duration)),
            detectionLatencyMs: nil
        )

        // Manual segments (timeline editor) are human ground truth — carry them
        // through reprocessing, dropping any newly detected segment that
        // overlaps one.
        var mergedSegments = rallySegments
        if let store = metadataStore,
           let existing = try? await store.loadMetadata(for: videoId) {
            let manual = existing.rallySegments.filter { $0.isManual }
            if !manual.isEmpty {
                let keptDetected = rallySegments.filter { detected in
                    !manual.contains { $0.startTime < detected.endTime && detected.startTime < $0.endTime }
                }
                mergedSegments = (manual + keptDetected).sorted { $0.startTime < $1.startTime }
                print("🖐️ Preserved \(manual.count) manual segment(s) through reprocessing")
            }
        }

        // Create final metadata
        eventLog.log(.processingCompleted, detail: "rallies=\(mergedSegments.count), duration=\(String(format: "%.1f", endTime.timeIntervalSince(startTime)))s")
        let metadata = ProcessingMetadata.createWithEnhancedData(
            for: videoId,
            with: config,
            rallySegments: mergedSegments,
            stats: processingStats,
            quality: qualityMetrics,
            trajectories: stage.trajectoryDataCollection,
            classifications: stage.classificationResults,
            physics: stage.physicsValidationData,
            performance: performanceMetrics,
            eventLog: eventLog.allEvents,
            netCenterX: detectedNet.map { Double($0.box.midX) },
            spatialChecks: spatialChecks
        )

        // Save metadata to store
        if persist {
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
        }

        // The run finished — its resume checkpoint is obsolete.
        if let checkpointURL { ProcessingCheckpoint.delete(at: checkpointURL) }

        await MainActor.run {
            processedMetadata = metadata
            isProcessing = false
            progress = 1
            backgroundGuard.end()
        }

        return metadata
    }

}
