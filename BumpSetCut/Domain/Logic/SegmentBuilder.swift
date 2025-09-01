//
//  SegmentBuilder.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreMedia

/// Builds keep-time segments with pre/post-roll, gap merge, and min-length filtering.
final class SegmentBuilder {
    private let config: ProcessorConfig
    private var currentStart: CMTime?
    private var ranges: [CMTimeRange] = []
    // Cap pre-roll for short segments to avoid long lead-in on false starts
    private let shortSegmentThreshold: Double = 2.5   // seconds; if raw rally < threshold, cap pre-roll
    private let maxPrerollForShort: Double = 0.5      // seconds; max pre-roll applied to short rallies

    init(config: ProcessorConfig) {
        self.config = config
    }

    func reset() {
        currentStart = nil
        ranges.removeAll()
    }

    /// Append a segment that is **already padded** (e.g., from RallyDecider.popEndedSegment()).
    /// This will not apply additional pre/post roll; padding/merging/filtering happens in `finalize`.
    func appendPadded(start: CMTime, end: CMTime) {
        ranges.append(CMTimeRange(start: start, end: end))
    }

    /// Append a **raw** segment that needs pre/post roll applied according to `config`.
    /// This uses the same internal path as when we close segments from observations.
    func appendRaw(start: CMTime, end: CMTime) {
        closeSegment(start: start, end: end)
    }

    func observe(isActive: Bool, at time: CMTime) {
        if isActive {
            if currentStart == nil { currentStart = time }
        } else {
            if let s = currentStart {
                closeSegment(start: s, end: time)
            }
            currentStart = nil
        }
    }

    func finalize(until duration: CMTime) -> [CMTimeRange] {
        if let s = currentStart {
            closeSegment(start: s, end: duration)
            currentStart = nil
        }

        // Clamp each range to [0, duration] and drop invalid/empty
        let clamped: [CMTimeRange] = ranges.compactMap { r in
            let start = CMTimeMaximum(.zero, r.start)
            let end = CMTimeMinimum(duration, r.end)
            return CMTimeCompare(end, start) == 1 ? CMTimeRange(start: start, end: end) : nil
        }

        // Merge small gaps (on clamped ranges)
        var merged: [CMTimeRange] = []
        for r in clamped.sorted(by: { CMTimeCompare($0.start, $1.start) < 0 }) {
            if let last = merged.last, gapSec(between: last, and: r) <= config.minGapToMerge {
                let union = CMTimeRange(start: last.start, end: CMTimeMaximum(last.end, r.end))
                _ = merged.popLast()
                merged.append(union)
            } else {
                merged.append(r)
            }
        }

        // Drop tiny segments
        return merged.filter { $0.duration.seconds >= config.minSegmentLength }
    }

    private func closeSegment(start: CMTime, end: CMTime) {
        // Use a smaller pre-roll for short raw rallies to avoid pulling start back too far
        let rawDur = CMTimeSubtract(end, start)
        let rawSec = max(0, CMTimeGetSeconds(rawDur))
        let effectivePreSec = (rawSec < shortSegmentThreshold)
            ? min(config.preroll, maxPrerollForShort)
            : config.preroll

        let pre = CMTimeMakeWithSeconds(effectivePreSec, preferredTimescale: 600)
        let post = CMTimeMakeWithSeconds(config.postroll, preferredTimescale: 600)
        let s = CMTimeMaximum(.zero, CMTimeSubtract(start, pre))
        let e = CMTimeAdd(end, post)
        ranges.append(CMTimeRange(start: s, end: e))
    }
}
