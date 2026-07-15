//
//  SegmentBuilder.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreMedia

/// Builds keep-time segments with pre/post-roll, gap merge, and min-length filtering.
final class SegmentBuilder {
    /// A finalized segment: the padded clip range plus the raw decided rally
    /// boundaries it came from (union of raws across merges). Content rules
    /// (e.g. the above-net arc count) must evaluate over `raw` — padding
    /// contains serve-toss/aftermath motion that isn't part of the rally.
    struct BuiltSegment {
        let padded: CMTimeRange
        let raw: CMTimeRange
    }

    private let config: ProcessorConfig
    private var currentStart: CMTime?
    private var segments: [BuiltSegment] = []
    // Cap pre-roll for short segments to avoid long lead-in on false starts
    private let shortSegmentThreshold: Double = 2.5   // seconds; if raw rally < threshold, cap pre-roll
    private let maxPrerollForShort: Double = 0.5      // seconds; max pre-roll applied to short rallies

    init(config: ProcessorConfig) {
        self.config = config
    }

    func reset() {
        currentStart = nil
        segments.removeAll()
    }

    /// Append a segment that is **already padded**.
    /// This will not apply additional pre/post roll; merging/filtering happens in `finalize`.
    func appendPadded(start: CMTime, end: CMTime) {
        let range = CMTimeRange(start: start, end: end)
        segments.append(BuiltSegment(padded: range, raw: range))
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
        finalizeWithRaw(until: duration).map { $0.padded }
    }

    /// Like `finalize`, but each padded range keeps its raw rally boundaries.
    func finalizeWithRaw(until duration: CMTime) -> [BuiltSegment] {
        if let s = currentStart {
            closeSegment(start: s, end: duration)
            currentStart = nil
        }

        // Clamp each range to [0, duration] and drop invalid/empty
        let clamped: [BuiltSegment] = segments.compactMap { seg in
            let start = CMTimeMaximum(.zero, seg.padded.start)
            let end = CMTimeMinimum(duration, seg.padded.end)
            guard CMTimeCompare(end, start) == 1 else { return nil }
            let padded = CMTimeRange(start: start, end: end)
            let rawStart = CMTimeMaximum(start, seg.raw.start)
            let rawEnd = CMTimeMinimum(end, seg.raw.end)
            let raw = CMTimeCompare(rawEnd, rawStart) == 1
                ? CMTimeRange(start: rawStart, end: rawEnd)
                : padded
            return BuiltSegment(padded: padded, raw: raw)
        }

        // Merge small gaps (on clamped padded ranges); raws union across merges
        var merged: [BuiltSegment] = []
        for seg in clamped.sorted(by: { CMTimeCompare($0.padded.start, $1.padded.start) < 0 }) {
            if let last = merged.last, gapSec(between: last.padded, and: seg.padded) <= config.minGapToMerge {
                let padded = CMTimeRange(start: last.padded.start,
                                         end: CMTimeMaximum(last.padded.end, seg.padded.end))
                let raw = CMTimeRange(start: CMTimeMinimum(last.raw.start, seg.raw.start),
                                      end: CMTimeMaximum(last.raw.end, seg.raw.end))
                _ = merged.popLast()
                merged.append(BuiltSegment(padded: padded, raw: raw))
            } else {
                merged.append(seg)
            }
        }

        // Drop tiny segments
        return merged.filter { $0.padded.duration.seconds >= config.minSegmentLength }
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
        segments.append(BuiltSegment(padded: CMTimeRange(start: s, end: e),
                                     raw: CMTimeRange(start: start, end: end)))
    }
}
