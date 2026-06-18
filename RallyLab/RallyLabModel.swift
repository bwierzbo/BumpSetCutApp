//
//  RallyLabModel.swift
//  RallyLab
//
//  State + actions for the labeling/evaluation sandbox. Drives the real
//  VideoProcessor for detection, then replays its recorded frame evidence
//  through RallyDecider/SegmentBuilder for instant re-scoring and sweeps.
//

import AppKit
import AVFoundation
import Foundation
import Observation

/// A ground-truth rally being edited in the UI. Mirrors `LabeledRally` but
/// with mutable fields and an identity so list rows can bind to it.
struct EditableRally: Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var end: Double
}

@MainActor
@Observable
final class RallyLabModel {

    // MARK: - Video / playback

    private(set) var videoURL: URL?
    private(set) var player: AVPlayer?
    private var observedPlayer: AVPlayer?
    private var timeObserver: Any?
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0

    // MARK: - Ground truth

    var labels: [EditableRally] = [] {
        didSet {
            guard !suppressLabelSideEffects, labels != oldValue else { return }
            saveLabels()
            recomputeScore()
        }
    }
    private(set) var pendingStart: Double?
    private var suppressLabelSideEffects = false

    // MARK: - Pipeline results

    private(set) var evidence: [VideoProcessor.FrameEvidence] = []
    private(set) var rawPredictions: [Interval] = []
    private(set) var paddedPredictions: [Interval] = []
    private(set) var score: ScoringResult?

    /// Serve-signature readout for one predicted rally (Phase A — measurement only,
    /// no gating). A serve travels down the court (camera behind the baseline), so
    /// the ball's apparent size should change consistently over the opening window;
    /// a carried/held ball stays roughly flat. `normalizedSlope` is the per-second
    /// fractional size change (signed: + = approaching/growing, − = receding);
    /// `monotonicity` is the fraction of steps moving in the dominant direction
    /// (~0.5 = noise, 1.0 = perfectly consistent).
    struct ServeSignature {
        let normalizedSlope: Double
        let monotonicity: Double
        let sampleCount: Int
    }
    /// Opening window (seconds from a rally's start) the serve signature is measured over.
    let serveWindowSec: Double = 0.6

    /// Weighted rally-likelihood breakdown for one predicted rally (Phase B-1 —
    /// flag-only, nothing is filtered). Each feature is 0…1, higher = more
    /// rally-like; `total` is their weighted average (serve dropped when the
    /// opening window is a skyball top-exit, since its size trend is unreliable).
    struct RallyScore {
        let serve: Double         // depth/size trend over the opening window
        let travel: Double        // how much court the ball covered (spatial extent)
        let continuity: Double    // fraction of segment frames with a ball
        let sizeDynamics: Double  // size variability — a held ball barely changes
        let skyball: Bool         // opening window reached the top of frame
        let total: Double
    }

    // Rally-score weights (flag-only; recompute live, no re-run needed).
    var serveWeight: Double = 0.40
    var travelWeight: Double = 0.25
    var continuityWeight: Double = 0.20
    var sizeWeight: Double = 0.15
    // Normalization references: the feature value at which each score saturates to 1.
    private let serveSlopeRef = 0.5    // |fractional size change / s|
    private let travelRef = 0.35       // normalized track spatial extent
    private let sizeCVRef = 0.25       // size coefficient of variation

    private(set) var activeProcessor: VideoProcessor?
    var isProcessing: Bool { activeProcessor != nil }
    private(set) var status = "Open a video to begin."

    // MARK: - Overlay

    /// Draw the detection/trajectory overlay on the player.
    var showOverlay = true
    /// Draw the per-candidate ROI/association circles + score labels. Off by
    /// default — they clutter the frame; the trail, detection boxes and track
    /// dot still show without them.
    var showROI = false
    /// Oriented display size of the loaded video (after preferredTransform),
    /// used to letterbox-fit the overlay over the player.
    private(set) var videoDisplaySize: CGSize = CGSize(width: 16, height: 9)
    /// Clockwise quarter-turns (0–3) the player applies vs the raw frame the
    /// detector saw, so overlay coordinates can be rotated to match.
    private(set) var videoRotationQuarterTurns: Int = 0

    /// Detections affect the captured evidence, so changing the confidence
    /// threshold needs a fresh pipeline run; this flags that the on-screen
    /// overlay/score are from a stale threshold.
    private(set) var detectionConfigDirty = false

    // MARK: - Tunable config

    /// Detection threshold — re-run the pipeline to apply (unlike the decider
    /// params below, this changes what the model detects, not just how
    /// segments are decided from cached evidence).
    var detectionConfidence: Double = 0.70 {
        didSet { markDetectionDirty(detectionConfidence, oldValue) }
    }

    /// Letterbox frames into the model (`.scaleFit`) instead of stretching
    /// (`.scaleFill`). Keeps the ball round (matches YOLO training) — A/B this on
    /// ultrawide/0.5x clips to see if confidence recovers. Re-run to apply.
    var useScaleFitLetterbox: Bool = false {
        didSet {
            guard useScaleFitLetterbox != oldValue, !evidence.isEmpty else { return }
            detectionConfigDirty = true
        }
    }

