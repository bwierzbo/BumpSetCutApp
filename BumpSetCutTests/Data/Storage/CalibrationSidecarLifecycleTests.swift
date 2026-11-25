//
//  CalibrationSidecarLifecycleTests.swift
//  BumpSetCutTests
//
//  A video's court and net calibration lives with its other sidecars: it goes when the
//  video is deleted or orphaned, and stays when the video is processed again.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class CalibrationSidecarLifecycleTests: XCTestCase {
    private var dir: URL!
    private var metadata: MetadataStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CalibrationSidecarLifecycleTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = dir
        metadata = MetadataStore()
    }

    override func tearDownWithError() throws {
        StorageManager.storageDirectoryOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func calibrate(_ id: UUID) throws -> CourtNetCalibrationStore {
        var binding = CalibrationFixtures.binding
        binding.recordingId = id.uuidString
        var file = CourtNetCalibrationFile.new(for: binding)
        try file.saveDraft(CalibrationFixtures.net, of: \.net, segment: 0, startedFrom: CourtNetCalibrationV1.manual, baseline: nil)
        try file.confirm(\.net, segment: 0, by: "tester", tool: "test", now: CalibrationFixtures.day)
        let store = CourtNetCalibrationStore.app
        try store.save(file)
        return store
    }

    func testTheAppKeepsCalibrationsWithTheVideosSidecars() throws {
        let id = UUID()
        let store = try calibrate(id)
        XCTAssertEqual(store.directory, metadata.metadataDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.metadataDirectory.appendingPathComponent("\(id.uuidString)_calibration.json").path))
        XCTAssertFalse(metadata.getAllMetadataVideoIds().contains(id), "a calibration is not processing metadata")
    }

    func testReprocessingKeepsTheCalibration() throws {
        let id = UUID()
        let store = try calibrate(id)
        metadata.deleteSidecarsForReprocess(videoId: id)
        XCTAssertNotNil(try store.load(id.uuidString)?.confirmed(\.net, at: 1))
    }

    func testDeletingTheVideoRemovesItsCalibrationAndOnlyIts() throws {
        let (gone, kept) = (UUID(), UUID())
        let store = try calibrate(gone)
        _ = try calibrate(kept)
        metadata.deleteAllSidecars(for: gone)
        XCTAssertNil(try store.load(gone.uuidString))
        XCTAssertNotNil(try store.load(kept.uuidString))
        XCTAssertEqual(metadata.sweepOrphanedSidecars(keeping: []), 1)
        XCTAssertNil(try store.load(kept.uuidString))
    }
}
