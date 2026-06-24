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
            let clipURL = stagingDirectory.appendingPathComponent(contribution.clipFileName)
            guard fileManager.fileExists(atPath: clipURL.path) else {
                // Clip went missing — drop the orphaned record.
                continue
            }
            do {
                try await client.submitFlywheelContribution(contribution, clipURL: clipURL, progress: { _ in })
                try? fileManager.removeItem(at: clipURL)
                uploaded += 1
            } catch {
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
            let clipURL = stagingDirectory.appendingPathComponent(contribution.clipFileName)
            try? fileManager.removeItem(at: clipURL)
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
        let dedupeKey = "\(videoId.uuidString)#\(rallyIndex)#\(trigger.rawValue)"
        guard !staged.contains(where: { $0.dedupeKey == dedupeKey }) else { return }
        guard segment.endTime > segment.startTime else { return }

        let id = UUID()
        let clipFileName = "\(id.uuidString).mp4"
        let clipURL = stagingDirectory.appendingPathComponent(clipFileName)

        // Export the raw model segment (no watermark, no user trim) — we want
        // exactly the frames the detector ran on.
        do {
            let asset = AVURLAsset(url: originalURL)
            let range = CMTimeRange(
                start: CMTime(seconds: segment.startTime, preferredTimescale: 600),
                end: CMTime(seconds: segment.endTime, preferredTimescale: 600)
            )
            _ = try await VideoExporter().exportClip(asset: asset, timeRange: range, to: clipURL, addWatermark: false)
        } catch {
            print("Flywheel: clip export failed for rally \(rallyIndex): \(error)")
            return
        }

        let sliced = evidence.filter {
            $0.time >= segment.startTime - evidenceMarginSec &&
            $0.time <= segment.endTime + evidenceMarginSec
        }

        let contribution = FlywheelContribution(
            id: id,
            videoId: videoId,
            rallyIndex: rallyIndex,
            startTime: segment.startTime,
            endTime: segment.endTime,
            trigger: trigger,
            userReason: reason,
            clipFileName: clipFileName,
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
