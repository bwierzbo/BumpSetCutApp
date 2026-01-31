import AVFoundation
import Combine

// MARK: - Rally Player Cache

/// Manages AVPlayer instances for rally playback with preloading support
@MainActor
final class RallyPlayerCache: ObservableObject {
    @Published private(set) var currentPlayer: AVPlayer?
    @Published private(set) var isPlaying: Bool = false

    private var players: [URL: AVPlayer] = [:]
    private var notificationObservers: [URL: NSObjectProtocol] = [:]
    private var playerCreationOrder: [URL] = []
    // No limit - cache ALL rally videos for instant transitions

    // MARK: - Player Management

    /// Get existing player for URL (returns nil if not preloaded)
    func getPlayer(for url: URL) -> AVPlayer? {
        return players[url]
    }

    func getOrCreatePlayer(for url: URL) -> AVPlayer {
        if let existing = players[url] {
            return existing
        }

        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)

        // Setup loop notification - attach to playerItem for stable reference
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak player] _ in
            Task { @MainActor in
                player?.seek(to: .zero)
                player?.play()
            }
        }

        players[url] = player
        notificationObservers[url] = observer
        playerCreationOrder.append(url)

        return player
    }

    func setCurrentPlayer(for url: URL) {
        // Pause all other players before switching (prevents audio bleeding)
        pauseAllExcept(url: url)

        currentPlayer = getOrCreatePlayer(for: url)
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

    func playFromBeginning() {
        currentPlayer?.seek(to: .zero)
        currentPlayer?.play()
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: CMTime) {
        currentPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Seek a specific player (by URL) to a given time
    func seek(url: URL, to time: CMTime) {
        players[url]?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Seek a specific player and wait for completion
    func seekAsync(url: URL, to time: CMTime) async {
        guard let player = players[url] else { return }

        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                continuation.resume()
            }
        }
    }

    func seekAndPlay(to time: CMTime) {
        currentPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.play()
            }
        }
    }

    // MARK: - Preloading

    func preloadPlayers(for urls: [URL]) {
        for url in urls {
            _ = getOrCreatePlayer(for: url)
        }
    }

    func preloadAdjacentRallies(currentIndex: Int, urls: [URL]) {
        var urlsToPreload: [URL] = []

        // Preload next rally (most important - user likely to swipe forward)
        if currentIndex + 1 < urls.count {
            urlsToPreload.append(urls[currentIndex + 1])
        }

        // Preload previous rally
        if currentIndex > 0 {
            urlsToPreload.append(urls[currentIndex - 1])
        }

        preloadPlayers(for: urlsToPreload)
    }

    // MARK: - Buffer State

    /// Check if player is ready to play without buffering
    func isPlayerReady(for url: URL) -> Bool {
        guard let player = players[url],
              let item = player.currentItem else { return false }
        return item.status == .readyToPlay
    }

    /// Wait for player to be ready with aggressive buffering check (with timeout)
    func waitForPlayerReady(for url: URL, timeout: TimeInterval = 2.0) async -> Bool {
        guard let player = players[url],
              let item = player.currentItem else { return false }

        // Wait for status and buffer
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Check status is ready
            guard item.status == .readyToPlay else {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                continue
            }

            // Check we have buffered data
            guard item.isPlaybackLikelyToKeepUp else {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                continue
            }

            // Both conditions met - ready!
            return true
        }

        // Timeout - return current state
        return item.status == .readyToPlay && item.isPlaybackLikelyToKeepUp
    }

    // MARK: - Audio Management

    /// Pause all players except the specified URL (prevents audio bleeding)
    private func pauseAllExcept(url: URL) {
        for (playerURL, player) in players {
            if playerURL != url {
                player.pause()
            }
        }
    }

    /// Pause all cached players
    func pauseAll() {
        for player in players.values {
            player.pause()
        }
        isPlaying = false
    }

    // MARK: - Cleanup

    func removePlayer(for url: URL) {
        // Remove observer first while player item still exists
        if let observer = notificationObservers[url] {
            NotificationCenter.default.removeObserver(observer)
            notificationObservers.removeValue(forKey: url)
        }

        if let player = players[url] {
            player.pause()
            player.replaceCurrentItem(with: nil) // Release the player item
            players.removeValue(forKey: url)
        }

        playerCreationOrder.removeAll { $0 == url }
    }

    func cleanup() {
        // Remove observers first
        for observer in notificationObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        // Then clean up players
        for player in players.values {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        players.removeAll()

        playerCreationOrder.removeAll()
        currentPlayer = nil
        isPlaying = false
    }

    private func evictOldestPlayer() {
        guard let oldestURL = playerCreationOrder.first else { return }
        removePlayer(for: oldestURL)
    }
}
