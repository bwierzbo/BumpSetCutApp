import AVFoundation

// MARK: - Rally Player Lifecycle

/// Manages AVPlayer time observers for rally looping, seek operations,
/// and preloading of adjacent players in the sliding window.
@MainActor
final class RallyPlayerLifecycle {
    // MARK: - Looping State

    private var timeObserver: Any?
    private weak var timeObserverPlayer: AVPlayer?

    // MARK: - Rally Looping

    func setupLooping(player: AVPlayer, startTime: Double, endTime: Double,
                      isTrimmingMode: @escaping () -> Bool,
                      playerCache: RallyPlayerCache) {
        removeLooping()

        let endCMTime = CMTimeMakeWithSeconds(endTime, preferredTimescale: 600)
        let startCMTime = CMTimeMakeWithSeconds(startTime, preferredTimescale: 600)

        let interval = CMTimeMakeWithSeconds(0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let _ = self, !isTrimmingMode() else { return }
                if CMTimeCompare(time, endCMTime) >= 0 {
                    playerCache.currentPlayer?.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
        timeObserverPlayer = player
    }

    func removeLooping() {
        if let observer = timeObserver, let player = timeObserverPlayer {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        timeObserverPlayer = nil
    }

    // MARK: - Seek

    func seekToRallyStart(url: URL, startTime: Double, playerCache: RallyPlayerCache) {
        let cmTime = CMTimeMakeWithSeconds(startTime, preferredTimescale: 600)
        playerCache.seek(url: url, to: cmTime)
    }

    // MARK: - Preloading

    func preloadWindowedVideos(indices: [Int], urls: [URL], segments: [RallySegment],
                               playerCache: RallyPlayerCache, thumbnailCache: RallyThumbnailCache,
                               allURLs: [URL]) async {
        let windowURLs = indices.map { urls[$0] }

        playerCache.preloadPlayers(for: windowURLs)

        for index in indices {
            guard index < segments.count else { continue }
            let url = urls[index]
            let segment = segments[index]

            await playerCache.seekAsync(url: url, to: segment.startCMTime)
            let _ = await playerCache.waitForPlayerReady(for: url, timeout: 5.0)
        }

        thumbnailCache.preloadThumbnails(for: allURLs)
    }

    func preloadAdjacent(currentIndex: Int, indices: [Int], urls: [URL],
                         segments: [RallySegment], windowURLs: Set<URL>,
                         playerCache: RallyPlayerCache, thumbnailCache: RallyThumbnailCache,
                         visibleCardIndices: [Int]) async {
        let indexURLs = indices.map { urls[$0] }

        playerCache.preloadPlayers(for: indexURLs)
        playerCache.enforceCacheLimit(keeping: windowURLs)

        for index in indices where index != currentIndex {
            guard index < segments.count else { continue }
            let url = urls[index]
            let segment = segments[index]
            await playerCache.seekAsync(url: url, to: segment.startCMTime)
        }

        let urlsToPreload = visibleCardIndices
            .filter { $0 != currentIndex }
            .compactMap { index -> URL? in
                guard index < urls.count else { return nil }
                return urls[index]
            }
        thumbnailCache.preloadThumbnails(for: urlsToPreload)
    }
}
