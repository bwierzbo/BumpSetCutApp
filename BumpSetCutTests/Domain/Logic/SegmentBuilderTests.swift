//
//  SegmentBuilderTests.swift
//  BumpSetCutTests
//
//  Tests for SegmentBuilder: pre/post-roll, gap merging,
//  minimum segment filtering, clamping, and edge cases.
//

import XCTest
import CoreMedia
@testable import BumpSetCut

final class SegmentBuilderTests: XCTestCase {

    private var config: ProcessorConfig!

    override func setUp() {
        super.setUp()
        config = ProcessorConfig()
        // Defaults: preroll=2.0, postroll=0.5, minGapToMerge=0.3, minSegmentLength=0.5
    }

    override func tearDown() {
        config = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func time(_ seconds: Double) -> CMTime {
        CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
    }

    private func durationSeconds(_ range: CMTimeRange) -> Double {
        CMTimeGetSeconds(range.duration)
    }

    private func startSeconds(_ range: CMTimeRange) -> Double {
        CMTimeGetSeconds(range.start)
    }

    private func endSeconds(_ range: CMTimeRange) -> Double {
        CMTimeGetSeconds(CMTimeRangeGetEnd(range))
    }

    // MARK: - 1. Basic segment creation with pre/post-roll

    func testBasicSegmentWithPrePostRoll() {
        let builder = SegmentBuilder(config: config)

        // Observe active from 5s to 10s (5s rally, above shortSegmentThreshold)
        for i in 0...150 {
            let t = Double(i) * (1.0 / 30.0)
            builder.observe(isActive: t >= 5.0 && t <= 10.0, at: time(t))
        }

        let segments = builder.finalize(until: time(20.0))
        XCTAssertEqual(segments.count, 1, "Should produce exactly one segment")

        if let seg = segments.first {
            let start = startSeconds(seg)
            let end = endSeconds(seg)

            // Pre-roll=2.0s, so start should be ~3.0s (5.0 - 2.0)
            XCTAssertEqual(start, 3.0, accuracy: 0.1,
                           "Start should include 2.0s pre-roll")
            // Post-roll=0.5s, so end should be ~10.5s (10.0 + 0.5)
            XCTAssertEqual(end, 10.5, accuracy: 0.1,
                           "End should include 0.5s post-roll")
        }
    }

    // MARK: - 2. Short-segment pre-roll capping (<2.5s rally)

    func testShortSegmentPreRollCapping() {
        let builder = SegmentBuilder(config: config)

        // A rally of only 2.0s (below shortSegmentThreshold of 2.5s)
        // Pre-roll should be capped to maxPrerollForShort (0.5s) instead of config.preroll (2.0s)
        for i in 0...120 {
            let t = Double(i) * (1.0 / 30.0)
            builder.observe(isActive: t >= 5.0 && t <= 7.0, at: time(t))
        }

        let segments = builder.finalize(until: time(20.0))
        XCTAssertEqual(segments.count, 1)

        if let seg = segments.first {
            let start = startSeconds(seg)
            // For a short rally, pre-roll is capped to 0.5s: 5.0 - 0.5 = 4.5
            XCTAssertEqual(start, 4.5, accuracy: 0.1,
                           "Short rally should have pre-roll capped to 0.5s, not full 2.0s")
        }
    }

    // MARK: - 3. Gap merging (gaps <= minGapToMerge merged)

    func testGapMerging() {
        let builder = SegmentBuilder(config: config)

        // Two segments separated by a 0.2s gap (< minGapToMerge 0.3s)
        // Segment A: 3s-6s, Segment B: 6.2s-9s
        for i in 0...300 {
            let t = Double(i) * (1.0 / 30.0)
            let active = (t >= 3.0 && t <= 6.0) || (t >= 6.2 && t <= 9.0)
            builder.observe(isActive: active, at: time(t))
        }

        let segments = builder.finalize(until: time(20.0))
        // The 0.2s gap is below minGapToMerge=0.3s, so these should merge into one
        XCTAssertEqual(segments.count, 1,
                       "Segments with gap <= minGapToMerge (0.3s) should merge into one")
    }

    // MARK: - 4. Minimum segment length filtering (<0.5s dropped)

    func testMinimumSegmentLengthFiltering() {
        let builder = SegmentBuilder(config: config)

        // A very short "rally" of ~0.1s -- after pre/post roll it might still be short
        // But with pre-roll capped to 0.5s + 0.1s + post-roll 0.5s = 1.1s
        // Actually this should pass. Let's test with a segment that's truly tiny.
        // Use appendRaw which applies pre/post-roll
        // But if raw segment itself is 0.05s, with capped pre-roll 0.5 + post 0.5 = 1.05s -> passes

        // Instead, use appendPadded to test the filter directly
        builder.appendPadded(start: time(5.0), end: time(5.3)) // 0.3s padded segment

        let segments = builder.finalize(until: time(20.0))
        XCTAssertEqual(segments.count, 0,
                       "Padded segment shorter than minSegmentLength (0.5s) should be filtered out")
    }

    // MARK: - 5. Clamping to video duration bounds

    func testClampingToVideoDuration() {
        let builder = SegmentBuilder(config: config)

        // Rally near the start of video -- pre-roll would go negative
        builder.appendRaw(start: time(0.5), end: time(4.0))

        // Rally near the end -- post-roll would exceed duration
        builder.appendRaw(start: time(18.0), end: time(20.0))

        let duration = time(20.0)
        let segments = builder.finalize(until: duration)

        for seg in segments {
            let start = startSeconds(seg)
            let end = endSeconds(seg)
            XCTAssertGreaterThanOrEqual(start, 0.0,
                                        "Segment start should be clamped to >= 0")
            XCTAssertLessThanOrEqual(end, 20.0 + 0.01,
                                     "Segment end should be clamped to <= video duration")
        }
    }

    // MARK: - 6. Multiple segments with varying gaps

    func testMultipleSegmentsVaryingGaps() {
        let builder = SegmentBuilder(config: config)

        // Three segments with gaps:
        // A: 2-5s, gap 0.1s (merge), B: 5.1-8s, gap 2.0s (keep separate), C: 10-13s
        for i in 0...400 {
            let t = Double(i) * (1.0 / 30.0)
            let active = (t >= 2.0 && t <= 5.0) ||
                         (t >= 5.1 && t <= 8.0) ||
                         (t >= 10.0 && t <= 13.0)
            builder.observe(isActive: active, at: time(t))
        }

        let segments = builder.finalize(until: time(20.0))

        // A and B should merge (gap 0.1s < minGapToMerge 0.3s after padding)
        // C should be separate (gap ~2.0s >> minGapToMerge)
        XCTAssertEqual(segments.count, 2,
                       "Should produce 2 segments: A+B merged, C separate")
    }

    // MARK: - 7. Empty input handling

    func testEmptyInput() {
        let builder = SegmentBuilder(config: config)

        // No observations at all
        let segments = builder.finalize(until: time(10.0))
        XCTAssertEqual(segments.count, 0,
                       "Empty input should produce zero segments")
    }

    func testAllInactiveInput() {
        let builder = SegmentBuilder(config: config)

        // All frames are inactive
        for i in 0...300 {
            let t = Double(i) * (1.0 / 30.0)
            builder.observe(isActive: false, at: time(t))
        }

        let segments = builder.finalize(until: time(10.0))
        XCTAssertEqual(segments.count, 0,
                       "All-inactive input should produce zero segments")
    }

    // MARK: - 8. Pre-roll/post-roll parameter variations

    func testCustomPrePostRoll() {
        var customConfig = ProcessorConfig()
        customConfig.preroll = 0.5
        customConfig.postroll = 1.0
        let builder = SegmentBuilder(config: customConfig)

        // Rally from 5s to 10s (5s -- above shortSegmentThreshold)
        for i in 0...330 {
            let t = Double(i) * (1.0 / 30.0)
            builder.observe(isActive: t >= 5.0 && t <= 10.0, at: time(t))
        }

        let segments = builder.finalize(until: time(20.0))
        XCTAssertEqual(segments.count, 1)

        if let seg = segments.first {
            let start = startSeconds(seg)
            let end = endSeconds(seg)

            // Pre-roll 0.5: 5.0 - 0.5 = 4.5
            XCTAssertEqual(start, 4.5, accuracy: 0.1)
            // Post-roll 1.0: 10.0 + 1.0 = 11.0
            XCTAssertEqual(end, 11.0, accuracy: 0.1)
        }
    }

    // MARK: - 9. appendPadded bypasses pre/post-roll

    func testAppendPaddedBypassesPrePostRoll() {
        let builder = SegmentBuilder(config: config)

        // appendPadded should NOT apply additional pre/post-roll
        builder.appendPadded(start: time(5.0), end: time(10.0))

        let segments = builder.finalize(until: time(20.0))
        XCTAssertEqual(segments.count, 1)

        if let seg = segments.first {
            let start = startSeconds(seg)
            let end = endSeconds(seg)
            XCTAssertEqual(start, 5.0, accuracy: 0.01,
                           "appendPadded should not apply additional pre-roll")
            XCTAssertEqual(end, 10.0, accuracy: 0.01,
                           "appendPadded should not apply additional post-roll")
        }
    }

    // MARK: - 10. Reset clears all state

    func testResetClearsState() {
        let builder = SegmentBuilder(config: config)

        // Add some data
        builder.appendPadded(start: time(1.0), end: time(5.0))

        // Reset
        builder.reset()

        // Finalize should produce nothing
        let segments = builder.finalize(until: time(10.0))
        XCTAssertEqual(segments.count, 0,
                       "After reset, builder should have no segments")
    }

    // MARK: - 11. Segment at very end of video gets clamped

    func testSegmentAtEndOfVideoGetsClamped() {
        let builder = SegmentBuilder(config: config)

        // Rally right at the end: 19.0-20.0 with post-roll would exceed duration
        builder.appendRaw(start: time(19.0), end: time(20.0))

        let segments = builder.finalize(until: time(20.0))
        XCTAssertEqual(segments.count, 1)

        if let seg = segments.first {
            let end = endSeconds(seg)
            XCTAssertLessThanOrEqual(end, 20.0 + 0.01,
                                     "Segment end should be clamped to video duration")
        }
    }

    // MARK: - 12. Large gap keeps segments separate

    func testLargeGapKeepsSegmentsSeparate() {
        let builder = SegmentBuilder(config: config)

        builder.appendPadded(start: time(1.0), end: time(4.0))
        builder.appendPadded(start: time(10.0), end: time(14.0))

        let segments = builder.finalize(until: time(20.0))
        XCTAssertEqual(segments.count, 2,
                       "Segments with large gap should remain separate")

        if segments.count == 2 {
            XCTAssertLessThan(endSeconds(segments[0]), startSeconds(segments[1]),
                              "Separate segments should not overlap")
        }
    }
}
