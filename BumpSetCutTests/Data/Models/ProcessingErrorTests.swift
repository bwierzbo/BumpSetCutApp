//
//  ProcessingErrorTests.swift
//  BumpSetCutTests
//

import XCTest
@testable import BumpSetCut

final class ProcessingErrorTests: XCTestCase {

    // MARK: - Error Case Distinctness

    func testAllErrorCasesAreDistinct() {
        let errors: [ProcessingError] = [
            .modelNotFound,
            .noVideoTrack,
            .noRalliesDetected,
            .assetReaderFailed(nil),
            .exportSessionFailed("test"),
            .compositionFailed,
            .metadataStoreUnavailable,
            .exportCancelled
        ]

        // Each error should have a non-empty description
        for error in errors {
            XCTAssertFalse(
                error.errorDescription?.isEmpty ?? true,
                "\(error) should have a non-empty errorDescription"
            )
        }

        // All descriptions should be unique
        let descriptions = errors.compactMap(\.errorDescription)
        let uniqueDescriptions = Set(descriptions)
        XCTAssertEqual(descriptions.count, uniqueDescriptions.count, "All error descriptions should be unique")
    }

    // MARK: - LocalizedError Conformance

    func testModelNotFoundDescription() {
        let error = ProcessingError.modelNotFound
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("model") ?? false)
    }

    func testNoVideoTrackDescription() {
        let error = ProcessingError.noVideoTrack
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("video") ?? false)
    }

    func testNoRalliesDetectedDescription() {
        let error = ProcessingError.noRalliesDetected
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("rall") ?? false)
    }

    func testAssetReaderFailedWithUnderlyingError() {
        let underlying = NSError(domain: "AVFoundation", code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "Cannot open"
        ])
        let error = ProcessingError.assetReaderFailed(underlying)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Cannot open") ?? false)
    }

    func testAssetReaderFailedWithNilError() {
        let error = ProcessingError.assetReaderFailed(nil)
        XCTAssertNotNil(error.errorDescription)
        // Should still produce a meaningful message even without underlying error
    }

    func testExportSessionFailedWithReason() {
        let error = ProcessingError.exportSessionFailed("Output file already exists")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Output file already exists") ?? false)
    }

    func testCompositionFailedDescription() {
        let error = ProcessingError.compositionFailed
        XCTAssertNotNil(error.errorDescription)
    }

    func testMetadataStoreUnavailableDescription() {
        let error = ProcessingError.metadataStoreUnavailable
        XCTAssertNotNil(error.errorDescription)
    }

    func testExportCancelledDescription() {
        let error = ProcessingError.exportCancelled
        XCTAssertNotNil(error.errorDescription)
    }

    // MARK: - Legacy Alias

    func testLegacyExportFailedAlias() {
        // The static let should still compile and produce an exportSessionFailed case
        let legacyError = ProcessingError.exportFailed
        XCTAssertNotNil(legacyError.errorDescription)
    }
}
