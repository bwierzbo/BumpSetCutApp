import AVFoundation

// MARK: - Rally Player Cache

/// The rally player's sliding window of AVPlayers (one per rally URL) on top
/// of `LoopingPlayerPool`, plus the "current rally" and its play state.
/// In-rally looping lives in `RallyPlayerLifecycle` (it must stand down during
/// trim mode); the pool only rewinds a player that reaches the end of the file.
@MainActor
final class RallyPlayerCache {
    private(set) var currentPlayer: AVPlayer?
    private(set) var isPlaying: Bool = false

    private let pool = LoopingPlayerPool<URL>()
    private let maxCachedPlayers = 5  // Sliding window: current +/- 2

    // MARK: - Player Management

    /// Existing player for URL (nil if not preloaded).
    func getPlayer(for url: URL) -> AVPlayer? {
        pool.player(for: url)
    }

    func setCurrentPlayer(for url: URL) {
        // Pause all other players before switching (prevents audio bleeding)
        pool.activate(url, play: false)
        currentPlayer = pool.player(for: url, url: url)
    }

    // MARK: - Playback Control

    func play() {
        currentPlayer?.play()
        isPlaying = true
    }

    func pause() {
        currentPlayer?.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seek a specific player (by URL) to a given time
    func seek(url: URL, to time: CMTime) {
        pool.player(for: url)?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Seek a specific player and wait for completion
    func seekAsync(url: URL, to time: CMTime) async {
        guard let player = pool.player(for: url) else { return }
        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    // MARK: - Preloading

    func preloadPlayers(for urls: [URL]) {
        for url in urls {
            pool.player(for: url, url: url)
        }
    }

    /// Evict players outside the keep set to stay within maxCachedPlayers.
    /// `urlsToKeep` should include current +/- 2 rally URLs.
    func enforceCacheLimit(keeping urlsToKeep: Set<URL>) {
        pool.retain(window: urlsToKeep, limit: maxCachedPlayers)
    }

    /// Wait for the player to be buffered enough to play without stalling.
    func waitForPlayerReady(for url: URL, timeout: TimeInterval) async -> Bool {
        await pool.waitUntilReady(url, timeout: timeout)
    }

    // MARK: - Cleanup

    func cleanup() {
        pool.teardownAll()
        currentPlayer = nil
        isPlaying = false
    }
}