    // Physics-gate / supported-ball veto params. Like confidence, these are
    // applied when the gate decides projectile-vs-carried at detection time, so
    // they need a re-run (and can't be swept — the sweep replays cached
    // evidence whose projectile decision is already baked in).

    /// Min gravity signature to accept as free flight; raise to veto more
    /// carried/rolled balls (which score near 0).
    var minGravitySignature: Double = 0.3 {
        didSet { markDetectionDirty(minGravitySignature, oldValue) }
    }
    /// Curvature at which the (fit-based) gravity signature reads ~1.0. Lower so
    /// real arcs saturate to full gravity sooner.
    var gravityReferenceCurvature: Double = 0.02 {
        didSet { markDetectionDirty(gravityReferenceCurvature, oldValue) }
    }
    /// "Flat" threshold: the veto only fires when vertical-motion score is below
    /// this. Raise to treat more motion as flat (more aggressive veto).
    var maxVerticalMotionForRolling: Double = 0.3 {
        didSet { markDetectionDirty(maxVerticalMotionForRolling, oldValue) }
    }
    /// Min parabola curvature |a|; raise to reject near-straight held balls.
    var minCurvatureMagnitude: Double = 0.004 {
        didSet { markDetectionDirty(minCurvatureMagnitude, oldValue) }
    }
    /// Min vertical travel (fraction of frame height) over the fit window.
    var minProjectileSpanY: Double = 0.04 {
        didSet { markDetectionDirty(minProjectileSpanY, oldValue) }
    }
    /// Min parabola fit quality (R²) to accept a projectile. Raise to reject
    /// jumpy/erratic motion that fits a clean arc poorly.
    var parabolaMinR2: Double = 0.80 {
        didSet { markDetectionDirty(parabolaMinR2, oldValue) }
    }
    /// Min detection points required in the fit window. Lower to relax the
    /// "too few points in window" rejection (accept sparser tracks).
    var parabolaMinPoints: Double = 8 {
        didSet { markDetectionDirty(parabolaMinPoints, oldValue) }
    }
    /// Seconds of recent track history the gate fits over. Widen to gather more
    /// points (also relaxes "too few points in window").
    var projectileWindowSec: Double = 0.45 {
        didSet { markDetectionDirty(projectileWindowSec, oldValue) }
    }
    /// Also veto tracks the classifier labels `.carried` (jumpy pickups).
    var vetoCarriedMovement: Bool = false {
        didSet {
            guard vetoCarriedMovement != oldValue, !evidence.isEmpty else { return }
            detectionConfigDirty = true
        }
    }
    /// Run the gate on Kalman-smoothed positions instead of raw detections.
    var useSmoothedTrack: Bool = false {
        didSet {
            guard useSmoothedTrack != oldValue, !evidence.isEmpty else { return }
            detectionConfigDirty = true
        }
    }
    /// Frames processed while actively tracking a ball (1 = every frame).
    var activeTrackingStride: Double = 1 {
        didSet { markDetectionDirty(activeTrackingStride, oldValue) }
    }
    /// Reject tracks that loop back to their horizontal start (pickup/scoop).
    var enableLoopRejection: Bool = false {
        didSet {
            guard enableLoopRejection != oldValue, !evidence.isEmpty else { return }
            detectionConfigDirty = true
        }
    }
    /// Reject when net horizontal travel ≤ this fraction of the side-to-side
    /// excursion (lower = stricter / only near-complete loops).
    var loopReturnRatio: Double = 0.5 {
        didSet { markDetectionDirty(loopReturnRatio, oldValue) }
    }
    /// Multi-court selection: how much a candidate's relative ball size adds to its
    /// score (quality-first; higher favors the bigger/closer main-court ball on ties).
    var trajectorySizeTiebreak: Double = 0.10 {
        didSet { markDetectionDirty(trajectorySizeTiebreak, oldValue) }
    }
    /// Multi-court selection: keep the current trajectory unless another beats it by
    /// this score margin (higher = stickier, less flicker between courts).
    var trajectorySelectionStickiness: Double = 0.10 {
        didSet { markDetectionDirty(trajectorySelectionStickiness, oldValue) }
    }

    private func markDetectionDirty(_ new: Double, _ old: Double) {
        guard new != old, !evidence.isEmpty else { return }
        detectionConfigDirty = true
    }

    var startBuffer: Double = 0 { didSet { recomputePredictionsAndScore() } }
    var endTimeout: Double = 0 { didSet { recomputePredictionsAndScore() } }
    var projDropGracePeriod: Double = 0 { didSet { recomputePredictionsAndScore() } }
    var minRallySec: Double = 3.0 { didSet { recomputePredictionsAndScore() } }
    var minGapToMerge: Double = 0 { didSet { recomputePredictionsAndScore() } }
    var minSegmentLength: Double = 0 { didSet { recomputePredictionsAndScore() } }
    /// Lead-in: seconds added BEFORE the decided start so the exported clip
    /// captures the serve/wind-up. Shown as the lighter padded block in the
    /// timeline; doesn't change the raw score (which uses pre-padding boundaries).
    var preroll: Double = 2.0 { didSet { recomputePredictionsAndScore() } }
    /// Sky-ball grace: extended no-ball timeout when the ball was last seen above
    /// `skyBallTopThreshold` (left the top of frame on a high arc).
    var skyBallTimeout: Double = 2.5 { didSet { recomputePredictionsAndScore() } }
    var skyBallTopThreshold: Double = 0.85 { didSet { recomputePredictionsAndScore() } }

