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
    private let lifetimeKey = "flywheelLifetimeContributed"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let metadataStore = MetadataStore()

    private var staged: [FlywheelContribution] = []

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

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        self.lifetimeContributedCount = UserDefaults.standard.integer(forKey: lifetimeKey)
        loadIndex()
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
        print("🪁 Flywheel: stageCorrection trigger=\(trigger.rawValue) rally=\(rallyIndex) optedIn=\(AppSettings.shared.enableDataFlywheel) reason=\(reason ?? "nil")")
        guard AppSettings.shared.enableDataFlywheel else { print("🪁 Flywheel: skip stage — opted out"); return }
        guard staged.count < maxPendingContributions else { print("🪁 Flywheel: skip stage — pending cap (\(staged.count))"); return }

        let evidence = metadataStore.loadFrameEvidence(for: videoId)
        print("🪁 Flywheel: loaded \(evidence.count) evidence frames for video \(videoId)")
        await stage(videoId: videoId, rallyIndex: rallyIndex, segment: segment,
                    trigger: trigger, reason: reason, originalURL: originalURL, evidence: evidence)
        triggerDrain()
    }

    // MARK: - Drain

    /// Upload staged contributions and remove the local copies on success.
    /// Failures (offline / unauthenticated) are kept for the next attempt.
    func drain(using client: any APIClient) async {
        guard AppSettings.shared.enableDataFlywheel else { print("🪁 Flywheel: drain skip — opted out"); return }
        guard !isDraining else { print("🪁 Flywheel: drain skip — already draining"); return }
        guard !staged.isEmpty else { print("🪁 Flywheel: drain skip — nothing pending"); return }
        print("🪁 Flywheel: draining \(staged.count) pending…")
        isDraining = true
        defer { isDraining = false }

        var remaining: [FlywheelContribution] = []
        var uploaded = 0

        for contribution in staged {
            let frameURLs = contribution.frameFileNames
                .map { stagingDirectory.appendingPathComponent($0) }
                .filter { fileManager.fileExists(atPath: $0.path) }
            guard !frameURLs.isEmpty else {
                // Frames went missing — drop the orphaned record.
                print("🪁 Flywheel: dropping orphaned record — frames missing for rally \(contribution.rallyIndex)")
                continue
            }
            do {
                print("🪁 Flywheel: uploading rally=\(contribution.rallyIndex) trigger=\(contribution.trigger.rawValue) frames=\(frameURLs.count)…")
                try await client.submitFlywheelContribution(contribution, frameURLs: frameURLs, progress: { _ in })
                frameURLs.forEach { try? fileManager.removeItem(at: $0) }
                uploaded += 1
                print("🪁 Flywheel: uploaded rally=\(contribution.rallyIndex) ✅")
            } catch {
                remaining.append(contribution)
                print("🪁 Flywheel: upload FAILED rally=\(contribution.rallyIndex): \(error)")
            }
        }

        staged = remaining
        pendingCount = staged.count
        persistIndex()

        if uploaded > 0 {
            lifetimeContributedCount += uploaded
            UserDefaults.standard.set(lifetimeContributedCount, forKey: lifetimeKey)
        }
        print("🪁 Flywheel: drain done — uploaded=\(uploaded) stillPending=\(remaining.count)")
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
        print("🪁 Flywheel: triggerDrain (pending=\(staged.count))")
        Task { await drain(using: SupabaseAPIClient.shared) }
    }

    private func stage(videoId: UUID, rallyIndex: Int, segment: RallySegment,
                       trigger: FlywheelTrigger, reason: String?, originalURL: URL,
                       evidence: [StoredFrameEvidence]) async {
        let dedupeKey = "\(videoId.uuidString)#\(rallyIndex)#\(trigger.rawValue)"
        guard !staged.contains(where: { $0.dedupeKey == dedupeKey }) else { print("🪁 Flywheel: skip stage — already staged \(dedupeKey)"); return }
        guard segment.endTime > segment.startTime else { print("🪁 Flywheel: skip stage — empty segment [\(segment.startTime)-\(segment.endTime)]"); return }

        let id = UUID()
        let sliced = evidence.filter {
            $0.time >= segment.startTime - evidenceMarginSec &&
            $0.time <= segment.endTime + evidenceMarginSec
        }

        // Sample full-resolution stills across the whole source video (the
        // annotation input) instead of a heavy clip.
        print("🪁 Flywheel: extracting frames rally=\(rallyIndex) from \(originalURL.lastPathComponent)")
        let frameNames = await extractFrames(from: originalURL, contributionId: id)
        guard !frameNames.isEmpty else {
            print("🪁 Flywheel: skip stage — no frames extracted for rally \(rallyIndex)")
            return
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
        print("🪁 Flywheel: staged \(frameNames.count) frames (\(sliced.count) evidence) — pending=\(staged.count)")
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
            print("🪁 Flywheel: couldn't load duration: \(error)")
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
                print("🪁 Flywheel: frame extract failed at \(String(format: "%.2f", t))s: \(error)")
            }
        }
        print("🪁 Flywheel: extracted \(names.count)/\(count) frames over \(String(format: "%.1f", durationSec))s")
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
}
