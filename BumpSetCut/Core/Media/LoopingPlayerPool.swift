//
//  LoopingPlayerPool.swift
//  BumpSetCut
//
//  One owner for the keyed, looping AVPlayers behind every swipeable video
//  surface (rally player, share carousel, feed cards, favorites feed, press-to-
//  play previews). Each player loops on its own: at the end of the item, and —
//  when a loop end is set — at that boundary inside the file, back to its loop
//  start. Teardown removes every observer from the player that added it before
//  releasing the item, so evicted players can't leak or fire late.
//

import AVFoundation
import Observation

@MainActor
@Observable
final class LoopingPlayerPool<Key: Hashable & Sendable> {

    /// Live players by key. Observable so views re-render when one is created
    /// or evicted.
    private(set) var players: [Key: AVPlayer] = [:]

    @ObservationIgnored private var loops: [Key: Loop] = [:]
    /// Creation order, oldest first — eviction under a limit drops oldest first.
    @ObservationIgnored private var creationOrder: [Key] = []
    @ObservationIgnored private let isMuted: Bool
    @ObservationIgnored private let waitsToMinimizeStalling: Bool

    private struct Loop {
        var start: CMTime
        let endObserver: NSObjectProtocol
        var boundaryObserver: Any?
    }

    init(isMuted: Bool = false, automaticallyWaitsToMinimizeStalling: Bool = true) {
        self.isMuted = isMuted
        self.waitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
    }

    // MARK: - Players

    /// The existing player for `key`, if any.
    func player(for key: Key) -> AVPlayer? {
        players[key]
    }

    /// The player for `key`, created (paused, at `loopStart`) when missing.
    /// An existing player is returned as-is; use `setLoop` to change its range.
    @discardableResult
    func player(for key: Key, url: URL, loopStart: CMTime = .zero, loopEnd: CMTime? = nil) -> AVPlayer {
        if let existing = players[key] { return existing }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = isMuted
        player.automaticallyWaitsToMinimizeStalling = waitsToMinimizeStalling

        let endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak player] _ in
            // queue: .main above — this is the main actor.
            MainActor.assumeIsolated {
                guard let player, let start = self?.loops[key]?.start else { return }
                Self.restart(player, at: start)
            }
        }
        loops[key] = Loop(start: loopStart, endObserver: endObserver)
        players[key] = player
        creationOrder.append(key)

        if loopStart != .zero {
            player.seek(to: loopStart, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        setLoop(for: key, start: loopStart, end: loopEnd)
        return player
    }

    /// Loop `key`'s player over `start..<end`. With no `end` it plays to the
    /// end of the file before returning to `start`. Does not seek.
    func setLoop(for key: Key, start: CMTime, end: CMTime?) {
        guard let player = players[key], var loop = loops[key] else { return }
        if let boundary = loop.boundaryObserver {
            player.removeTimeObserver(boundary)
        }
        loop.start = start
        loop.boundaryObserver = end.map { end in
            player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak player] in
                MainActor.assumeIsolated {
                    guard let player else { return }
                    Self.restart(player, at: start)
                }
            }
        }
        loops[key] = loop
    }

    private static func restart(_ player: AVPlayer, at start: CMTime) {
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    // MARK: - Playback

    /// Pause every player except `key`'s, which plays when `play` is true.
    func activate(_ key: Key, play: Bool = true) {
        for (other, player) in players where other != key {
            player.pause()
        }
        if play { players[key]?.play() }
    }

    func pauseAll() {
        for player in players.values { player.pause() }
    }

    // MARK: - Readiness

    /// Wait (KVO, no polling) until `key`'s item is ready and likely to keep
    /// up, it fails, or `timeout` passes. Returns whether it became ready.
    func waitUntilReady(_ key: Key, timeout: TimeInterval) async -> Bool {
        guard let item = players[key]?.currentItem else { return false }
        func isReady() -> Bool { item.status == .readyToPlay && item.isPlaybackLikelyToKeepUp }
        if isReady() { return true }

        let readiness = AsyncStream<Bool> { continuation in
            let check: @Sendable () -> Void = {
                if item.status == .readyToPlay && item.isPlaybackLikelyToKeepUp {
                    continuation.yield(true)
                    continuation.finish()
                } else if item.status == .failed {
                    continuation.yield(false)
                    continuation.finish()
                }
            }
            let status = item.observe(\.status, options: [.new]) { _, _ in check() }
            let buffer = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { _, _ in check() }
            let timer = Task {
                try? await Task.sleep(for: .seconds(timeout))
                continuation.yield(item.status == .readyToPlay && item.isPlaybackLikelyToKeepUp)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                status.invalidate()
                buffer.invalidate()
                timer.cancel()
            }
            // State may have changed between the fast path and observer setup.
            check()
        }
        for await ready in readiness { return ready }
        return isReady()
    }

    // MARK: - Eviction

    /// Tear down players whose key is outside `window`, oldest first, until at
    /// most `limit` remain (0 = drop everything outside the window).
    func retain(window: Set<Key>, limit: Int = 0) {
        for key in creationOrder where !window.contains(key) {
            guard players.count > limit else { break }
            teardown(key)
        }
    }

    func teardown(_ key: Key) {
        guard let player = players.removeValue(forKey: key) else { return }
        if let loop = loops.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(loop.endObserver)
            if let boundary = loop.boundaryObserver {
                player.removeTimeObserver(boundary)
            }
        }
        creationOrder.removeAll { $0 == key }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func teardownAll() {
        for key in creationOrder { teardown(key) }
    }
}
