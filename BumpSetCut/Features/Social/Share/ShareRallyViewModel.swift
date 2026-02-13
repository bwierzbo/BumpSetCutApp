//
//  ShareRallyViewModel.swift
//  BumpSetCut
//
//  Manages the rally-to-highlight upload flow.
//

import Foundation
import AVFoundation
import Observation
import Supabase

// MARK: - Share State

enum ShareState: Equatable {
    case idle
    case uploading(progress: Double)
    case processing
    case complete(Highlight)
    case failed(String)

    static func == (lhs: ShareState, rhs: ShareState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.uploading(let a), .uploading(let b)): return a == b
        case (.processing, .processing): return true
        case (.complete(let a), .complete(let b)): return a.id == b.id
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Rally Share Info

struct RallyShareInfo {
    let startTime: Double
    let endTime: Double
    let metadata: RallyHighlightMetadata
}

// MARK: - View Model

@MainActor
@Observable
final class ShareRallyViewModel {
    var caption: String = ""
    var hideLikes: Bool = false
    var selectedPage: Int
    var postAllSaved: Bool
    private(set) var state: ShareState = .idle

    let originalVideoURL: URL
    let rallyVideoURLs: [URL]
    let savedRallyIndices: [Int]
    let thumbnailCache: RallyThumbnailCache
    let videoId: UUID
    let rallyInfo: [Int: RallyShareInfo]

    private let apiClient: any APIClient
    private var uploadTask: Task<Void, Never>?

    // MARK: - Current Selection

    var currentRallyIndex: Int {
        guard selectedPage < savedRallyIndices.count else { return 0 }
        return savedRallyIndices[selectedPage]
    }

    var currentShareInfo: RallyShareInfo? {
        rallyInfo[currentRallyIndex]
    }

    var currentMetadata: RallyHighlightMetadata {
        rallyInfo[currentRallyIndex]?.metadata
            ?? RallyHighlightMetadata(duration: 0, confidence: 0, quality: 0, detectionCount: 0)
    }

    /// Total duration of all rallies that will be posted.
    var totalDuration: Double {
        if postAllSaved {
            return savedRallyIndices.compactMap { rallyInfo[$0] }.reduce(0) { $0 + ($1.endTime - $1.startTime) }
        }
        return currentDuration ?? 0
    }

    /// Number of rallies that will be posted.
    var postCount: Int {
        postAllSaved ? savedRallyIndices.count : 1
    }

    // MARK: - Hashtag Extraction

    var extractedTags: [String] {
        let pattern = #"#(\w+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(caption.startIndex..., in: caption)
        return regex.matches(in: caption, range: range).compactMap { match in
            guard let tagRange = Range(match.range(at: 1), in: caption) else { return nil }
            return String(caption[tagRange]).lowercased()
        }
    }

    // MARK: - Init

