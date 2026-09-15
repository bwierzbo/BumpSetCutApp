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

// MARK: - Share Source

/// What is being posted: rallies clipped from a source video at upload time,
/// or an already-exported file (a stitched highlight reel) uploaded as-is —
/// its watermark decision was made at stitch time.
enum ShareSource {
    case rallies
    case preparedFile(url: URL, duration: Double, clipCount: Int, title: String)
}

// MARK: - View Model

@MainActor
@Observable
final class ShareRallyViewModel {
    var caption: String = ""
    var hideLikes: Bool = false
    var pickedLocation: PickedLocation?
    var selectedPage: Int
    var postAllSaved: Bool
    private(set) var state: ShareState = .idle

    // Poll
    var includePoll: Bool = false
    var pollQuestion: String = ""
    var pollOptions: [String] = ["", ""]

    let source: ShareSource
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

    // MARK: - Poll Helpers

    var isPollValid: Bool {
        guard includePoll else { return true }
        let trimmedQuestion = pollQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyOptions = pollOptions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !trimmedQuestion.isEmpty && nonEmptyOptions.count >= 2
    }

    func addPollOption() {
        guard pollOptions.count < 5 else { return }
        pollOptions.append("")
    }

    func removePollOption(at index: Int) {
        guard pollOptions.count > 2 else { return }
        pollOptions.remove(at: index)
    }

    // MARK: - Init

