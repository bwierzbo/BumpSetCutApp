//
//  FlywheelCaptureService.swift
//  BumpSetCut
//
//  Data flywheel: when the user opts in, stage clips of rallies the detector
//  struggled with (passively) or that the user corrected, then drain them to the
//  private `training-data` bucket for relabeling. Mirrors OfflineQueue's
//  stage-on-disk / drain-on-network design.
//

import Foundation
import AVFoundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class FlywheelCaptureService {

    static let shared = FlywheelCaptureService()

    // MARK: - Observable state (for Settings)

    private(set) var pendingCount: Int = 0
    private(set) var lifetimeContributedCount: Int = 0
    private(set) var isDraining = false
    /// Rallies the user has explicitly reported, as "videoId#rallyIndex" keys.
    /// Drives the "reported" indicator and survives app restarts.
    private(set) var reportedRallies: Set<String> = []

    // MARK: - Tuning

    /// Rallies whose model confidence is at or below this are "borderline" — the
    /// hard examples worth relabeling. (RallySegment.confidence is the average
    /// physics confidence over the segment, 0–1.)
    private let passiveConfidenceThreshold = 0.5
    /// Cap passive captures per video so one process doesn't flood the queue.
    private let maxPassivePerVideo = 2
    /// Hard ceiling on staged contributions awaiting upload.
    private let maxPendingContributions = 50
    /// Pad the evidence window slightly past the segment edges.
    private let evidenceMarginSec = 0.25
    /// Full-resolution stills sampled evenly across the WHOLE source video (not
    /// just the rally) so annotating them lets the model generalize to the rest
    /// of the footage. Native resolution; count scales with video length, clamped.
    private let minFrames = 20
    private let maxFrames = 50
    private let frameIntervalSec = 2.0   // aim for ~one frame per 2s of source
    private let frameJpegQuality: CGFloat = 0.9

    // MARK: - Storage

    private let fileManager = FileManager.default
    private let stagingDirectory: URL
    private let indexURL: URL
    private let uploadedVideosURL: URL
    private let reportedURL: URL
    private let lifetimeKey = "flywheelLifetimeContributed"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let metadataStore = MetadataStore()

    private var staged: [FlywheelContribution] = []
    /// Videos whose whole-video frames are already on the server — later flags on
    /// these only send an event (no frame re-upload).
    private var framesUploadedVideos: Set<UUID> = []

    // MARK: - Device info (stamped onto each contribution)

    private static let appVersion: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    private static let osVersion: String = {
        #if canImport(UIKit)
        return "iOS \(UIDevice.current.systemVersion)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }()
    private static let deviceModel: String = {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }()

    // MARK: - Init

    init() {
        let base = StorageManager.getPersistentStorageDirectory()
            .appendingPathComponent("ProcessedMetadata", isDirectory: true)
            .appendingPathComponent("Flywheel", isDirectory: true)
        self.stagingDirectory = base
        self.indexURL = base.appendingPathComponent("flywheel_index.json")
        self.uploadedVideosURL = base.appendingPathComponent("flywheel_uploaded_videos.json")
        self.reportedURL = base.appendingPathComponent("flywheel_reported.json")

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        self.lifetimeContributedCount = UserDefaults.standard.integer(forKey: lifetimeKey)
        loadIndex()
        loadUploadedVideos()
        loadReported()
    }

    // MARK: - Reported indicator

    private static func reportKey(_ videoId: UUID, _ rallyIndex: Int) -> String {
        "\(videoId.uuidString)#\(rallyIndex)"
    }

    /// Record that the user reported a rally (drives the UI indicator).
    func markRallyReported(videoId: UUID, rallyIndex: Int) {
        let key = Self.reportKey(videoId, rallyIndex)
        guard !reportedRallies.contains(key) else { return }
        reportedRallies.insert(key)
        persistReported()
    }

    /// How many rallies in a video the user has reported.
    func reportedCount(videoId: UUID) -> Int {
        let prefix = "\(videoId.uuidString)#"
        return reportedRallies.reduce(0) { $0 + ($1.hasPrefix(prefix) ? 1 : 0) }
    }

    // MARK: - Passive capture (processing time)

    /// Stage the borderline-confidence rallies from a freshly processed video.
    /// No-op unless the user has opted in.
    func stagePassiveContributions(videoId: UUID, metadata: ProcessingMetadata, originalURL: URL) async {
        guard AppSettings.shared.enableDataFlywheel else { return }
        guard staged.count < maxPendingContributions else { return }

        let evidence = metadataStore.loadFrameEvidence(for: videoId)

        let borderline = metadata.rallySegments.enumerated()
            .filter { $0.element.confidence <= passiveConfidenceThreshold }
            .sorted { $0.element.confidence < $1.element.confidence }
            .prefix(maxPassivePerVideo)

        for (index, segment) in borderline {
            await stage(videoId: videoId, rallyIndex: index, segment: segment,
                        trigger: .lowScore, reason: nil, originalURL: originalURL, evidence: evidence)
        }
        triggerDrain()
    }

    // MARK: - Correction capture (review time)

    /// Stage a contribution for a rally the user corrected or reported.
    /// No-op unless the user has opted in.
    func stageCorrection(videoId: UUID, rallyIndex: Int, segment: RallySegment,
                         trigger: FlywheelTrigger, reason: String? = nil, originalURL: URL) async {
        guard AppSettings.shared.enableDataFlywheel else { return }
        guard staged.count < maxPendingContributions else { return }

        let evidence = metadataStore.loadFrameEvidence(for: videoId)
        await stage(videoId: videoId, rallyIndex: rallyIndex, segment: segment,
                    trigger: trigger, reason: reason, originalURL: originalURL, evidence: evidence)
        triggerDrain()
    }

    // MARK: - Drain

    /// Upload staged contributions and remove the local copies on success.
    /// Failures (offline / unauthenticated) are kept for the next attempt.
    func drain(using client: any APIClient) async {
        guard AppSettings.shared.enableDataFlywheel, !isDraining, !staged.isEmpty else { return }
        isDraining = true
        defer { isDraining = false }

        var remaining: [FlywheelContribution] = []
        var uploaded = 0

        for contribution in staged {
            let frameURLs = contribution.frameFileNames
                .map { stagingDirectory.appendingPathComponent($0) }
                .filter { fileManager.fileExists(atPath: $0.path) }
            // Event-only repeats legitimately have no frames; only drop when frames
            // were expected but their files vanished.
            if !contribution.frameFileNames.isEmpty && frameURLs.isEmpty {
                continue
            }
            do {
                try await client.submitFlywheelContribution(contribution, frameURLs: frameURLs, progress: { _ in })
                frameURLs.forEach { try? fileManager.removeItem(at: $0) }
                if !contribution.frameFileNames.isEmpty {
                    framesUploadedVideos.insert(contribution.videoId)
                    persistUploadedVideos()
                }
                uploaded += 1
            } catch {
                // Keep failed items for the next attempt (offline / unauthenticated).
                remaining.append(contribution)
            }
        }

        staged = remaining
        pendingCount = staged.count
        persistIndex()

        if uploaded > 0 {
            lifetimeContributedCount += uploaded
            UserDefaults.standard.set(lifetimeContributedCount, forKey: lifetimeKey)
        }
    }

    // MARK: - Clear

    /// Delete all staged contributions (clips + records). Used on opt-out or a
    /// manual "clear pending" in Settings.
    func clearPending() {
        for contribution in staged {
            for name in contribution.frameFileNames {
                try? fileManager.removeItem(at: stagingDirectory.appendingPathComponent(name))
            }
        }
        staged.removeAll()
        pendingCount = 0
        persistIndex()
    }

    // MARK: - Evidence scoping

    /// Map the processor's in-memory evidence to its storable form, keeping only
    /// frames within a rally window (± margin) so the persisted sidecar stays small.
    nonisolated static func scopedEvidence(_ raw: [VideoProcessor.FrameEvidence],
                                           segments: [RallySegment],
                                           margin: Double = 0.25) -> [StoredFrameEvidence] {
        guard !raw.isEmpty, !segments.isEmpty else { return [] }
        let windows: [(Double, Double)] = segments.map { ($0.startTime - margin, $0.endTime + margin) }
        return raw.compactMap { e in
            windows.contains(where: { e.time >= $0.0 && e.time <= $0.1 }) ? StoredFrameEvidence(e) : nil
        }
    }

    // MARK: - Private

    private func triggerDrain() {
        Task { await drain(using: SupabaseAPIClient.shared) }
    }

    private func stage(videoId: UUID, rallyIndex: Int, segment: RallySegment,
                       trigger: FlywheelTrigger, reason: String?, originalURL: URL,
                       evidence: [StoredFrameEvidence]) async {
        guard segment.endTime > segment.startTime else { return }

        let event = FlywheelFlagEvent(rallyIndex: rallyIndex, trigger: trigger.rawValue, reason: reason, at: Date())

        // Already staged for this video → just record the extra flag (frames are
        // whole-video, so one set covers every rally). No re-extraction.
        if let idx = staged.firstIndex(where: { $0.videoId == videoId }) {
            staged[idx].flagEvents.append(event)
            persistIndex()
            return
        }

        let id = UUID()
        let sliced = evidence.filter {
            $0.time >= segment.startTime - evidenceMarginSec &&
            $0.time <= segment.endTime + evidenceMarginSec
        }

        // Frames already on the server → stage an event-only repeat (no frames).
        let frameNames: [String]
        if framesUploadedVideos.contains(videoId) {
            frameNames = []
        } else {
            frameNames = await extractFrames(from: originalURL, contributionId: id)
            guard !frameNames.isEmpty else { return }
        }

        let contribution = FlywheelContribution(
            id: id,
            videoId: videoId,
            rallyIndex: rallyIndex,
            startTime: segment.startTime,
            endTime: segment.endTime,
            trigger: trigger,
            userReason: reason,
            frameFileNames: frameNames,
            flagEvents: [event],
            evidence: sliced,
            rallyConfidence: segment.confidence,
            rallyQuality: segment.quality,
            appVersion: Self.appVersion,
            osVersion: Self.osVersion,
            deviceModel: Self.deviceModel,
            consentVersion: AppSettings.shared.flywheelConsentVersion,
            createdAt: Date()
        )

        staged.append(contribution)
        pendingCount = staged.count
        persistIndex()
    }

    // MARK: - Frame extraction

    /// Sample full-resolution JPEG stills evenly across the entire source video.
    /// Count scales with duration (~one per `frameIntervalSec`), clamped to
    /// [minFrames, maxFrames]. Returns the staged file names (empty on failure).
    private func extractFrames(from originalURL: URL, contributionId: UUID) async -> [String] {
        let asset = AVURLAsset(url: originalURL)
        let durationSec: Double
        do {
            durationSec = CMTimeGetSeconds(try await asset.load(.duration))
        } catch {
            print("Flywheel: couldn't load video duration: \(error)")
            return []
        }
        guard durationSec > 0 else { return [] }

        let count = min(maxFrames, max(minFrames, Int((durationSec / frameIntervalSec).rounded())))
        // Spread across the interior of the video (avoid the very first/last frame).
        let times: [Double] = (0..<count).map { i in
            durationSec * (Double(i) + 0.5) / Double(count)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true          // correct orientation
        generator.requestedTimeToleranceBefore = .zero           // exact frames
        generator.requestedTimeToleranceAfter = .zero
        // No maximumSize → native full resolution (1080p / 2K / 4K as source).

        var names: [String] = []
        for (i, t) in times.enumerated() {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            do {
                let cgImage: CGImage
                if #available(iOS 16.0, *) {
                    cgImage = try await generator.image(at: cmTime).image
                } else {
                    cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
                }
                #if canImport(UIKit)
                guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: frameJpegQuality) else { continue }
                #else
                continue
                #endif
                let name = "\(contributionId.uuidString)_f\(String(format: "%03d", i)).jpg"
                try data.write(to: stagingDirectory.appendingPathComponent(name), options: .atomic)
                names.append(name)
            } catch {
                print("Flywheel: frame extract failed at \(String(format: "%.2f", t))s: \(error)")
            }
        }
        return names
    }

    private func persistIndex() {
        do {
            let data = try encoder.encode(staged)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("Flywheel: failed to persist index: \(error)")
        }
    }

    private func loadIndex() {
        guard fileManager.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let loaded = try? decoder.decode([FlywheelContribution].self, from: data) else {
            return
        }
        staged = loaded
        pendingCount = staged.count
    }

    private func persistUploadedVideos() {
        do {
            let data = try encoder.encode(framesUploadedVideos)
            try data.write(to: uploadedVideosURL, options: .atomic)
        } catch {
            print("Flywheel: failed to persist uploaded videos: \(error)")
        }
    }

    private func loadUploadedVideos() {
        guard fileManager.fileExists(atPath: uploadedVideosURL.path),
              let data = try? Data(contentsOf: uploadedVideosURL),
              let loaded = try? decoder.decode(Set<UUID>.self, from: data) else {
            return
        }
        framesUploadedVideos = loaded
    }

    private func persistReported() {
        do {
            let data = try encoder.encode(reportedRallies)
            try data.write(to: reportedURL, options: .atomic)
        } catch {
            print("Flywheel: failed to persist reported: \(error)")
        }
    }

    private func loadReported() {
        guard fileManager.fileExists(atPath: reportedURL.path),
              let data = try? Data(contentsOf: reportedURL),
              let loaded = try? decoder.decode(Set<String>.self, from: data) else {
            return
        }
        reportedRallies = loaded
    }
}
