//
//  FlywheelCaptureServiceTests.swift
//  BumpSetCutTests
//
//  Unit tests for the data-flywheel capture service: evidence scoping, the
//  upload-payload mapping, and drain behavior (success removes the local frames,
//  failure keeps them, opt-out short-circuits).
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

    private func makeContribution(frameFileNames: [String]) -> FlywheelContribution {
        FlywheelContribution(
            id: UUID(),
            videoId: UUID(),
            rallyIndex: 0,
            startTime: 1.0,
            endTime: 3.0,
            trigger: .lowScore,
            userReason: nil,
            frameFileNames: frameFileNames,
            flagEvents: [FlywheelFlagEvent(rallyIndex: 0, trigger: "low_score", reason: nil,
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

    /// Seed a staged contribution (index + dummy frame files) so a fresh service loads it.
    @discardableResult
    private func seedStaged(frameFileNames: [String]) throws -> FlywheelContribution {
        let contribution = makeContribution(frameFileNames: frameFileNames)
        for name in frameFileNames {
            FileManager.default.createFile(
                atPath: stagingDir.appendingPathComponent(name).path,
                contents: Data("dummy-jpeg".utf8)
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([contribution])
        try data.write(to: indexURL, options: .atomic)
        return contribution
    }

    private func framesExist(_ names: [String]) -> Bool {
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

    // MARK: - Upload payload mapping

    func testRPCParamsMapContributionFields() {
        let contribution = makeContribution(frameFileNames: ["a.jpg", "b.jpg"])
        let params = FlywheelFlagRPCParams(
            contribution: contribution, frameUrls: ["u/x/f000.jpg", "u/x/f001.jpg"])

        XCTAssertEqual(params.pLocalVideoId, contribution.videoId)
        XCTAssertEqual(params.pRallyIndex, 0)
        XCTAssertEqual(params.pFrameUrls, ["u/x/f000.jpg", "u/x/f001.jpg"])
        XCTAssertEqual(params.pTrigger, "low_score")
        XCTAssertEqual(params.pRallyConfidence, 0.3, accuracy: 0.0001)
        XCTAssertEqual(params.pEvents.count, 1)
        XCTAssertEqual(params.pEvents.first?.rallyIndex, 0)
    }

    // MARK: - Drain

    func testDrainSuccessRemovesFramesAndCountsContribution() async throws {
        AppSettings.shared.enableDataFlywheel = true
        let frames = ["\(UUID().uuidString)_f00.jpg", "\(UUID().uuidString)_f01.jpg"]
        try seedStaged(frameFileNames: frames)

        let service = FlywheelCaptureService()
        XCTAssertEqual(service.pendingCount, 1)

        let client = MockFlywheelClient(shouldSucceed: true)
        let baseline = service.lifetimeContributedCount
        await service.drain(using: client)

        XCTAssertEqual(client.submitCount, 1)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertEqual(service.lifetimeContributedCount, baseline + 1)
        XCTAssertFalse(framesExist(frames))
    }

    func testDrainFailureKeepsFramesStaged() async throws {
        AppSettings.shared.enableDataFlywheel = true
        let frames = ["\(UUID().uuidString)_f00.jpg"]
        try seedStaged(frameFileNames: frames)

        let service = FlywheelCaptureService()
        let client = MockFlywheelClient(shouldSucceed: false)
        await service.drain(using: client)

        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertTrue(framesExist(frames))
    }

    func testDrainShortCircuitsWhenOptedOut() async throws {
        AppSettings.shared.enableDataFlywheel = false
        let frames = ["\(UUID().uuidString)_f00.jpg"]
        try seedStaged(frameFileNames: frames)

        let service = FlywheelCaptureService()
        let client = MockFlywheelClient(shouldSucceed: true)
        await service.drain(using: client)

        XCTAssertEqual(client.submitCount, 0)
        XCTAssertEqual(service.pendingCount, 1)
    }

    func testClearPendingRemovesEverything() async throws {
        AppSettings.shared.enableDataFlywheel = true
        let frames = ["\(UUID().uuidString)_f00.jpg", "\(UUID().uuidString)_f01.jpg"]
        try seedStaged(frameFileNames: frames)

        let service = FlywheelCaptureService()
        service.clearPending()

        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertFalse(framesExist(frames))
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

    func submitFlywheelContribution(_ contribution: FlywheelContribution, frameURLs: [URL], progress: @escaping @Sendable (Double) -> Void) async throws {
        submitCount += 1
        if !shouldSucceed { throw APIError.networkUnavailable }
    }
}
