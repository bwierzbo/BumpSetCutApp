import UIKit
import AVFoundation

// MARK: - Rally Thumbnail Cache

/// Manages thumbnail preloading for rally peek previews
@MainActor
final class RallyThumbnailCache {
    private var thumbnails: [URL: UIImage] = [:]
    private var preloadTasks: [URL: Task<UIImage?, Never>] = [:]
    private var thumbnailCreationOrder: [URL] = []
    private let maxCachedThumbnails = 8  // Support visible stack + preloading

    /// Rally segments for extracting at correct start times
    private var rallySegments: [RallySegment] = []

    // MARK: - Configuration

    /// Set rally segments to enable time-accurate thumbnail extraction
    func setRallySegments(_ segments: [RallySegment]) {
        self.rallySegments = segments
    }

    // MARK: - Thumbnail Access

    func getThumbnail(for url: URL) -> UIImage? {
        return thumbnails[url]
    }

    func getThumbnailAsync(for url: URL) async -> UIImage? {
        // Return cached if available
        if let cached = thumbnails[url] {
            return cached
        }

        // Check if preload task exists
        if let task = preloadTasks[url] {
            return await task.value
        }

        // Extract synchronously
        return await extractThumbnail(for: url)
    }

    // MARK: - Preloading

    func preloadThumbnails(for urls: [URL]) {
        for url in urls where thumbnails[url] == nil && preloadTasks[url] == nil {
            let task = Task { @MainActor in
                await extractThumbnail(for: url)
            }
            preloadTasks[url] = task
        }
    }

    func preloadAdjacentThumbnails(currentIndex: Int, urls: [URL]) {
        var urlsToPreload: [URL] = []

        // Preload next
        if currentIndex + 1 < urls.count {
            urlsToPreload.append(urls[currentIndex + 1])
        }

        // Preload previous
        if currentIndex > 0 {
            urlsToPreload.append(urls[currentIndex - 1])
        }

        preloadThumbnails(for: urlsToPreload)
    }

    // MARK: - Extraction

    @discardableResult
    private func extractThumbnail(for url: URL) async -> UIImage? {
        // Parse rally index from URL fragment (e.g., "#rally_0" -> 0)
        let rallyIndex = parseRallyIndex(from: url)
        let startTime = getRallyStartTime(for: rallyIndex)

        // Get base URL without fragment for actual extraction (URLComponents handles file URLs properly)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let baseURL = components?.url ?? url

        print("RallyThumbnailCache: Extracting thumbnail for rally \(rallyIndex ?? -1) at time \(startTime?.seconds ?? 0.1)s from \(baseURL.lastPathComponent)")

        // Use FrameExtractor with the rally's actual start time
        // Use high priority for longer timeout (seeking to specific time may take longer)
        do {
            let image = try await FrameExtractor.shared.extractFrame(
                from: baseURL,
                at: startTime,
                priority: .high
            )
            print("RallyThumbnailCache: ✅ Successfully extracted thumbnail for rally \(rallyIndex ?? -1)")
            cacheThumbnail(image, for: url)
            preloadTasks.removeValue(forKey: url)
            return image
        } catch {
            print("RallyThumbnailCache: ❌ Failed to extract thumbnail for rally \(rallyIndex ?? -1): \(error)")
            preloadTasks.removeValue(forKey: url)
            return nil
        }
    }

    /// Parse rally index from URL fragment (e.g., "#rally_0" -> 0)
    private func parseRallyIndex(from url: URL) -> Int? {
        guard let fragment = url.fragment,
              fragment.hasPrefix("rally_"),
              let indexString = fragment.components(separatedBy: "_").last,
              let index = Int(indexString) else {
            return nil
        }
        return index
    }

    /// Get rally start time for the given index
    private func getRallyStartTime(for index: Int?) -> CMTime? {
        guard let index = index,
              index >= 0,
              index < rallySegments.count else {
            return nil
        }
        return rallySegments[index].startCMTime
    }

    private func cacheThumbnail(_ image: UIImage, for url: URL) {
        // Track creation order only for new entries
        if thumbnails[url] == nil {
            thumbnailCreationOrder.append(url)
        }
        thumbnails[url] = image

        // Evict oldest if over limit (using creation order, not random)
        while thumbnails.count > maxCachedThumbnails, let oldest = thumbnailCreationOrder.first {
            thumbnails.removeValue(forKey: oldest)
            thumbnailCreationOrder.removeFirst()
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        for task in preloadTasks.values {
            task.cancel()
        }
        preloadTasks.removeAll()
        thumbnails.removeAll()
        thumbnailCreationOrder.removeAll()
    }
}
