import UIKit
import AVFoundation

// MARK: - Rally Thumbnail Cache

/// Manages thumbnail preloading for rally peek previews
@MainActor
final class RallyThumbnailCache {
    private var thumbnails: [URL: UIImage] = [:]
    private var preloadTasks: [URL: Task<UIImage?, Never>] = [:]
    private var thumbnailCreationOrder: [URL] = []
    /// ~3.7 MB each at 1280 px. The overview grid fetches what scrolls into
    /// view again, so it doesn't need every rally held.
    private let maxCachedThumbnails = 30

    /// At most this many decodes at once. Each opens its own decoder on the
    /// (often 4K) video: a game's worth started together got the app killed
    /// for memory. Waiters for a card on screen go to the front.
    private let maxConcurrentExtractions = 2
    private var runningExtractions = 0
    private var waiting: [(url: URL, resume: CheckedContinuation<Void, Never>)] = []

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

        // A queued preload for it: move it to the front, then wait for it
        if let task = preloadTasks[url] {
            if let i = waiting.firstIndex(where: { $0.url == url }) {
                waiting.insert(waiting.remove(at: i), at: 0)
            }
            return await task.value
        }

        // On-demand fetch for a visible card — high priority so the fallback
        // frame appears quickly.
        return await extractThumbnail(for: url, priority: .high)
    }

    // MARK: - Preloading

    /// Preload thumbnails in the background. Defaults to `.low` priority so the
    /// bulk decode doesn't compete with the just-started AVPlayer (which caused
    /// choppy playback for the first few seconds). Callers that need a specific
    /// frame on screen immediately should use `getThumbnailAsync` instead.
    func preloadThumbnails(for urls: [URL], priority: ExtractionPriority = .low) {
        for url in urls where thumbnails[url] == nil && preloadTasks[url] == nil {
            let task = Task { @MainActor in
                await extractThumbnail(for: url, priority: priority)
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
    private func extractThumbnail(for url: URL, priority: ExtractionPriority = .high) async -> UIImage? {
        // Parse rally index from URL fragment (e.g., "#rally_0" -> 0)
        let rallyIndex = parseRallyIndex(from: url)
        let startTime = getRallyStartTime(for: rallyIndex)

        // Get base URL without fragment for actual extraction (URLComponents handles file URLs properly)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let baseURL = components?.url ?? url

        await acquireSlot(for: url, urgent: priority == .high)
        defer { releaseSlot() }
        // Closed while it waited (cleanup() emptied the cache): don't decode
        // or repopulate it.
        guard !Task.isCancelled else { return nil }

        print("RallyThumbnailCache: Extracting thumbnail for rally \(rallyIndex ?? -1) at time \(startTime?.seconds ?? 0.1)s from \(baseURL.lastPathComponent)")

        // Use FrameExtractor with the rally's actual start time
        // Use high priority for longer timeout (seeking to specific time may take longer)
        do {
            let image = try await FrameExtractor.shared.extractFrame(
                from: baseURL,
                at: startTime,
                priority: priority
            )
            guard !Task.isCancelled else { return nil }
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

    /// Wait for a decode slot. A freed slot is handed straight to the next
    /// waiter, so the running count only drops when nobody is waiting.
    private func acquireSlot(for url: URL, urgent: Bool) async {
        if runningExtractions < maxConcurrentExtractions {
            runningExtractions += 1
            return
        }
        await withCheckedContinuation { continuation in
            if urgent {
                waiting.insert((url, continuation), at: 0)
            } else {
                waiting.append((url, continuation))
            }
        }
    }

    private func releaseSlot() {
        if waiting.isEmpty {
            runningExtractions -= 1
        } else {
            waiting.removeFirst().resume.resume()
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
        // Wake every waiter (each now holds a slot it releases): their tasks
        // are cancelled, so they return without decoding.
        let woken = waiting
        waiting.removeAll()
        runningExtractions += woken.count
        woken.forEach { $0.resume.resume() }
        thumbnails.removeAll()
        thumbnailCreationOrder.removeAll()
    }
}
