//
//  RallyEdits.swift
//  BumpSetCut
//
//  What a person did to a video's rallies: trims and framing, saved /
//  removed / favourited / posted, the game's points and set starts. All of
//  it is keyed by a rally's position in the list, so whatever changes the
//  list has to move it: the timeline editor does, by each rally's id.
//  Rallies decided again (a reprocess, a recalibration) are other rallies,
//  and the edits start over (MediaStore.clearRallyEdits).
//

import Foundation

struct RallyEdits {
    var trims: [Int: RallyTrimAdjustment]
    var selections: RallyReviewSelections
    var scoring: GameScoring?

    /// Every edit at its rally's new position. An edit of a rally with no new
    /// position is dropped. `oldToNew` must not send two rallies to one place.
    func moved(by oldToNew: [Int: Int]) -> RallyEdits {
        var movedScoring = scoring
        movedScoring?.pointWinners = Dictionary(uniqueKeysWithValues:
            (scoring?.pointWinners ?? [:]).compactMap { old, winner in oldToNew[old].map { ($0, winner) } })
        movedScoring?.setBreaks = Set((scoring?.setBreaks ?? []).compactMap { oldToNew[$0] })
        return RallyEdits(
            trims: Dictionary(uniqueKeysWithValues:
                trims.compactMap { old, trim in oldToNew[old].map { ($0, trim) } }),
            selections: RallyReviewSelections(
                saved: Set(selections.saved.compactMap { oldToNew[$0] }),
                removed: Set(selections.removed.compactMap { oldToNew[$0] }),
                favorited: Set(selections.favorited.compactMap { oldToNew[$0] }),
                favoriteCollections: Dictionary(uniqueKeysWithValues:
                    selections.favoriteCollections.compactMap { old, name in oldToNew[old].map { ($0, name) } }),
                posted: Set(selections.posted.compactMap { oldToNew[$0] })
            ),
            scoring: movedScoring
        )
    }
}

extension MetadataStore {
    func loadRallyEdits(for videoId: UUID) -> RallyEdits {
        RallyEdits(trims: loadTrimAdjustments(for: videoId),
                   selections: loadReviewSelections(for: videoId),
                   scoring: loadGameScoring(for: videoId))
    }
}
