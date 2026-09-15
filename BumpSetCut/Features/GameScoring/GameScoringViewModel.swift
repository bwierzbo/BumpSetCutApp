//
//  GameScoringViewModel.swift
//  BumpSetCut
//
//  Drives the Game Scoring viewer: steps through detected rallies on the
//  original video, records who won each point, and keeps the running
//  scoreboard. Every change persists immediately to the GameScoring sidecar.
//

import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class GameScoringViewModel {

    // MARK: - Input

    let videoMetadata: VideoMetadata
    let metadataStore = MetadataStore()

    // MARK: - State

    private(set) var segments: [RallySegment] = []
    private(set) var trimAdjustments: [Int: RallyTrimAdjustment] = [:]
    private(set) var scoring = GameScoring()
    private(set) var isLoaded = false
    private(set) var loadFailed = false
    private(set) var videoDuration: Double = 0
    /// First open for this video: collect team names/colors before scoring.
    var needsSetup = false
    var currentIndex = 0
    var isPlaying = false

    let player = AVPlayer()
    private var boundaryObserver: Any?

    private var videoId: UUID {
        videoMetadata.originalVideoId ?? videoMetadata.id
    }

    init(videoMetadata: VideoMetadata) {
        self.videoMetadata = videoMetadata
    }

    // MARK: - Derived

    var rallyCount: Int { segments.count }
    var scoredCount: Int { scoring.pointWinners.count }

    /// Scoreboard during each rally (before its point is awarded).
    var states: [GameScoreState] {
        GameScoreEngine.states(for: scoring, rallyCount: rallyCount)
    }

    var currentState: GameScoreState {
        let all = states
        guard currentIndex < all.count else {
            return GameScoreEngine.finalState(for: scoring, rallyCount: rallyCount)
        }
        return all[currentIndex]
    }

    var finalState: GameScoreState {
        GameScoreEngine.finalState(for: scoring, rallyCount: rallyCount)
    }

    var currentWinner: GamePointWinner? { scoring.pointWinners[currentIndex] }
    var currentStartsNewSet: Bool { scoring.setBreaks.contains(currentIndex) }
    var showsSets: Bool { !scoring.setBreaks.isEmpty }

    // MARK: - Loading

    func load() async {
        do {
            let metadata = try metadataStore.loadMetadata(for: videoId)
            segments = metadata.rallySegments
            trimAdjustments = metadataStore.loadTrimAdjustments(for: videoId)

            if let saved = metadataStore.loadGameScoring(for: videoId) {
                scoring = saved
            } else {
                needsSetup = true
            }

            let asset = AVURLAsset(url: videoMetadata.originalURL)
            videoDuration = try await CMTimeGetSeconds(asset.load(.duration))

            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.automaticallyWaitsToMinimizeStalling = false

            guard !segments.isEmpty else {
                loadFailed = true
                return
            }
            isLoaded = true
            playCurrentRally()
        } catch {
            loadFailed = true
        }
    }

    func cleanup() {
        removeBoundaryObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Playback

    /// Trim-aware bounds for a rally within the original video.
    func effectiveStart(for index: Int) -> Double {
        guard index < segments.count else { return 0 }
        return max(0, segments[index].startTime - (trimAdjustments[index]?.before ?? 0))
    }

    func effectiveEnd(for index: Int) -> Double {
        guard index < segments.count else { return 0 }
        let maxEnd = videoDuration > 0 ? videoDuration : segments[index].endTime
        return min(maxEnd, segments[index].endTime + (trimAdjustments[index]?.after ?? 0))
    }

    func playCurrentRally() {
        guard currentIndex < segments.count else { return }
        removeBoundaryObserver()

        let start = effectiveStart(for: currentIndex)
        let end = effectiveEnd(for: currentIndex)
        guard end > start else { return }

        player.seek(
            to: CMTime(seconds: start, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
        let boundary = CMTime(seconds: end, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundary)], queue: .main
        ) { [weak self] in
            Task { @MainActor in
                self?.player.pause()
                self?.isPlaying = false
            }
        }
        player.play()
        isPlaying = true
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // At/past the rally end: replay from its start.
            let end = effectiveEnd(for: currentIndex)
            if CMTimeGetSeconds(player.currentTime()) >= end - 0.05 {
                playCurrentRally()
            } else {
                player.play()
                isPlaying = true
            }
        }
    }

    private func removeBoundaryObserver() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
    }

    // MARK: - Navigation

    func goTo(index: Int) {
        guard index >= 0, index < segments.count else { return }
        currentIndex = index
        playCurrentRally()
    }

    func goNext() { goTo(index: currentIndex + 1) }
    func goPrevious() { goTo(index: currentIndex - 1) }

    // MARK: - Scoring

    /// Record the current rally's winner and advance to the next rally.
    func assign(_ winner: GamePointWinner) {
        scoring.pointWinners[currentIndex] = winner
        persist()
        if currentIndex + 1 < segments.count {
            goNext()
        }
    }

    /// Clear the current rally's point (no score change — e.g. a replayed point).
    func clearCurrentPoint() {
        scoring.pointWinners.removeValue(forKey: currentIndex)
        persist()
    }

    /// Toggle "this rally starts a new set" for the current rally.
    func toggleSetBreak() {
        guard currentIndex > 0 else { return }
        if scoring.setBreaks.contains(currentIndex) {
            scoring.setBreaks.remove(currentIndex)
        } else {
            scoring.setBreaks.insert(currentIndex)
        }
        persist()
    }

    func saveTeams(teamA: GameTeam, teamB: GameTeam) {
        scoring.teamA = teamA
        scoring.teamB = teamB
        needsSetup = false
        persist()
    }

    private func persist() {
        try? metadataStore.saveGameScoring(scoring, for: videoId)
    }

    // MARK: - Export Inputs

    /// The full game as stitch clips (every rally, trim-aware, in order) with
    /// the scoreboard state shown during each.
    func exportClips() -> [VideoExporter.StitchClip] {
        segments.indices.map { index in
            VideoExporter.StitchClip(
                url: videoMetadata.originalURL,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: effectiveStart(for: index), preferredTimescale: 600),
                    end: CMTime(seconds: effectiveEnd(for: index), preferredTimescale: 600)
                )
            )
        }
    }
}
