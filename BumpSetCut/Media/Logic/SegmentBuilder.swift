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

    init(config: ProcessorConfig) {
        self.config = config
    }

    func reset() {
        currentStart = nil
        ranges.removeAll()
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
        let pre = CMTimeMakeWithSeconds(config.preroll, preferredTimescale: 600)
        let post = CMTimeMakeWithSeconds(config.postroll, preferredTimescale: 600)
        let s = CMTimeMaximum(.zero, CMTimeSubtract(start, pre))
        let e = CMTimeAdd(end, post)
        ranges.append(CMTimeRange(start: s, end: e))
    }
}
