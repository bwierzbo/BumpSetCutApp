//
//  FlywheelCaptureService.swift
//  BumpSetCut
//
//  Data flywheel: when the user opts in (testers are in by default), stage
//  every rally of each processed video as a clip of the original footage, and
//  the rallies the user corrected or reported as flags on it, then drain them
//  to the private `training-data` bucket, where RallyLab pulls them into
//  training. Staged on disk, drained on Wi-Fi.
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
    /// Progress (0–1) of the current upload drain, for the upload pill.
    private(set) var uploadProgress: Double = 0
    /// Total clips being uploaded in the current drain, for the pill's label.
    private(set) var uploadClipTotal: Int = 0
    /// Rallies the user has explicitly reported, as "videoId#rallyIndex" keys.
    /// Drives the "reported" indicator and survives app restarts.
    private(set) var reportedRallies: Set<String> = []

    // MARK: - Tuning

    /// Hard ceiling on staged videos awaiting upload (each is up to a few
    /// hundred MB of clips).
    private let maxPendingContributions = 10
    /// Each rally's clip starts and ends this far past it: the serve toss and
    /// the ball's last bounce, which the rally times cut close.
    private let clipPaddingSec = 2.0
    /// A video with no rallies found sends this many stretches of this long,
    /// spread across it: the rallies the detector missed are in there.
    private let missedSampleCount = 3
    private let missedSampleSec = 15.0
    /// 1080p HEVC: the training package scales frames to 1024 px anyway, and
    /// a 4K original would be four times the upload.
    private let clipPreset = AVAssetExportPresetHEVC1920x1080

    // MARK: - Storage

    private let fileManager = FileManager.default
    private let stagingDirectory: URL
    private let indexURL: URL
    private let uploadedVideosURL: URL
    private let reportedURL: URL
    private let lifetimeKey = "flywheelLifetimeContributed"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let metadataStore = MetadataStore.shared

    private var staged: [FlywheelContribution] = []
    /// Videos whose clips are already on the server — later flags on these
    /// only send an event (no re-upload).
    private var uploadedVideos: Set<UUID> = []
    /// Videos whose clips are being exported right now. Flags arriving
    /// meanwhile wait in `eventsAwaitingStage` instead of starting a second
    /// export for the same video.
    private var stagingVideoIds: Set<UUID> = []
    private var eventsAwaitingStage: [UUID: [FlywheelFlagEvent]] = [:]

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
        // Staged clips are waiting to upload — never worth an iCloud backup.
        StorageManager.excludeFromBackup(base)

        self.lifetimeContributedCount = UserDefaults.standard.integer(forKey: lifetimeKey)
        let indexLoaded = loadIndex()
        uploadedVideos = loadJSON(Set<UUID>.self, from: uploadedVideosURL) ?? []
        reportedRallies = loadJSON(Set<String>.self, from: reportedURL) ?? []
        // Only trust the index to say which files are orphaned if it loaded.
        if indexLoaded {
            sweepUnreferencedFiles()
        }
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

    /// Stage every rally of a freshly processed video. No-op unless the user
    /// has opted in.
    func stagePassiveContributions(videoId: UUID, metadata: ProcessingMetadata, originalURL: URL) async {
        guard AppSettings.shared.enableDataFlywheel, let first = metadata.rallySegments.first else { return }
        guard staged.count < maxPendingContributions else { return }

        await stage(videoId: videoId, rallyIndex: 0, segment: first, trigger: .processed, reason: nil,
                    originalURL: originalURL,
                    windows: Self.rallyWindows(metadata.rallySegments, padding: clipPaddingSec))
        triggerDrain()
    }

    /// Stage a video where the detector found NO rallies: a few stretches
    /// spread across it, where the rallies it missed are. No-op unless the
    /// user has opted in.
    func stageNoRallyContribution(videoId: UUID, originalURL: URL) async {
        guard AppSettings.shared.enableDataFlywheel else { return }
        guard staged.count < maxPendingContributions else { return }

        let durationSec: Double
        do {
            durationSec = CMTimeGetSeconds(try await AVURLAsset(url: originalURL).load(.duration))
        } catch {
            print("Flywheel: couldn't load duration for no-rally contribution: \(error)")
            return
        }
        guard durationSec > 0 else { return }

        let wholeVideo = RallySegment(startTimeSeconds: 0, endTimeSeconds: durationSec,
                                      confidence: 0, quality: 0, detectionCount: 0,
                                      averageTrajectoryLength: 0)
        await stage(videoId: videoId, rallyIndex: 0, segment: wholeVideo, trigger: .noRallies, reason: nil,
                    originalURL: originalURL, windows: Self.samples(of: durationSec, count: missedSampleCount,
                                                                     length: missedSampleSec))
        triggerDrain()
    }

    // MARK: - Correction capture (review time)

    /// Stage a flag for a rally the user corrected or reported — with the
    /// video's clips, unless they're staged or uploaded already. No-op unless
    /// the user has opted in.
    func stageCorrection(videoId: UUID, rallyIndex: Int, segment: RallySegment,
                         trigger: FlywheelTrigger, reason: String? = nil, originalURL: URL) async {
        guard AppSettings.shared.enableDataFlywheel else { return }
        guard staged.count < maxPendingContributions else { return }

        let segments = (try? metadataStore.loadMetadata(for: videoId).rallySegments) ?? [segment]
        await stage(videoId: videoId, rallyIndex: rallyIndex, segment: segment, trigger: trigger, reason: reason,
                    originalURL: originalURL, windows: Self.rallyWindows(segments, padding: clipPaddingSec))
        triggerDrain()
    }

    // MARK: - Drain

    /// Upload staged contributions and remove the local copies on success.
    /// Failures (offline / unauthenticated) are kept for the next attempt.
    func drain(using client: any APIClient) async {
        guard AppSettings.shared.enableDataFlywheel, !isDraining, !staged.isEmpty else { return }
        isDraining = true
        uploadProgress = 0
        defer { isDraining = false; uploadProgress = 0; uploadClipTotal = 0 }

        // Resolve each contribution's on-disk clips once, so we know the total
        // up front (for the pill) and can report overall progress.
        let jobs: [(contribution: FlywheelContribution, clipURLs: [URL])] = staged.map { c in
            let urls = c.clips
                .map { stagingDirectory.appendingPathComponent($0.fileName) }
                .filter { fileManager.fileExists(atPath: $0.path) }
            return (c, urls)
        }
        let totalClips = jobs.reduce(0) { $0 + $1.clipURLs.count }
        uploadClipTotal = totalClips
        print("📤 Flywheel: uploading \(jobs.count) contribution(s), \(totalClips) clip(s)…")

        var remaining: [FlywheelContribution] = []
        var resent: [FlywheelContribution] = []
        var uploaded = 0
        var clipsDone = 0

        for job in jobs {
            let contribution = job.contribution
            let clipURLs = job.clipURLs
            // Event-only repeats legitimately have no clips; only drop when clips
            // were expected but their files vanished.
            if !contribution.clips.isEmpty && clipURLs.count != contribution.clips.count {
                clipURLs.forEach { try? fileManager.removeItem(at: $0) }
                continue
            }
            let thisCount = clipURLs.count
            let doneBefore = clipsDone
            do {
                try await client.submitFlywheelContribution(contribution, clipURLs: clipURLs, progress: { [weak self] p in
                    Task { @MainActor in
                        guard let self, totalClips > 0 else { return }
                        self.uploadProgress = (Double(doneBefore) + p * Double(thisCount)) / Double(totalClips)
                    }
                })
                clipURLs.forEach { try? fileManager.removeItem(at: $0) }
                if !contribution.clips.isEmpty {
                    uploadedVideos.insert(contribution.videoId)
                    persistUploadedVideos()
                }
                // Flags appended to this contribution while it was uploading
                // weren't in what was sent — queue them as an event-only repeat.
                if let current = staged.first(where: { $0.id == contribution.id }),
                   current.flagEvents.count > contribution.flagEvents.count {
                    resent.append(eventOnlyRepeat(of: current,
                                                  events: Array(current.flagEvents.dropFirst(contribution.flagEvents.count))))
                }
                uploaded += 1
                clipsDone += thisCount
                uploadProgress = totalClips > 0 ? Double(clipsDone) / Double(totalClips) : 0
                print("✅ Flywheel: sent \(contribution.trigger.rawValue) data for video \(contribution.videoId.uuidString.prefix(8)) — \(thisCount) clip(s)")
            } catch {
                // Keep failed items for the next attempt (offline / unauthenticated).
                remaining.append(contribution)
                clipsDone += thisCount
                print("⚠️ Flywheel: upload failed (will retry): \(error.localizedDescription)")
            }
        }

        // Merge instead of overwrite: contributions staged while this drain's
        // uploads were in flight are in `staged` but not in the `jobs` snapshot
        // Failed items keep any flags added in flight (take the live copy).
        let drainedIds = Set(jobs.map { $0.contribution.id })
        let remainingIds = Set(remaining.map(\.id))
        staged = staged.filter { remainingIds.contains($0.id) }
            + resent
            + staged.filter { !drainedIds.contains($0.id) }
        pendingCount = staged.count
        persistIndex()

        if uploaded > 0 {
            lifetimeContributedCount += uploaded
            UserDefaults.standard.set(lifetimeContributedCount, forKey: lifetimeKey)
        }
        print("📤 Flywheel: drain complete — \(uploaded) sent, \(remaining.count) pending")
    }

    // MARK: - Clear

    /// Delete all staged contributions (clips + records). Used on opt-out or a
    /// manual "clear pending" in Settings.
    func clearPending() {
        discard(staged)
    }

    /// The videos were deleted from the library — drop everything staged or
    /// recorded for them.
    func discardContributions(for videoIds: Set<UUID>) {
        discard(staged.filter { videoIds.contains($0.videoId) })
        // An export in flight for one of them drops its clips on return.
        stagingVideoIds.subtract(videoIds)
        eventsAwaitingStage = eventsAwaitingStage.filter { !videoIds.contains($0.key) }
        uploadedVideos.subtract(videoIds)
        persistUploadedVideos()
        let reportPrefixes = videoIds.map { "\($0.uuidString)#" }
        reportedRallies = reportedRallies.filter { key in !reportPrefixes.contains { key.hasPrefix($0) } }
        persistReported()
    }

    private func discard(_ contributions: [FlywheelContribution]) {
        guard !contributions.isEmpty else { return }
        let ids = Set(contributions.map(\.id))
        for contribution in contributions {
            for clip in contribution.clips {
                try? fileManager.removeItem(at: stagingDirectory.appendingPathComponent(clip.fileName))
            }
        }
        staged.removeAll { ids.contains($0.id) }
        pendingCount = staged.count
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
        Task { await drainOnWiFi() }
    }

    /// Drain now if the phone is on Wi-Fi (or wired): clips are tens of MB
    /// each, too much for a cellular plan.
    func drainOnWiFi() async {
        guard NetworkMonitor.shared.isConnected, NetworkMonitor.shared.connectionType != .cellular else { return }
        await drain(using: SupabaseAPIClient.shared)
    }

    private func stage(videoId: UUID, rallyIndex: Int, segment: RallySegment,
                       trigger: FlywheelTrigger, reason: String?, originalURL: URL,
                       windows: [FlywheelClipWindow]) async {
        guard segment.endTime > segment.startTime, !windows.isEmpty else { return }

        let event = FlywheelFlagEvent(rallyIndex: rallyIndex, trigger: trigger.rawValue, reason: reason, at: Date())

        // Already staged for this video → just record the extra flag (the
        // clips cover every rally). No re-export.
        if let idx = staged.firstIndex(where: { $0.videoId == videoId }) {
            staged[idx].flagEvents.append(event)
            persistIndex()
            return
        }

        // Clips for this video are being exported by an earlier flag right
        // now — ride along with it instead of exporting a duplicate set.
        guard stagingVideoIds.insert(videoId).inserted else {
            eventsAwaitingStage[videoId, default: []].append(event)
            return
        }

        let id = UUID()
        let evidence = metadataStore.loadFrameEvidence(for: videoId).filter { e in
            windows.contains { e.time >= $0.start && e.time <= $0.end }
        }

        // Clips already on the server → stage an event-only repeat (no clips).
        let eventOnly = uploadedVideos.contains(videoId)
        let clips = eventOnly ? [] : await exportClips(from: originalURL, windows: windows, contributionId: id)

        // Removed from `stagingVideoIds` by discardContributions → the video
        // was deleted while we exported.
        guard stagingVideoIds.remove(videoId) != nil else {
            for clip in clips {
                try? fileManager.removeItem(at: stagingDirectory.appendingPathComponent(clip.fileName))
            }
            return
        }
        let queuedEvents = eventsAwaitingStage.removeValue(forKey: videoId) ?? []
        guard eventOnly || !clips.isEmpty else { return }

        let contribution = FlywheelContribution(
            id: id,
            videoId: videoId,
            rallyIndex: rallyIndex,
            startTime: segment.startTime,
            endTime: segment.endTime,
            trigger: trigger,
            userReason: reason,
            clips: clips,
            flagEvents: [event] + queuedEvents,
            evidence: evidence,
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

    // MARK: - Clips

    /// Each rally padded by `padding` either side, overlapping ones merged.
    nonisolated static func rallyWindows(_ segments: [RallySegment], padding: Double) -> [FlywheelClipWindow] {
        var windows: [FlywheelClipWindow] = []
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) where segment.endTime > segment.startTime {
            let start = max(0, segment.startTime - padding), end = segment.endTime + padding
            if let last = windows.last, start <= last.end {
                windows[windows.count - 1] = FlywheelClipWindow(start: last.start, end: max(last.end, end))
            } else {
                windows.append(FlywheelClipWindow(start: start, end: end))
            }
        }
        return windows
    }

    /// `count` stretches of `length` seconds spread evenly across a video
    /// `duration` long (the whole video when it's shorter than them all).
    nonisolated static func samples(of duration: Double, count: Int, length: Double) -> [FlywheelClipWindow] {
        guard duration > 0, count > 0 else { return [] }
        guard duration > Double(count) * length else { return [FlywheelClipWindow(start: 0, end: duration)] }
        let gap = (duration - Double(count) * length) / Double(count + 1)
        return (0..<count).map { i in
            let start = gap * Double(i + 1) + length * Double(i)
            return FlywheelClipWindow(start: start, end: start + length)
        }
    }

    /// Each window of the original as a 1080p .mp4 in the staging folder,
    /// named `{id}_clip_NN.mp4`. Windows that fail to export are left out
    /// (empty on failure).
    private func exportClips(from originalURL: URL, windows: [FlywheelClipWindow], contributionId: UUID) async -> [FlywheelClip] {
        let asset = AVURLAsset(url: originalURL)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            print("Flywheel: couldn't load video duration")
            return []
        }
        var clips: [FlywheelClip] = []
        for (i, window) in windows.enumerated() {
            let end = min(window.end, duration.seconds)
            guard end > window.start else { continue }
            // 1080p HEVC; a phone that can't encode HEVC keeps the original.
            guard let session = AVAssetExportSession(asset: asset, presetName: clipPreset)
                    ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { continue }
            session.timeRange = CMTimeRange(start: CMTime(seconds: window.start, preferredTimescale: 600),
                                            end: CMTime(seconds: end, preferredTimescale: 600))
            let name = "\(contributionId.uuidString)_clip_\(String(format: "%02d", i)).mp4"
            let url = stagingDirectory.appendingPathComponent(name)
            try? fileManager.removeItem(at: url)
            do {
                try await session.export(to: url, as: .mp4)
                clips.append(FlywheelClip(fileName: name, window: FlywheelClipWindow(start: window.start, end: end)))
            } catch {
                try? fileManager.removeItem(at: url)
                print("Flywheel: clip export failed at \(String(format: "%.1f", window.start))s: \(error)")
            }
        }
        return clips
    }

    /// A clipless copy of `contribution` carrying only `events` — sent when
    /// flags arrive after its clips already went up.
    private func eventOnlyRepeat(of contribution: FlywheelContribution, events: [FlywheelFlagEvent]) -> FlywheelContribution {
        FlywheelContribution(
            id: UUID(),
            videoId: contribution.videoId,
            rallyIndex: contribution.rallyIndex,
            startTime: contribution.startTime,
            endTime: contribution.endTime,
            trigger: contribution.trigger,
            userReason: contribution.userReason,
            clips: [],
            flagEvents: events,
            evidence: contribution.evidence,
            rallyConfidence: contribution.rallyConfidence,
            rallyQuality: contribution.rallyQuality,
            appVersion: contribution.appVersion,
            osVersion: contribution.osVersion,
            deviceModel: contribution.deviceModel,
            consentVersion: contribution.consentVersion,
            createdAt: Date()
        )
    }

    /// Delete staged clips no contribution references — left behind when the
    /// app died between exporting and recording the contribution — and the
    /// stills earlier versions staged.
    private func sweepUnreferencedFiles() {
        let referenced = Set(staged.flatMap { $0.clips.map(\.fileName) })
        guard let names = try? fileManager.contentsOfDirectory(atPath: stagingDirectory.path) else { return }
        for name in names where (name.hasSuffix(".mp4") || name.hasSuffix(".jpg")) && !referenced.contains(name) {
            try? fileManager.removeItem(at: stagingDirectory.appendingPathComponent(name))
        }
    }

    private func persistIndex() {
        persist(staged, to: indexURL, what: "index")
    }

    /// Returns false when an index file existed but couldn't be read (it's
    /// quarantined, and nothing on disk should be judged by the empty index).
    private func loadIndex() -> Bool {
        let existed = fileManager.fileExists(atPath: indexURL.path)
        let loaded = loadJSON([FlywheelContribution].self, from: indexURL)
        staged = loaded ?? []
        pendingCount = staged.count
        return loaded != nil || !existed
    }

    private func persistUploadedVideos() {
        persist(uploadedVideos, to: uploadedVideosURL, what: "uploaded videos")
    }

    private func persistReported() {
        persist(reportedRallies, to: reportedURL, what: "reported rallies")
    }

    private func persist<T: Encodable>(_ value: T, to url: URL, what: String) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Flywheel: failed to persist \(what): \(error)")
        }
    }

    /// Missing → nil. Unreadable → quarantined (so the next persist can't
    /// overwrite it) and nil.
    private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(T.self, from: Data(contentsOf: url))
        } catch {
            print("Flywheel: unreadable \(url.lastPathComponent): \(error)")
            StorageManager.quarantineCorruptFile(at: url)
            return nil
        }
    }
}