    init(originalVideoURL: URL, rallyVideoURLs: [URL], savedRallyIndices: [Int],
         initialPage: Int, thumbnailCache: RallyThumbnailCache, videoId: UUID,
         rallyInfo: [Int: RallyShareInfo], postAllSaved: Bool = false,
         apiClient: (any APIClient)? = nil) {
        self.source = .rallies
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

    /// Post an already-exported file (stitched highlight reel) as one post.
    /// No per-rally clipping happens — the file uploads as-is.
    init(preparedFileURL: URL, duration: Double, clipCount: Int, title: String,
         apiClient: (any APIClient)? = nil) {
        self.source = .preparedFile(url: preparedFileURL, duration: duration, clipCount: clipCount, title: title)
        self.originalVideoURL = preparedFileURL
        self.rallyVideoURLs = []
        self.savedRallyIndices = []
        self.selectedPage = 0
        self.thumbnailCache = RallyThumbnailCache()
        self.videoId = UUID()
        self.rallyInfo = [:]
        self.postAllSaved = false
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    // MARK: - Actions

    private let maxDurationSeconds: Double = 60
    /// Reels are longer-form by design, but still capped.
    static let maxReelDurationSeconds: Double = 300

    var currentDuration: Double? {
        guard let info = currentShareInfo else { return nil }
        return info.endTime - info.startTime
    }

    var isTooLong: Bool {
        guard let duration = currentDuration else { return false }
        return duration > maxDurationSeconds
    }

    var isReelTooLong: Bool {
        guard case .preparedFile(_, let duration, _, _) = source else { return false }
        return duration > Self.maxReelDurationSeconds
    }

    func upload() {
        guard state == .idle else { return }
        if case .preparedFile(let url, let duration, let clipCount, _) = source {
            if isReelTooLong {
                state = .failed("Highlight reels must be under 5 minutes")
                return
            }
            startPreparedFileUpload(url: url, duration: duration, clipCount: clipCount)
            return
        }
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
        // Re-enter through upload() so a failed batch retries the batch,
        // not just the currently selected rally
        state = .idle
        upload()
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
                    rallyMetadata: metadata,
                    locationName: pickedLocation?.name,
                    latitude: pickedLocation?.latitude,
                    longitude: pickedLocation?.longitude
                )

                var highlight: Highlight = try await apiClient.request(.createHighlight(upload))

                if includePoll {
                    let poll = try await createPollForHighlight(highlightId: highlight.id)
                    highlight.poll = poll
                }

                state = .complete(highlight)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(Self.uploadErrorMessage(for: error))
            }
        }
    }

    // MARK: - Prepared File Upload (Highlight Reel)

    /// Upload an already-stitched file as one post. The caller owns the temp
    /// file (it is NOT deleted here — the export sheet cleans it up on dismiss).
    private func startPreparedFileUpload(url: URL, duration: Double, clipCount: Int) {
        uploadTask = Task {
            state = .uploading(progress: 0)

            do {
                let uploadURL = try await apiClient.upload(
                    fileURL: url,
                    to: .createUploadURL
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.state = .uploading(progress: progress)
                    }
                }

                try Task.checkCancellation()
                state = .processing

                let userId = try await SupabaseConfig.client.auth.session.user.id.uuidString.lowercased()
                let upload = HighlightUpload(
                    authorId: userId,
                    muxPlaybackId: uploadURL.absoluteString,
                    caption: caption.isEmpty ? nil : caption,
                    tags: extractedTags,
                    hideLikes: hideLikes,
                    localVideoId: nil,
                    localRallyIndex: nil,
                    rallyMetadata: RallyHighlightMetadata(
                        duration: duration, confidence: 1.0, quality: 1.0, detectionCount: clipCount
                    ),
                    locationName: pickedLocation?.name,
                    latitude: pickedLocation?.latitude,
                    longitude: pickedLocation?.longitude
                )

                var highlight: Highlight = try await apiClient.request(.createHighlight(upload))

                if includePoll {
                    let poll = try await createPollForHighlight(highlightId: highlight.id)
                    highlight.poll = poll
                }

                state = .complete(highlight)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(Self.uploadErrorMessage(for: error))
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
                    rallyMetadata: firstMetadata,
                    locationName: pickedLocation?.name,
                    latitude: pickedLocation?.latitude,
                    longitude: pickedLocation?.longitude
                )

                var highlight: Highlight = try await apiClient.request(.createHighlight(upload))

                if includePoll {
                    let poll = try await createPollForHighlight(highlightId: highlight.id)
                    highlight.poll = poll
                }

                state = .complete(highlight)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(Self.uploadErrorMessage(for: error))
            }
        }
    }

    // MARK: - Error Mapping

    /// Turn a raw upload error into an actionable, user-facing message so the retry
    /// screen tells people *how* to fix it (connection vs. sign-in vs. server).
    static func uploadErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "No internet connection. Check your connection and try again."
            case .timedOut:
                return "The upload timed out. Check your connection and try again."
            default:
                break
            }
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized:
                return "Your session expired. Please sign in again."
            case .networkUnavailable:
                return "No internet connection. Check your connection and try again."
            case .rateLimited:
                return "Too many requests. Please wait a moment and try again."
            case .serverError:
                return "Something went wrong on our end. Please try again."
            default:
                break
            }
        }
        return "Upload failed. Please try again."
    }

    // MARK: - Poll Creation

    private func createPollForHighlight(highlightId: String) async throws -> Poll {
        let upload = PollUpload(highlightId: highlightId, question: pollQuestion.trimmingCharacters(in: .whitespacesAndNewlines))
        let poll: Poll = try await apiClient.request(.createPoll(upload))

        let optionUploads = pollOptions.enumerated().compactMap { index, text -> PollOptionUpload? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return PollOptionUpload(pollId: poll.id, text: trimmed, sortOrder: index)
        }

        let options: [PollOption] = try await apiClient.request(.createPollOptions(pollId: poll.id, options: optionUploads))
        var completePoll = poll
        completePoll.options = options.sorted { $0.sortOrder < $1.sortOrder }
        return completePoll
    }

    /// Export just the rally time range from the source video.
    /// Uses passthrough when possible; falls back to re-encoding when watermark is needed.
    private func exportRallyClip(asset: AVAsset, startTime: CMTime, endTime: CMTime, rallyIndex: Int) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("share_rally_\(rallyIndex)_\(UUID().uuidString).mp4")

        let timeRange = CMTimeRange(start: startTime, end: endTime)
        let addWatermark = SubscriptionService.shared.shouldAddWatermark

        return try await VideoExporter().exportClip(
            asset: asset,
            timeRange: timeRange,
            to: outURL,
            addWatermark: addWatermark
        )
    }
}
