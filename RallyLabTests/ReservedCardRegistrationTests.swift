//
//  ReservedCardRegistrationTests.swift
//  RallyLabTests
//
//  Giving a card its dataset session is not running a model over its
//  recording (owner decision 2026-11-12). A withheld card — final test,
//  lineage holdout, legacy holdout, or an alias of one — is registered with
//  the session its provenance and its labeling by hand need, and neither the
//  pipeline nor the pre-label detector is reached; every other card is
//  sampled as before; a withheld recording coming in any other way (dropped
//  under another name, queued for a card that is not its own, or queued
//  again when its card has its session) is refused; and a project whose
//  reservations or cards can't be read registers nothing.
//

import AVFoundation
import XCTest
@testable import RallyLab

@MainActor
final class ReservedCardRegistrationTests: XCTestCase {

    private var base: URL!
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private let F = DatasetSplitManifestTests.self

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rl-registration-\(UUID().uuidString)")
        root = base.appendingPathComponent("P", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("footage"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
        // A defaults suite of this test's own: a fixture never becomes the dataset RallyLab opens next.
        suite = "RallyLabTests.ReservedCardRegistration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixtures

    /// How often each model an ingest can reach was reached.
    private final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var pipelineRuns = 0, detectorsMade = 0, stillsLabeled = 0
        func pipelineRan() { lock.lock(); pipelineRuns += 1; lock.unlock() }
        func detectorMade() { lock.lock(); detectorsMade += 1; lock.unlock() }
        func stillLabeled() { lock.lock(); stillsLabeled += 1; lock.unlock() }
        var pipeline: Int { lock.lock(); defer { lock.unlock() }; return pipelineRuns }
        var detectors: Int { lock.lock(); defer { lock.unlock() }; return detectorsMade }
        var stills: Int { lock.lock(); defer { lock.unlock() }; return stillsLabeled }
        var none: Bool { pipeline == 0 && detectors == 0 && stills == 0 }
    }

    /// Stand-ins for both models: a pipeline that finds no rally in a one-second video, and a detector that
    /// boxes a ball on every still. Each counts its runs.
    private func models(_ runs: Runs) -> IngestModels {
        IngestModels(
            pipeline: { _, _ in runs.pipelineRan(); return ([], 1) },
            prelabeler: { _, _ in
                runs.detectorMade()
                return { _, time in
                    runs.stillLabeled()
                    return [DetectionResult(bbox: CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.05), confidence: 0.6, timestamp: time)]
                }
            })
    }

    /// A one-second H.264 video under footage/ whose picture depends on `seed` (another seed is another file).
    private func video(_ name: String, seed: Int) async throws -> URL {
        let url = base.appendingPathComponent("footage/\(name).mp4")
        let width = 320, height = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pixels = buffer
            else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pixels, [])
            let rows = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let p = rows + y * stride + x * 4
                    p[0] = UInt8((seed * 67 + x / 8 + i * 5) % 256)
                    p[1] = UInt8((seed * 131 + y / 8) % 256)
                    p[2] = UInt8((seed * 29 + (x + y) / 16 + i * 3) % 256)
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

    private func writeValidation(_ text: String) throws {
        try text.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
    }

