//
//  FlywheelCaptureServiceTests.swift
//  BumpSetCutTests
//
//  Unit tests for the data-flywheel capture service: evidence scoping, the
//  upload-payload mapping, and drain behavior (success removes the local clip,
//  failure keeps it, opt-out short-circuits).
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

    private func makeContribution(clipFileName: String) -> FlywheelContribution {
        FlywheelContribution(
            id: UUID(),
            videoId: UUID(),
            rallyIndex: 0,
            startTime: 1.0,
            endTime: 3.0,
            trigger: .lowScore,
            userReason: nil,
            clipFileName: clipFileName,
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

    /// Seed a staged contribution (index + dummy clip) so a fresh service loads it.
    private func seedStaged(clipFileName: String) throws -> FlywheelContribution {
        let contribution = makeContribution(clipFileName: clipFileName)
        FileManager.default.createFile(
            atPath: stagingDir.appendingPathComponent(clipFileName).path,
            contents: Data("dummy".utf8)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([contribution])
        try data.write(to: indexURL, options: .atomic)
        return contribution
    }

    // MARK: - scopedEvidence

    func testScopedEvidenceKeepsOnlyFramesInRallyWindows() {
        let frames: [VideoProcessor.FrameEvidence] = [1.0, 5.0, 9.0].map { t in
            VideoProcessor.FrameEvidence(
                time: t,
                hasBall: true,
                isProjectile: t == 5.0,
                detections: [VideoProcessor.BallDetection(
                    bbox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), confidence: 0.7)],
                trackPoint: CGPoint(x: 0.5, y: 0.5),
                rSquared: 0.9,
                gravitySignature: 0.8,
                movementType: .airborne,
                rejectionReason: nil,
                candidates: []
            )
        }
        let segment = RallySegment(
            startTime: CMTime(seconds: 4.5, preferredTimescale: 600),
            endTime: CMTime(seconds: 5.5, preferredTimescale: 600),
            confidence: 0.3, quality: 0.2, detectionCount: 1, averageTrajectoryLength: 1)

        let scoped = FlywheelCaptureService.scopedEvidence(frames, segments: [segment], margin: 0.25)

        XCTAssertEqual(scoped.count, 1)
        let kept = try? XCTUnwrap(scoped.first)
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
            movementType: nil, rejectionReason: "no motion", candidates: [])
        XCTAssertTrue(FlywheelCaptureService.scopedEvidence([frame], segments: []).isEmpty)
    }

    // MARK: - Upload payload mapping

    func testUploadPayloadMapsContributionFields() {
        let contribution = makeContribution(clipFileName: "x.mp4")
        let upload = FlywheelContributionUpload(
            userId: "user-123", contribution: contribution, clipUrl: "user-123/x.mp4")

        XCTAssertEqual(upload.userId, "user-123")
        XCTAssertEqual(upload.localVideoId, contribution.videoId)
        XCTAssertEqual(upload.rallyIndex, 0)
        XCTAssertEqual(upload.clipUrl, "user-123/x.mp4")
        XCTAssertEqual(upload.triggerType, "low_score")
        XCTAssertEqual(upload.rallyConfidence, 0.3, accuracy: 0.0001)
    }

    // MARK: - Drain

    func testDrainSuccessRemovesClipAndCountsContribution() async throws {
        AppSettings.shared.enableDataFlywheel = true
        let clipName = "\(UUID().uuidString).mp4"
        _ = try seedStaged(clipFileName: clipName)

        let service = FlywheelCaptureService()
        XCTAssertEqual(service.pendingCount, 1)

        let client = MockFlywheelClient(shouldSucceed: true)
        let baseline = service.lifetimeContributedCount
        await service.drain(using: client)

        XCTAssertEqual(client.submitCount, 1)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertEqual(service.lifetimeContributedCount, baseline + 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stagingDir.appendingPathComponent(clipName).path))
    }

    func testDrainFailureKeepsClipStaged() async throws {
        AppSettings.shared.enableDataFlywheel = true
        let clipName = "\(UUID().uuidString).mp4"
        _ = try seedStaged(clipFileName: clipName)

        let service = FlywheelCaptureService()
        let client = MockFlywheelClient(shouldSucceed: false)
        await service.drain(using: client)

        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stagingDir.appendingPathComponent(clipName).path))
    }

    func testDrainShortCircuitsWhenOptedOut() async throws {
        AppSettings.shared.enableDataFlywheel = false
        let clipName = "\(UUID().uuidString).mp4"
        _ = try seedStaged(clipFileName: clipName)

        let service = FlywheelCaptureService()
        let client = MockFlywheelClient(shouldSucceed: true)
        await service.drain(using: client)

        XCTAssertEqual(client.submitCount, 0)
        XCTAssertEqual(service.pendingCount, 1)
    }

    func testClearPendingRemovesEverything() async throws {
        AppSettings.shared.enableDataFlywheel = true
        let clipName = "\(UUID().uuidString).mp4"
        _ = try seedStaged(clipFileName: clipName)

        let service = FlywheelCaptureService()
        service.clearPending()

        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stagingDir.appendingPathComponent(clipName).path))
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

    func submitFlywheelContribution(_ contribution: FlywheelContribution, clipURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        submitCount += 1
        if !shouldSucceed { throw APIError.networkUnavailable }
    }
}
