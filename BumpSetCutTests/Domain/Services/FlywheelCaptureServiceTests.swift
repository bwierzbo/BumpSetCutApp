//
//  FlywheelCaptureServiceTests.swift
//  BumpSetCutTests
//
//  Unit tests for the data-flywheel capture service: evidence scoping, the
//  clip windows, the upload-payload mapping, and drain behavior (success
//  removes the local clips, failure keeps them, opt-out short-circuits).
//

import XCTest
import CoreGraphics
import CoreMedia
@testable import BumpSetCut

@MainActor
final class FlywheelCaptureServiceTests: XCTestCase {

    // MARK: - Fixtures

    private var stagingDir: URL {
        StorageManager.getPersistentStorageDirectory()
            .appendingPathComponent("ProcessedMetadata", isDirectory: true)
            .appendingPathComponent("Flywheel", isDirectory: true)
    }

    private var indexURL: URL { stagingDir.appendingPathComponent("flywheel_index.json") }

    override func setUp() async throws {
        try? FileManager.default.removeItem(at: stagingDir)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: stagingDir)
        AppSettings.shared.enableDataFlywheel = false
    }

    private func makeContribution(clipFileNames: [String]) -> FlywheelContribution {
        FlywheelContribution(
            id: UUID(),
            videoId: UUID(),
            rallyIndex: 0,
            startTime: 1.0,
            endTime: 3.0,
            trigger: .processed,
            userReason: nil,
            clips: clipFileNames.enumerated().map { i, name in
                FlywheelClip(fileName: name, window: FlywheelClipWindow(start: Double(i) * 10, end: Double(i) * 10 + 5))
            },
            flagEvents: [FlywheelFlagEvent(rallyIndex: 0, trigger: "processed", reason: nil,
                                           at: Date(timeIntervalSince1970: 1_700_000_000))],
            evidence: [],
            rallyConfidence: 0.3,
            rallyQuality: 0.2,
            appVersion: "test",
            osVersion: "test",
            deviceModel: "test",
            consentVersion: FlywheelConsent.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Seed a staged contribution (index + dummy clip files) so a fresh service loads it.
    @discardableResult
    private func seedStaged(clipFileNames: [String]) throws -> FlywheelContribution {
        let contribution = makeContribution(clipFileNames: clipFileNames)
        for name in clipFileNames {
            FileManager.default.createFile(
                atPath: stagingDir.appendingPathComponent(name).path,
                contents: Data("dummy-mp4".utf8)
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([contribution])
        try data.write(to: indexURL, options: .atomic)
        return contribution
    }

    private func clipsExist(_ names: [String]) -> Bool {
        names.allSatisfy { FileManager.default.fileExists(atPath: stagingDir.appendingPathComponent($0).path) }
    }

    // MARK: - scopedEvidence

    func testScopedEvidenceKeepsOnlyFramesInRallyWindows() {
        let frames: [VideoProcessor.FrameEvidence] = [1.0, 5.0, 9.0].map { t in
            VideoProcessor.FrameEvidence(
                time: t,
                hasBall: true,
                isProjectile: t == 5.0,
                detections: [VideoProcessor.BallDetection(
                    bbox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), confidence: 0.7,
                    isOffCourt: false)],
                trackPoint: CGPoint(x: 0.5, y: 0.5),
                rSquared: 0.9,
                gravitySignature: 0.8,
                movementType: .airborne,
                rejectionReason: nil,
                candidates: [],
                detectedNet: nil
            )
        }
        let segment = RallySegment(
            startTime: CMTime(seconds: 4.5, preferredTimescale: 600),
            endTime: CMTime(seconds: 5.5, preferredTimescale: 600),
            confidence: 0.3, quality: 0.2, detectionCount: 1, averageTrajectoryLength: 1)

        let scoped = FlywheelCaptureService.scopedEvidence(frames, segments: [segment], margin: 0.25)

        XCTAssertEqual(scoped.count, 1)
        let kept = scoped.first
        XCTAssertEqual(kept?.time, 5.0)
        XCTAssertTrue(kept?.isProjectile ?? false)
        XCTAssertEqual(kept?.detections.count, 1)
        XCTAssertEqual(kept?.detections.first?.confidence ?? 0, 0.7, accuracy: 0.0001)
        XCTAssertEqual(kept?.movementType, "airborne")
    }

    func testScopedEvidenceEmptyWhenNoSegments() {
        let frame = VideoProcessor.FrameEvidence(
            time: 2.0, hasBall: true, isProjectile: false, detections: [],
            trackPoint: nil, rSquared: nil, gravitySignature: nil,
            movementType: nil, rejectionReason: "no motion", candidates: [], detectedNet: nil)
        XCTAssertTrue(FlywheelCaptureService.scopedEvidence([frame], segments: []).isEmpty)
    }

    // MARK: - Clip windows

    private func segment(_ start: Double, _ end: Double) -> RallySegment {
        RallySegment(startTimeSeconds: start, endTimeSeconds: end, confidence: 1, quality: 1,
                     detectionCount: 1, averageTrajectoryLength: 1)
    }

    func testRallyWindowsPadAndMergeOverlaps() {
        let windows = FlywheelCaptureService.rallyWindows(
            [segment(30, 40), segment(1, 8), segment(10, 15)], padding: 2)
        // 1–8 and 10–15 overlap once padded; nothing starts before 0.
        XCTAssertEqual(windows, [FlywheelClipWindow(start: 0, end: 17), FlywheelClipWindow(start: 28, end: 42)])
    }

    func testSamplesSpreadAcrossVideo() {
        let windows = FlywheelCaptureService.samples(of: 120, count: 3, length: 15)
        XCTAssertEqual(windows.map(\.start), [18.75, 52.5, 86.25])
        XCTAssertTrue(windows.allSatisfy { $0.end - $0.start == 15 })
        XCTAssertEqual(FlywheelCaptureService.samples(of: 30, count: 3, length: 15),
                       [FlywheelClipWindow(start: 0, end: 30)])
    }

    // MARK: - Upload payload mapping

    func testRPCParamsMapContributionFields() {
        let contribution = makeContribution(clipFileNames: ["a.mp4", "b.mp4"])
        let params = FlywheelFlagRPCParams(
            contribution: contribution, clipUrls: ["u/x/clip_00.mp4", "u/x/clip_01.mp4"])

        XCTAssertEqual(params.pLocalVideoId, contribution.videoId)
        XCTAssertEqual(params.pRallyIndex, 0)
        XCTAssertEqual(params.pClipUrls, ["u/x/clip_00.mp4", "u/x/clip_01.mp4"])
        XCTAssertEqual(params.pClipWindows, [FlywheelClipWindow(start: 0, end: 5), FlywheelClipWindow(start: 10, end: 15)])
        XCTAssertEqual(params.pTrigger, "processed")
        XCTAssertEqual(params.pRallyConfidence, 0.3, accuracy: 0.0001)
        XCTAssertEqual(params.pEvents.count, 1)
        XCTAssertEqual(params.pEvents.first?.rallyIndex, 0)
    }

    // MARK: - Drain

    func testDrainSuccessRemovesClipsAndCountsContribution() async throws {
        AppSettings.shared.enableDataFlywheel = true
        let clips = ["\(UUID().uuidString)_clip_00.mp4", "\(UUID().uuidString)_clip_01.mp4"]
        try seedStaged(clipFileNames: clips)

        let service = FlywheelCaptureService()
        XCTAssertEqual(service.pendingCount, 1)

        let client = MockFlywheelClient(shouldSucceed: true)
        let baseline = service.lifetimeContributedCount
        await service.drain(using: client)

        XCTAssertEqual(client.submitCount, 1)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertEqual(service.lifetimeContributedCount, baseline + 1)
        XCTAssertFalse(clipsExist(clips))
    }

    func testDrainFailureKeepsClipsStaged() async throws {
        AppSettings.shared.enableDataFlywheel = true
        let clips = ["\(UUID().uuidString)_clip_00.mp4"]
        try seedStaged(clipFileNames: clips)

        let service = FlywheelCaptureService()
        let client = MockFlywheelClient(shouldSucceed: false)
        await service.drain(using: client)

        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertTrue(clipsExist(clips))
    }

    func testDrainShortCircuitsWhenOptedOut() async throws {
        AppSettings.shared.enableDataFlywheel = false
        let clips = ["\(UUID().uuidString)_clip_00.mp4"]
        try seedStaged(clipFileNames: clips)

        let service = FlywheelCaptureService()
        let client = MockFlywheelClient(shouldSucceed: true)
        await service.drain(using: client)

        XCTAssertEqual(client.submitCount, 0)
        XCTAssertEqual(service.pendingCount, 1)
    }

    func testClearPendingRemovesEverything() async throws {
        AppSettings.shared.enableDataFlywheel = true
        let clips = ["\(UUID().uuidString)_clip_00.mp4", "\(UUID().uuidString)_clip_01.mp4"]
        try seedStaged(clipFileNames: clips)

        let service = FlywheelCaptureService()
        service.clearPending()

        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertFalse(clipsExist(clips))
    }
}

// MARK: - Mock client

private final class MockFlywheelClient: APIClient, @unchecked Sendable {
    nonisolated(unsafe) var shouldSucceed: Bool
    nonisolated(unsafe) var submitCount = 0

    init(shouldSucceed: Bool) { self.shouldSucceed = shouldSucceed }

    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }

    func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw APIError.serverError(statusCode: 501, message: "not used")
    }

    func submitFlywheelContribution(_ contribution: FlywheelContribution, clipURLs: [URL], progress: @escaping @Sendable (Double) -> Void) async throws {
        submitCount += 1
        if !shouldSucceed { throw APIError.networkUnavailable }
    }
}
