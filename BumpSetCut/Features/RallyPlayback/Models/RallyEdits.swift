//
//  RallyEdits.swift
//  BumpSetCut
//
//  What a person did to a video's rallies: trims and framing, saved /
//  removed / favourited / posted, the game's points and set starts. All of
//  it is keyed by a rally's position in the list, so whatever changes the
//  list has to move it — the timeline editor (which knows each rally's id)
//  and deciding the rallies again under another net or camera (D-044),
//  where the new rallies are new and only their times say which is which.
//

import Foundation

struct RallyEdits {
    var trims: [Int: RallyTrimAdjustment]
    var selections: RallyReviewSelections
    var scoring: GameScoring?

    /// Positions a person did something to (a set start is not one: it belongs
    /// to the game, and moves by time).
    var editedIndices: Set<Int> {
        Set(trims.keys)
            .union(selections.saved)
            .union(selections.removed)
            .union(selections.favorited)
            .union(selections.posted)
            .union(scoring.map { Set($0.pointWinners.keys) } ?? [])
    }

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

// MARK: - Carrying edits to rallies decided again

/// Moves a video's edits from the rallies it had to the rallies it has after
/// they were decided again. A new rally is the old one when the two share at
/// least half of the longer one's time; each old rally goes to at most one
/// new rally and each new rally takes at most one, the pair sharing the most
/// time first. An edited rally with no such partner is left behind and
/// reported, never put on a rally that is mostly something else.
enum RallyEditCarryOver {

    struct Outcome {
        let edits: RallyEdits
        /// Old position → new position, for the rallies that were found again.
        let oldToNew: [Int: Int]
        /// Old positions that had an edit and were not found again, in order.
        let leftBehind: [Int]
        /// Old positions of rallies found again whose trimmed start and end
        /// could not be kept: at those times the new rally would play nothing.
        /// It has its own start and end instead, and the rest of its framing.
        let trimTimesDropped: [Int]
    }

    /// The part of the longer rally two rallies must share to be the same one.
    static let sharedPartOfLonger = 0.5

    static func pairs(from old: [RallySegment], to new: [RallySegment]) -> [Int: Int] {
        var candidates: [(old: Int, new: Int, shared: Double)] = []
        for (oldIndex, was) in old.enumerated() {
            for (newIndex, now) in new.enumerated() {
                let shared = min(was.endTime, now.endTime) - max(was.startTime, now.startTime)
                let longer = max(was.endTime - was.startTime, now.endTime - now.startTime)
                guard shared > 0, shared >= sharedPartOfLonger * longer else { continue }
                candidates.append((oldIndex, newIndex, shared))
            }
        }
        candidates.sort { ($1.shared, $0.old, $0.new) < ($0.shared, $1.old, $1.new) }

        var oldToNew: [Int: Int] = [:]
        var taken = Set<Int>()
        for candidate in candidates where oldToNew[candidate.old] == nil && !taken.contains(candidate.new) {
            oldToNew[candidate.old] = candidate.new
            taken.insert(candidate.new)
        }
        return oldToNew
    }

    static func carry(_ edits: RallyEdits, from old: [RallySegment], to new: [RallySegment]) -> Outcome {
        let oldToNew = pairs(from: old, to: new)
        var carried = edits.moved(by: oldToNew)

        // A trimmed edge is a time the person chose: it stays at that time
        // though the rally's own edge moved. An edge they left alone follows
        // the new rally. If that leaves nothing to play (the kept start is
        // at or past the end the new rally brought), neither time is kept.
        var trimTimesDropped: [Int] = []
        for (oldIndex, trim) in edits.trims {
            guard let newIndex = oldToNew[oldIndex] else { continue }
            let was = old[oldIndex], now = new[newIndex]
            let before = trim.before == 0 ? 0 : now.startTime - (was.startTime - trim.before)
            let after = trim.after == 0 ? 0 : (was.endTime + trim.after) - now.endTime
            if now.startTime - before < now.endTime + after {
                carried.trims[newIndex]?.before = before
                carried.trims[newIndex]?.after = after
            } else {
                carried.trims[newIndex]?.before = 0
                carried.trims[newIndex]?.after = 0
                trimTimesDropped.append(oldIndex)
            }
        }

        // A set starts at a moment in the game, whether or not its first
        // rally was found again: it goes to the first new rally that is not
        // wholly before that moment. The first rally starts a set anyway.
        if let breaks = edits.scoring?.setBreaks {
            carried.scoring?.setBreaks = Set(breaks.compactMap { oldIndex in
                guard old.indices.contains(oldIndex),
                      let newIndex = new.firstIndex(where: { $0.endTime > old[oldIndex].startTime }),
                      newIndex > 0 else { return nil }
                return newIndex
            })
        }

        return Outcome(edits: carried,
                       oldToNew: oldToNew,
                       leftBehind: edits.editedIndices.filter { oldToNew[$0] == nil }.sorted(),
                       trimTimesDropped: trimTimesDropped.sorted())
    }

    /// Puts `metadata` (the rallies decided again) in place of the video's
    /// saved rallies together with its edits moved onto them, as the one
    /// multi-file save the timeline editor uses, then points the library's
    /// favourite clips at their rallies' new positions. The outcome says what
    /// could not be carried.
    @MainActor
    @discardableResult
    static func install(_ metadata: ProcessingMetadata, metadataStore: MetadataStore,
                        mediaStore: MediaStore?) throws -> Outcome {
        let videoId = metadata.videoId
        let previous = try metadataStore.loadMetadata(for: videoId).rallySegments
        let outcome = carry(metadataStore.loadRallyEdits(for: videoId), from: previous, to: metadata.rallySegments)
        try metadataStore.saveTimelineEdit(metadata: metadata,
                                           trims: outcome.edits.trims,
                                           selections: outcome.edits.selections,
                                           scoring: outcome.edits.scoring)
        mediaStore?.remapFavoriteSourceIndices(sourceVideoId: videoId, oldToNew: outcome.oldToNew)
        return outcome
    }
}