    init(originalVideoURL: URL, rallyVideoURLs: [URL], savedRallyIndices: [Int],
         initialPage: Int, thumbnailCache: RallyThumbnailCache, videoId: UUID,
         rallyInfo: [Int: RallyShareInfo], postAllSaved: Bool = false,
         apiClient: (any APIClient)? = nil) {
        self.originalVideoURL = originalVideoURL
        self.rallyVideoURLs = rallyVideoURLs
        self.savedRallyIndices = savedRallyIndices
        self.selectedPage = initialPage
        self.thumbnailCache = thumbnailCache
        self.videoId = videoId
        self.rallyInfo = rallyInfo
        self.postAllSaved = postAllSaved
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    // MARK: - Actions

    private let maxDurationSeconds: Double = 60

    var currentDuration: Double? {
        guard let info = currentShareInfo else { return nil }
        return info.endTime - info.startTime
    }

    var isTooLong: Bool {
        guard let duration = currentDuration else { return false }
        return duration > maxDurationSeconds
    }

    func upload() {
        guard state == .idle else { return }
        if postAllSaved {
            startBatchUpload()
        } else {
            if isTooLong {
                state = .failed("Rally must be under 1 minute to share")
                return
            }
            startUpload()
        }
    }

    func retry() {
        state = .idle
        startUpload()
    }

    func cancel() {
        uploadTask?.cancel()
        uploadTask = nil
        state = .idle
    }

    private func startUpload() {
        uploadTask = Task {
            state = .uploading(progress: 0)

            do {
                let rallyIndex = currentRallyIndex
                let metadata = currentMetadata

                guard let shareInfo = currentShareInfo else {
                    state = .failed("Rally info not available")
                    return
                }

                // Step 1: Export just the rally segment (a few seconds, not the whole video)
                let asset = AVURLAsset(url: originalVideoURL)
                let startCM = CMTime(seconds: shareInfo.startTime, preferredTimescale: 600)
                let endCM = CMTime(seconds: shareInfo.endTime, preferredTimescale: 600)
                let clipURL = try await exportRallyClip(
                    asset: asset,
                    startTime: startCM,
                    endTime: endCM,
                    rallyIndex: rallyIndex
                )

                try Task.checkCancellation()

                // Step 2: Upload the small clip (real byte-level progress via URLSession delegate)
                let uploadURL = try await apiClient.upload(
                    fileURL: clipURL,
                    to: .createUploadURL
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.state = .uploading(progress: progress)
                    }
                }

                // Clean up temp clip
                try? FileManager.default.removeItem(at: clipURL)

                try Task.checkCancellation()
                state = .processing

                // Step 3: Create highlight record
                let userId = try await SupabaseConfig.client.auth.session.user.id.uuidString.lowercased()
                let upload = HighlightUpload(
                    authorId: userId,
                    muxPlaybackId: uploadURL.absoluteString,
                    caption: caption.isEmpty ? nil : caption,
                    tags: extractedTags,
                    hideLikes: hideLikes,
                    localVideoId: videoId,
                    localRallyIndex: rallyIndex,
                    rallyMetadata: metadata
                )

                let highlight: Highlight = try await apiClient.request(.createHighlight(upload))
                state = .complete(highlight)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Batch Upload (Multi-Rally Carousel)

    private func startBatchUpload() {
        uploadTask = Task {
            state = .uploading(progress: 0)

            do {
                let indicesToUpload = savedRallyIndices
                let totalCount = Double(indicesToUpload.count)
                var uploadedURLs: [String] = []
                var clipURLsToClean: [URL] = []

                let asset = AVURLAsset(url: originalVideoURL)

                // Export and upload each rally
                for (i, rallyIndex) in indicesToUpload.enumerated() {
                    try Task.checkCancellation()

                    guard let info = rallyInfo[rallyIndex] else { continue }
                    let startCM = CMTime(seconds: info.startTime, preferredTimescale: 600)
                    let endCM = CMTime(seconds: info.endTime, preferredTimescale: 600)

                    let clipURL = try await exportRallyClip(
                        asset: asset, startTime: startCM, endTime: endCM, rallyIndex: rallyIndex
                    )
                    clipURLsToClean.append(clipURL)

                    try Task.checkCancellation()

                    // Upload with progress scoped to this rally's portion
                    let baseProgress = Double(i) / totalCount
                    let uploadURL = try await apiClient.upload(
                        fileURL: clipURL,
                        to: .createUploadURL
                    ) { [weak self] progress in
                        Task { @MainActor in
                            let overallProgress = baseProgress + (progress / totalCount)
                            self?.state = .uploading(progress: overallProgress)
                        }
                    }

                    uploadedURLs.append(uploadURL.absoluteString)
                }

                // Clean up temp clips
                for url in clipURLsToClean {
                    try? FileManager.default.removeItem(at: url)
                }

                try Task.checkCancellation()
                state = .processing

                // Create a single highlight with all video URLs
                let userId = try await SupabaseConfig.client.auth.session.user.id.uuidString.lowercased()
                let firstIndex = indicesToUpload.first ?? 0
                let firstMetadata = rallyInfo[firstIndex]?.metadata
                    ?? RallyHighlightMetadata(duration: 0, confidence: 0, quality: 0, detectionCount: 0)

                let upload = HighlightUpload(
                    authorId: userId,
                    muxPlaybackId: uploadedURLs.first ?? "",
                    caption: caption.isEmpty ? nil : caption,
                    tags: extractedTags,
                    hideLikes: hideLikes,
                    videoUrls: uploadedURLs.count > 1 ? uploadedURLs : nil,
                    localVideoId: videoId,
                    localRallyIndex: nil,
                    rallyMetadata: firstMetadata
                )

                let highlight: Highlight = try await apiClient.request(.createHighlight(upload))
                state = .complete(highlight)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Export just the rally time range from the source video using passthrough (no re-encoding).
    private func exportRallyClip(asset: AVAsset, startTime: CMTime, endTime: CMTime, rallyIndex: Int) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("share_rally_\(rallyIndex)_\(UUID().uuidString).mp4")

        let timeRange = CMTimeRange(start: startTime, end: endTime)

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "ShareRally", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"])
        }

        exporter.timeRange = timeRange
        exporter.outputURL = outURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        if #available(iOS 18.0, *) {
            try await exporter.export(to: outURL, as: .mp4)
        } else {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously { cont.resume() }
            }
            if exporter.status == .failed {
                throw exporter.error ?? NSError(domain: "ShareRally", code: 2, userInfo: [NSLocalizedDescriptionKey: "Export failed"])
            }
        }

        return outURL
    }
}
