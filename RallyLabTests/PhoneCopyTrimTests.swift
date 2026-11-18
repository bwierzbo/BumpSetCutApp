//
//  PhoneCopyTrimTests.swift
//  RallyLabTests
//
//  The phone copy of a trimmed original (LabelingSync.CopyTrim, copy version 4): the copy must have the frames
//  the original's published identity names, or the phone refuses frame-exact work on it. ffmpeg's own reading of
//  an edit that starts inside a frame begins at the first whole frame, a fraction of a frame early throughout.
//
//  Fixture trimmed-mid-frame.mp4: `ffmpeg -f lavfi -i testsrc2=size=64x36:rate=60:duration=2 -c:v libx264 -g 30
//  -bf 0 -pix_fmt yuv420p base.mp4 && ffmpeg -ss 0.2733 -i base.mp4 -c copy trimmed-mid-frame.mp4` — 120 samples,
//  one edit from 0.2733 s: 104 frames, the first shown from the edit's start. trimmed-mid-frame-bframes.mp4: the
//  same with `-bf 2` — its media times start after a composition delay (edit from 0.3066 s), which ffmpeg takes
//  off its input's times unless told to keep them.
//

import AVFoundation
import XCTest
@testable import RallyLab

final class PhoneCopyTrimTests: XCTestCase {
    private func edit(from start: Double, for duration: Double, at target: Double = 0, shownFor shown: Double? = nil) -> CMTimeMapping {
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600_000) }
        return CMTimeMapping(source: CMTimeRange(start: time(start), duration: time(duration)), target: CMTimeRange(start: time(target), duration: time(shown ?? duration)))
    }

    private let sixty = (0..<120).map { Double($0) / 60 }

    func testAnEditThatStartsInsideAFrameKeepsThatFrameAndShiftsByTheEditsStart() throws {
        let trim = try XCTUnwrap(LabelingSync.CopyTrim(media: sixty, edits: [edit(from: 0.2733, for: 1.7)]))
        XCTAssertEqual(trim.keepFrom, 16.0 / 60, accuracy: 1e-9, "the frame showing at 0.2733 s")
        XCTAssertEqual(trim.start, 0.2733, accuracy: 1e-6)
        XCTAssertEqual(trim.end, 1.9733, accuracy: 1e-6)
        XCTAssertEqual(trim.inputOptions, ["-copyts", "-ignore_editlist", "1"])
        XCTAssertEqual(trim.filters, "select='gte(t,0.266666)*lt(t,1.973299)',setpts='max(round(PTS-0.273300000/TB),0)',")
    }

    func testAnEditOnAFrameBoundaryKeepsFromThatFrame() throws {
        let trim = try XCTUnwrap(LabelingSync.CopyTrim(media: sixty, edits: [edit(from: 0.5, for: 1)]))
        XCTAssertEqual(trim.keepFrom, 0.5, accuracy: 1e-9)
    }

    func testNoTrimWhenFfmpegsOwnReadingAlreadyGivesTheFrames() {
        XCTAssertNil(LabelingSync.CopyTrim(media: sixty, edits: []), "no edit list")
        XCTAssertNil(LabelingSync.CopyTrim(media: sixty.map { $0 + 0.5 }, edits: [edit(from: 0.5, for: 1.5)]), "no sample before the edit")
        XCTAssertNil(LabelingSync.CopyTrim(media: sixty, edits: [edit(from: 0.2733, for: 1.7, at: 0.033)]), "a delayed edit")
        XCTAssertNil(LabelingSync.CopyTrim(media: sixty, edits: [edit(from: 0.2733, for: 1.7, shownFor: 3.4)]), "a retimed edit")
        XCTAssertNil(LabelingSync.CopyTrim(media: sixty, edits: [edit(from: 0.2733, for: 0.5), edit(from: 1, for: 0.5, at: 0.5)]), "several edits")
    }

    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: "mp4") ?? bundle.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
    }

    func testTheCopyOfATrimmedClipWithBFramesHasTheOriginalsFrames() async throws {
        guard await ToolEnvironment.run("ffmpeg", ["-version"]).status == 0 else { throw XCTSkip("ffmpeg is not installed") }
        let source = try fixture("trimmed-mid-frame-bframes")
        let timeline = try await FrameIdentity.timeline(of: source)
        XCTAssertGreaterThan(try XCTUnwrap(timeline.media.min()), 0.01, "the media times start after the composition delay")
        XCTAssertNotNil(LabelingSync.CopyTrim(media: timeline.media, edits: timeline.edits))
        let original = FrameIdentity.presentationTimes(media: timeline.media, edits: timeline.edits)
        XCTAssertEqual(original.count, 104)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try await LabelingSync.encodeSmallCopy(source, out)
        let faithful = await LabelingSync.copy(out, reproduces: FrameIdentity.digest(of: original))
        XCTAssertTrue(faithful)
    }

    func testTheCopyOfATrimmedClipHasTheOriginalsFrames() async throws {
        guard await ToolEnvironment.run("ffmpeg", ["-version"]).status == 0 else { throw XCTSkip("ffmpeg is not installed") }
        let source = try fixture("trimmed-mid-frame")
        let original = try await FrameIdentity.allFrameTimes(of: source)
        XCTAssertEqual(original.count, 104)
        XCTAssertEqual(original[0], 0)
        XCTAssertGreaterThan(original[1], 0.005, "the first frame is shown for part of a frame only")
        XCTAssertLessThan(original[1], 1.0 / 60 - 0.001)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try await LabelingSync.encodeSmallCopy(source, out)
        let digest = FrameIdentity.digest(of: original)
        let copy = try await FrameIdentity.allFrameTimes(of: out)
        XCTAssertEqual(copy.count, original.count)
        XCTAssertTrue(FrameIdentity.matches(copy: copy, original: digest), "the phone's check passes")
        let faithful = await LabelingSync.copy(out, reproduces: digest)
        XCTAssertTrue(faithful)

        // What the round reports for a copy that is not the original's frames, or can't be read.
        let other = await LabelingSync.copy(out, reproduces: FrameIdentity.digest(of: Array(original.dropFirst())))
        XCTAssertFalse(other)
        let unreadable = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: unreadable) }
        try Data("a smaller copy".utf8).write(to: unreadable)
        let unread = await LabelingSync.copy(unreadable, reproduces: digest)
        XCTAssertFalse(unread)
        let unheld = await LabelingSync.copy(unreadable, reproduces: nil)
        XCTAssertTrue(unheld, "no published identity to hold it to")
    }
}
