//
//  MultiFramePackageResumeTests.swift
//  RallyLabTests
//
//  A multi-frame export writes every frame its windows need, whole, or
//  fails naming the frame; an export cut short is completed in place only
//  from frames proven to be whole, planned, the right size and of the same
//  video, against the journal written beside it — and a finished package,
//  another run, a stray folder or a foreign file is refused without
//  touching anything.
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

    /// An H.264 clip — 3 s at 30 fps by default — whose picture depends on `seed` (another seed
    /// is another video) and changes a little every frame. `irregular`: frames of uneven
    /// duration (1 and 2 ticks of 1/(2·fps) in turn), as a phone that drops frames leaves.
    /// `keyFrameEvery`: the encoder's key-frame interval in frames (its default otherwise).
    private func video(_ name: String, seed: Int = 0, width: Int = 320, height: Int = 180, frames: Int = 90, fps: Int32 = 30,
                       irregular: Bool = false, keyFrameEvery: Int? = nil) async throws -> URL {
        let url = root.appendingPathComponent("footage/\(name).mp4")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if let keyFrameEvery { settings[AVVideoCompressionPropertiesKey] = [AVVideoMaxKeyFrameIntervalKey: keyFrameEvery] }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var band = [UInt8](repeating: 255, count: width * 4)   // one row of the picture: rows of a 4-pixel band are alike
        var ticks: CMTimeValue = 0
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pixels = buffer
            else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let left = (i * 3) % (width - 40)
            for y in 0..<height {
                if y % 4 == 0 {
                    for x in 0..<width {
                        band[x * 4] = UInt8((seed * 97 + x / 4 + y / 4) % 160)
                        band[x * 4 + 1] = UInt8((seed * 31 + i) % 200)
                        band[x * 4 + 2] = UInt8((seed * 53) % 200)
                    }
                }
                band.withUnsafeBytes { (base + y * stride).update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: width * 4) }
                if y >= 40 && y < 80 { (base + y * stride + left * 4).update(repeating: 255, count: 40 * 4) }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let time = irregular ? CMTime(value: ticks, timescale: fps * 2) : CMTime(value: CMTimeValue(i), timescale: fps)
            ticks += i % 3 == 0 ? 1 : 2
            guard adaptor.append(pixels, withPresentationTime: time) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Every frame's presentation time in `video`, by the exporter's file-name key.
    private func presentationTimes(of video: URL) async throws -> [Int64: CMTime] {
        let tracks = try await AVURLAsset(url: video).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        var times: [Int64: CMTime] = [:]
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: .zero) else { return times }
        repeat {
            let t = cursor.presentationTimeStamp
            times[Int64((t.seconds * 1_000_000).rounded())] = t
        } while cursor.stepInPresentationOrder(byCount: 1) == 1
        return times
    }

    /// An image generator set up as the exporter's (`ClipFrames`): frames as stored, capped at
    /// `MultiFramePackage.longSide`, exact moments only.
    private func generator(for video: URL) async throws -> AVAssetImageGenerator {
        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let natural = try await XCTUnwrap(tracks.first).load(.naturalSize)
        let scale = min(1, MultiFramePackage.longSide / max(natural.width, natural.height))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false
        generator.maximumSize = CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    /// The frames at `times`, each decoded on its own (one seek per frame, what the exporter did
    /// before batched validation), encoded as the exporter encodes them.
    private func singleSeek(_ generator: AVAssetImageGenerator, _ times: [CMTime]) async throws -> [Data] {
        var out: [Data] = []
        for t in times {
            let image = try await generator.image(at: t).image
            out.append(try XCTUnwrap(SamplerImageTools.jpegData(image, quality: MultiFramePackage.jpegQuality)))
        }
        return out
    }

    /// The same frames asked for together, `batch` at a time, each matched to its requested moment.
    private func batched(_ generator: AVAssetImageGenerator, _ times: [CMTime], batch: Int = MultiFramePackage.validationBatch) async throws -> [Data] {
        var byKey: [Int64: Data] = [:]
        for start in stride(from: 0, to: times.count, by: batch) {
            for await result in generator.images(for: Array(times[start..<min(start + batch, times.count)])) {
                byKey[Int64((result.requestedTime.seconds * 1_000_000).rounded())] = try XCTUnwrap(SamplerImageTools.jpegData(try result.image, quality: MultiFramePackage.jpegQuality))
            }
        }
        return try times.map { try XCTUnwrap(byKey[Int64(($0.seconds * 1_000_000).rounded())]) }
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

    private func export(_ sessions: [VideoSession], longSide: CGFloat = MultiFramePackage.longSide, resume: URL? = nil,
                        identity: [String: String] = [:], beforeZip: ((URL) throws -> Void)? = nil) async throws -> (dir: URL, summary: MultiFramePackage.Summary) {
        let result = try await MultiFramePackage.export(sessions: sessions, store: DatasetStore(root: root), name: "Fixture-L2", longSide: longSide,
                                                        resume: resume, identity: identity, beforeZip: beforeZip, now: now) { _, _ in }
        let dir = result.output.pathExtension == "zip" ? result.output.deletingPathExtension() : result.output
        return (dir, result.summary)
    }

    private func journalLines(_ dir: URL) throws -> [String] {
        try String(contentsOf: ExportJournal.url(forPackage: dir), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// Turns a finished export into what an interrupted one leaves: no zip, no top-level files,
    /// and a journal that stops where the run stopped — after `keepFrames` frame lines (all of
    /// them by default), without its closing states, optionally with a torn last line. With
    /// `journal: false` the journal is gone: an export from before journals.
    private func interrupt(_ dir: URL, keepFrames: Int? = nil, tornTail: Bool = false, journal: Bool = true) throws {
        let fm = FileManager.default
        try fm.removeItem(at: dir.deletingPathExtension().appendingPathExtension("zip"))
        for f in ["windows.jsonl", "README.txt", "summary.json"] { try fm.removeItem(at: dir.appendingPathComponent(f)) }
        let url = ExportJournal.url(forPackage: dir)
        guard journal else { return try fm.removeItem(at: url) }
        var lines = try journalLines(dir)
        var kept: [String] = []
        var frames = 0
        for line in lines {
            if line.contains("\"type\":\"frame\"") {
                frames += 1
                if let keepFrames, frames > keepFrames { continue }
            } else if line.contains("\"type\":\"clip\"") && keepFrames != nil { continue }
            else if line.contains("\"type\":\"state\"") && !line.contains("in_progress") { continue }
            kept.append(line)
        }
        lines = kept
        var text = lines.joined(separator: "\n") + "\n"
        if tornTail { text += "{\"type\":\"frame\",\"clip\":\"a\",\"key\":12" }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func hashes(_ dir: URL) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try XCTUnwrap(DatasetSplitManifest.canonicalFileHashes(ofDirectory: dir)).map { ($0.path, $0.sha256) })
    }

    /// The package's files except the two that carry run metadata (summary.json: createdAt and the resume report; README.txt: the same in words).
    private func payload(_ dir: URL) throws -> [String: String] { try hashes(dir).filter { $0.key != "summary.json" && $0.key != "README.txt" } }

    private func frameNames(_ dir: URL, _ clip: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("frames/\(clip)").path).sorted()
    }

    private func ledgerRows(ref: String) throws -> [DatasetSplitManifest.ExposureLogRow] {
        let url = ExposureLog.url(in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([DatasetSplitManifest.ExposureLogRow].self, from: Data(contentsOf: url)).filter { $0.ref == ref }
    }

    private func footageHashes() throws -> [String: String] { try hashes(root.appendingPathComponent("footage")) }

    /// The lineage preflight as `--package-l2` runs it, for the two fixture clips.
    private func preflight(_ dir: URL) throws -> LineagePackage.Preflight {
        let plan = LineagePackage.Plan(lineage: "L2", project: "Fixture", createdAt: now, generator: "test",
                                       manifestHashes: .init(projectJson: "p", sessions: "s", validationJson: "v"), audit: .init(hard: 0, soft: 0, info: 0),
                                       withheld: [.init(video: "w", split: .lineageHoldout, reservedAs: "listed", aliasGroup: "w", identities: [])], withheldClosure: ["w"],
                                       eligible: [.init(video: "a", split: .devVal, packageSplit: "val", aliasGroup: "a", identities: [], reviewedFrames: 2, ralliesMarked: false),
                                                  .init(video: "b", split: .train, packageSplit: "train", aliasGroup: "b", identities: [], reviewedFrames: 1, ralliesMarked: false)])
        return try LineagePackage.preflight(packageDir: dir, plan: plan, sourceFingerprints: ["a": "file:A", "b": "file:B"], protectedSources: ["file:W"],
                                            protectedHashes: ["0000"], now: now)
    }

    // MARK: - Fresh export

    func testExportWritesEveryNeededFrameWholeAndJournalsIt() async throws {
        let sessions = try await sessions()
        let before = try footageHashes()
        let (dir, summary) = try await export(sessions)
        XCTAssertNil(summary.resume)
        XCTAssertEqual(summary.frames, 32 + 17, "a: frames 37…68, b: frames 22…38")
        XCTAssertEqual(try frameNames(dir, "a").count, 32)
        XCTAssertEqual(try frameNames(dir, "b").count, 17)
        for (path, _) in try hashes(dir) where path.hasPrefix("frames/") {
            XCTAssertFalse(path.hasSuffix(ExportIO.partialSuffix), "no .part left behind: \(path)")
            guard case .valid(let w, let h) = ExportIO.inspectFrame(try Data(contentsOf: dir.appendingPathComponent(path))) else { return XCTFail("\(path) is not a whole JPEG") }
            XCTAssertEqual([w, h], [320, 180])
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("windows.jsonl"), encoding: .utf8).split(separator: "\n").count, 3)
        // The journal beside the folder, never inside it: a header with the run identity, every frame with its hash, the states.
        XCTAssertEqual(Set(try hashes(dir).keys.filter { !$0.hasPrefix("frames/") }), ["README.txt", "summary.json", "windows.jsonl"])
        let journal = try ExportJournal.read(ExportJournal.url(forPackage: dir), forPackage: dir.lastPathComponent)
        XCTAssertEqual(journal.state, .finalized)
        XCTAssertEqual(journal.states, [.inProgress, .finalized])
        XCTAssertEqual(journal.completedClips, ["a", "b"])
        XCTAssertEqual(journal.frames["a"]?.count, 32); XCTAssertEqual(journal.frames["b"]?.count, 17)
        XCTAssertFalse(journal.tornTail)
        XCTAssertEqual(journal.identity.exporter, MultiFramePackage.exporterVersion)
        XCTAssertEqual(journal.identity.clips["a"]?.plannedKeys, 32)
        XCTAssertEqual(journal.identity.clips["a"]?.sourceFingerprint, ProjectsModel.fileFingerprint(atPath: root.appendingPathComponent("footage/a.mp4").path))
        for (path, sha) in try hashes(dir) where path.hasPrefix("frames/") {
            let parts = path.split(separator: "/")
            XCTAssertEqual(journal.frames[String(parts[1])]?[Int64(parts[2].dropLast(4))!]?.sha256, sha, "journal hash of \(path)")
        }
        XCTAssertEqual(try ledgerRows(ref: dir.lastPathComponent).map(\.video), ["a", "b"])
        XCTAssertEqual(try footageHashes(), before, "the footage is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("footage/a.rallylabels.json").path), "no sidecar was created")
    }

    // MARK: - Resume

    func testResumeCompletesAnInterruptedExportReusingOnlyProvenFrames() async throws {
        let sessions = try await sessions()
        let (dir, _) = try await export(sessions)
        let freshPayload = try payload(dir)
        let windowsBefore = try Data(contentsOf: dir.appendingPathComponent("windows.jsonl"))
        let fm = FileManager.default
        // The run stopped after journaling 32 + 3 frames, mid-write of the next line; clip b has only 5 frames on disk;
        // one of a's journaled frames was torn afterwards; a .part was left behind.
        try interrupt(dir, keepFrames: 35, tornTail: true)
        // (Frame names sort as numbers: the journal's first three of b are its earliest moments.)
        let bFrames = try frameNames(dir, "b").sorted { Int64($0.dropLast(4))! < Int64($1.dropLast(4))! }
        for name in bFrames.dropFirst(5) { try fm.removeItem(at: dir.appendingPathComponent("frames/b/\(name)")) }
        let torn = try frameNames(dir, "a")[3]
        let tornURL = dir.appendingPathComponent("frames/a/\(torn)")
        try Data(contentsOf: tornURL).prefix(1000).write(to: tornURL)
        try Data("half".utf8).write(to: dir.appendingPathComponent("frames/a/1233333.jpg.part"))
        let ledgerBefore = try ledgerRows(ref: dir.lastPathComponent)

        var preflighted: LineagePackage.Preflight?
        let (resumedDir, summary) = try await export(sessions, resume: dir, beforeZip: { preflighted = try self.preflight($0) })
        XCTAssertEqual(resumedDir.path, dir.path)
        let report = try XCTUnwrap(summary.resume)
        XCTAssertEqual(report.from, dir.lastPathComponent)
        XCTAssertFalse(report.legacy); XCTAssertTrue(report.identityVerified)
        XCTAssertTrue(report.journal.contains("35 frames journaled") && report.journal.contains("last line torn") && report.journal.contains("state interrupted"), report.journal)
        XCTAssertEqual(report.retainedByJournal, 31 + 3, "a's journaled frames but the torn one; b's three journaled ones")
        XCTAssertEqual(report.retainedByRegeneration, 2, "b's two frames past the journal's end, proven byte-identical to their regeneration")
        XCTAssertEqual(report.framesRetained, 36)
        XCTAssertEqual(report.framesReplaced, 1); XCTAssertEqual(report.replaced, ["frames/a/\(torn)"])
        XCTAssertEqual(report.framesWritten, 12)
        XCTAssertEqual(report.partialFilesRemoved, 1)
        XCTAssertEqual(report.clips.map(\.toWrite), [0, 12])
        XCTAssertEqual(summary.frames, 49, "the whole package, not only what this run wrote")

        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("windows.jsonl")), windowsBefore, "the same windows as the uninterrupted export")
        XCTAssertEqual(try payload(dir), freshPayload, "every frame byte-identical to the uninterrupted export's")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("frames/a/1233333.jpg.part").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.deletingPathExtension().appendingPathExtension("zip").path), "the resumed export finishes like a fresh one")
        let p = try XCTUnwrap(preflighted)
        XCTAssertTrue(p.passed, p.checks.filter { !$0.passed }.map { "\($0.name): \($0.detail)" }.joined(separator: "; "))
        XCTAssertTrue(p.checks.contains { $0.name == "no-stray-files" && $0.passed }, "the journal lives beside the package, not in it")
        XCTAssertEqual(p.digest, DatasetSplitManifest.canonicalDigest(ofDirectory: dir))
        // The ledger: one row per video, written once the package passed its checks; the failed run had none, the resumed run adds none twice.
        XCTAssertEqual(ledgerBefore.map(\.video), ["a", "b"], "the fresh fixture export had recorded its own rows")
        XCTAssertEqual(try ledgerRows(ref: dir.lastPathComponent).count, 2)
        let journal = try ExportJournal.read(ExportJournal.url(forPackage: dir), forPackage: dir.lastPathComponent)
        XCTAssertEqual(journal.state, .finalized)
        XCTAssertEqual(journal.states, [.inProgress, .inProgress, .preflightPassed, .finalized])
        XCTAssertEqual(journal.frames["a"]?.count, 32); XCTAssertEqual(journal.frames["b"]?.count, 17)
        XCTAssertFalse(journal.tornTail, "the torn line was cut off before the resumed run appended")
    }

    func testResumeOfALegacyFolderProvesEveryFrameByRegeneration() async throws {
        let sessions = try await sessions()
        let (dir, _) = try await export(sessions)
        let freshPayload = try payload(dir)
        try interrupt(dir, journal: false)
        for name in try frameNames(dir, "b").dropFirst(10) { try FileManager.default.removeItem(at: dir.appendingPathComponent("frames/b/\(name)")) }
        // Read-only first: what would be reused, nothing changed.
        let before = try hashes(dir)
        let inspection = try await MultiFramePackage.inspectResume(sessions: sessions, store: DatasetStore(root: root), resume: dir)
        XCTAssertTrue(inspection.legacy); XCTAssertFalse(inspection.identityVerified); XCTAssertEqual(inspection.journal, "none")
        XCTAssertEqual(inspection.retainedByJournal, 0); XCTAssertEqual(inspection.retainedByRegeneration, 42)
        XCTAssertEqual(inspection.clips.map(\.toWrite), [0, 7])
        XCTAssertEqual(try hashes(dir), before, "inspection wrote nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportJournal.url(forPackage: dir).path), "inspection started no journal")

        let (_, summary) = try await export(sessions, resume: dir)
        let report = try XCTUnwrap(summary.resume)
        XCTAssertTrue(report.legacy)
        XCTAssertEqual(report.retainedByRegeneration, 42); XCTAssertEqual(report.retainedByJournal, 0)
        XCTAssertEqual(report.framesWritten, 7); XCTAssertEqual(report.framesReplaced, 0)
        XCTAssertEqual(try payload(dir), freshPayload)
        let journal = try ExportJournal.read(ExportJournal.url(forPackage: dir), forPackage: dir.lastPathComponent)
        XCTAssertEqual(journal.frames["a"]?.count, 32, "frames proven by regeneration are journaled for the next time")
        XCTAssertEqual(journal.frames["b"]?.count, 17)
    }

    // MARK: - Batched validation

    /// A frame regenerated in a batch is the frame regenerated on its own, byte for byte — at
    /// 30 fps, at 60 fps and with frames of uneven duration — so the frames a legacy folder
    /// holds (written by the batch path) are all proven by the batched validation, and the
    /// package completed from it is the fresh package.
    func testBatchedValidationProvesWhatSingleSeeksWouldAt30And60FpsAndWithUnevenFrames() async throws {
        let variants: [(name: String, frames: Int, fps: Int32, irregular: Bool, moments: [Double])] = [
            ("thirty", 90, 30, false, [1.5, 2.0]),
            ("sixty", 180, 60, false, [1.5, 2.0]),
            ("uneven", 120, 30, true, [1.5, 2.0])
        ]
        for v in variants {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("mfp-\(v.name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let a = try await video("a", frames: v.frames, fps: v.fps, irregular: v.irregular)
            let b = try await video("b", seed: 7, frames: v.frames, fps: v.fps, irregular: v.irregular)
            let sessions = [session("a", split: "val", video: a, times: v.moments), session("b", split: "train", video: b, times: [1.0])]
            let (dir, fresh) = try await export(sessions)
            let freshPayload = try payload(dir)
            // Every written frame against its single-seek regeneration, and the batch against the single seeks.
            for (clip, video) in [("a", a), ("b", b)] {
                let times = try await presentationTimes(of: video)
                let gen = try await generator(for: video)
                let names = try frameNames(dir, clip)
                let moments = try names.map { try XCTUnwrap(times[Int64($0.dropLast(4))!], "\(v.name) \(clip)/\($0): not a frame of the video") }
                let single = try await singleSeek(gen, moments)
                let batch = try await batched(gen, moments)
                for (i, name) in names.enumerated() {
                    let stored = try Data(contentsOf: dir.appendingPathComponent("frames/\(clip)/\(name)"))
                    XCTAssertEqual(stored, single[i], "\(v.name) \(clip)/\(name): the written frame is not its single-seek regeneration")
                    XCTAssertEqual(batch[i], single[i], "\(v.name) \(clip)/\(name): batch and single seek differ")
                }
            }
            try interrupt(dir, journal: false)
            let before = try hashes(dir)
            let inspection = try await MultiFramePackage.inspectResume(sessions: sessions, store: DatasetStore(root: root), resume: dir)
            XCTAssertEqual(inspection.retainedByRegeneration, fresh.frames, v.name)
            XCTAssertEqual(inspection.framesReplaced, 0, v.name); XCTAssertEqual(inspection.clips.map(\.toWrite), [0, 0], v.name)
            XCTAssertEqual(try hashes(dir), before, "\(v.name): inspection wrote nothing")
            let (_, summary) = try await export(sessions, resume: dir)
            XCTAssertEqual(summary.resume?.retainedByRegeneration, fresh.frames, v.name)
            XCTAssertEqual(summary.resume?.framesWritten, 0, v.name)
            XCTAssertEqual(try payload(dir), freshPayload, "\(v.name): the completed package is not the fresh one")
        }
    }

    /// With more frames than one batch holds, torn and missing frames in different batches are
    /// judged in the order found, the invalid limit counts across batches, and a refused folder
    /// is left as it was.
    func testBatchedValidationJudgesAcrossBatchesInTheOrderFound() async throws {
        // 10 s at 30 fps, a window every 0.5 s: 300 frames needed in one clip, several batches.
        let a = try await video("a", frames: 300)
        let b = try await video("b", seed: 7)
        let sessions = [session("a", split: "val", video: a, times: stride(from: 0.5, through: 9.5, by: 0.5).map { $0 }),
                        session("b", split: "train", video: b, times: [1.0])]
        let (dir, fresh) = try await export(sessions)
        let freshPayload = try payload(dir)
        let names = try frameNames(dir, "a")
        XCTAssertGreaterThan(names.count, 2 * MultiFramePackage.validationBatch, "the fixture must span several batches")
        try interrupt(dir, journal: false)
        let fm = FileManager.default
        // Three torn frames, one per batch; four missing ones, likewise spread.
        let torn = [5, MultiFramePackage.validationBatch + 3, 2 * MultiFramePackage.validationBatch + 7].map { names[$0] }
        let gone = [1, MultiFramePackage.validationBatch - 1, MultiFramePackage.validationBatch, names.count - 1].map { names[$0] }
        for name in torn { let url = dir.appendingPathComponent("frames/a/\(name)"); try Data(contentsOf: url).prefix(700).write(to: url) }
        for name in gone { try fm.removeItem(at: dir.appendingPathComponent("frames/a/\(name)")) }
        let inspection = try await MultiFramePackage.inspectResume(sessions: sessions, store: DatasetStore(root: root), resume: dir)
        XCTAssertEqual(inspection.retainedByRegeneration, fresh.frames - 7)
        XCTAssertEqual(inspection.replaced, torn.map { "frames/a/\($0)" }, "replaced frames are listed in the order found")
        XCTAssertEqual(inspection.clips.map(\.toWrite), [4, 0])
        let (_, summary) = try await export(sessions, resume: dir)
        XCTAssertEqual(summary.resume?.framesReplaced, 3); XCTAssertEqual(summary.resume?.framesWritten, 4)
        XCTAssertEqual(try payload(dir), freshPayload)

        // Too many torn frames, spread over the batches: refused once the limit is passed, nothing touched.
        try interrupt(dir)
        let spread = (0...MultiFramePackage.maxInvalidPerClip).map { names[$0 * (names.count / (MultiFramePackage.maxInvalidPerClip + 1))] }
        for name in spread { let url = dir.appendingPathComponent("frames/a/\(name)"); try Data(contentsOf: url).prefix(700).write(to: url) }
        let before = try hashes(dir)
        do { _ = try await export(sessions, resume: dir); XCTFail("trusted a folder with torn frames in every batch") }
        catch MultiFramePackage.ResumeError.tooManyInvalid(let clip, let count, let limit) {
            XCTAssertEqual(clip, "a"); XCTAssertEqual(count, limit + 1)
        }
        XCTAssertEqual(try hashes(dir), before, "a refused folder is left as it was")
    }

    /// Another spelling of a frame's number (`0123.jpg` beside `123.jpg`) is not a frame of this
    /// export: refused before anything is judged, so two files can never claim one moment.
    func testResumeRefusesAnAliasedFrameName() async throws {
        let sessions = try await sessions()
        let (dir, _) = try await export(sessions)
        let fm = FileManager.default
        for journal in [false, true] {
            try interrupt(dir, journal: journal)
            let name = try frameNames(dir, "a")[3]
            let alias = dir.appendingPathComponent("frames/a/0\(name)")
            try fm.copyItem(at: dir.appendingPathComponent("frames/a/\(name)"), to: alias)
            let before = try hashes(dir)
            do { _ = try await MultiFramePackage.inspectResume(sessions: sessions, store: DatasetStore(root: root), resume: dir); XCTFail("accepted an aliased frame name") }
            catch MultiFramePackage.ResumeError.unexpectedFile(let path) { XCTAssertEqual(path, "frames/a/0\(name)") }
            do { _ = try await export(sessions, resume: dir); XCTFail("resumed over an aliased frame name") }
            catch MultiFramePackage.ResumeError.unexpectedFile(let path) { XCTAssertEqual(path, "frames/a/0\(name)") }
            XCTAssertEqual(try hashes(dir), before, "refused without touching the folder")
            try fm.removeItem(at: alias)
            _ = try await export(sessions, resume: dir)   // whole again, for the next round
        }
    }

    /// Representative timing, not a pass/fail test: how long regenerating a legacy folder's frames
    /// takes one seek at a time against batched, on a synthetic 1280×720 clip with a key frame
    /// every second — contiguous frames (a tracked rally) and isolated windows (sampled frames).
    /// Runs only with RALLYLAB_BENCHMARK set; prints frames per second.
    func testBenchmarkBatchedAgainstSingleSeekRegeneration() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RALLYLAB_BENCHMARK"] != nil, "set RALLYLAB_BENCHMARK=1 to run the benchmark")
        for fps: Int32 in [30, 60] {
            let frames = Int(fps) * 20
            let clip = try await video("bench\(fps)", width: 1280, height: 720, frames: frames, fps: fps, keyFrameEvery: Int(fps))
            let times = try await presentationTimes(of: clip)
            let gen = try await generator(for: clip)
            let sorted = times.values.sorted { $0 < $1 }
            let step = max(1, Int((Double(fps) / MultiFramePackage.frameRate).rounded()))
            func window(_ seconds: Double) -> [CMTime] {
                let centre = Int((seconds * Double(fps)).rounded())
                return (-MultiFramePackage.span...MultiFramePackage.span).map { sorted[centre + $0 * step] }
            }
            for (label, moments) in [("contiguous (a window every 0.5 s)", stride(from: 1.0, through: 19.0, by: 0.5).map { $0 }),
                                     ("isolated (a window every 2 s)", stride(from: 1.0, through: 19.0, by: 2.0).map { $0 })] {
                let wanted = Array(Set(moments.flatMap(window))).sorted { $0 < $1 }
                let t0 = Date()
                let single = try await singleSeek(gen, wanted)
                let t1 = Date()
                let batch = try await batched(gen, wanted)
                let t2 = Date()
                XCTAssertEqual(single, batch, "\(fps) fps \(label): batch and single seek differ")
                let s = t1.timeIntervalSince(t0), b = t2.timeIntervalSince(t1)
                print(String(format: "BENCH %d fps, %@: %d frames — single seek %.1f s (%.1f frames/s), batched %.1f s (%.1f frames/s), ×%.1f",
                             fps, label, wanted.count, s, Double(wanted.count) / s, b, Double(wanted.count) / b, s / b))
            }
        }
    }

    func testResumeTwiceAddsNothingTwice() async throws {
        let sessions = try await sessions()
        let (dir, _) = try await export(sessions)
        let freshPayload = try payload(dir)
        try interrupt(dir, keepFrames: 10)
        for name in try frameNames(dir, "b") { try FileManager.default.removeItem(at: dir.appendingPathComponent("frames/b/\(name)")) }
        _ = try await export(sessions, resume: dir)
        // Interrupted again after that, and resumed again.
        try interrupt(dir, keepFrames: 40)
        for name in try frameNames(dir, "b").dropFirst(2) { try FileManager.default.removeItem(at: dir.appendingPathComponent("frames/b/\(name)")) }
        let (_, summary) = try await export(sessions, resume: dir)
        let report = try XCTUnwrap(summary.resume)
        XCTAssertEqual(report.framesRetained, 34); XCTAssertEqual(report.framesWritten, 15)
        XCTAssertEqual(try payload(dir), freshPayload)
        XCTAssertEqual(try ledgerRows(ref: dir.lastPathComponent).count, 2, "one row per video, however many runs")
        let journal = try ExportJournal.read(ExportJournal.url(forPackage: dir), forPackage: dir.lastPathComponent)
        XCTAssertEqual(journal.frames["a"]?.count, 32); XCTAssertEqual(journal.frames["b"]?.count, 17)
        XCTAssertEqual(journal.states.filter { $0 == .finalized }.count, 1)
        // A finished package is never resumed into.
        do { _ = try await export(sessions, resume: dir); XCTFail("resumed a finished package") }
        catch MultiFramePackage.ResumeError.notResumable { }
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
        // A journal that says the run finished, with the folder stripped: refused on the state.
        try fm.removeItem(at: dir.appendingPathComponent("frames/a/999.jpg"))
        let url = ExportJournal.url(forPackage: dir)
        try (try journalLines(dir).joined(separator: "\n") + "\n{\"type\":\"state\",\"state\":\"finalized\",\"at\":\"2026-10-22T20:00:00Z\"}\n").write(to: url, atomically: true, encoding: .utf8)
        do { _ = try await export(sessions, resume: dir); XCTFail("resumed a finalized journal") }
        catch MultiFramePackage.ResumeError.wrongState(let st) { XCTAssertEqual(st, "finalized") }
        // Not a folder at all.
        do { _ = try await export(sessions, resume: root.appendingPathComponent("nowhere")); XCTFail("resumed a missing folder") }
        catch MultiFramePackage.ResumeError.notAFolder { }
    }

    func testResumeRefusesAnotherRunIdentityAndAnotherVideo() async throws {
        // The journal's identity: another --long-side, another caller identity, another source file — each named, nothing changed.
        var sessions = try await sessions()
        let (dir, _) = try await export(sessions, identity: ["manifest": "m1"])
        try interrupt(dir)
        let before = try hashes(dir)
        do { _ = try await export(sessions, longSide: 160, resume: dir, identity: ["manifest": "m1"]); XCTFail("resumed at another size") }
        catch MultiFramePackage.ResumeError.identityMismatch(let d) { XCTAssertEqual(d, ["longSide: journal 1024.0, now 160.0"]) }
        do { _ = try await export(sessions, resume: dir, identity: ["manifest": "m2"]); XCTFail("resumed under another manifest") }
        catch MultiFramePackage.ResumeError.identityMismatch(let d) { XCTAssertEqual(d, ["extra.manifest: journal m1, now m2"]) }
        sessions = try await self.sessions(seedA: 1)
        do { _ = try await export(sessions, resume: dir, identity: ["manifest": "m1"]); XCTFail("resumed with another video") }
        catch MultiFramePackage.ResumeError.identityMismatch(let d) {
            XCTAssertTrue(d.contains { $0.hasPrefix("clip a.sourceFingerprint:") }, d.joined(separator: "; "))
            XCTAssertTrue(d.contains { $0.hasPrefix("clip a.sourceModified:") || $0.hasPrefix("clip a.sourceBytes:") }, d.joined(separator: "; "))
        }
        XCTAssertEqual(try hashes(dir), before, "nothing touched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("windows.jsonl").path))
        // Without a journal the frames themselves give it away: none is identical to its regeneration from the other video.
        try FileManager.default.removeItem(at: ExportJournal.url(forPackage: dir))
        do { _ = try await export(sessions, resume: dir); XCTFail("reused frames of another video") }
        catch MultiFramePackage.ResumeError.tooManyInvalid(let clip, let count, let limit) {
            XCTAssertEqual(clip, "a"); XCTAssertEqual(count, limit + 1); XCTAssertEqual(limit, MultiFramePackage.maxInvalidPerClip)
        }
        XCTAssertEqual(try hashes(dir), before, "nothing touched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportJournal.url(forPackage: dir).path), "the refused resume took its new journal with it")
        // The same from a legacy folder written at another size: every frame differs from its regeneration.
        sessions = try await self.sessions()
        try FileManager.default.removeItem(at: dir)
        let (small, _) = try await export(sessions, longSide: 160)
        let smallPayload = try payload(small)
        try interrupt(small, journal: false)
        do { _ = try await export(sessions, resume: small); XCTFail("reused frames of another size") }
        catch MultiFramePackage.ResumeError.tooManyInvalid(let clip, _, _) { XCTAssertEqual(clip, "a") }
        // The refusal left no journal behind, so the right size can still resume the folder.
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportJournal.url(forPackage: small).path), "a refused resume leaves no journal")
        let (_, summary) = try await export(sessions, longSide: 160, resume: small)
        XCTAssertEqual(summary.resume?.retainedByRegeneration, 49); XCTAssertEqual(summary.resume?.framesWritten, 0)
        XCTAssertEqual(try payload(small), smallPayload)
        // Clip by clip is not enough: a's single wrong-size frame would pass as "one torn frame" and be repaired before b's
        // seventeen refuse the folder. Every clip is judged before anything is touched, so a stays as it was.
        try interrupt(small, journal: false)
        for name in try frameNames(small, "a").dropFirst() { try FileManager.default.removeItem(at: small.appendingPathComponent("frames/a/\(name)")) }
        let untouched = try hashes(small)
        do { _ = try await export(sessions, resume: small); XCTFail("reused frames of another size") }
        catch MultiFramePackage.ResumeError.tooManyInvalid(let clip, _, _) { XCTAssertEqual(clip, "b") }
        XCTAssertEqual(try hashes(small), untouched, "nothing touched in any clip, a included")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportJournal.url(forPackage: small).path))
        let (_, again) = try await export(sessions, longSide: 160, resume: small)
        XCTAssertEqual(again.resume?.clips.map(\.retainedByRegeneration), [1, 17]); XCTAssertEqual(again.resume?.framesWritten, 31)
        XCTAssertEqual(try payload(small), smallPayload)
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
            XCTAssertEqual(clip, "a"); XCTAssertEqual(count, limit + 1, "refused as soon as the limit is passed, not after the whole folder"); XCTAssertEqual(limit, MultiFramePackage.maxInvalidPerClip)
        }
        // The torn files are still there, untouched: the folder was refused, not repaired.
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("frames/a/\(names[0])")).count, 500)
    }

    func testResumedFolderSurvivesAFailedPreflight() async throws {
        let sessions = try await sessions()
        let (dir, _) = try await export(sessions)
        try interrupt(dir, keepFrames: 20)
        try FileManager.default.removeItem(at: ExposureLog.url(in: root))   // as after a run that never reached its preflight
        let framesBefore = try hashes(dir)
        struct Refused: Error {}
        do { _ = try await export(sessions, resume: dir, beforeZip: { _ in throw Refused() }); XCTFail("finished past a failed hook") }
        catch is Refused { }
        XCTAssertEqual(Set(try hashes(dir).keys.filter { !$0.hasPrefix("frames/") }), [], "frames kept, nothing that says finished")
        XCTAssertEqual(try hashes(dir).filter { framesBefore[$0.key] != nil }, framesBefore)
        XCTAssertEqual(try ledgerRows(ref: dir.lastPathComponent).count, 0, "no exposure row for a package that failed its checks")
        let journal = try ExportJournal.read(ExportJournal.url(forPackage: dir), forPackage: dir.lastPathComponent)
        XCTAssertEqual(journal.state, .preflightFailed)
        // …and it can be resumed again, now with every frame on disk.
        let (_, summary) = try await export(sessions, resume: dir)
        XCTAssertEqual(summary.resume?.framesRetained, 49); XCTAssertEqual(summary.resume?.framesWritten, 0)
        XCTAssertEqual(try ledgerRows(ref: dir.lastPathComponent).count, 2)
    }

    func testResumeRecoversARunCutShortWhileFinalizingButNotAFinishedOne() async throws {
        // windows.jsonl written, then the run died before summary.json: the journal never reached a finished state.
        let sessions = try await sessions()
        let (dir, _) = try await export(sessions)
        let freshPayload = try payload(dir)
        let fm = FileManager.default
        try interrupt(dir)
        try Data("stale".utf8).write(to: dir.appendingPathComponent("windows.jsonl"))
        try Data("stale".utf8).write(to: dir.appendingPathComponent("README.txt"))
        // Read-only inspection tolerates the leftovers and removes nothing.
        let inspection = try await MultiFramePackage.inspectResume(sessions: sessions, store: DatasetStore(root: root), resume: dir)
        XCTAssertEqual(inspection.framesRetained, 49)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("windows.jsonl")), Data("stale".utf8))
        // The resume sheds them and rebuilds them from the plan.
        let (_, summary) = try await export(sessions, resume: dir)
        XCTAssertEqual(summary.resume?.framesRetained, 49)
        XCTAssertEqual(try payload(dir), freshPayload)
        // Without a journal the same leftovers cannot be told from a finished package: refused.
        try interrupt(dir, journal: false)
        try Data("stale".utf8).write(to: dir.appendingPathComponent("windows.jsonl"))
        do { _ = try await export(sessions, resume: dir); XCTFail("resumed a journal-less folder with completion files") }
        catch MultiFramePackage.ResumeError.notResumable(_, let found) { XCTAssertEqual(found, ["frames", "windows.jsonl"]) }
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("windows.jsonl").path), "nothing removed")
        // A record or a zip is never shed, journal or not.
        try fm.removeItem(at: dir)
        let (dir2, _) = try await export(sessions)
        XCTAssertEqual(dir2.path, dir.path)
        try interrupt(dir2, keepFrames: 49)   // an unfinished journal again
        try Data("record".utf8).write(to: dir.appendingPathComponent(LineagePackage.recordFile))
        try Data("stale".utf8).write(to: dir.appendingPathComponent("windows.jsonl"))
        do { _ = try await export(sessions, resume: dir); XCTFail("resumed past a record") }
        catch MultiFramePackage.ResumeError.notResumable(_, let found) { XCTAssertEqual(found, ["frames", LineagePackage.recordFile, "windows.jsonl"]) }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("windows.jsonl")), Data("stale".utf8), "a refused folder loses nothing, stale files included")
        // Nor are stale files shed when the identity does not match.
        try fm.removeItem(at: dir.appendingPathComponent(LineagePackage.recordFile))
        do { _ = try await export(sessions, longSide: 160, resume: dir); XCTFail("resumed under another identity") }
        catch MultiFramePackage.ResumeError.identityMismatch { }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("windows.jsonl")), Data("stale".utf8))
    }

    func testJournalReadsBackWhatWasWrittenAndRefusesWhatIsNotIts() throws {
        let dir = root.appendingPathComponent("P")
        let url = ExportJournal.url(forPackage: dir)
        let identity = ExportJournal.Identity(exporter: "2", longSide: 1024, quality: 0.85, span: 8, frameRate: 30, trackStride: 2, deadStep: 3, deadMargin: 1.5,
                                              unreviewed: false, valOnly: false, extra: ["k": "v"],
                                              clips: ["a": .init(name: "a", split: "val", sourcePath: "/a.mp4", sourceFingerprint: "file:A", sourceBytes: 10, sourceModified: "t",
                                                                 sidecarSha256: nil, plannedKeysSha256: "p", plannedKeys: 3)])
        let w = try ExportJournal.Writer(creating: url, package: "P", identity: identity, now: now)
        try w.state(.inProgress, now: now)
        try w.append(.frame(clip: "a", key: 1, sha256: "s1", bytes: 5))
        try w.append(.frame(clip: "a", key: 2, sha256: "s2", bytes: 6))
        try w.append(.clipComplete(clip: "a", frames: 2))
        try w.close()
        var c = try ExportJournal.read(url, forPackage: "P")
        XCTAssertEqual(c.identity, identity); XCTAssertEqual(c.state, .interrupted); XCTAssertEqual(c.completedClips, ["a"]); XCTAssertFalse(c.tornTail)
        XCTAssertEqual(c.frames["a"]?[2]?.sha256, "s2"); XCTAssertEqual(c.frames["a"]?[2]?.bytes, 6)
        // A torn last line is dropped and reported; damage earlier is not an interruption.
        let whole = try Data(contentsOf: url).count
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"type\":\"fra".utf8)); try handle.close()
        c = try ExportJournal.read(url, forPackage: "P")
        XCTAssertTrue(c.tornTail); XCTAssertEqual(c.frames["a"]?.count, 2); XCTAssertEqual(Int(c.validLength), whole)
        let again = try ExportJournal.Writer(appendingTo: url, after: c.validLength)
        try again.append(.frame(clip: "a", key: 3, sha256: "s3", bytes: 7)); try again.close()
        c = try ExportJournal.read(url, forPackage: "P")
        XCTAssertFalse(c.tornTail); XCTAssertEqual(c.frames["a"]?.count, 3)
        XCTAssertThrowsError(try ExportJournal.read(url, forPackage: "Q")) { XCTAssertEqual($0 as? ExportJournal.JournalError, .otherPackage(url.path, journal: "P", folder: "Q")) }
        try "{\"type\":\"frame\"}\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ExportJournal.read(url, forPackage: "P")) { XCTAssertEqual($0 as? ExportJournal.JournalError, .notAJournal(url.path, detail: "no header line")) }
        try "not json\n{\"type\":\"state\",\"state\":\"finalized\",\"at\":\"t\"}\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ExportJournal.read(url, forPackage: "P")) { XCTAssertEqual($0 as? ExportJournal.JournalError, .notAJournal(url.path, detail: "line 1 does not parse")) }
        XCTAssertThrowsError(try ExportJournal.Writer(creating: url, package: "P", identity: identity, now: now), "never over an existing journal")
        // Identity differences are named field by field.
        var other = identity
        other.longSide = 512; other.extra["k"] = "w"; other.clips["a"]?.plannedKeys = 4; other.clips["b"] = other.clips["a"]
        XCTAssertEqual(identity.differences(from: other), ["longSide: journal 512.0, now 1024.0", "extra.k: journal w, now v", "clip a.plannedKeys: journal 4, now 3", "clip b: not planned now"])
        XCTAssertEqual(identity.differences(from: identity), [])
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
        // Encoding is deterministic: the same picture gives the same bytes, which is what proves a retained frame.
        XCTAssertEqual(SamplerImageTools.jpegData(image, quality: 0.85), jpeg)
        XCTAssertNotNil(ExportIO.decodeFrame(jpeg))
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
