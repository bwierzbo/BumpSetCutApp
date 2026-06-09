import Foundation
import Observation
import CoreGraphics

// MARK: - Pending Propagation

/// Describes a just-confirmed adjustment that can be propagated to the rest of
/// the rallies. A field is non-nil when it changed during this trim session, so
/// the prompt can name what's being applied.
struct PendingPropagation {
    var rotation: Double?
    var zoom: Double?
}

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
    var currentTrimRotation: Double = 0.0
    var currentTrimZoom: Double = 1.0
    var currentTrimPanX: Double = 0.0
    var currentTrimPanY: Double = 0.0

    /// Set when the user confirms a trim that changed rotation and/or zoom/pan.
    /// The view reads this to surface a "apply to the rest of the rallies?"
    /// confirmation, then clears it.
    var pendingPropagation: PendingPropagation?

    /// Captured at enterTrimMode so we can detect changes on confirm.
    private var rotationAtEnter: Double = 0.0
    private var zoomAtEnter: Double = 1.0
    private var panXAtEnter: Double = 0.0
    private var panYAtEnter: Double = 0.0

    // MARK: - Adjustment Access

    func rotation(for rallyIndex: Int) -> Double {
        trimAdjustments[rallyIndex]?.rotation ?? 0.0
    }

    func zoom(for rallyIndex: Int) -> Double {
        trimAdjustments[rallyIndex]?.zoom ?? 1.0
    }

    func pan(for rallyIndex: Int) -> CGSize {
        let adj = trimAdjustments[rallyIndex]
        return CGSize(width: adj?.panX ?? 0, height: adj?.panY ?? 0)
    }

    func clearPendingPropagation() {
        pendingPropagation = nil
    }

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
        currentTrimRotation = existing?.rotation ?? 0.0
        currentTrimZoom = existing?.zoom ?? 1.0
        currentTrimPanX = existing?.panX ?? 0.0
        currentTrimPanY = existing?.panY ?? 0.0
        rotationAtEnter = currentTrimRotation
        zoomAtEnter = currentTrimZoom
        panXAtEnter = currentTrimPanX
        panYAtEnter = currentTrimPanY
        isTrimmingMode = true
    }

    @discardableResult
    func confirmTrim(rallyIndex: Int, videoId: UUID, metadataStore: MetadataStore) -> RallyTrimAdjustment? {
        let previous = trimAdjustments[rallyIndex]
        trimAdjustments[rallyIndex] = RallyTrimAdjustment(
            before: currentTrimBefore,
            after: currentTrimAfter,
            rotation: currentTrimRotation,
            zoom: currentTrimZoom,
            panX: currentTrimPanX,
            panY: currentTrimPanY
        )
        try? metadataStore.saveTrimAdjustments(trimAdjustments, for: videoId)
        isTrimmingMode = false

        // Surface a propagation prompt when rotation and/or zoom/pan changed.
        let rotationChanged = abs(currentTrimRotation - rotationAtEnter) >= 0.01
        let zoomChanged = abs(currentTrimZoom - zoomAtEnter) >= 0.01
        let panChanged = abs(currentTrimPanX - panXAtEnter) >= 0.001
            || abs(currentTrimPanY - panYAtEnter) >= 0.001
        if rotationChanged || zoomChanged || panChanged {
            pendingPropagation = PendingPropagation(
                rotation: rotationChanged ? currentTrimRotation : nil,
                zoom: (zoomChanged || panChanged) ? currentTrimZoom : nil
            )
        }

        return previous
    }

    func restoreTrimAdjustment(_ adjustment: RallyTrimAdjustment?, for rallyIndex: Int, videoId: UUID, metadataStore: MetadataStore) {
        if let adjustment {
            trimAdjustments[rallyIndex] = adjustment
        } else {
            trimAdjustments.removeValue(forKey: rallyIndex)
        }
        try? metadataStore.saveTrimAdjustments(trimAdjustments, for: videoId)
    }

    func cancelTrim(rallyIndex: Int) {
        let existing = trimAdjustments[rallyIndex]
        currentTrimBefore = existing?.before ?? 0.0
        currentTrimAfter = existing?.after ?? 0.0
        currentTrimRotation = existing?.rotation ?? 0.0
        currentTrimZoom = existing?.zoom ?? 1.0
        currentTrimPanX = existing?.panX ?? 0.0
        currentTrimPanY = existing?.panY ?? 0.0
        isTrimmingMode = false
    }

    /// Write rotation + zoom + pan into the trim adjustment for every rally with
    /// index ≥ `fromIndex`, preserving each rally's existing before/after trim.
    /// Persists once at the end.
    func applyAdjustmentForward(rotation: Double, zoom: Double, panX: Double, panY: Double,
                                fromIndex: Int, totalRallies: Int, videoId: UUID, metadataStore: MetadataStore) {
        guard totalRallies > fromIndex else { return }
        for index in fromIndex..<totalRallies {
            let existing = trimAdjustments[index]
            trimAdjustments[index] = RallyTrimAdjustment(
                before: existing?.before ?? 0.0,
                after: existing?.after ?? 0.0,
                rotation: rotation,
                zoom: zoom,
                panX: panX,
                panY: panY
            )
        }
        try? metadataStore.saveTrimAdjustments(trimAdjustments, for: videoId)
    }

    // MARK: - Persistence

    func loadSavedAdjustments(videoId: UUID, metadataStore: MetadataStore) {
        trimAdjustments = metadataStore.loadTrimAdjustments(for: videoId)
    }
}
