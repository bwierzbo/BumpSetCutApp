//
//  MultiFramePackageResumeTests.swift
//  RallyLabTests
//
//  A multi-frame export writes every frame its windows need, whole, or
//  fails naming the frame; an export cut short is completed in place only
//  from frames proven to be whole, planned, the right size and of the same
//  video — and a finished package, a stray folder or a foreign file is
//  refused without touching anything.
//

import AVFoundation
import CryptoKit
import XCTest
@testable import RallyLab

final class MultiFramePackageResumeTests: XCTestCase {

    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-10-22T20:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mfp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// A 3 s, 30 fps H.264 clip whose picture depends on `seed` (another seed is another video)
    /// and changes a little every frame.
    private func video(_ name: String, seed: Int = 0, width: Int = 320, height: Int = 180) async throws -> URL {
        let url = root.appendingPathComponent("footage/\(name).mp4")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                            AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pixels = buffer
            else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let left = (i * 3) % (width - 40)
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * stride + x * 4
                    let square = x >= left && x < left + 40 && y >= 40 && y < 80
                    p[0] = square ? 255 : UInt8((seed * 97 + x / 4 + y / 4) % 160)
                    p[1] = square ? 255 : UInt8((seed * 31 + i) % 200)
                    p[2] = square ? 255 : UInt8((seed * 53) % 200)
                    p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private func session(_ name: String, split: String, video: URL, times: [Double]) -> VideoSession {
        let frames = times.map { FrameRecord(id: UUID(), file: "images/\(split)/\(name)_\($0).jpg", time: $0, source: "random", boxes: [], keep: true, reviewed: true) }
        return VideoSession(name: name, sourcePath: video.path, split: split, addedAt: now, frames: frames)
    }

    /// Two clips: `a` (val, windows at 1.5 s and 2.0 s: frames 37…68) and `b` (train, one window at 1.0 s: frames 22…38).
    private func sessions(seedA: Int = 0) async throws -> [VideoSession] {
        [session("a", split: "val", video: try await video("a", seed: seedA), times: [1.5, 2.0]),
         session("b", split: "train", video: try await video("b", seed: 7), times: [1.0])]
    }

    private func export(_ sessions: [VideoSession], longSide: CGFloat = MultiFramePackage.longSide, resume: URL? = nil) async throws -> (dir: URL, summary: MultiFramePackage.Summary) {
        let result = try await MultiFramePackage.export(sessions: sessions, store: DatasetStore(root: root), name: "Fixture-L2", longSide: longSide,
                                                        resume: resume, now: now) { _, _ in }
        let dir = result.output.pathExtension == "zip" ? result.output.deletingPathExtension() : result.output
        return (dir, result.summary)
    }

    /// Strips what a finished export has and an interrupted one hasn't: the zip and the top-level files.
    private func interrupt(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.removeItem(at: dir.deletingPathExtension().appendingPathExtension("zip"))
        for f in ["windows.jsonl", "README.txt", "summary.json"] { try fm.removeItem(at: dir.appendingPathComponent(f)) }
    }

    private func hashes(_ dir: URL) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try XCTUnwrap(DatasetSplitManifest.canonicalFileHashes(ofDirectory: dir)).map { ($0.path, $0.sha256) })
    }

    private func frameNames(_ dir: URL, _ clip: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("frames/\(clip)").path).sorted()
    }

    // MARK: - Fresh export

    func testExportWritesEveryNeededFrameWhole() async throws {
        let (dir, summary) = try await export(try await sessions())
        XCTAssertNil(summary.resume)
        XCTAssertEqual(summary.frames, 32 + 17, "a: frames 37…68, b: frames 22…38")
        XCTAssertEqual(try frameNames(dir, "a").count, 32)
        XCTAssertEqual(try frameNames(dir, "b").count, 17)
        for (path, _) in try hashes(dir) where path.hasPrefix("frames/") {
            XCTAssertFalse(path.hasSuffix(ExportIO.partialSuffix), "no .part left behind: \(path)")
            guard case .valid(let w, let h) = ExportIO.inspectFrame(try Data(contentsOf: dir.appendingPathComponent(path))) else { return XCTFail("\(path) is not a whole JPEG") }
            XCTAssertEqual([w, h], [320, 180])
        }
        let windows = try String(contentsOf: dir.appendingPathComponent("windows.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(windows.count, 3)
    }

    // MARK: - Resume

    func testResumeCompletesAnInterruptedExportWithoutRewritingValidFrames() async throws {
        let sessions = try await sessions()
        let (dir, _) = try await export(sessions)
        let windowsBefore = try Data(contentsOf: dir.appendingPathComponent("windows.jsonl"))
        let before = try hashes(dir)
        try interrupt(dir)
        // Clip b lost all but five frames; one of a's frames was torn mid-write; a .part was left behind.
        let fm = FileManager.default
        let bFrames = try frameNames(dir, "b")
        for name in bFrames.dropFirst(5) { try fm.removeItem(at: dir.appendingPathComponent("frames/b/\(name)")) }
        let torn = try frameNames(dir, "a")[3]
        let tornURL = dir.appendingPathComponent("frames/a/\(torn)")
        try Data(contentsOf: tornURL).prefix(1000).write(to: tornURL)
        try Data("half".utf8).write(to: dir.appendingPathComponent("frames/a/1233333.jpg.part"))

        let (resumedDir, summary) = try await export(sessions, resume: dir)
        XCTAssertEqual(resumedDir.path, dir.path)
        let report = try XCTUnwrap(summary.resume)
        XCTAssertEqual(report.from, dir.lastPathComponent)
        XCTAssertEqual(report.framesRetained, 31 + 5)
        XCTAssertEqual(report.framesReplaced, 1)
        XCTAssertEqual(report.replaced, ["frames/a/\(torn)"])
        XCTAssertEqual(report.framesWritten, 1 + 12)
        XCTAssertEqual(report.partialFilesRemoved, 1)
        XCTAssertEqual(report.sourceChecks.map(\.clip), ["a", "b"])
        XCTAssertEqual(report.sourceChecks.map(\.sampled), [5, 5])
        XCTAssertLessThanOrEqual(report.sourceChecks.map(\.maxDifference).max()!, ExportIO.sameFrame)
        XCTAssertEqual(summary.frames, 49)

        let after = try hashes(dir)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("windows.jsonl")), windowsBefore, "the same windows as the uninterrupted export")
        for (path, sha) in before where path.hasPrefix("frames/") && path != "frames/a/\(torn)" && (path.hasPrefix("frames/a/") || bFrames.prefix(5).contains(String(path.dropFirst("frames/b/".count)))) {
            XCTAssertEqual(after[path], sha, "retained frame rewritten: \(path)")
        }
        XCTAssertEqual(Set(after.keys.filter { $0.hasPrefix("frames/") }), Set(before.keys.filter { $0.hasPrefix("frames/") }))
        guard case .valid = ExportIO.inspectFrame(try Data(contentsOf: tornURL)) else { return XCTFail("the torn frame was not replaced by a whole one") }
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("frames/a/1233333.jpg.part").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.deletingPathExtension().appendingPathExtension("zip").path), "the resumed export finishes like a fresh one")
    }

    func testResumeRefusesAFinishedPackageAStrayFolderAndAForeignFile() async throws {
        let sessions = try await sessions()
        let (dir, _) = try await export(sessions)
        let fm = FileManager.default
        let before = try hashes(dir)
        // Finished (zip and top-level files present): never written into.
        do { _ = try await export(sessions, resume: dir); XCTFail("resumed into a finished package") }
        catch MultiFramePackage.ResumeError.notResumable(let path, let found) {
            XCTAssertEqual(path, dir.path)
            XCTAssertEqual(found, ["\(dir.lastPathComponent).zip", "README.txt", "frames", "summary.json", "windows.jsonl"])
        }
        XCTAssertEqual(try hashes(dir), before, "nothing touched")
        try interrupt(dir)
        // A clip folder this export does not package.
        try fm.createDirectory(at: dir.appendingPathComponent("frames/zzz"), withIntermediateDirectories: true)
        do { _ = try await export(sessions, resume: dir); XCTFail("resumed past a stray clip folder") }
        catch MultiFramePackage.ResumeError.strayClipFolder(let p) { XCTAssertEqual(p, "frames/zzz") }
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("frames/zzz").path), "the stray folder is not removed")
        try fm.removeItem(at: dir.appendingPathComponent("frames/zzz"))
        // A file that is not a frame, and a frame at a moment the plan does not need.
        try Data("x".utf8).write(to: dir.appendingPathComponent("frames/a/notes.txt"))
        do { _ = try await export(sessions, resume: dir); XCTFail("resumed past a foreign file") }
        catch MultiFramePackage.ResumeError.unexpectedFile(let p) { XCTAssertEqual(p, "frames/a/notes.txt") }
        try fm.removeItem(at: dir.appendingPathComponent("frames/a/notes.txt"))
        try fm.copyItem(at: dir.appendingPathComponent("frames/a/\(try frameNames(dir, "a")[0])"), to: dir.appendingPathComponent("frames/a/999.jpg"))
        do { _ = try await export(sessions, resume: dir); XCTFail("resumed past an unplanned frame") }
        catch MultiFramePackage.ResumeError.unexpectedFile(let p) { XCTAssertEqual(p, "frames/a/999.jpg") }
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("frames/a/999.jpg").path), "the unplanned frame is not removed")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("windows.jsonl").path), "nothing finished")
        // Not a folder at all.
        do { _ = try await export(sessions, resume: root.appendingPathComponent("nowhere")); XCTFail("resumed a missing folder") }
        catch MultiFramePackage.ResumeError.notAFolder { }
    }

    func testResumeRefusesFramesOfAnotherSizeOrAnotherVideo() async throws {
        // Written at --long-side 160 (160×90), resumed at the default (320×180): the retained frames are the wrong size.
        var sessions = try await sessions()
        let (small, _) = try await export(sessions, longSide: 160)
        try interrupt(small)
        do { _ = try await export(sessions, resume: small); XCTFail("reused frames of another size") }
        catch MultiFramePackage.ResumeError.sizeMismatch(let clip, let retained, let expected) {
            XCTAssertEqual(clip, "a"); XCTAssertEqual(retained, "160×90"); XCTAssertEqual(expected, "320×180")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: small.appendingPathComponent("windows.jsonl").path))
        // Written from one video, resumed with another under the same name: the sample does not match.
        try FileManager.default.removeItem(at: small)
        let (dir, _) = try await export(sessions)
        try interrupt(dir)
        sessions = try await self.sessions(seedA: 1)
        do { _ = try await export(sessions, resume: dir); XCTFail("reused frames of another video") }
        catch MultiFramePackage.ResumeError.sourceMismatch(let clip, _, let difference) {
            XCTAssertEqual(clip, "a"); XCTAssertGreaterThan(difference, ExportIO.sameFrame)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("windows.jsonl").path))
    }

    func testResumeReplacesAFewTornFramesButNotAFolderFullOfThem() async throws {
        let sessions = try await sessions()
        let (dir, _) = try await export(sessions)
        try interrupt(dir)
        let names = try frameNames(dir, "a")
        for name in names.prefix(MultiFramePackage.maxInvalidPerClip + 1) {
            let url = dir.appendingPathComponent("frames/a/\(name)")
            try Data(contentsOf: url).prefix(500).write(to: url)
        }
        do { _ = try await export(sessions, resume: dir); XCTFail("trusted a folder full of torn frames") }
        catch MultiFramePackage.ResumeError.tooManyInvalid(let clip, let count, let limit) {
            XCTAssertEqual(clip, "a"); XCTAssertEqual(count, limit + 1); XCTAssertEqual(limit, MultiFramePackage.maxInvalidPerClip)
        }
        // The torn files are still there, untouched: the folder was refused, not repaired.
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("frames/a/\(names[0])")).count, 500)
    }

    // MARK: - Pieces

    func testFrameInspectionTellsWholeJPEGsFromTornOrForeignFiles() throws {
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = ctx.makeImage()!
        let jpeg = try XCTUnwrap(SamplerImageTools.jpegData(image, quality: 0.85))
        XCTAssertEqual(ExportIO.inspectFrame(jpeg), .valid(width: 40, height: 30))
        XCTAssertEqual(ExportIO.inspectFrame(jpeg.prefix(jpeg.count / 2)), .invalid("incomplete (no end marker)"))
        XCTAssertEqual(ExportIO.inspectFrame(Data("not an image at all".utf8)), .invalid("not a JPEG (no start marker)"))
        XCTAssertEqual(ExportIO.inspectFrame(Data()), .invalid("not a JPEG (no start marker)"))
        // A PNG wearing JPEG markers at both ends is still not a JPEG.
        let png = NSMutableData()
        let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
        var dressed = Data([0xFF, 0xD8, 0xFF]); dressed.append(png as Data); dressed.append(contentsOf: [0xFF, 0xD9])
        XCTAssertEqual(ExportIO.inspectFrame(dressed), .invalid("does not decode"))
        // The same picture through a JPEG round trip is the same frame; a different picture is not.
        let again = try XCTUnwrap(ExportIO.decodeFrame(jpeg))
        XCTAssertLessThan(ExportIO.meanDifference(image, again), ExportIO.sameFrame)
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        XCTAssertGreaterThan(ExportIO.meanDifference(ctx.makeImage()!, again), ExportIO.sameFrame)
    }

    func testRetryingIsBoundedAndNeverRetriesAFinalError() async throws {
        var calls = 0
        var slept: [TimeInterval] = []
        let policy = ExportIO.Retry(delays: [1, 2, 3])
        let value = try await ExportIO.retrying("writing", anchors: [], policy: policy, sleep: { slept.append($0) }) {
            calls += 1
            if calls < 3 { throw CocoaError(.fileWriteUnknown) }
            return 7
        }
        XCTAssertEqual(value, 7); XCTAssertEqual(calls, 3); XCTAssertEqual(slept, [1, 2])

        calls = 0; slept = []
        do {
            _ = try await ExportIO.retrying("writing", anchors: [], policy: policy, sleep: { slept.append($0) }) { () throws -> Int in
                calls += 1; throw CocoaError(.fileWriteUnknown)
            }
            XCTFail("kept going")
        } catch ExportIO.Failure.gaveUp(let what, let attempts, _) { XCTAssertEqual(what, "writing"); XCTAssertEqual(attempts, 4) }
        XCTAssertEqual(calls, 4); XCTAssertEqual(slept, [1, 2, 3])

        // A plan violation is final: once, no pause.
        calls = 0; slept = []
        do {
            _ = try await ExportIO.retrying("listing", anchors: [], policy: policy, sleep: { slept.append($0) }) { () throws -> Int in
                calls += 1; throw MultiFramePackage.ResumeError.strayClipFolder("frames/zzz")
            }
            XCTFail("retried a final error")
        } catch MultiFramePackage.ResumeError.strayClipFolder { }
        XCTAssertEqual(calls, 1); XCTAssertEqual(slept, [])

        // A lost volume is final too: the first failure is checked against the anchors, nothing is retried.
        let folder = root.appendingPathComponent("volume")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let anchor = try ExportIO.Anchor(path: folder.path)
        try FileManager.default.removeItem(at: folder)
        calls = 0; slept = []
        do {
            _ = try await ExportIO.retrying("writing", anchors: [anchor], policy: policy, sleep: { slept.append($0) }) { () throws -> Int in
                calls += 1; throw CocoaError(.fileWriteUnknown)
            }
            XCTFail("retried on a lost volume")
        } catch ExportIO.Failure.volumeLost(let path, _) { XCTAssertEqual(path, folder.path) }
        XCTAssertEqual(calls, 1); XCTAssertEqual(slept, [])
    }

    func testAnchorNoticesAReplacedFolderOrFileEvenThroughALink() throws {
        let fm = FileManager.default
        let folder = root.appendingPathComponent("mount")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let anchor = try ExportIO.Anchor(path: folder.path)
        XCTAssertNoThrow(try anchor.verify())
        // The same path, another folder: what a dropped mount leaves behind.
        try fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try anchor.verify()) { XCTAssertEqual($0 as? ExportIO.Failure, .volumeLost(path: folder.path, detail: "a different file system object is there now")) }
        try fm.removeItem(at: folder)
        XCTAssertThrowsError(try anchor.verify()) { XCTAssertEqual($0 as? ExportIO.Failure, .volumeLost(path: folder.path, detail: "No such file or directory")) }
        // Through a symlink the anchor is the target: a swapped target is noticed, the link itself may stay.
        let target = root.appendingPathComponent("video.mp4"), link = root.appendingPathComponent("link.mp4")
        try Data("one".utf8).write(to: target)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = try ExportIO.Anchor(path: link.path)
        XCTAssertNoThrow(try linked.verify())
        try fm.removeItem(at: target)
        try Data("two".utf8).write(to: target)
        XCTAssertThrowsError(try linked.verify())
        XCTAssertThrowsError(try ExportIO.Anchor(path: root.appendingPathComponent("absent").path))
    }
}
