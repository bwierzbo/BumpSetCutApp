//
//  GameSetupViewModel.swift
//  BumpSetCut
//
//  Form state and validation for Game Review setup.
//

import Foundation

@MainActor
@Observable
final class GameSetupViewModel {
    // MARK: - Form State

    var firstServer: CourtSide = .near
    var scoringMode: ScoringMode = .rallyScoring
    var switchInterval: Int = 7
    var switchEnabled: Bool = true

    // MARK: - Resume State

    private(set) var existingReviewState: GameReviewState?
    private(set) var hasExistingReview: Bool = false

    // MARK: - Dependencies

    private let videoId: UUID
    private let metadataStore: MetadataStore

    init(videoId: UUID, metadataStore: MetadataStore? = nil) {
        self.videoId = videoId
        self.metadataStore = metadataStore ?? MetadataStore()
    }

    // MARK: - Load / Resume

    func loadExistingState() {
        existingReviewState = metadataStore.loadGameReview(for: videoId)
        hasExistingReview = existingReviewState != nil
        inferFirstServer()
    }

    /// Auto-detect first server from the first rally's ball size trend.
    private func inferFirstServer() {
        guard let metadata = try? metadataStore.loadMetadata(for: videoId),
              let firstSegment = metadata.rallySegments.first,
              let slope = firstSegment.ballSizeTrend,
              abs(slope) > 1e-6 else { return }
        firstServer = slope > 0 ? .far : .near
    }

    // MARK: - Build Setup

    func buildSetup() -> GameSetup {
        GameSetup(
            firstServer: firstServer,
            switchInterval: switchInterval,
            switchEnabled: switchEnabled,
            scoringMode: scoringMode
        )
    }
}