    /// A project of four cards with their cut footage and no session yet: `l` the lineage holdout, `a` a train
    /// card sharing a confirmed sourceId with it (an alias), `h` the legacy holdout, `t` an ordinary train card.
    private func makeProject() async throws -> [String: URL] {
        var videos: [String: URL] = [:]
        var clips: [PlannedClip] = []
        for (i, name) in ["l", "a", "h", "t"].enumerated() {
            let url = try await video(name, seed: i + 1)
            videos[name] = url
            var source = F.source(name, fingerprint: try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: url.path)),
                                  sourceId: ["l", "a"].contains(name) ? "camera-roll-1" : nil)
            source.clipFile = url.path
            clips.append(F.clip(name, split: "train", videos: [source]))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: "P", createdAt: F.day, framesPerRally: 4, clips: clips)).write(to: root.appendingPathComponent("project.json"))
        try writeValidation(#"{"tune":[],"holdout":["h"],"finalTest":[],"lineageHoldout":["l"]}"#)
        return videos
    }

    private func copy(of video: URL, named name: String) throws -> URL {
        let copy = base.appendingPathComponent("footage/\(name).mp4")
        try FileManager.default.copyItem(at: video, to: copy)
        return copy
    }

    private func makeSampler(_ runs: Runs) -> SamplerModel {
        SamplerModel(defaults: defaults, root: root, models: models(runs))
    }

    private func drain(_ sampler: SamplerModel) async throws {
        while sampler.isIngesting || sampler.queue.contains(where: { !$0.isFinished }) { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func sessions() throws -> [String: VideoSession] {
        Dictionary(uniqueKeysWithValues: try DatasetStore(root: root).loadSessionsStrict().map { ($0.name, $0) })
    }

    /// Every still and label file anywhere in the dataset (kept, or parked under excluded/).
    private func framesAndLabelsOnDisk() -> [String] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { ["jpg", "jpeg", "png", "txt"].contains($0.pathExtension.lowercased()) }.map(\.lastPathComponent).sorted()
    }

    private var ledgerExists: Bool { FileManager.default.fileExists(atPath: ExposureLog.url(in: root).path) }

    /// What a registered-only job and session say: `l` and its alias `a` are of the final-test closure, `h` of
    /// the rest of the withheld one.
    private func reason(_ card: String) -> String {
        SamplerModel.registeredOnlyReason(card: card, standing: card == "h" ? "withheld — a lineage or legacy holdout, or an alias of one (D-017)"
                                                                            : "reserved as final_test (D-002)")
    }

    // MARK: - A withheld card is registered, and no model runs

    func testRegisteringAWithheldCardMakesItsSessionAndRunsNoModel() async throws {
        let videos = try await makeProject()
        let runs = Runs()
        let sampler = makeSampler(runs)
        let cut = [CutRange(start: 0.2, end: 0.4)]
        let started = Date()
        // As the Projects tab queues a card's clip: the cut file, under the card's name.
        for name in ["l", "a", "h"] {
            sampler.enqueueClip(try XCTUnwrap(videos[name]), sessionName: name, split: "val", framesPerRally: 4, cuts: name == "l" ? cut : nil)
        }
        try await drain(sampler)

        for job in sampler.queue {
            XCTAssertEqual(job.state, .done(reason(try XCTUnwrap(job.sessionName))), "\(job.sessionName ?? "?"): the job says why it has no frames")
        }
        let made = try sessions()
        XCTAssertEqual(made.keys.sorted(), ["a", "h", "l"], "the lineage holdout, its alias and the legacy holdout each have their session")
        for (name, session) in made {
            XCTAssertEqual(session.sourcePath, videos[name]?.path, name)
            XCTAssertEqual(session.split, "val", name)
            XCTAssertGreaterThanOrEqual(session.addedAt.timeIntervalSince(started), -1, name)
            XCTAssertTrue(session.frames.isEmpty, "\(name): no still was pulled")
            XCTAssertEqual(session.notSampled, reason(name), "\(name): the session says it was not sampled")
            XCTAssertNil(session.tracks, name)
        }
        XCTAssertEqual(made["l"]?.cuts, cut, "the cut ranges it was queued with stay on it")
        XCTAssertEqual(runs.pipeline, 0, "the pipeline never ran over a withheld recording")
        XCTAssertEqual(runs.detectors, 0, "no pre-label detector was made")
        XCTAssertEqual(runs.stills, 0, "nothing was pre-labeled")
        XCTAssertEqual(framesAndLabelsOnDisk(), [], "no still and no label file was written")
        XCTAssertFalse(ledgerExists, "no model ran, so no row claims a run")
        XCTAssertNil(sampler.currentSession, "nothing to review is opened")
        XCTAssertTrue(sampler.status.contains("not sampled"), sampler.status)
    }

    func testAdmissionIsDecidedByTheCardNotByTheCaller() async throws {
        let videos = try await makeProject()
        let l = try XCTUnwrap(videos["l"]), t = try XCTUnwrap(videos["t"])
        for name in ["l", "a", "h"] {
            XCTAssertEqual(try SamplerModel.admission(of: videos[name]!, card: name, hasSession: false, root: root), .registeredOnly(reason(name)), name)
            // The card has its session: queued again is sampling it again, refused — nothing replaces the session.
            XCTAssertThrowsError(try SamplerModel.admission(of: videos[name]!, card: name, hasSession: true, root: root), name) { error in
                guard case SamplerModel.IngestError.withheld(let why) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(why, try? SamplerModel.ingestRefusal(ofClip: name, root: self.root))
            }
        }
        XCTAssertEqual(try SamplerModel.admission(of: t, card: "t", hasSession: false, root: root), .sampled)
        XCTAssertEqual(try SamplerModel.admission(of: t, card: "t", hasSession: true, root: root), .sampled, "an ordinary card is sampled again")
        // The same withheld file with no card of its own to be registered for: refused, not registered.
        XCTAssertThrowsError(try SamplerModel.admission(of: l, card: nil, hasSession: false, root: root)) { error in
            guard case SamplerModel.IngestError.withheld(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("reserved as final_test"), why)
        }
        XCTAssertThrowsError(try SamplerModel.admission(of: l, card: "t", hasSession: false, root: root), "queued under an ordinary card's name")
        XCTAssertThrowsError(try SamplerModel.admission(of: videos["h"]!, card: nil, hasSession: false, root: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("withheld"), error.localizedDescription)
        }
        // A file the project does not know, and a dataset that is no project: sampled as always.
        let unknown = try await video("new", seed: 9)
        XCTAssertEqual(try SamplerModel.admission(of: unknown, card: nil, hasSession: false, root: root), .sampled)
        XCTAssertEqual(try SamplerModel.admission(of: l, card: nil, hasSession: false, root: base.appendingPathComponent("no-project")), .sampled)
    }

    // MARK: - Every other card is sampled as before

    func testRegisteringAnOrdinaryCardStillRunsThePipelineAndPreLabels() async throws {
        let videos = try await makeProject()
        let runs = Runs()
        let sampler = makeSampler(runs)
        sampler.enqueueClip(try XCTUnwrap(videos["t"]), sessionName: "t", split: "train", framesPerRally: 4)
        try await drain(sampler)

        guard case .done(let text) = try XCTUnwrap(sampler.queue.first).state else { return XCTFail("\(String(describing: sampler.queue.first?.state))") }
        let session = try XCTUnwrap(try sessions()["t"])
        XCTAssertEqual(text, "\(session.frames.count) frames · \(session.boxCount) boxes")
        XCTAssertEqual(runs.pipeline, 1, "the pipeline ran over the recording, once")
        XCTAssertEqual(runs.detectors, 1, "one pre-label detector was made")
        XCTAssertFalse(session.frames.isEmpty, "stills were pulled")
        XCTAssertGreaterThanOrEqual(runs.stills, session.frames.count, "every still kept was pre-labeled")
        XCTAssertNil(session.notSampled)
        XCTAssertTrue(session.frames.allSatisfy { !$0.reviewed && $0.boxes.map(\.confidence) == [0.6] }, "each still carries the detector's box, unreviewed")
        let store = DatasetStore(root: root)
        XCTAssertTrue(session.frames.allSatisfy { FileManager.default.fileExists(atPath: store.currentImageURL(for: $0).path) }, "and is on disk")
    }

    // MARK: - A withheld recording coming in any other way is refused

    func testAWithheldRecordingDroppedOrQueuedForAnotherCardIsRefused() async throws {
        let videos = try await makeProject()
        let runs = Runs()
        let sampler = makeSampler(runs)
        let lineage = try copy(of: try XCTUnwrap(videos["l"]), named: "renamed copy")
        let legacy = try copy(of: try XCTUnwrap(videos["h"]), named: "another copy")
        sampler.enqueue([lineage, legacy])                                                         // dropped on the Sampler
        sampler.enqueueClip(lineage, sessionName: "t", split: "train", framesPerRally: 4)          // queued for a card that is not its own
        sampler.enqueueClip(try XCTUnwrap(videos["l"]), sessionName: "t_v2", split: "train", framesPerRally: 4)
        try await drain(sampler)

        let reasons: [String] = sampler.queue.map { if case .failed(let why) = $0.state { return why } else { return "not refused: \($0.state)" } }
        XCTAssertEqual(reasons.count, 4)
        XCTAssertTrue(reasons[0].contains("is l, reserved as final_test (D-002) — not sampled"), reasons[0])
        XCTAssertTrue(reasons[1].contains("is h, withheld") && reasons[1].contains("not sampled"), reasons[1])
        XCTAssertTrue(reasons[2].contains("is l, reserved as final_test"), reasons[2])
        XCTAssertTrue(reasons[3].contains("is l, reserved as final_test"), reasons[3])
        XCTAssertTrue(try sessions().isEmpty, "no session was made for any of them")
        XCTAssertTrue(runs.none, "neither model was reached")
        XCTAssertEqual(framesAndLabelsOnDisk(), [])
        XCTAssertFalse(ledgerExists)
    }

    // MARK: - Fails closed

    func testNothingIsRegisteredOrSampledWhenTheProjectOrTheReservationsCantBeRead() async throws {
        let videos = try await makeProject()
        let l = try XCTUnwrap(videos["l"]), t = try XCTUnwrap(videos["t"])
        let runs = Runs()
        let sampler = makeSampler(runs)
        let projectFile = root.appendingPathComponent("project.json")
        let project = try Data(contentsOf: projectFile)

        // project.json unreadable: which cards alias a withheld one is unknown.
        try Data("{not json".utf8).write(to: projectFile)
        for (video, card) in [(l, "l"), (t, "t")] {
            XCTAssertThrowsError(try SamplerModel.admission(of: video, card: card, hasSession: false, root: root), card) {
                XCTAssertTrue($0 is ReservedVideos.ProjectUnreadable, "\($0)")
            }
            sampler.enqueueClip(video, sessionName: card, split: "train", framesPerRally: 4)
        }
        try await drain(sampler)
        for job in sampler.queue {
            guard case .failed(let why) = job.state else { XCTFail("\(job.sessionName ?? "?"): \(job.state)"); continue }
            XCTAssertTrue(why.contains("project.json"), why)
        }

        // validation.json truncated beside a readable project: the reservations are unknown.
        try project.write(to: projectFile)
        try writeValidation(#"{"tune":[],"holdout":["h"],"finalTest":[],"lineageHoldout":["l"]"#)
        for (video, card) in [(l, "l"), (t, "t")] {
            XCTAssertThrowsError(try SamplerModel.admission(of: video, card: card, hasSession: false, root: root), card)
            sampler.enqueueClip(video, sessionName: card, split: "train", framesPerRally: 4)
        }
        try await drain(sampler)
        XCTAssertEqual(sampler.queue.count, 4)
        XCTAssertTrue(sampler.queue.allSatisfy { if case .failed = $0.state { return true } else { return false } })

        XCTAssertTrue(try DatasetStore(root: root).loadSessionsStrict().isEmpty, "no session, sampled or registered")
        XCTAssertTrue(runs.none, "neither model was reached")
        XCTAssertEqual(framesAndLabelsOnDisk(), [])
    }

    func testAWithheldCardWhoseFileIsNoVideoIsNotRegistered() async throws {
        let videos = try await makeProject()
        let runs = Runs()
        let sampler = makeSampler(runs)
        let l = try XCTUnwrap(videos["l"])
        try Data("not a video".utf8).write(to: l)
        sampler.enqueueClip(l, sessionName: "l", split: "train", framesPerRally: 4)
        try await drain(sampler)
        XCTAssertEqual(sampler.queue.first?.state, .failed("Couldn't read the video."))
        XCTAssertTrue(try sessions().isEmpty)
        XCTAssertTrue(runs.none)
    }

    // MARK: - The Projects tab

    func testTheProjectsTabRegistersAWithheldCardAndNeverReplacesItsSessionByARePull() async throws {
        _ = try await makeProject()
        let runs = Runs()
        let sampler = SamplerModel(defaults: defaults, root: base.appendingPathComponent("empty"), models: models(runs))
        let projects = ProjectsModel(sampler: sampler, defaults: defaults)
        projects.open(root)
        XCTAssertEqual(projects.progress(ofVideo: "l"), .notStarted)

        // The card has no session: it is given one, without a model.
        XCTAssertTrue(projects.repull("l", in: "l"))
        try await drain(sampler)
        XCTAssertEqual(projects.progress(ofVideo: "l"), .registered(reason("l")))
        XCTAssertEqual(projects.progress(of: try XCTUnwrap(projects.project?.clips.first { $0.id == "l" })), .registered(reason("l")))
        XCTAssertTrue(runs.none)

        // The owner labels it by hand; a re-pull then keeps the session as it is — sampling it is refused.
        sampler.setRalliesMarked(true, session: "l")
        let file = root.appendingPathComponent("sessions/l.json")
        let before = try Data(contentsOf: file)
        XCTAssertFalse(projects.repull("l", in: "l"))
        XCTAssertTrue(projects.status.hasPrefix("⛔ l is reserved as final_test (D-002) — not sampled"), projects.status)
        try await drain(sampler)
        XCTAssertEqual(try Data(contentsOf: file), before, "the session is untouched")
        XCTAssertEqual(try sessions()["l"]?.ralliesMarked, true)
        XCTAssertEqual(sampler.queue.count, 1, "nothing was queued")
        XCTAssertTrue(runs.none)

        // An ordinary card on the same path is sampled.
        XCTAssertTrue(projects.repull("t", in: "t"))
        try await drain(sampler)
        guard case .pulled(let frames, let reviewed) = projects.progress(ofVideo: "t") else { return XCTFail("\(projects.progress(ofVideo: "t"))") }
        XCTAssertGreaterThan(frames, 0)
        XCTAssertEqual(reviewed, 0)
        XCTAssertEqual(runs.pipeline, 1)
        XCTAssertEqual(runs.detectors, 1)

        // Reservations that can't be read: the session a re-pull would have deleted first is kept.
        let sampled = try Data(contentsOf: root.appendingPathComponent("sessions/t.json"))
        try writeValidation(#"{"tune":[],"holdout":["h"]"#)
        XCTAssertFalse(projects.repull("t", in: "t"))
        XCTAssertTrue(projects.status.hasPrefix("⛔ t: "), projects.status)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sessions/t.json")), sampled)
        XCTAssertEqual(runs.pipeline, 1)
    }

    func testASessionSavedBeforeThisChangeReadsAsSampled() throws {
        let json = #"{"name":"old","sourcePath":"/f/old.mp4","split":"train","addedAt":"2026-10-20T00:00:00Z","frames":[]}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(VideoSession.self, from: Data(json.utf8)).notSampled)
    }
}
