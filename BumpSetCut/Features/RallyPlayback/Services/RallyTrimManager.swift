import Foundation
import Observation

// MARK: - Rally Trim Manager

/// Manages trim adjustments for rally segments: enter/confirm/cancel trim mode,
/// compute effective start/end times, and persist adjustments to disk.
@MainActor
@Observable
final class RallyTrimManager {
    // MARK: - State

    private(set) var isTrimmingMode: Bool = false
    var trimAdjustments: [Int: RallyTrimAdjustment] = [:]
    var currentTrimBefore: Double = 0.0
    var currentTrimAfter: Double = 0.0

    // MARK: - Effective Rally Times

    func effectiveStartTime(for rallyIndex: Int, segments: [RallySegment]) -> Double {
        guard rallyIndex < segments.count else { return 0 }
        let segment = segments[rallyIndex]
        let adj = trimAdjustments[rallyIndex]
        return max(0, segment.startTime - (adj?.before ?? 0))
    }

    func effectiveEndTime(for rallyIndex: Int, segments: [RallySegment], videoDuration: Double) -> Double {
        guard rallyIndex < segments.count else { return 0 }
        let segment = segments[rallyIndex]
        let adj = trimAdjustments[rallyIndex]
        let maxEnd = videoDuration > 0 ? videoDuration : segment.endTime
        return min(maxEnd, segment.endTime + (adj?.after ?? 0))
    }

    /// Returns true if the effective time range for the rally is valid (start < end).
    func isValidTimeRange(for rallyIndex: Int, segments: [RallySegment], videoDuration: Double) -> Bool {
        let start = effectiveStartTime(for: rallyIndex, segments: segments)
        let end = effectiveEndTime(for: rallyIndex, segments: segments, videoDuration: videoDuration)
        return start < end
    }

    // MARK: - Trim Mode Lifecycle

    func enterTrimMode(rallyIndex: Int) {
        let existing = trimAdjustments[rallyIndex]
        currentTrimBefore = existing?.before ?? 0.0
        currentTrimAfter = existing?.after ?? 0.0
        isTrimmingMode = true
    }

    func confirmTrim(rallyIndex: Int, videoId: UUID, metadataStore: MetadataStore) {
        trimAdjustments[rallyIndex] = RallyTrimAdjustment(
            before: currentTrimBefore, after: currentTrimAfter
        )
        try? metadataStore.saveTrimAdjustments(trimAdjustments, for: videoId)
        isTrimmingMode = false
    }

    func cancelTrim(rallyIndex: Int) {
        let existing = trimAdjustments[rallyIndex]
        currentTrimBefore = existing?.before ?? 0.0
        currentTrimAfter = existing?.after ?? 0.0
        isTrimmingMode = false
    }

    // MARK: - Persistence

    func loadSavedAdjustments(videoId: UUID, metadataStore: MetadataStore) {
        trimAdjustments = metadataStore.loadTrimAdjustments(for: videoId)
    }
}