    /// Display-only: the candidate ROI circle is drawn with radius = ball size ×
    /// this scale. Changing it just redraws the overlay (no re-run / re-score).
    var trajectoryRoiScale: Double = 3.0

    // MARK: - Sweep

    /// One config the sweep surfaced, scored against the labels. `score` is the
    /// raw F1+boundary objective (what you actually care about); ranking also
    /// factors in how far it strays from your current config.
    struct SweepCandidate: Identifiable {
        let id = UUID()
        let params: [String: Double]
        let f1: Double
        let score: Double
        let driftFromCurrent: Double  // 0 = unchanged, 1 = every param at an extreme
    }
    /// Top results from the last sweep, best first.
    private(set) var sweepCandidates: [SweepCandidate] = []
    private(set) var isSweeping = false

    // MARK: - Recent videos

    /// Recently opened videos (most recent first), persisted across launches so
    /// relaunching restores the session — and with it the per-video labels.
    private(set) var recentVideos: [URL] = []
    private let recentsKey = "RallyLab.recentVideoPaths"
    private let maxRecents = 12

    init() {
        resetTunablesToPreset()
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recentVideos = paths.map { URL(fileURLWithPath: $0) }
    }

    /// Reopen the most recent still-present video. Call once on launch; no-op if
    /// a video is already loaded.
    func restoreLastSession() {
        guard videoURL == nil else { return }
        guard let url = recentVideos.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        loadVideo(url)
    }

    private func pushRecent(_ url: URL) {
        recentVideos.removeAll { $0.path == url.path }
        recentVideos.insert(url, at: 0)
        if recentVideos.count > maxRecents { recentVideos = Array(recentVideos.prefix(maxRecents)) }
        UserDefaults.standard.set(recentVideos.map(\.path), forKey: recentsKey)
    }

    private func resetTunablesToPreset() {
        let preset = ProcessorConfig()
        detectionConfidence = preset.detectionConfidence
        useScaleFitLetterbox = preset.useScaleFitLetterbox
        minGravitySignature = preset.minGravitySignature
        gravityReferenceCurvature = preset.gravityReferenceCurvature
        maxVerticalMotionForRolling = preset.maxVerticalMotionForRolling
        minCurvatureMagnitude = Double(preset.minCurvatureMagnitude)
        minProjectileSpanY = Double(preset.minProjectileSpanY)
        parabolaMinR2 = preset.parabolaMinR2
        parabolaMinPoints = Double(preset.parabolaMinPoints)
        projectileWindowSec = preset.projectileWindowSec
        vetoCarriedMovement = preset.vetoCarriedMovement
        useSmoothedTrack = preset.useSmoothedTrack
        activeTrackingStride = Double(preset.activeTrackingStride)
        enableLoopRejection = preset.enableLoopRejection
        loopReturnRatio = preset.loopReturnRatio
        trajectorySizeTiebreak = preset.trajectorySizeTiebreak
        trajectorySelectionStickiness = preset.trajectorySelectionStickiness
        startBuffer = preset.startBuffer
        endTimeout = preset.endTimeout
        projDropGracePeriod = Double(preset.projDropGracePeriod)
        minRallySec = 1.1653  // RallyDecider's production default
        minGapToMerge = preset.minGapToMerge
        minSegmentLength = preset.minSegmentLength
        preroll = preset.preroll
        skyBallTimeout = preset.skyBallTimeout
        skyBallTopThreshold = Double(preset.skyBallTopThreshold)
    }

    /// Default config with the panel's tunables applied — used for pipeline
    /// runs, replays, and as the sweep's base.
    func currentConfig() -> ProcessorConfig {
        var cfg = ProcessorConfig()
        cfg.detectionConfidence = detectionConfidence
        cfg.useScaleFitLetterbox = useScaleFitLetterbox
        cfg.minGravitySignature = minGravitySignature
        cfg.gravityReferenceCurvature = gravityReferenceCurvature
        cfg.maxVerticalMotionForRolling = maxVerticalMotionForRolling
        cfg.minCurvatureMagnitude = CGFloat(minCurvatureMagnitude)
        cfg.minProjectileSpanY = CGFloat(minProjectileSpanY)
        cfg.parabolaMinR2 = parabolaMinR2
        cfg.parabolaMinPoints = Int(parabolaMinPoints.rounded())
        cfg.projectileWindowSec = projectileWindowSec
        cfg.vetoCarriedMovement = vetoCarriedMovement
        cfg.useSmoothedTrack = useSmoothedTrack
        cfg.activeTrackingStride = Int(activeTrackingStride.rounded())
        cfg.enableLoopRejection = enableLoopRejection
        cfg.loopReturnRatio = loopReturnRatio
        cfg.trajectorySizeTiebreak = trajectorySizeTiebreak
        cfg.trajectorySelectionStickiness = trajectorySelectionStickiness
        cfg.startBuffer = startBuffer
        cfg.endTimeout = endTimeout
        cfg.projDropGracePeriod = Int(projDropGracePeriod.rounded())
        cfg.minGapToMerge = minGapToMerge
        cfg.minSegmentLength = minSegmentLength
        cfg.preroll = preroll
        cfg.skyBallTimeout = skyBallTimeout
        cfg.skyBallTopThreshold = CGFloat(skyBallTopThreshold)
        return cfg
    }

    // MARK: - Parameter export

    /// The current tunables as a human-readable block keyed by their real
    /// `ProcessorConfig` / `RallyDecider` field names, so the values can be
    /// pasted back and applied verbatim as the shared defaults.
    func parametersExport() -> String {
        func f(_ v: Double) -> String { String(format: "%.4f", v) }
        return """
        // RallyLab tuned parameters — apply as ProcessorConfig defaults (shared by RallyLab + BumpSetCut)
        ProcessorConfig:
          detectionConfidence = \(f(detectionConfidence))
          useScaleFitLetterbox = \(useScaleFitLetterbox)
          minGravitySignature = \(f(minGravitySignature))
          gravityReferenceCurvature = \(f(gravityReferenceCurvature))
          maxVerticalMotionForRolling = \(f(maxVerticalMotionForRolling))
          minCurvatureMagnitude = \(f(minCurvatureMagnitude))
          minProjectileSpanY = \(f(minProjectileSpanY))
          parabolaMinR2 = \(f(parabolaMinR2))
          parabolaMinPoints = \(Int(parabolaMinPoints.rounded()))
          projectileWindowSec = \(f(projectileWindowSec))
          vetoCarriedMovement = \(vetoCarriedMovement)
          useSmoothedTrack = \(useSmoothedTrack)
          activeTrackingStride = \(Int(activeTrackingStride.rounded()))
          enableLoopRejection = \(enableLoopRejection)
          loopReturnRatio = \(f(loopReturnRatio))
          trajectorySizeTiebreak = \(f(trajectorySizeTiebreak))
          trajectorySelectionStickiness = \(f(trajectorySelectionStickiness))
          startBuffer = \(f(startBuffer))
          endTimeout = \(f(endTimeout))
          projDropGracePeriod = \(Int(projDropGracePeriod.rounded()))
          minGapToMerge = \(f(minGapToMerge))
          minSegmentLength = \(f(minSegmentLength))
          preroll = \(f(preroll))
          skyBallTimeout = \(f(skyBallTimeout))
          skyBallTopThreshold = \(f(skyBallTopThreshold))
        RallyDecider:
          minRallySec = \(f(minRallySec))
        """
    }

    /// Copy `parametersExport()` to the clipboard.
    func copyParameters() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(parametersExport(), forType: .string)
        status = "Parameters copied — paste them to the assistant to bake in as defaults."
    }

    // MARK: - Video loading

    func loadVideo(_ url: URL) {
        teardownPlayer()
        videoURL = url
        pushRecent(url)
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        observedPlayer = newPlayer
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = CMTimeGetSeconds(time)
            }
        }

        duration = 0
        currentTime = 0
        evidence = []
        rawPredictions = []
        paddedPredictions = []
        score = nil
        sweepCandidates = []
        pendingStart = nil

        videoDisplaySize = CGSize(width: 16, height: 9)
        videoRotationQuarterTurns = 0
        detectionConfigDirty = false

        Task {
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            if videoURL == url { duration = seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform),
               videoURL == url {
                let oriented = natural.applying(transform)
                videoDisplaySize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                // Clockwise quarter-turns from the transform's rotation angle.
                let angle = atan2(transform.b, transform.a)
                let turns = Int((angle / (.pi / 2)).rounded()) % 4
                videoRotationQuarterTurns = (turns + 4) % 4
            }
        }

        loadLabels()
        status = "Loaded \(url.lastPathComponent)" + (labels.isEmpty ? "." : " with \(labels.count) saved labels.")
    }

    func setStatus(_ message: String) {
        status = message
    }

    /// Moves a fulfilled file promise (e.g. a Photos drag, staged in a temp
    /// dir by VideoDropView) into ~/Movies/RallyLab so the labels sidecar has
    /// a stable path. Re-dropping the same item reuses the existing copy and
    /// therefore its labels.
    func importPromisedFile(_ fileURL: URL) {
        do {
            let importDir = FileManager.default
                .urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RallyLab", isDirectory: true)
            try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)

            let destination = importDir.appendingPathComponent(fileURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: fileURL)
            } else {
                try FileManager.default.moveItem(at: fileURL, to: destination)
            }
            loadVideo(destination)
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    private func teardownPlayer() {
        if let observer = timeObserver, let owner = observedPlayer {
            owner.removeTimeObserver(observer)
        }
        timeObserver = nil
        observedPlayer = nil
        player?.pause()
        player = nil
    }

    // MARK: - Playback controls

    func togglePlayPause() {
        guard let player else { return }
        player.timeControlStatus == .playing ? player.pause() : player.play()
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        player?.seek(
            to: CMTimeMakeWithSeconds(clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
        currentTime = clamped
    }

    // MARK: - Marking

    func markStart() {
        guard videoURL != nil else { return }
        pendingStart = currentTime
        status = String(format: "Rally start marked at %.2fs — press E at the rally end.", currentTime)
    }

    func markEnd() {
        guard let start = pendingStart else {
            status = "Press S to mark a rally start first."
            return
        }
        let end = currentTime
        guard end > start else {
            status = "Rally end must come after its start — keep playing, then press E."
            return
        }
        labels.append(EditableRally(start: start, end: end))
        labels.sort { $0.start < $1.start }
        pendingStart = nil
        status = String(format: "Labeled rally %.2fs – %.2fs.", start, end)
    }

    func cancelPendingStart() {
        pendingStart = nil
    }

    func deleteLabel(_ label: EditableRally) {
        labels.removeAll { $0.id == label.id }
    }

    // MARK: - Ground-truth persistence

    /// Sidecar JSON next to the video: `game.mov` → `game.rallylabels.json`.
    /// Content is a plain `[LabeledRally]` array.
    var labelsFileURL: URL? {
        videoURL?.deletingPathExtension().appendingPathExtension("rallylabels.json")
    }

    private func saveLabels() {
        guard let url = labelsFileURL else { return }
        let payload = labels.map { LabeledRally(startTime: $0.start, endTime: $0.end) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(payload).write(to: url, options: .atomic)
        } catch {
            status = "Failed to save labels: \(error.localizedDescription)"
        }
    }

    private func loadLabels() {
        suppressLabelSideEffects = true
        defer { suppressLabelSideEffects = false }
        labels = []
        guard let url = labelsFileURL, let data = try? Data(contentsOf: url) else { return }
        do {
            let decoded = try JSONDecoder().decode([LabeledRally].self, from: data)
            labels = decoded.map { EditableRally(start: $0.startTime, end: $0.endTime) }
        } catch {
            status = "Found \(url.lastPathComponent) but couldn't decode it: \(error.localizedDescription)"
        }
        recomputeScore()
    }

    // MARK: - Pipeline

    /// Runs the real VideoProcessor (YOLO → Kalman → ballistics → decider →
    /// segments) on the loaded video with the current config, capturing
    /// per-frame evidence for replays.
    func runPipeline() async {
        guard let url = videoURL else { return }
        guard !isProcessing else { return }

        let processor = VideoProcessor()
        processor.config = currentConfig()
        processor.collectFrameEvidence = true
        activeProcessor = processor
        status = "Running pipeline…"
        defer { activeProcessor = nil }

        do {
            _ = try await processor.processVideo(url, videoId: UUID())
        } catch is CancellationError {
            status = "Pipeline cancelled."
            return
        } catch ProcessingError.noRalliesDetected {
            // Zero predicted segments is a legitimate outcome to score; the
            // frame evidence was still fully captured.
        } catch {
            status = "Pipeline failed: \(error.localizedDescription)"
            return
        }

        evidence = processor.frameEvidence
        detectionConfigDirty = false
        if processor.lastVideoDurationSec > 0 { duration = processor.lastVideoDurationSec }
        recomputePredictionsAndScore()

        let ballFrames = evidence.filter(\.hasBall).count
        if ballFrames == 0 {
            status = "Pipeline finished but saw no ball in \(evidence.count) frames — is the CoreML model in the RallyLab bundle?"
        } else {
            status = "Pipeline done: \(rawPredictions.count) predicted rallies, ball seen in \(ballFrames)/\(evidence.count) frames."
        }
    }

    /// Loads the pipeline's raw predictions as the ground-truth list so you
    /// correct boundaries instead of labeling from scratch.
    func seedFromPredictions() async {
        if evidence.isEmpty {
            await runPipeline()
        }
        guard !rawPredictions.isEmpty else {
            status = "No predictions to seed from."
            return
        }
        labels = rawPredictions.map { EditableRally(start: $0.start, end: $0.end) }
        status = "Seeded \(labels.count) labels from predictions — correct them and re-score."
    }

    // MARK: - Overlay lookup

    /// Frames within `window` seconds before `time` (and the frame straddling
    /// it), oldest first — the source for the current detection boxes and the
    /// recent ball trail. Evidence is time-sorted, so this binary-searches the
    /// upper bound and walks back.
    func overlayFrames(at time: Double, window: Double) -> [VideoProcessor.FrameEvidence] {
        guard !evidence.isEmpty else { return [] }
        var hi = evidence.count - 1
        var lo = 0
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if evidence[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        let upper = lo
        let lowerBound = time - window
        var start = upper
        while start > 0 && evidence[start - 1].time >= lowerBound { start -= 1 }
        return Array(evidence[start...upper])
    }

    // MARK: - Scoring

    private func recomputePredictionsAndScore() {
        guard !evidence.isEmpty else { return }
        let cfg = currentConfig()
        rawPredictions = EvidenceReplayer.decidedRanges(
            evidence: evidence, duration: duration, config: cfg,
            minRallySec: minRallySec, padded: false)
        paddedPredictions = EvidenceReplayer.decidedRanges(
            evidence: evidence, duration: duration, config: cfg,
            minRallySec: minRallySec, padded: true)
        recomputeScore()
    }

    private func recomputeScore() {
        guard !evidence.isEmpty else {
            score = nil
            return
        }
        // Score RAW decided boundaries against hand labels, never the padded
        // export ranges — otherwise preroll/postroll reads as model error.
        score = RallySegmentationScorer.score(
            predicted: rawPredictions,
            groundTruth: labels.map { Interval(start: $0.start, end: $0.end) }
        )
    }

    // MARK: - Serve signature (Phase A: measure only)

    /// Each predicted rally paired with its serve signature, for eyeballing
    /// whether real serves separate from carries/false rallies by size trend.
    var serveSignatures: [(rally: Interval, sig: ServeSignature?)] {
        rawPredictions.map { ($0, serveSignature(for: $0)) }
    }

    /// Size trend over the opening window of a predicted rally, computed from the
    /// captured evidence. Size source per frame: the raw detection nearest the
    /// selected track (truest trend), falling back to the selected candidate's
    /// smoothed mean size, then the largest detection. Side length (√area) is used
    /// so the value scales linearly with apparent size. nil if too few samples.
    func serveSignature(for rally: Interval) -> ServeSignature? {
        guard !evidence.isEmpty else { return nil }
        let windowEnd = rally.start + serveWindowSec
        var pts: [(t: Double, size: Double)] = []
        for f in evidence where f.time >= rally.start && f.time <= windowEnd {
            let size: Double?
            if let sel = f.candidates.first(where: { $0.isSelected }) {
                if let near = f.detections.min(by: {
                    hypot($0.bbox.midX - sel.point.x, $0.bbox.midY - sel.point.y)
                        < hypot($1.bbox.midX - sel.point.x, $1.bbox.midY - sel.point.y)
                }) {
                    size = sqrt(Double(near.bbox.width * near.bbox.height))
                } else if sel.ballSize > 0 {
                    size = Double(sel.ballSize)
                } else { size = nil }
            } else if let maxDet = f.detections.map({ sqrt(Double($0.bbox.width * $0.bbox.height)) }).max(),
                      maxDet > 0 {
                size = maxDet
            } else { size = nil }
            if let s = size, s > 0 { pts.append((t: f.time - rally.start, size: s)) }
        }
        guard pts.count >= 3 else { return nil }
        let n = Double(pts.count)
        let sumX = pts.reduce(0.0) { $0 + $1.t }
        let sumY = pts.reduce(0.0) { $0 + $1.size }
        let sumXY = pts.reduce(0.0) { $0 + $1.t * $1.size }
        let sumX2 = pts.reduce(0.0) { $0 + $1.t * $1.t }
        let denom = n * sumX2 - sumX * sumX
        guard abs(denom) > 1e-12 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom
        let mean = sumY / n
        guard mean > 1e-9 else { return nil }
        // Monotonicity: fraction of consecutive steps moving in the slope's direction.
        var agree = 0, total = 0
        for i in 1..<pts.count {
            let d = pts[i].size - pts[i - 1].size
            if d == 0 { continue }
            total += 1
            if (d > 0) == (slope > 0) { agree += 1 }
        }
        let mono = total > 0 ? Double(agree) / Double(total) : 0
        return ServeSignature(normalizedSlope: slope / mean, monotonicity: mono, sampleCount: pts.count)
    }

    // MARK: - Rally score (Phase B-1: weighted, flag-only)

    /// Each predicted rally paired with its weighted rally-likelihood breakdown,
    /// for the inspector table.
    var rallyScores: [(rally: Interval, score: RallyScore?)] {
        rawPredictions.map { ($0, rallyScore(for: $0)) }
    }

    /// Combine the orthogonal features into a single rally-likelihood score for a
    /// predicted rally. Features are computed from captured evidence over the
    /// segment; serve uses the opening-window signature. Flag-only — callers
    /// display it, nothing in the pipeline consumes it yet.
    func rallyScore(for rally: Interval) -> RallyScore? {
        guard !evidence.isEmpty else { return nil }
        let frames = evidence.filter { $0.time >= rally.start && $0.time <= rally.end }
        guard !frames.isEmpty else { return nil }

        // Continuity: fraction of segment frames that actually saw a ball.
        let continuity = Double(frames.filter { $0.hasBall }.count) / Double(frames.count)

        // Selected-track points + raw sizes over the segment.
        var pts: [CGPoint] = []
        var sizes: [Double] = []
        for f in frames {
            guard let sel = f.candidates.first(where: { $0.isSelected }) else { continue }
            pts.append(sel.point)
            if let near = f.detections.min(by: {
                hypot($0.bbox.midX - sel.point.x, $0.bbox.midY - sel.point.y)
                    < hypot($1.bbox.midX - sel.point.x, $1.bbox.midY - sel.point.y)
            }) {
                sizes.append(sqrt(Double(near.bbox.width * near.bbox.height)))
            } else if sel.ballSize > 0 {
                sizes.append(Double(sel.ballSize))
            }
        }

        // Travel: spatial extent the ball covered (both axes — depth shows as
        // vertical motion for a baseline camera, so we don't restrict to horizontal).
        let travel: Double = {
            guard pts.count >= 2 else { return 0 }
            let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
            let dx = (xs.max() ?? 0) - (xs.min() ?? 0)
            let dy = (ys.max() ?? 0) - (ys.min() ?? 0)
            return min(1, hypot(dx, dy) / travelRef)
        }()

        // Size dynamics: coefficient of variation. A flying ball changes apparent
        // size; a carried/held ball barely does.
        let sizeDynamics: Double = {
            guard sizes.count >= 3 else { return 0 }
            let mean = sizes.reduce(0, +) / Double(sizes.count)
            guard mean > 1e-9 else { return 0 }
            let varc = sizes.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(sizes.count)
            return min(1, (sqrt(varc) / mean) / sizeCVRef)
        }()

        // Serve: graded opening-window depth trend (magnitude × consistency).
        let serve: Double = {
            guard let s = serveSignature(for: rally) else { return 0 }
            return min(1, abs(s.normalizedSlope) / serveSlopeRef) * s.monotonicity
        }()

        // Skyball: the ball reached the top of frame within the opening window —
        // its size trend is unreliable, so drop serve from the average (bypass).
        let windowEnd = rally.start + serveWindowSec
        let skyball = frames.contains {
            $0.time <= windowEnd && Double($0.trackPoint?.y ?? 0) >= skyBallTopThreshold
        }

        var feats: [(v: Double, w: Double)] = [
            (travel, travelWeight),
            (continuity, continuityWeight),
            (sizeDynamics, sizeWeight),
        ]
        if !skyball { feats.append((serve, serveWeight)) }
        let wsum = feats.reduce(0) { $0 + $1.w }
        let total = wsum > 1e-9 ? feats.reduce(0) { $0 + $1.v * $1.w } / wsum : 0

        return RallyScore(serve: serve, travel: travel, continuity: continuity,
                          sizeDynamics: sizeDynamics, skyball: skyball, total: total)
    }

    /// Per-feature weighted contributions for a score, normalized so they sum to
    /// `total` — drives the stacked contribution bar. Serve weight is zeroed on a
    /// skyball (its term is bypassed), matching `rallyScore`. Order is stable so
    /// the bar's colors stay consistent across rallies.
    func contributions(_ s: RallyScore) -> [(name: String, value: Double)] {
        let raw: [(String, Double, Double)] = [
            ("serve", s.serve, s.skyball ? 0 : serveWeight),
            ("travel", s.travel, travelWeight),
            ("continuity", s.continuity, continuityWeight),
            ("sizeDyn", s.sizeDynamics, sizeWeight),
        ]
        let wsum = raw.reduce(0) { $0 + $1.2 }
        guard wsum > 1e-9 else { return raw.map { ($0.0, 0) } }
        return raw.map { ($0.0, $0.1 * $0.2 / wsum) }
    }

    // MARK: - Parameter sweep

    static let sweepBounds: [String: (min: Double, max: Double)] = [
        "startBuffer": (0.0, 1.5),
        "endTimeout": (0.3, 3.0),
        "projDropGracePeriod": (0.0, 8.0),
        "minRallySec": (0.5, 6.0),
        "minGapToMerge": (0.0, 2.0),
        "minSegmentLength": (0.0, 4.0),
    ]

    func runSweep() async {
        guard !evidence.isEmpty else {
            status = "Run the pipeline first — the sweep replays its recorded evidence."
            return
        }
        guard !labels.isEmpty else {
            status = "Label at least one rally before sweeping."
            return
        }
        guard !isSweeping else { return }

        isSweeping = true
        defer { isSweeping = false }
        status = "Sweeping parameters…"

        let evidenceCopy = evidence
        let durationCopy = duration
        let truth = labels.map { Interval(start: $0.start, end: $0.end) }
        let bounds = Self.sweepBounds
        // Anchor the search on the CURRENT config so it only strays when that
        // genuinely improves the score — this is what stops it nuking your
        // settings to game the metric by a hair.
        let anchor: [String: Double] = currentSweptParams()

        let candidates = await Task.detached(priority: .userInitiated) {
            () -> [SweepCandidate] in

            // Raw F1+boundary score for a param set (the real objective).
            func rawScore(_ p: [String: Double]) -> (f1: Double, opt: Double) {
                var cfg = ProcessorConfig()
                cfg.startBuffer = p["startBuffer"] ?? cfg.startBuffer
                cfg.endTimeout = p["endTimeout"] ?? cfg.endTimeout
                cfg.projDropGracePeriod = Int((p["projDropGracePeriod"] ?? 0).rounded())
                cfg.minGapToMerge = p["minGapToMerge"] ?? cfg.minGapToMerge
                cfg.minSegmentLength = p["minSegmentLength"] ?? cfg.minSegmentLength
                let raw = EvidenceReplayer.decidedRanges(
                    evidence: evidenceCopy, duration: durationCopy, config: cfg,
                    minRallySec: p["minRallySec"] ?? 3.0, padded: false)
                let s = RallySegmentationScorer.score(predicted: raw, groundTruth: truth)
                return (s.f1, s.optimizerScore())
            }

            // Mean normalized distance from the anchor (0 = unchanged).
            func drift(_ p: [String: Double]) -> Double {
                var sum = 0.0
                for (k, b) in bounds {
                    let span = max(1e-9, b.max - b.min)
                    sum += abs((p[k] ?? 0) - (anchor[k] ?? 0)) / span
                }
                return sum / Double(bounds.count)
            }

            // Rank by score minus a small drift penalty: ties and near-ties go to
            // the config closest to what the user already has.
            let lambda = 0.06
            struct Eval { let p: [String: Double]; let f1: Double; let opt: Double; let drift: Double }
            func ranked(_ e: Eval) -> Double { e.opt - lambda * e.drift }
            var evals: [Eval] = []
            func evalStore(_ p: [String: Double]) {
                let (f1, opt) = rawScore(p)
                evals.append(Eval(p: p, f1: f1, opt: opt, drift: drift(p)))
            }

            let keys = Array(bounds.keys)
            // Always evaluate "no change" so staying put is on the table.
            evalStore(anchor)
            // Phase 1: broad random sampling for fine-grained values.
            for _ in 0..<600 {
                var p: [String: Double] = [:]
                for k in keys { let b = bounds[k]!; p[k] = Double.random(in: b.min...b.max) }
                evalStore(p)
            }
            // Phase 2: local refinement around the current best (by ranked score).
            let best = evals.max { ranked($0) < ranked($1) }!.p
            for _ in 0..<400 {
                var p: [String: Double] = [:]
                for k in keys {
                    let b = bounds[k]!
                    let sigma = (b.max - b.min) * 0.08
                    let v = (best[k] ?? 0) + Double.random(in: -sigma...sigma)
                    p[k] = min(b.max, max(b.min, v))
                }
                evalStore(p)
            }

            // Top distinct configs by ranked score.
            let sorted = evals.sorted { ranked($0) > ranked($1) }
            var top: [SweepCandidate] = []
            for e in sorted {
                if top.count >= 5 { break }
                let isNearExisting = top.contains { existing in
                    keys.allSatisfy { k in
                        let b = bounds[k]!
                        return abs((existing.params[k] ?? 0) - (e.p[k] ?? 0)) / max(1e-9, b.max - b.min) < 0.05
                    }
                }
                if isNearExisting { continue }
                top.append(SweepCandidate(params: e.p, f1: e.f1, score: e.opt, driftFromCurrent: e.drift))
            }
            return top
        }.value

        sweepCandidates = candidates
        if let best = candidates.first {
            status = String(format: "Sweep done: best score %.3f (F1 %.3f). Showing top %d — Apply any, then Revert if it's worse.", best.score, best.f1, candidates.count)
        } else {
            status = "Sweep produced no usable configs."
        }
    }

    /// The six swept params as a dictionary, keyed to match `sweepBounds`.
    private func currentSweptParams() -> [String: Double] {
        [
            "startBuffer": startBuffer,
            "endTimeout": endTimeout,
            "projDropGracePeriod": projDropGracePeriod,
            "minRallySec": minRallySec,
            "minGapToMerge": minGapToMerge,
            "minSegmentLength": minSegmentLength,
        ]
    }

    /// Snapshot of the swept (live-rescore) params captured just before
    /// `applySweepBest`, so the apply can be undone if the result looks wrong.
    private struct SweptParams {
        var startBuffer, endTimeout, projDropGracePeriod, minRallySec, minGapToMerge, minSegmentLength: Double
    }
    private var preApplySnapshot: SweptParams?
    var canRevertSweepApply: Bool { preApplySnapshot != nil }

    /// Apply a specific sweep candidate (defaults to the best). Snapshots the
    /// current config first so it can be reverted.
    func applySweepCandidate(_ candidate: SweepCandidate? = nil) {
        guard let chosen = candidate ?? sweepCandidates.first else { return }
        let p = chosen.params
        preApplySnapshot = SweptParams(
            startBuffer: startBuffer, endTimeout: endTimeout,
            projDropGracePeriod: projDropGracePeriod, minRallySec: minRallySec,
            minGapToMerge: minGapToMerge, minSegmentLength: minSegmentLength)
        startBuffer = p["startBuffer"] ?? startBuffer
        endTimeout = p["endTimeout"] ?? endTimeout
        projDropGracePeriod = (p["projDropGracePeriod"] ?? projDropGracePeriod).rounded()
        minRallySec = p["minRallySec"] ?? minRallySec
        minGapToMerge = p["minGapToMerge"] ?? minGapToMerge
        minSegmentLength = p["minSegmentLength"] ?? minSegmentLength
        status = "Applied sweep config — use Revert to undo."
    }

    /// Restore the config that was active before the last `applySweepBest`.
    func revertSweepApply() {
        guard let snap = preApplySnapshot else { return }
        startBuffer = snap.startBuffer
        endTimeout = snap.endTimeout
        projDropGracePeriod = snap.projDropGracePeriod
        minRallySec = snap.minRallySec
        minGapToMerge = snap.minGapToMerge
        minSegmentLength = snap.minSegmentLength
        preApplySnapshot = nil
        status = "Reverted to the config from before Apply."
    }
}
